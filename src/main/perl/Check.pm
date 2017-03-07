#+##############################################################################
#                                                                              #
# File: Check.pm                                                               #
#                                                                              #
# Description: check that things are really the way we expect them to be       #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Check;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.21 $ =~ /(\d+)\.(\d+)/);

#
# modules
#

use POSIX qw(:errno_h);
use LC::Cached getpwnam => 180;
use LC::Cached getgrnam => 180;
use LC::Exception qw(throw_error throw_warning SUCCESS);
use LC::Fatal;
use LC::File qw(destroy file_contents makedir);
use LC::Stat qw(:ST :S);
use LC::Util qw(past);

#
# constants
#

use constant DO_CHOWN => 1;
use constant DO_CHMOD => 2;
use constant DO_UTIME => 4;

#
# public variables
#

our(
    $Debug,		# print debugging information
    $NoAction,		# check only, do not fix the problems
    $RootDir,		# root directory when we emulate chroot(3)
    $Silent,		# report only errors
    $Verbose,		# report also when things are correct
);

#
# private variables
#

our(
    $_EC,               # module's exception context
    %_Alias,		# options aliases
);

#+++############################################################################
#                                                                              #
# initialisation                                                               #
#                                                                              #
#---############################################################################

$_EC = LC::Exception::Context->new()->will_store_errors();

%_Alias = (
    "dst" => "destination",
    "src" => "source",
    "uid" => "owner",
    "gid" => "group",
);

#+++############################################################################
#                                                                              #
# internal routines                                                            #
#                                                                              #
#---############################################################################

#
# check if the given options are expected and replace aliases
#

sub _badoption ($$) {
    my($optref, $okref) = @_;
    my(%ok, $opt);

    grep($ok{$_} = 1, @$okref, qw(debug noaction rootdir silent verbose));
    foreach $opt (keys(%_Alias)) {
	next unless $ok{$_Alias{$opt}};
	$ok{$opt} = 1;
	next unless exists($optref->{$opt});
	$optref->{$_Alias{$opt}} = $optref->{$opt};
    }
    foreach $opt (keys(%$optref)) {
	return($opt) unless defined($optref->{$opt});
	return($opt) unless $ok{$opt};
    }
    return();
}

#
# check that the given path does not contain . or .. which are forbidden
#

sub _badpath ($) {
    my($path) = @_;
    return($1) if $path =~  /^(\.\.?)$/;
    return($1) if $path =~  /^(\.\.?)\//;
    return($1) if $path =~ /\/(\.\.?)$/;
    return($1) if $path =~ /\/(\.\.?)\//;
    return();
}

#
# given an _absolute_ path, return the real path to use
#

sub _realpath ($) {
    my($path) = @_;
    return($RootDir ? $RootDir . $path : $path);
}

#
# print an informational message
#

sub _message ($$) {
    my($todo, $message) = @_;
    my($verb);

    # no message if silent!
    return if $Silent;
    # guess the verb of the message to print
    if ($message =~ /^(\w+)\s+(.*)$/) {
	# verb is the first word
	$verb = $1;
	$message = $2;
    } else {
	# or by default...
	$verb = "change";
	$message =~ s/^\s+//;
    }
    # output something
    if ($todo) {
	if ($NoAction) {
	    print("would $verb $message\n");
	} else {
	    printf("%s %s\n", past($verb), $message);
	}
    } else {
	print("$message is ok\n") if $Verbose;
    }
}

#
# unlink and maybe keep a backup copy
# (we never follow symlinks here, hence the lstat() calls before the -e tests)
#

sub _unlink ($$) {
    my($path, $backup) = @_;
    my($error, $old, $dont_follow);

    # test if we have something to do
    $dont_follow = lstat($path);
    return(SUCCESS) unless -e _;
    # yes, let's do it
    if (defined($backup) and $backup ne "") {
	# rename to a backup copy
	$old = $path . $backup;
	$dont_follow = lstat($old);
	if (-e _) {
	    # remove the backup first!
	    unless (LC::Fatal::unlink($old)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	unless (LC::Fatal::rename($path, $old)) {
	    $_EC->rethrow_error();
	    return();
	}
    } else {
	# simple unlink
	unless (LC::Fatal::unlink($path)) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    # so far so good
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# check directories                                                            #
#                                                                              #
#---############################################################################

#
# LC::Check::directory(PATHS)
#

sub directory ($;%) {
    my($opaths, %opt) = @_;
    my($opath, $path, $message, $todo, $result);

    # option handling
    $result = _badoption(\%opt, [qw(mode)]);
    if ($result) {
	throw_error(defined($opt{$result}) ?
		    "invalid option" : "undefined option", $result);
	return();
    }
    local $Debug    = exists($opt{debug})    ? $opt{debug}    : $Debug;
    local $NoAction = exists($opt{noaction}) ? $opt{noaction} : $NoAction;
    local $RootDir  = exists($opt{rootdir})  ? $opt{rootdir}  : $RootDir;
    local $Silent   = exists($opt{silent})   ? $opt{silent}   : $Silent;
    local $Verbose  = exists($opt{verbose})  ? $opt{verbose}  : $Verbose;
    $opt{mode} = 0755 unless exists($opt{mode});
    # main processing
    $result = 0;
    foreach $opath (ref($opaths) ? @$opaths : $opaths) {
	$path = _realpath($opath);
	$message = "create directory $opath";
	$todo = ! -d $path;
	if ($todo and not $NoAction) {
	    unless (makedir($path, $opt{mode})) {
		$_EC->rethrow_error();
		return();
	    }
	}
	_message($todo, $message);
	$result++ if $todo;
    }
    return($result);
}

#
# LC::Check::parent_directory(PATHS)
#

sub parent_directory ($;%) {
    my($paths, %opt) = @_;
    my($path, $ppath, $result, $subres);

    $result = 0;
    foreach $path (ref($paths) ? @$paths : $paths) {
	# check the path
	if (_badpath($path)) {
	    throw_error("invalid path", $path);
	    return();
	}
	# remove the last component of the path
	$ppath = $path;
	$ppath =~ s=/*[^/]*$==;
	next unless $ppath;
	# call directory on the parent path
	$subres = LC::Check::directory($ppath, %opt);
	unless (defined($subres)) {
	    $_EC->rethrow_error();
	    return();
	}
	$result += $subres;
    }
    return($result);
}

#+++############################################################################
#                                                                              #
# check file status as returned from from stat()                               #
#                                                                              #
#---############################################################################

#
# LC::Check::status(PATHS)
#

sub status ($;%) {
    my($opaths, %opt) = @_;
    my($result, %message, $todo, @todo, $opath, $path, $uid, $gid);
    my(@stat, $mode, $mode_set, $mode_clear);

    #
    # init
    #
    $result = _badoption(\%opt, [qw(owner group mode mtime)]);
    if ($result) {
	throw_error(defined($opt{$result}) ?
		    "invalid option" : "undefined option", $result);
	return();
    }
    local $Debug    = exists($opt{debug})    ? $opt{debug}    : $Debug;
    local $NoAction = exists($opt{noaction}) ? $opt{noaction} : $NoAction;
    local $RootDir  = exists($opt{rootdir})  ? $opt{rootdir}  : $RootDir;
    local $Silent   = exists($opt{silent})   ? $opt{silent}   : $Silent;
    local $Verbose  = exists($opt{verbose})  ? $opt{verbose}  : $Verbose;
    if (exists($opt{owner})) {
	if ($opt{owner} =~ /\D/) {
	    # name given instead of id
	    $uid = LC::Cached::getpwnam($opt{owner});
	    unless (defined($uid)) {
		throw_error("unknown user", $opt{owner});
		return();
	    }
	} else {
	    $uid = $opt{owner};
	}
	$message{owner} = "owner($opt{owner})";
    }
    if (exists($opt{group})) {
	if ($opt{group} =~ /\D/) {
	    # name given instead of id
	    $gid = LC::Cached::getgrnam($opt{group});
	    unless (defined($gid)) {
		throw_error("unknown group", $opt{group});
		return();
	    }
	} else {
	    $gid = $opt{group};
	}
	$message{group} = "group($opt{group})";
    }
    if (exists($opt{mode})) {
	my($action, $number);
	$mode_set = $mode_clear = 0;
	if ($opt{mode} =~ /^([+-])?(\d+)$/) {
	    $action = $1 || "";
	    $number = substr($2, 0, 1) eq "0" ? oct($2) : ($2+0);
	    if ($action eq "+") {
		# check that at least these bits are set
		$mode_set = $number;
	    } elsif ($action eq "-") {
		# check that at least these bits are cleared
		$mode_clear = $number;
	    } else {
		# check that these bits are exactly the ones set
		$mode_set = $number;
		$mode_clear = 07777;
	    }
	    # use the canonical form for the message
	    $opt{mode} = sprintf("%s%05o", $action, $number);
	} else {
	    throw_error("invalid mode", $opt{mode});
	    return();
	}
	$message{mode} = "mode($opt{mode})";
    }
    if (exists($opt{mtime})) {
	$message{mtime} = "mtime($opt{mtime})";
    }
    #
    # now really do the work
    #
    $result = 0;
    foreach $opath (ref($opaths) ? @$opaths : $opaths) {
	$path = _realpath($opath);
	$todo = 0;
	@todo = ();
	#
	# lstat the file
	#
	@stat = LC::Fatal::lstat($path);
	if (@stat) {
	    # we cannot chown() or chmod() symlinks
	    next if -l _;
	} else {
	    if ($NoAction and $_EC->error()->reason() == ENOENT) {
		# maybe the target does not _yet_ exist, we cannot do much
		# in this case so we ignore the error and assume the worst...
		$_EC->ignore_error();
	    } else {
		$_EC->rethrow_error();
		return();
	    }
	}
	if (exists($opt{owner})) {
	    unless (@stat and $uid == $stat[ST_UID]) {
		$todo |= DO_CHOWN;
		push(@todo, $message{owner});
	    }
	} else {
	    $uid = $stat[ST_UID];
	}
	if (exists($opt{group})) {
	    unless (@stat and $gid == $stat[ST_GID]) {
		$todo |= DO_CHOWN;
		push(@todo, $message{group});
	    }
	} else {
	    $gid = $stat[ST_GID];
	}
	if (exists($opt{mode})) {
	    if (@stat) {
		$mode = $stat[ST_MODE] & S_IALLUGO;
		$mode &= ~$mode_clear;
		$mode |=  $mode_set;
		unless ($mode == ($stat[ST_MODE] & S_IALLUGO)) {
		    $todo |= DO_CHMOD;
		    push(@todo, $message{mode});
		}
	    } else {
		$todo |= DO_CHMOD;
		push(@todo, $message{mode});
	    }
	}
	if (exists($opt{mtime})) {
	    unless (@stat and $opt{mtime} == $stat[ST_MTIME]) {
		$todo |= DO_UTIME;
		push(@todo, $message{mtime});
	    }
	}
	#
	# just do it
	#
	if (($todo & DO_CHOWN) and not $NoAction) {
	    unless (LC::Fatal::chown($uid, $gid, $path)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	if (($todo & DO_CHMOD) and not $NoAction) {
	    unless (LC::Fatal::chmod($mode, $path)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	if (($todo & DO_UTIME) and not $NoAction) {
	    unless (LC::Fatal::utime($stat[ST_ATIME], $opt{mtime}, $path)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	if ($todo) {
	    _message(1, "change @todo of $opath");
	    $result++;
	} else {
	    foreach $todo (qw(owner group mode mtime)) {
		push(@todo, $message{$todo}) if $message{$todo};
	    }
	    _message(0, "change @todo of $opath");
	}
    }
    return($result);
}

#
# LC::Check::owner(OWNER, PATH...)
#

sub owner ($;@) {
    my($owner, @args) = @_;
    my($result) = LC::Check::status(\@args, "owner" => $owner);
    unless (defined($result)) {
	$_EC->rethrow_error();
	return();
    }
    return($result);
}

#
# LC::Check::group(GROUP, PATH...)
#

sub group ($;@) {
    my($group, @args) = @_;
    my($result) = LC::Check::status(\@args, "group" => $group);
    unless (defined($result)) {
	$_EC->rethrow_error();
	return();
    }
    return($result);
}

#
# LC::Check::mode(MODE, PATH...)
#

sub mode ($;@) {
    my($mode, @args) = @_;
    my($result) = LC::Check::status(\@args, "mode" => $mode);
    unless (defined($result)) {
	$_EC->rethrow_error();
	return();
    }
    return($result);
}

#
# LC::Check::mtime(TIME, PATH...)
#

sub mtime ($;@) {
    my($mtime, @args) = @_;
    my($result) = LC::Check::status(\@args, "mtime" => $mtime);
    unless (defined($result)) {
	$_EC->rethrow_error();
	return();
    }
    return($result);
}

#+++############################################################################
#                                                                              #
# check hard and symbolic links                                                #
#                                                                              #
#---############################################################################

#
# LC::Check::link(SOURCE, TARGET)
#

sub link ($$;%) {
    my($osource, $otarget, %opt) = @_;
    my($message, $todo, $source, $target, $remove, @stat, $test);
    my($sdev, $sino, $tdev, $tino);

    #
    # init
    #
    $test = _badoption(\%opt, [qw(hard backup nocheck force)]);
    if ($test) {
	throw_error(defined($opt{$test}) ?
		    "invalid option" : "undefined option", $test);
	return();
    }
    local $Debug    = exists($opt{debug})    ? $opt{debug}    : $Debug;
    local $NoAction = exists($opt{noaction}) ? $opt{noaction} : $NoAction;
    local $RootDir  = exists($opt{rootdir})  ? $opt{rootdir}  : $RootDir;
    local $Silent   = exists($opt{silent})   ? $opt{silent}   : $Silent;
    local $Verbose  = exists($opt{verbose})  ? $opt{verbose}  : $Verbose;
    $source = _realpath($osource);
    $target = _realpath($otarget);
    $message = $opt{hard} ? "create hard link $osource => $otarget" :
	"create symlink $osource -> $otarget";
    #
    # check target
    #
    if ($otarget =~ /^\//) {
	$test = $target;
    } else {
	$test = $source;
	$test =~ s=[^/]+$==;
	$test .= $otarget;
    }
    if ($opt{hard}) {
        # Check target that is required to exist.
	@stat = LC::Fatal::lstat($test);
        # With magic _ after a lstat, -d tests the symlink, not its target
	if (@stat) {
	    if (-d _) {
		throw_error("invalid hard link target ($otarget)",
			    "is a directory");
		return();
	    }
	    ($tdev, $tino) = @stat[ST_DEV, ST_INO];
	}
    } elsif (not $opt{nocheck}) {
	@stat = LC::Fatal::lstat($test);
    } else {
	@stat = (1); # to pass the test below ;-)
    }
    unless (@stat) {
	if ($NoAction and $_EC->error()->reason() == ENOENT) {
	    # maybe the target does not _yet_ exist, we cannot do much
	    # in this case so we ignore the error...
	    $_EC->ignore_error();
	} else {
	    throw_error("invalid target ($otarget)", $_EC->error());
	    return();
	}
    }
    #
    # check source
    #
    $todo = 1;
    $remove = 0;
    # do _not_ follow a symlink!
    @stat = LC::Fatal::lstat($source);
    if (@stat) {
	if ($opt{hard}) {
            #
	    # check hard link
            # With magic _ after a lstat, -d tests the symlink, not its target
            #
	    if (-d _) {
		throw_error("cannot hard link $osource", "it is a directory");
		return();
	    }
	    ($sdev, $sino) = @stat[ST_DEV, ST_INO];
	    $message =~ s/^create/update/;
	    if (defined($tdev) and defined($tino)) {
		# target exists
		if ($sdev != $tdev) {
		    throw_error("cannot hard link $osource",
				"target is on a different filesystem");
		    return();
		}
		if ($sino == $tino) {
		    # good, nothing to do!
		    $todo = 0;
		} else {
		    # bad, we remove it
		    $remove++;
		}
	    } else {
		# target does not exist, this is because we have $NoAction
		# otherwise, we would have got an error previously...
	    }
	} else {
	    #
	    # check symlink
	    #
	    if (-l _) {
		# source is a symlink
		$message =~ s/^create/update/;
		$test = LC::Fatal::readlink($source);
		unless (defined($test)) {
		    $_EC->rethrow_error();
		    return();
		}
		if ($test eq $target) {
		    # good, nothing to do!
		    $todo = 0;
		} else {
		    # bad, we remove it
		    $remove++;
		}
	    } elsif ($opt{force} and -f _) {
		# source is a file, we remove it by force
		$remove++;
	    } else {
		# source is _not_ a symlink
		throw_error("cannot symlink $osource",
			    "it is not an existing symlink");
		return();
	    }
	}
    } else {
	if ($_EC->error()->reason() == ENOENT) {
	    $_EC->ignore_error();
	} else {
	    $_EC->rethrow_error();
	    return();
	}
    }
    #
    # maybe remove the source
    #
    if ($remove and not $NoAction) {
	unless (_unlink($source, $opt{backup})) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    #
    # just do it!
    #
    if ($todo and not $NoAction) {
	$test = LC::Check::parent_directory($source, "silent" => 1);
	unless (defined($test)) {
	    $_EC->rethrow_error();
	    return();
	}
	$todo += $test;
	if ($opt{hard}) {
	    unless (LC::Fatal::link($target, $source)) {
		$_EC->rethrow_error();
		return();
	    }
	} else {
	    unless (LC::Fatal::symlink($target, $source)) {
		$_EC->rethrow_error();
		return();
	    }
	}
    }
    _message($todo, $message);
    return($todo);
}

#
# LC::Check::hardlink(SOURCE, TARGET)
#

sub hardlink ($$;%)  {
    my($source, $target, %opt) = @_;
    $opt{hard} = 1;
    my($result) = LC::Check::link($source, $target, %opt);
    unless (defined($result)) {
	$_EC->rethrow_error();
	return();
    }
    return($result);
}

#
# LC::Check::symlink(SOURCE, TARGET)
#

sub symlink ($$;%)  {
    my($source, $target, %opt) = @_;
    $opt{hard} = 0;
    my($result) = LC::Check::link($source, $target, %opt);
    unless (defined($result)) {
	$_EC->rethrow_error();
	return();
    }
    return($result);
}

#+++############################################################################
#                                                                              #
# check the absence of something                                               #
#                                                                              #
#---############################################################################

#
# LC::Check::absence(PATHS)
# (we never follow symlinks here, hence the lstat() calls before the -e tests)
#

sub absence ($;%) {
    my($opaths, %opt) = @_;
    my($opath, $path, $message, $todo, $result, $old, $dont_follow);

    # option handling
    $result = _badoption(\%opt, [qw(backup file)]);
    if ($result) {
	throw_error(defined($opt{$result}) ?
		    "invalid option" : "undefined option", $result);
	return();
    }
    local $Debug    = exists($opt{debug})    ? $opt{debug}    : $Debug;
    local $NoAction = exists($opt{noaction}) ? $opt{noaction} : $NoAction;
    local $RootDir  = exists($opt{rootdir})  ? $opt{rootdir}  : $RootDir;
    local $Silent   = exists($opt{silent})   ? $opt{silent}   : $Silent;
    local $Verbose  = exists($opt{verbose})  ? $opt{verbose}  : $Verbose;
    # main processing
    $result = 0;
    foreach $opath (ref($opaths) ? @$opaths : $opaths) {
	$path = _realpath($opath);
	$dont_follow = lstat($path);
	if (-e _) {
	    if (-d _ and $opt{file}) {
		throw_error("cannot remove $opath", "it is a directory");
		return();
	    }
            $message = "remove $opath";
	    $todo = 1;
	} else {
            $message = "check absence of $opath";
	    $todo = 0;
	}
	if ($todo and not $NoAction) {
	    if (defined($opt{backup}) and $opt{backup} ne "") {
		$old = $path . $opt{backup};
		$dont_follow = lstat($old);
		if (-e _) {
		    # remove the backup first!
		    unless (destroy($old)) {
			$_EC->rethrow_error();
			return();
		    }
		}
		unless (LC::Fatal::rename($path, $old)) {
		    $_EC->rethrow_error();
		    return();
		}
	    } else {
		unless (destroy($path)) {
		    $_EC->rethrow_error();
		    return();
		}
	    }
	}
	_message($todo, $message);
	$result++ if $todo;
    }
    return($result);
}

#+++############################################################################
#                                                                              #
# check file contents                                                          #
#                                                                              #
#---############################################################################

#
# LC::Check::file(PATHS)
#

sub file ($;%) {
    my($opaths, %opt) = @_;
    my($result, $opath, $osource, $source, $odestination, $destination);
    my($todo, @sstat, @dstat, $expected, $actual, %xopt);

    # option handling
    $result = _badoption(\%opt, [qw(owner group mode mtime backup
				    source destination contents code)]);
    if ($result) {
	throw_error(defined($opt{$result}) ?
		    "invalid option" : "undefined option", $result);
	return();
    }
    if (exists($opt{source}) and exists($opt{contents})) {
	throw_error("exclusive options", "source and contents");
	return();
    }
    unless (exists($opt{source})) {
	foreach $todo (qw(owner group mode mtime)) {
	    next unless $opt{$todo} and $opt{$todo} eq "COPY";
	    throw_error("no source given for copy option", $todo);
	    return();
	}
    }
    local $Debug    = exists($opt{debug})    ? $opt{debug}    : $Debug;
    local $NoAction = exists($opt{noaction}) ? $opt{noaction} : $NoAction;
    local $RootDir  = exists($opt{rootdir})  ? $opt{rootdir}  : $RootDir;
    local $Silent   = exists($opt{silent})   ? $opt{silent}   : $Silent;
    local $Verbose  = exists($opt{verbose})  ? $opt{verbose}  : $Verbose;
    # main processing
    $result = 0;
    foreach $opath (ref($opaths) ? @$opaths : $opaths) {
	#
	# check the source
	#
	if (exists($opt{source})) {
	    $osource = $opt{source};
	    $osource .= $opath if $osource =~ /\/$/;
	    $source = _realpath($osource);
	    # we stat the source anyway (following symlink)
	    @sstat = LC::Fatal::stat($source);
	    unless (@sstat) {
		# a non existing source is an error!
		$_EC->rethrow_error();
		return();
	    }
	    unless (-f _) {
		throw_error("invalid source ($osource)",
			    "not a regular file");
		return();
	    }
	    $expected = file_contents($source);
	    unless (defined($expected)) {
		$_EC->rethrow_error();
		return();
	    }
	} else {
	    $source = $osource = undef;
	    @sstat = ();
	    if (exists($opt{contents})) {
		$expected = $opt{contents};
	    } else {
		$expected = undef;
	    }
	}
	#
	# check the destination
	#
	if (exists($opt{destination})) {
	    $odestination = $opt{destination};
	    $odestination .= $opath if $odestination =~ /\/$/;
	} else {
	    $odestination = $opath;
	}
	$destination = _realpath($odestination);
	#
	# check the expected contents
	#
	if (exists($opt{code})) {
	    $expected = $opt{code}->($expected);
	}
	unless (defined($expected)) {
	    throw_error("undefined contents");
	    return();
	}
	#
	# check the status and actual contents
	#
	$todo = 1;
	@dstat = LC::Fatal::stat($destination);
	if (@dstat) {
	    unless (-f _) {
		throw_error("invalid destination ($odestination)",
			    "not a regular file");
		return();
	    }
	    $actual = file_contents($destination);
	    unless (defined($actual)) {
		$_EC->rethrow_error();
		return();
	    }
	    $todo = 0 if $actual eq $expected;
	} else {
	    if ($_EC->error()->reason() == ENOENT) {
		# the destination does not exist yet
		$_EC->ignore_error();
	    } else {
		$_EC->rethrow_error();
		return();
	    }
	}
	#
	# update file contents
	#
	if ($todo and not $NoAction) {
	    unless (_unlink($destination, $opt{backup})) {
		$_EC->rethrow_error();
		return();
	    }
	    unless (defined(LC::Check::parent_directory($destination,
							"silent" => 1))) {
		$_EC->rethrow_error();
		return();
	    }
	    unless (file_contents($destination, $expected)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	#
	# tell the user
	#
	_message($todo, "update $odestination");
	$result++ if $todo;
	#
	# check owner, group and mode
	#
	%xopt = ();
	if (exists($opt{owner})) {
	    if ($opt{owner} eq "COPY") {
		$xopt{owner} = $sstat[ST_UID];
	    } else {
		$xopt{owner} = $opt{owner};
	    }
	} elsif (@dstat) {
	    $xopt{owner} = $dstat[ST_UID];
	}
	if (exists($opt{group})) {
	    if ($opt{group} eq "COPY") {
		$xopt{group} = $sstat[ST_GID];
	    } else {
		$xopt{group} = $opt{group};
	    }
	} elsif (@dstat) {
	    $xopt{group} = $dstat[ST_GID];
	}
	if (exists($opt{mode})) {
	    if ($opt{mode} eq "COPY") {
		$xopt{mode} = $sstat[ST_MODE] & S_IALLUGO;
	    } else {
		$xopt{mode} = $opt{mode};
	    }
	} elsif (@dstat) {
	    $xopt{mode} = $dstat[ST_MODE] & S_IALLUGO;
	}
	if (exists($opt{mtime})) {
	    if ($opt{mtime} eq "COPY") {
		$xopt{mtime} = $sstat[ST_MTIME];
	    } else {
		$xopt{mtime} = $opt{mtime};
	    }
	}
	if (keys(%xopt)) {
	    $todo = LC::Check::status($odestination, %xopt);
	    unless (defined($todo)) {
		$_EC->rethrow_error();
		return();
	    }
	    $result++ if $todo;
	}
    }
    return($result);
}

1;

__END__

=head1 NAME

LC::Check - check that things are really the way we expect them to be

=head1 SYNOPSIS

  # check that one file is the same as the master version
  LC::Check::file(undef, # unused
    source      => "/usr/lib/ncm/config/named/named.conf",
    destination => "/etc/named.conf",
    owner       => 0,
    mode        => 0644,
  );

  # idem but for a bunch of files (note the trailing /)
  %opt = ();
  $opt{source} = "/somewhere/openssh/";
  $opt{destination} = "/usr/bin/";
  $opt{mode} = 0555;
  foreach $name (qw(ssh scp ssh-keygen ssh-add)) {
    LC::Check::file($name, %opt);
  }
  # or even
  LC::Check::file([ qw(ssh scp ssh-keygen ssh-add) ], %opt);

  # make sure resolv.conf uses the localhost name server first
  LC::Check::file("/etc/resolv.conf",
    source => "/etc/resolv.conf",
    backup => '.old',
    code   => sub {
      my($contents) = @_;
      # do nothing if the file is missing
      return() unless $contents;
      # remove any nameserver line with 127.0.0.1
      $contents =~ s/^\s*nameserver\s+127\.0\.0\.1\s*\n//mg;
      # add the nameserver 127.0.0.1 in first position
      if ($contents =~ /^\s*nameserver\s/m) {
	  # another nameserver line exists, insert before it
	  $contents =~ s/^(\s*nameserver\s)/nameserver 127.0.0.1\n$1/m;
      } else {
	  # no other nameserver line, insert at the end
	  $contents =~ s/\s+$//s;
	  $contents .= "\nnameserver 127.0.0.1\n";
      }
      return($contents);
    },
  );

=head1 DESCRIPTION

This package provides the following functions (which are not exported
so you must prefix them with C<LC::Check::>):

=over

=item absence(PATHS)

check the absence of the given path, maybe destroying it; options:
file (destroy only files),
backup (rename instead of destroying, with this suffix)

=item directory(PATHS)

check that the given path is a directory; options:
mode (numerical mode used to create new directories, C<0755> by default)

=item file(PATHS)

check that the given path is a file with the expected contents; options
(the first four take the same value as C<status()> or C<COPY> meaning
use the same value as on the source file):
owner (expected owner),
group (expected group),
mode (expected mode),
mtime (expected modification time),
backup (rename the old file, with this suffix),
source (use this path as a source file or directory),
destination (use this path as a destination file or directory),
contents (use this as the contents of the file),
code (this Perl code is given the actual contents of the file
(using the C<source> or the C<contents> option) and
should return the expected contents)

=item group(GROUP, PATH...)

check the group (name or number) of the given list of paths; takes no
option

=item hardlink(SOURCE, TARGET)

check that SOURCE is really a hard link pointing to TARGET;
options: same as C<link()>

=item link(SOURCE, TARGET)

check that SOURCE is really link pointing to TARGET; options:
hard (if true create a hard link instead of a symlink),
backup (keep a backup copy of the source, with this suffix),
nocheck (do not check that target exists, valid only for symlinks),
force (remove the source if it's a file, valid only for symlinks)

=item mode(MODE, PATH...)

check the mode (see C<status()> for possible values) of the given list
of paths; takes no option

=item mtime(TIME, PATH...)

check the modification time of the given list of paths; takes no
option

=item owner(OWNER, PATH...)

check the owner (name or number) of the given list of paths; takes no
option

=item parent_directory(PATHS)

check that the parent directory of the given path exists; options:
same as C<directory()>

=item status(PATHS)

check some of the file status (i.e. the information usually returned
by stat(2)); options:
owner (expected owner, this can be a name or number),
group (expected group, this can be a name or number),
mode (exact mode or bits to check for presence (when prefixed with a C<+>)
or absence (C<->)),
mtime (expected modification time)

=item symlink(SOURCE, TARGET)

check that SOURCE is really a symbolic link pointing to TARGET;
options: same as C<link()>

=back

The PATHS arguments can always be a string (single path) or a reference
to a list of strings (multiple paths). In the later case, the
behaviour is identical to calling the function several times,
accumulating changes and stopping on the first error.

The return value is always the number of changes performed (or needed
if C<$NoAction> is true) or C<undef> in case of error.

=head1 OPTIONS

Most of the documented functions accept zero or more options that must
be given as pairs of (lowercase) key and value after the mandatory
parameter(s). Here are the global options understood by all these
functions:

=over

=item debug

locally override the global C<$Debug> variable

=item noaction

locally override the global C<$NoAction> variable

=item rootdir

locally override the global C<$RootDir> variable

=item silent

locally override the global C<$Silent> variable

=item verbose

locally override the global C<$Verbose> variable

=back

=head1 NOTES

When a parent directory needs to be created (e.g. for a new file to be
added), the module refuses to use paths containing C<.> or C<..>, for
paranoid security reasons. This should not be a problem in practice.

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Check.pm,v 1.21 2010/01/19 07:43:14 cons Exp $

=head1 TODO

=over

=item * document it more!

=item * print messages to a given filehandle instead of always STDOUT

=back

=cut
