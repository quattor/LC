#+##############################################################################
#                                                                              #
# File: Process.pm                                                             #
#                                                                              #
# Description: high-level object-oriented interface to manipulate processes    #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Process;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.60 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(execute output toutput run trun daemonise
		pidcheck pidset pidsetup pidtouch cwait cfork sendmail);

#
# used modules
#

use LC::Exception qw(throw_error throw_warning SUCCESS);
use LC::File qw(SYSBUFSIZE path_for_open file_contents);
use LC::Stat qw(:ST);
use LC::Util qw(new_symbol timestamp unctrl);
use POSIX qw(:errno_h :sys_wait_h); # we need a few POSIX constants
use sigtrap qw(die normal-signals); # so that ^C and such trigger END()

#+++############################################################################
#                                                                              #
# constants                                                                    #
#                                                                              #
#---############################################################################

#
# process states
#

use constant IS_NEW   => 0;	# object created but process not started
use constant IS_ALIVE => 1;	# process started and alive
use constant IS_DEAD  => 2;	# started process died

#+++############################################################################
#                                                                              #
# variables                                                                    #
#                                                                              #
#---############################################################################

#
# public variables
#

our(
    $Tag,		# tag used by children when they badly die
    $Debug,		# default debug level for all children
);

#
# private variables
#

our(
    %_Family,		# all our children stored by parent and child pids
    $_PidStored,	# pid stored in the pid path
    $_PidPath,		# pid path to handle
    %_StartTime,	# start time for the controlled children
);

#+++############################################################################
#                                                                              #
# class constructor and destructor                                             #
#                                                                              #
#---############################################################################

#
# class constructor
#

BEGIN {
    # public variables
    $Tag = "(proc)";
    $Debug = 0;
    # private variables
    %_Family = ();
}

#
# class destructor
#

END {
    # cleanup the pid file
    if ($_PidPath and $_PidStored and $_PidStored == $$) {
	unlink($_PidPath) if -e $_PidPath;
    }
    # gently kill all my mortal children...
    return unless $_Family{$$};
    grep($_->stop(), grep($_->mortal(), values(%{ $_Family{$$} })));
}

#+++############################################################################
#                                                                              #
# internal methods                                                             #
#                                                                              #
#---############################################################################

#
# print debugging messages
#

sub _trace : method {
    my($self, @message) = @_;
    print STDERR ("# $self @message\n") if $self->debug();
}

#
# what to do on child birth
#

sub _birth : method {
    my($self, $pid) = @_;

    $self->pid($pid);
    $self->status(-1);
    $_Family{$$}{$pid} = $self;
    $self->state(IS_ALIVE);
    $self->_trace("started as $pid");
}

#
# what to do on child death
#

sub _death : method {
    my($self, $status) = @_;

    $self->status($status);
    delete($_Family{$$}{$self->pid()});
    $self->state(IS_DEAD);
    $self->_trace("died with $status");
}

#+++############################################################################
#                                                                              #
# object fields access methods                                                 #
#                                                                              #
#---############################################################################

#
# debug level
#

sub debug : method {
    my($self, $debug) = @_;
    $self->{"_debug"} = $debug if @_ > 1;
    return($self->{"_debug"});
}

#
# will it be killed in the END()?
#

sub mortal : method {
    my($self, $mortal) = @_;
    $self->{"_mortal"} = $mortal if @_ > 1;
    return($self->{"_mortal"});
}

#
# pid when alive
#

sub pid : method {
    my($self, $pid) = @_;
    $self->{"_pid"} = $pid if @_ > 1;
    return($self->{"_pid"});
}

#
# command to execute to start it
#

sub cmd : method {
    my($self, @cmd) = @_;
    $self->{"_cmd"} = \@cmd if @_ > 1;
    return() unless $self->{"_cmd"};
    return(@{$self->{"_cmd"}});
}

#
# state out of IS_NEW or IS_ALIVE or IS_DEAD
#

sub state : method {
    my($self, $state) = @_;
    $self->{"_state"} = $state if @_ > 1;
    return($self->{"_state"});
}

#
# status (i.e. $?) when dead, can be -1 when unknown as returned by waitpid()
#

sub status : method {
    my($self, $status) = @_;
    $self->{"_status"} = $status if @_ > 1;
    return($self->{"_status"});
}

#
# connected file, fd can be 0, 1 or 2
#

sub fconnect : method {
    my($self, $fd, $file) = @_;
    $self->{"_file"}[$fd] = $file if @_ > 2;
    return() unless $self->{"_file"};
    return($self->{"_file"}[$fd]);
}

#
# connected pipe, fd can be 0, 1 or 2
#

sub pconnect : method {
    my($self, $fd, $pipe) = @_;
    $self->{"_pipe"}[$fd] = $pipe if @_ > 2;
    return() unless $self->{"_pipe"};
    return($self->{"_pipe"}[$fd]);
}

#
# current working directory (at time of exec())
#

sub cwd : method {
    my($self, $path) = @_;
    $self->{"_cwd"} = $path if @_ > 1;
    return($self->{"_cwd"});
}

#
# grace period to use when killing
#

sub grace : method {
    my($self, $path) = @_;
    $self->{"_grace"} = $path if @_ > 1;
    return($self->{"_grace"});
}

#+++############################################################################
#                                                                              #
# public methods                                                               #
#                                                                              #
#---############################################################################

#
# create a new process object linked to a command to execute
#

sub new : method {
    my($class, @cmd) = @_;
    my $self = {};
    bless($self, $class);
    $self->cmd(@cmd);
    $self->state(IS_NEW);
    $self->debug($Debug);
    $self->mortal(1);
    $self->grace(1);
    $self->_trace("created with '@cmd'");
    return($self);
}

#
# start a process object, optionally redirecting its input/output
#

sub start : method {
    my($self, $unsafe) = @_;
    my($pid, $tries, $path, $fd, $in, $in2, $out, $out2, $err, $err2, @cmd);

    #
    # initialisation before the fork
    #
    # flush stdout and stderr so that the child gets empty stdio buffers
    $fd = select;
    select(STDOUT); $| = 1; print("");
    select(STDERR); $| = 1; print("");
    select($fd);
    # prepare stdin
    if (defined($in = $self->fconnect(0))) {
	if (not ref($in) and length($in)) {
	    $path = $in;
	    $in = new_symbol();
	    unless (open($in, "<" . path_for_open($path))) {
		throw_error("open(<$path)", $!);
		return();
	    }
	}
    } elsif ($in2 = $self->pconnect(0)) {
	$in = new_symbol();
	unless (pipe($in, $in2)) {
	    throw_error("pipe($in, $in2)", $!);
	    return();
	}
    }
    if ($in and not defined(fileno($in))) {
	throw_error("fileno(in)", "closed");
	return();
    }
    # prepare stdout
    if (defined($out = $self->fconnect(1))) {
	if (not ref($out) and length($out)) {
	    $path = $out;
	    $out = new_symbol();
	    unless (open($out, ">" . path_for_open($path))) {
		throw_error("open(>$path)", $!);
		return();
	    }
	}
    } elsif ($out2 = $self->pconnect(1)) {
	$out = new_symbol();
	unless (pipe($out2, $out)) {
	    throw_error("pipe($out2, $out)", $!);
	    return();
	}
    }
    if ($out and not defined(fileno($out))) {
	throw_error("fileno(out)", "closed");
	return();
    }
    # prepare stderr
    if (defined($err = $self->fconnect(2))) {
	if (not ref($err) and length($err)) {
	    $path = $err;
	    $err = new_symbol();
	    unless (open($err, ">" . path_for_open($path))) {
		throw_error("open(>$path)", $!);
		return();
	    }
	}
    } elsif ($err2 = $self->pconnect(2)) {
	$err = new_symbol();
	unless (pipe($err2, $err)) {
	    throw_error("pipe($err2, $err)", $!);
	    return();
	}
    }
    if ($err and not defined(fileno($err))) {
	throw_error("fileno(err)", "closed");
	return();
    }
    #
    # fork and dispatch
    #
    $tries = 5;
    TRY_TO_FORK: {
	$pid = fork;
	if ($pid) {
	    #
	    # father
	    #
	    # close our end of the pipes
	    if ($in2) {
		unless (close($in)) {
		    throw_error("close($in)", $!);
		    goto CLOSE_FAILED;
		}
	    }
	    if ($out2) {
		unless (close($out)) {
		    throw_error("close($out)", $!);
		    goto CLOSE_FAILED;
		}
	    }
	    if ($err2) {
		unless (close($err)) {
		    throw_error("close($err)", $!);
		    goto CLOSE_FAILED;
		}
	    }
	    if ($pid) {
		# if we're here then all close() succeeded...
		$self->_birth($pid);
	    } else {
	      CLOSE_FAILED:
		# the child may have started (or even finished!) now but we
		# have no other choice than killing it... note that this kill
		# can fail (e.g. if the exec'ed programis setuid)
		kill("KILL", $pid) or throw_warning("kill($pid)", $!);
		return();
	    }
	} elsif (defined($pid)) {
	    #
	    # child
	    #
	    # we die() this way to avoid triggering the END blocks of the father
	    local $SIG{__DIE__} = sub {
		print(STDERR $_[0]);
		POSIX::_exit(1);
	    };
	    # prepare stdin
	    if ($in) {
		$fd = fileno($in);
		if ($fd != fileno(STDIN)) {
		    open(STDIN, "<&=$fd")
			or die("$Tag: open(STDIN, '<&=$fd'): $!\n");
		}
		if ($in2) {
		    close($in2)
			or die("$Tag: close($in2): $!\n");
		}
	    }
	    # prepare stdout
	    if ($out) {
		$fd = fileno($out);
		if ($fd != fileno(STDOUT)) {
		    select((select($out), $| = 1)[0]); # unbuffer
		    open(STDOUT, ">&=$fd")
			or die("$Tag: open(STDOUT, '>&=$fd'): $!\n");
		}
		if ($out2) {
		    close($out2)
			or die("$Tag: close($out2): $!\n");
		}
	    }
	    # prepare stderr
	    if ($err) {
		$fd = fileno($err);
		if ($fd != fileno(STDERR)) {
		    select((select($err), $| = 1)[0]); # unbuffer
		    open(STDERR, ">&=$fd")
			or die("$Tag: open(STDERR, '>&=$fd'): $!\n");
		}
		if ($err2) {
		    close($err2)
			or die("$Tag: close($err2): $!\n");
		}
	    } elsif (defined($err)) {
		# special case for $p->fconnect(2, "")
		open(STDERR, ">&STDOUT")
		    or die("$Tag: open(STDERR, '>&STDOUT'): $!\n");
	    }
	    # chdir
	    $path = $self->cwd();
	    if (defined($path)) {
		chdir($path)
		    or die("$Tag: chdir($path): $!\n");
	    }
	    # and eventually exec()...
	    @cmd = $self->cmd();
	    local $SIG{__WARN__} = sub {}; # because exec() can warn on error
	    local $" = ", "; # to have a nicer error message
	    if ($unsafe) {
		# unsafe invocation potentially with shell expansion
		exec(@cmd) or die("$Tag: exec(@cmd): $!\n");
	    } else {
		if (scalar(@cmd) == 1) {
		    @cmd = split(/\s/, $cmd[0]);
		}
		# safe invocation that never involves the shell
		exec({ $cmd[0] } @cmd) or die("$Tag: exec(@cmd): $!\n");
	    }
	} elsif ($! == EAGAIN) {
	    #
	    # cannot fork right now but let's try again...
	    #
	    select(undef, undef, undef, 0.01); # wait a little bit
	    redo TRY_TO_FORK if $tries-- > 0;
	    throw_error("fork", $!);
	    return();
	} else {
	    #
	    # error
	    #
	    throw_error("fork", $!);
	    return();
	}
    }
    # Alles klar Herr Kommissar
    return($pid);
}

#
# stop a process object first gently (SIGINT) and then deadly (SIGKILL)
# we cannot guarantee that we will always get its status but we try hard...
# (note: we currently ignore the errors that kill() could report)
#

sub stop : method {
    my($self) = @_;
    my($pid, $timeout);

    return unless $self->state() == IS_ALIVE;
    $self->_trace("will be killed");
    $pid = $self->pid();
    kill("INT", $pid) or return;
    # leave him some time to die in peace
    $timeout = int($self->grace() * 100);
    while ($timeout--) {
	select(undef, undef, undef, 0.01);
	return unless $self->alive();
    }
    kill("KILL", $pid) or return;
    # wait a bit more to get a chance to get its status immediately: .1s
    $timeout = 10;
    while ($timeout--) {
	select(undef, undef, undef, 0.01);
	return unless $self->alive();
    }
}

#
# check if a process object is alive
#

sub alive : method {
    my($self) = @_;
    my($pid);
    
    # easy when we know that he's *not* alive
    return() unless $self->state() == IS_ALIVE;
    # check if he died recently
    $pid = $self->pid();
    if (waitpid($pid, WNOHANG) == $pid) {
	# yes, bury him
	$self->_death($?);
	return();
    }
    # now check that he's still alive (in case somebody did the waitpid())
    if (kill(0, $pid) or ($! == EPERM)) {
	# yes, assume he's alive and kicking
	return(SUCCESS);
    }
    # oops, he died without telling us! (-1 is the unknown status in Perl)
    $self->_death(-1);
    return();
}

#+++############################################################################
#                                                                              #
# high-level (non object-oriented) subroutines                                 #
#                                                                              #
#---############################################################################

#
# execute something with flexible options
#

sub execute ($%) {
    my($cmd, %opt) = @_;
    my($timeout, $proc, $ref, $nfound, $limit, $done, $eof, $error, $res, $pid);
    my($bufin, $bufout, $buferr, $rin, $rout, $win, $wout);
    my($fdin, $fdout, $fderr);
    local(*FHIN, *FHOUT, *FHERR);

    #
    # init
    #
    unless (ref($cmd) eq "ARRAY") {
	throw_error("not an array reference", $cmd);
	return();
    }
    if (exists($opt{timeout})) {
	$timeout = $opt{timeout};
	delete($opt{timeout});
    } else {
	$timeout = 0;
    }
    ($error) = grep($_ !~ /^(cb|cwd|grace|pid|shell|std(in|out|err))$/, keys(%opt));
    if (defined($error)) {
	throw_error("invalid option", $error);
	return();
    }
    #
    # create and start the process
    #
    $proc = LC::Process->new(@$cmd);
    if (defined($opt{grace})) {
	$proc->grace($opt{grace});
    }
    if (defined($opt{stdin})) {
	# use the supplied input
	$proc->pconnect(0, \*FHIN);
	$bufin = $opt{stdin};
	$opt{stdin} = 1;
    } else {
	$bufin = "";
	delete($opt{stdin});
    }
    if ($opt{stdout}) {
	# redirect stdout
	$ref = $opt{stdout};
	if (ref($ref) eq "SCALAR" or ref($ref) eq "CODE") {
	    $proc->pconnect(1, \*FHOUT);
	} else {
	    throw_error("not a scalar or code reference", $ref);
	    return();
	}
    }
    if ($opt{stderr}) {
	# redirect stderr
	$ref = $opt{stderr};
	if ($ref eq "stdout") {
	    # special case: we merge stdout and stderr
	    $proc->fconnect(2, "");
	    delete($opt{stderr});
	} elsif (ref($ref) eq "SCALAR" or ref($ref) eq "CODE") {
	    $proc->pconnect(2, \*FHERR);
	} else {
	    throw_error("not a scalar or code reference", $ref);
	    return();
	}
    }
    if ($opt{pid}) {
	# remember pid
	$ref = $opt{pid};
	unless (ref($ref) eq "SCALAR") {
	    throw_error("not a scalar reference", $ref);
	    return();
	}
    } else {
	$ref = "";
    }
    if (defined($opt{cwd})) {
	$proc->cwd($opt{cwd});
    }
    $proc->start($opt{shell}) or return();
    $pid = $proc->pid();
    $$ref = $pid if $ref;
    #
    # collect its output
    #
    $eof = $error = 0;
    $win = $rin = "";
    if ($opt{stdin}) {
	$fdin = fileno(FHIN);
	vec($win, $fdin, 1) = 1;
    } else {
	$fdin = -1;
    }
    if ($opt{stdout}) {
	$fdout = fileno(FHOUT);
	vec($rin, $fdout, 1) = 1;
    } else {
	$fdout = -1;
    }
    if ($opt{stderr}) {
	$fderr = fileno(FHERR);
	vec($rin, $fderr, 1) = 1;
    } else {
	$fderr = -1;
    }
    $bufout = $buferr = "";
    $limit = time() + $timeout;
    while (not $timeout or time() < $limit) {
	# start by executing the main callback
	if ($opt{cb}) {
	    $res = $opt{cb}->($pid);
	    if ($res) {
		$error = ["callback()", $res];
		last;
	    }
	}
	if (not $opt{stdin} and not $opt{stdout} and not $opt{stderr}) {
	    # we do not play with std* so we only check if it's alive
	    if ($proc->alive()) {
		if ($opt{cb}) {
		    # there is a callback so we should not loop too fast!
		    sleep(1);
		} else {
		    # no callback, sleep only for 1/100 second
		    select(undef, undef, undef, 0.01);
		}
		next;
	    } else {
		$eof = 1;
		last;
	    }
	}
	# we do play with std* so we use select
	$nfound = select($rout=$rin, $wout=$win, undef, 1);
	unless ($nfound) {
	    # nothing found, check if it's still alive
	    unless ($proc->alive()) {
		$eof = 1;
		last;
	    }
	}
	# stdout
	if ($fdout >= 0 and vec($rout, $fdout, 1)) {
	    $done = sysread(FHOUT, $bufout, SYSBUFSIZE, length($bufout));
	    unless (defined($done)) {
		$error = ["sysread(out)", $!];
		last;
	    }
	    if ($done and ref($opt{stdout}) eq "CODE") {
		$res = $opt{stdout}->($bufout);
		if ($res) {
		    $error = ["callback(out)", $res];
		    last;
		}
	    }
	    vec($rin, $fdout, 1) = 0 unless $done;
	}
	# stderr
	if ($fderr >= 0 and vec($rout, $fderr, 1)) {
	    $done = sysread(FHERR, $buferr, SYSBUFSIZE, length($buferr));
	    unless (defined($done)) {
		$error = ["sysread(err)", $!];
		last;
	    }
	    if ($done and ref($opt{stderr}) eq "CODE") {
		$res = $opt{stderr}->($buferr);
		if ($res) {
		    $error = ["callback(err)", $res];
		    last;
		}
	    }
	    vec($rin, $fderr, 1) = 0 unless $done;
	}
	# stdin
	if ($fdin >= 0 and vec($wout, $fdin, 1)) {
	    if (length($bufin)) {
		$done = syswrite(FHIN, $bufin);
		unless (defined($done)) {
		    $error = ["syswrite(in)", $!];
		    last;
		}
		substr($bufin, 0, $done) = "" if $done;
	    }
	    unless (length($bufin)) {
		unless (close(FHIN)) {
		    $error = ["close(in)", $!];
		    last;
		}
		vec($win, $fdin, 1) = 0;
	    }
	}
	# finished?
	if (($fdin  >= 0 and vec($win, $fdin,  1)) or
	    ($fdout >= 0 and vec($rin, $fdout, 1)) or
	    ($fderr >= 0 and vec($rin, $fderr, 1))) {
	    # still something to do
	} else {
	    # no more file handle to read
	    $eof = 1;
	    last;
	}
    }
    #
    # cleanup
    #
    if ($eof) {
	# command finished normally
	if ($bufout =~ /^\Q$Tag: \E(.+\)): (.+)$/ or
	    $buferr =~ /^\Q$Tag: \E(.+\)): (.+)$/) {
	    # child returned an internal error
	    $error = [$1, $2];
	} else {
	    # child seems OK at first glance
	}
	# we wait until the process really dies to get its status
	while (not $timeout or time() < $limit) {
	    last unless $proc->alive();
	    select(undef, undef, undef, 0.01);
	}
    } elsif ($error) {
	# error while reading output
	$proc->stop();
    } else {
	# command did not finish in time
	$proc->stop();
	$error = ["timeout", $timeout];
    }
    # put the status in $? anyway
    $? = $proc->status();
    # set the output buffers anyway
    ${ $opt{stdout} } = $bufout if $opt{stdout} and ref($opt{stdout}) eq "SCALAR";
    ${ $opt{stderr} } = $buferr if $opt{stderr} and ref($opt{stderr}) eq "SCALAR";
    # return success status
    return(SUCCESS) unless $error;
    throw_error($error->[0], $error->[1]);
    return();
}

#
# timeout + capture output (stdout and stderr)
#

sub toutput ($@) {
    my($timeout, @args) = @_;
    my($output);

    $output = "";
    execute(\@args, "timeout" => $timeout,
	    "stdout" => \$output, "stderr" => "stdout") or return();
    return($output);
}

#
# capture output (stdout and stderr)
#

sub output (@) {
    my(@args) = @_;
    my($output);

    $output = "";
    execute(\@args, "stdout" => \$output, "stderr" => "stdout") or return();
    return($output);
}

#
# timeout + execute (merge stdout and stderr)
#

sub trun ($@) {
    my($timeout, @args) = @_;
    
    return(execute(\@args, "timeout" => $timeout, "stderr" => "stdout"));
}

#
# execute (merge stdout and stderr)
#

sub run (@) {
    my(@args) = @_;

    return(execute(\@args, "stderr" => "stdout"));
}

#+++############################################################################
#                                                                              #
# daemonisation                                                                #
#                                                                              #
#---############################################################################

#
# daemonise the current process: background, chdir, setsid()...
#

sub daemonise () {
    my($pid, $count, $chld);

    # chdir to a known place
    unless (chdir("/")) {
	throw_error("chdir(/)", $!);
	return();
    }
    # fork and let dad die
    local $SIG{CHLD} = sub { $chld = 1 };
    $pid = fork();
    unless (defined($pid)) {
	throw_error("fork()", $!);
	return();
    }
    if ($pid) {
        # the parent waits a bit to see if the start is successful
        $count = 10;
	while ($count-- and not $chld and kill(0, $pid)) {
	    select(undef, undef, undef, 0.25);
	}
	if ($chld) {
	    # got SIGCHLD, child died properly
	    if (waitpid($pid, WNOHANG) == $pid) {
		# got status, we report it
		exit($? >> 8);
	    } else {
		# did not get status, return code is 1
		exit(1);
	    }
	} else {
	    # exit with 1 if child dead after the timeout
	    exit(kill(0, $pid) ? 0 : 1);
	}
    }
    # create a new session if we're root
    if ($> == 0) {
        $pid = POSIX::setsid();
	if ($pid == -1) {
	    throw_error("setsid()", $!);
	    return();
	}
    }
    # detach std* from any terminal
    if (-t STDIN) {
	unless (open(STDIN, "</dev/null")) {
	    throw_error("open(STDIN, </dev/null)", $!);
	    return();
	}
    }
    if (-t STDOUT) {
	unless (open(STDOUT, ">/dev/null")) {
	    throw_error("open(STDOUT, >/dev/null)", $!);
	    return();
	}
    }
    if (-t STDERR) {
	unless (open(STDERR, ">/dev/null")) {
	    throw_error("open(STDERR, >/dev/null)", $!);
	    return();
	}
    }
    # so far so good
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# pid file handling                                                            #
#                                                                              #
#---############################################################################

#
# check the contents of the pid file, optionally updating the action token
#

sub pidcheck ($;$) {
    my($path, $action) = @_;
    my($pid, $extra);

    # ok if file does not exist
    return(-1) unless -e $path;
    # read the pid file
    $pid = file_contents($path);
    return() unless defined($pid);
    if ($pid =~ /\A(\d+)\Z/) {
	# untaint pid
	$pid = $1;
    } elsif ($pid =~ /\A(\d+)\s+([a-z]+)\Z/) {
	# untaint pid and extra data
	($pid, $extra) = ($1, $2);
    } else {
	# remove pid file with invalid contents
	unless (unlink($path)) {
	    throw_error("unlink($path)", $!);
	    return();
	}
	if (length($pid)) {
	    $extra = unctrl($pid);
	    throw_warning("removed invalid pid file ($extra)", $path);
	} else {
	    throw_warning("removed invalid empty pid file", $path);
	}
	return(-1);
    }
    # test if the corresponding process still runs
    if ($pid == $$ or kill(0, $pid)) {
	if (defined($action)) {
	    # we update the action token
	    file_contents($path, "$pid\n$action\n") or return();
	}
	return($pid, $extra) if wantarray;
	return($pid);
    }
    # remove the stale pid file
    unless (unlink($path)) {
	throw_error("unlink($path)", $!);
	return();
    }
    throw_warning("removed stale pid file ($pid)", $path);
    return(-1);
}

#
# overwrites the pid file for the current process
#

sub pidset ($) {
    my($path) = @_;

    file_contents($path, "$$\n") or return();
    # remember it for cleanup
    $_PidStored = $$;
    $_PidPath = $path;
    return(SUCCESS);
}

#
# check and set the pid file, optionally killing a stalled process
#

sub pidsetup ($;$) {
    my($path, $maxage) = @_;
    my($pid, @stat);

    $pid = pidcheck($path);
    if ($pid == -1) {
        pidset($path) or return();
	return("not running");
    }
    return(sprintf("already running as %d", $pid))
	unless $maxage;
    @stat = stat($path);
    unless (@stat) {
	throw_error("stat($path)", $!);
	return();
    }
    return(sprintf("already running as %d (last update %s)",
		   $pid, timestamp($stat[ST_MTIME])))
	if $stat[ST_MTIME] > time() - $maxage;
    # the running process may be stalled, we kill it
    unless (kill("INT", $pid)) {
	throw_error("kill(INT, $pid)", $!);
	return();
    }
    sleep(1);
    if (kill(0, $pid)) {
	unless (kill("KILL", $pid)) {
	    throw_error("kill(KILL, $pid)", $!);
	    return();
	}
	sleep(1);
    }
    pidset($path) or return();
    return(sprintf("not running anymore (killed process %d stalled since %s)",
		   $pid, timestamp($stat[ST_MTIME])));
}

#
# "touch" the pid file to indicate that we are still alive and kicking
#

sub pidtouch ($) {
    my($path) = @_;
    my($now);

    $now = time();
    unless (utime($now, $now, $path)) {
	throw_error("utime($now, $now, $path)", $!);
	return();
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# controlled wait and fork                                                     #
#                                                                              #
#---############################################################################

#
# controlled wait
#

sub cwait ($;$) {
    my($maxpids, $timeout) = @_;
    my($pid, @slow, @dead, $died);

    while (1) {
	foreach $pid (keys(%_StartTime)) {
	    # check if it died (notifying us)
	    $died = waitpid($pid, WNOHANG());
	    if ($pid == $died) {
		push(@dead, $pid);
		next;
	    }
	    # check if it died (without notifying us)
	    unless (kill(0, $pid)) {
		push(@dead, $pid);
		next;
	    }
	    # check if it is too slow to finish
	    next unless $timeout;
	    if ($_StartTime{$pid} + $timeout < time()) {
		push(@slow, $pid);
		next;
	    }
	}
	# remove dead children
	foreach $pid (@dead) {
	    delete($_StartTime{$pid});
	}
	# kill slow children
	foreach $pid (@slow) {
	    kill("TERM", $pid) and select(undef, undef, undef, 0.01);
	    delete($_StartTime{$pid}) unless kill(0, $pid);
	}
	last if keys(%_StartTime) <= $maxpids;
	select(undef, undef, undef, 0.1);
    }
}

#
# controlled fork
#

sub cfork ($;$) {
    my($maxpids, $timeout) = @_;
    my($pid);

    cwait($maxpids - 1, $timeout);
    $pid = fork;
    unless (defined($pid)) {
	throw_error("fork", $!);
	return();
    }
    if ($pid) {
	# father updates %_StartTime
	$_StartTime{$pid} = time();
    }
    return($pid);
}

#+++############################################################################
#                                                                              #
# simple sendmail front-end                                                    #
#                                                                              #
#---############################################################################

sub sendmail ($$;%) {
    my($body, $rcpt, %opt) = @_;
    my($sendmail, $field, $data, $output, %eopt);

    # init
    $sendmail = "/usr/lib/sendmail";
    $sendmail = "/usr/sbin/sendmail" unless -f $sendmail and -x _;
    unless (-f $sendmail and -x _) {
	throw_error("sendmail not found", $sendmail);
	return();
    }
    ($field) = grep($_ !~ /^(from|subject|date|cc|header|timeout)$/, keys(%opt));
    if ($field) {
	throw_error("invalid option", $field);
	return();
    }
    $opt{to} = $rcpt;
    $data = $opt{header} || "";
    foreach $field (keys(%opt)) {
	next if $field eq "header" or $field eq "timeout";
	$data .= ucfirst($field) . ": $opt{$field}\n";
    }
    $data .= "Precedence: junk\n\n$body\n";
    $output = "";
    %eopt = (
	     "stdin"  => $data,
	     "stdout" => \$output,
	     "stderr" => "stdout",
	     );
    $eopt{timeout} = $opt{timeout} if $opt{timeout};
    # send mail
    $data = execute([$sendmail, "-oi", $rcpt], %eopt);
    return() unless $data;
    if ($? >> 8) {
	throw_error("$sendmail failed", $?);
	return();
    }
    return($data);
}

1;

__END__

=head1 NAME

LC::Process - high-level object-oriented interface to manipulate processes

=head1 SYNOPSIS

  use LC::Process qw(output);
  $data = output(qw(command arg1 arg2));

  use LC::Process qw(execute);
  $success = execute([qw(ls /foo)], "stderr" => \$bufferr);

  use LC::Process qw(pidcheck pidset);
  $pidpath = "/var/run/foo.pid";
  $pid = pidcheck($pidpath) or die("cannot check $pidpath");
  if ($pid == -1) {
      # me alone
      pidset($pidpath) or die("cannot set $pidpath");
  } else {
      # already running
      die("already running as $pid");
  }

=head1 DESCRIPTION

This package provides a (currently undocumented) object-oriented
interface to manipulate processes and documented high-level functions
using this OO interface under the hood.

Its main purpose is to provide better control on process execution and
to avoid using the shell as much as possible.

=head1 PROCESS EXECUTION

The main function regarding process execution is C<execute>. It takes
a mandatory first argument (which must be an array reference holding
the command to execute and its arguments) and then optionally a list
of named options. It executes the given command until the process
finishes or an error occurs. The result is true on success, C<$?> will
contain the child status when possible.

It supports the following options:

=over

=item C<timeout>

maximum execution time in seconds, the command will be killed if it
takes too long to finish

=item C<stdin>

data that will se sent to stdin

=item C<stdout>

reference to the scalar that will contain stdout
or a callback to be called each time there is new data on stdout

=item C<stderr>

reference to the scalar that will contain stderr
or a callback to be called each time there is new data on stderr
or the string C<stdout> meaning that stdout and stderr should be merged

=item C<cwd>

path of a directory to change to before executing the child process

=item C<pid>

reference to the scalar that will contain the created process pid

=item C<grace>

number specifying the grace period (in seconds, can be fractional):
this is the time given to processes being killed to cleanup, between
the gentle SIGINT and the brutal SIGKILL

=item C<shell>

boolean specifying whether the shell should be called in case the list
holding the command to execute has only one arguement (default: no),
see the C<exec> documentation in perlfunc for background information

=item C<cb>

callback that will be called while the main process waits for the
child to terminate

=back

The options that can receive a callback (C<stdout>, C<stderr> and
C<cb>) expect a reference to some code that returns an error message
in case of problem and a false value (e.g. C<undef>) on success. The
code will be called with only one argument that will be respectively:
the current stdout buffer, the current stderr buffer and the pid.

In addition, this module exports the following functions which are
simple wrappers around C<execute>:

=over

=item toutput(TIMEOUT, COMMAND[, ARGS...])

execute the given command capturing its output, merge stdout and
stderr, handle a timeout; the result is the output or C<undef> on
error, C<$?> is also set

=item output(COMMAND[, ARGS...])

same as above but without a timeout

=item trun(TIMEOUT, COMMAND[, ARGS...])

execute the given command, merge stdout and stderr, handle a timeout;
the result is true if there is no error, C<$?> is also set

=item run(COMMAND[, ARGS...])

same as above but without a timeout

=back

As an illustration, here is C<toutput>'s actual code:

  sub toutput ($@) {
      my($timeout, @args) = @_;
      my($output);
      $output = "";
      execute(\@args, "timeout" => $timeout,
  	    "stdout" => \$output, "stderr" => "stdout") or return();
      return($output);
  }

=head1 PID FILE HANDLING

This module also exports some functions to ease the handling of pid files:

=over

=item pidcheck(PATH[, ACTION])

check if the given PATH corresponds to the pid file of a running
process; this pid file should contain the process id on the first
line, optionally followed by an "action" word on a second line;
if the process is indeed running, this function returns the pid
(in scalar context) or both the pid and action (in list context);
it returns -1 if the no process is running and undef on error;
if the ACTION parameter is given and a process is running, the
action in the pid file is updated

=item pidset(PATH)

put the pid of the current process in the pid file identified by the
given PATH, the file will be removed when the current process dies

=item pidsetup(PATH[, MAXAGE])

check the contents of the pid file, the state of the running process
(if any, killing stalled processes if MAXAGE is given) and in the end
set the pid file if no other processes are running; it returns a
string indicating what has been found/done

=item pidtouch(PATH)

update the pid file's access and modification times to indicate that
the current process is still healthy

=back

=head1 OTHER FUNCTIONS

=over

=item cfork(MAXPIDS[, TIMEOUT])

perform a controlled C<fork>, blocking if we already have too many
children (see C<cwait>); return the new pid or undef on error

=item cwait(MAXPIDS[, TIMEOUT])

perform a controlled C<wait>, waiting for enough children to die so
that we have at most MAXPIDS children running, killing the ones
running for more than TIMEOUT seconds; note: the children must have
been created with C<cfork>

=item daemonise()

put the current process in the background and detach it from any
terminal

=item sendmail(BODY, RECIPIENT[, OPTIONS...])

send the given mail body to the given recipient using the sendmail
program (that must be available and properly configured);
options are:
C<timeout> (maximum execution time in seconds),
C<cc> (specify the value of the "Cc" mail header),
C<date> (specify the value of the "Date" mail header),
C<from> (specify the value of the "From" mail header),
C<subject> (specify the value of the "Subject" mail header),
C<header> (specify arbitrary extra header lines)

=back

=head1 NOTES

=over

=item * filehandle swapping (stdout <-> stderr) is not (yet?) supported

=item * error reporting cannot be bullet proof because a child may be
in a state where it cannot send its error message (e.g. stderr closed)

=item * if someone plays with the SIGCHLD signal handler, we may not
get the proper status code

=item * the pid file handling assumes that the program behaves
normally (see the example above); if something else messes with the
file, pidcheck() will maybe not check the right process

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Process.pm,v 1.60 2011/01/05 08:49:28 cons Exp $

=head1 TODO

=over

=item * what do we do with sendmail's output?

=back

=cut

__END__

# (here are internal notes that used to be in the man page)
# 
# =head1 NOTES
# 
# =over
# 
# =item * $p->fconnect(2, "") can be used to merge stdout and stderr
# 
# =item * also, we cannot know if a child nicely exited or if exec() failed;
# one should look to see if the stderr output starts with $Tag...
# 
# =item * all children will be killed upon class destruction, this is a feature,
# use $p->mortal(0) if you want to let some survive...
# 
# =item * the child may have started (or even finished!) when the father detects an
# error so a false value for $p->start() does not mean that the child did not
# run but only that we could not setup things correctly... fortunately, this
# can never happen when you do not play with file handles...
# 
# =item * if the started process changes its uid, we may not be able to stop it
# anymore with $p->stop()
# 
# =back
# 
# =head1 TODO
# 
# =over
# 
# =item * when a process is not mortal, it may stay as zombie when the program ends
# (could we do a local $SIG{CHLD} = "IGNORE"?)
# 
# =item * handle stopped/continued processes (i.e. state updated)?
# 
# =back
