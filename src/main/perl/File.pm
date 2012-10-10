#+##############################################################################
#                                                                              #
# File: File.pm                                                                #
#                                                                              #
# Description: assorted file and filesystem utilities                          #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::File;
use 5.006;
use strict;
use warnings;
use POSIX qw(O_WRONLY);
our $VERSION = sprintf("%d.%02d", q$Revision: 1.22 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(change_stat copy destroy differ directory_contents
		file_contents lock makedir move path_for_open random_file
		random_directory remove rglob unlock SYSBUFSIZE);

#
# used modules
#

use LC::Exception qw(throw_error throw_warning SUCCESS);
use LC::Fatal;
use LC::Stat qw(:ST :S file_type);
use LC::Util qw(random_name);
use POSIX qw(:errno_h O_RDONLY O_CREAT O_EXCL);
use sigtrap qw(die normal-signals); # so that ^C and such trigger END()

#
# constants
#

use constant SYSBUFSIZE => 8192; # meaningful buffer size for I/O operations

#
# private variables
#

our(
    $_EC,               # module's exception context
    $_OPENFLAGS,	# flags to give to sysopen for random_file()
    %_Lock,		# locked files (file path => lock path)
);

$_EC = LC::Exception::Context->new()->will_store_errors();

#
# forward declarations for recursive functions
#

sub remove  ($);
sub destroy ($);
sub makedir ($;$);

#+++############################################################################
#                                                                              #
# read a directory contents                                                    #
#                                                                              #
#---############################################################################

sub directory_contents ($) {
    my($path) = @_;
    my(@contents);
    local(*DH);

    unless (opendir(DH, $path)) {
	throw_error("opendir($path)", $!);
	return();
    }
    @contents = grep($_ !~ /^\.\.?$/, readdir(DH));
    unless (closedir(DH)) {
	throw_error("closedir($path)", $!);
	return();
    }
    return(\@contents);
}

#+++############################################################################
#                                                                              #
# return a string suitable for open (allowing weird characters in file name)   #
#                                                                              #
#---############################################################################

sub path_for_open ($) {
    my($path) = @_;

    $path =~ s=^([^/])=./$1=;
    return($path . "\0");
}

#+++############################################################################
#                                                                              #
# read or write to a file                                                      #
#                                                                              #
#---############################################################################

sub file_contents ($;$) {
    my($path, $contents) = @_;
    my($length, $offset, $done);
    local(*FH);

    # write to a file
    if (defined($contents)) {
	unless (remove($path)) {
	    $_EC->rethrow_error();
	    return();
	}
	unless (sysopen(FH, path_for_open($path), O_CREAT|O_WRONLY|O_EXCL)) {
	    throw_error("sysopen($path, O_WRONLY|O_CREAT|O_EXCL)", $!);
	    return();
	}
	unless (binmode(FH)) {
	    throw_error("binmode($path)", $!);
	    return();
	}
	$length = length($contents);
        $offset = 0;
        while ($length) {
            $done = syswrite(FH, $contents, SYSBUFSIZE, $offset);
            unless (defined($done)) {
		throw_error("syswrite($path)", $!);
		return();
	    }
            $length -= $done;
            $offset += $done;
        }
	unless (close(FH)) {
	    throw_error("close($path)", $!);
	    return();
	}
	return(SUCCESS);
    }
    # read from a file
    unless (open(FH, "<" . path_for_open($path))) {
	throw_error("open($path)", $!);
	return();
    }
    unless (binmode(FH)) {
	throw_error("binmode($path)", $!);
	return();
    }
    $contents = "";
    while (1) {
	$done = sysread(FH, $contents, SYSBUFSIZE, length($contents));
	unless (defined($done)) {
	    throw_error("sysread($path)", $!);
	    return();
	}
	last unless $done;
    }
    unless (close(FH)) {
	throw_error("close($path)", $!);
	return();
    }
    return($contents);
}

#+++############################################################################
#                                                                              #
# check if two files differ (block by block comparison of the contents)        #
#                                                                              #
#---############################################################################

sub differ ($$) {
    my($path1, $path2) = @_;
    my($differ, @stat1, @stat2, $done1, $done2, $data1, $data2, $length1, $length2, $common);
    local(*FH1, *FH2);
    
    # first try with stat()
    @stat1 = stat($path1);
    unless (@stat1) {
	throw_error("stat($path1)", $!);
	return();
    }
    @stat2 = stat($path2);
    unless (@stat2) {
	throw_error("stat($path2)", $!);
	return();
    }
    return(1) if $stat1[ST_SIZE] != $stat2[ST_SIZE];
    # init
    unless (open(FH1, "<" . path_for_open($path1))) {
	throw_error("open($path1)", $!);
	return();
    }
    unless (binmode(FH1)) {
	throw_error("binmode($path1)", $!);
	return();
    }
    unless (open(FH2, "<" . path_for_open($path2))) {
	throw_error("open($path2)", $!);
	return();
    }
    unless (binmode(FH2)) {
	throw_error("binmode($path2)", $!);
	return();
    }
    $data1 = $data2 = "";
    while (1) {
	$done1 = sysread(FH1, $data1, SYSBUFSIZE, length($data1));
	unless (defined($done1)) {
	    throw_error("sysread($path1)", $!);
	    return();
	}
	$done2 = sysread(FH2, $data2, SYSBUFSIZE, length($data2));
	unless (defined($done2)) {
	    throw_error("sysread($path2)", $!);
	    return();
	}
	$length1 = length($data1);
	$length2 = length($data2);
	# compare the common bytes
	$common = $length1 < $length2 ? $length1 : $length2;
	if ($common > 0) {
	    if (substr($data1, 0, $common) ne substr($data2, 0, $common)) {
		$differ = 1;
		last;
	    }
	    substr($data1, 0, $common) = "";
	    $length1 -= $common;
	    substr($data2, 0, $common) = "";
	    $length2 -= $common;
	}
	# check for end-of-file
	if ($done1 == 0 and $length1 == 0) {
	    if ($done2 == 0 and $length2 == 0) {
		# both at end-of-file with no leftover data
		$differ = 0;
		last;
	    } elsif ($length2 > 0) {
		# file1 necessarily too short
		$differ = 1;
		last;
	    }
	}
	if ($done2 == 0 and $length2 == 0) {
	    if ($length1 > 0) {
		# file2 necessarily too short
		$differ = 1;
		last;
	    }
	}
    }
    unless (close(FH1)) {
	throw_error("close($path1)", $!);
	return();
    }
    unless (close(FH2)) {
	throw_error("close($path2)", $!);
	return();
    }
    return($differ);
}

#+++############################################################################
#                                                                              #
# remove a file (not a directory!) with unlink() and maybe rename() if busy    #
#                                                                              #
#---############################################################################

sub remove ($) {
    my($path) = @_;
    my($slash, $busy);

    return(SUCCESS) unless -l $path or -e _; # ok if it does not exist
    # we detect directories here because Perl's unlink could work on directories
    # which is a very bad idea, see unlink's documentation for more information
    if (-d _) {
	throw_error("cannot remove a directory");
	return();
    }
    # we first try to unlink the file
    unlink($path) and return(SUCCESS);
    # did it fail because of a text file busy error?
    unless ($! == ETXTBSY) {
	throw_error("unlink($path)", $!);
	return();
    }
    # we now try to rename the file /foo/bar -> /foo/#bar
    $slash = rindex($path, "/");
    if ($slash < 0) {
	$busy = "#" . $path;
    } else {
	$slash++;
	$busy = substr($path, 0, $slash) . "#" . substr($path, $slash);
    }
    unless (remove($busy)) {
        $_EC->rethrow_error();
	return();
    }
    unless (LC::Fatal::rename($path, $busy)) {
        $_EC->rethrow_error();
	return();
    }
    # success
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# destroy everything under a given path a la 'rm -fr'                          #
# (busy files will create problems as they will prevent directory removal)     #
#                                                                              #
#---############################################################################

sub destroy ($) {
    my($path) = @_;
    my($name);
    local(*DH);

    return(SUCCESS) unless -l $path or -e _; # ok if it does not exist
    # destroy a directory
    if (-d _) {
        unless (opendir(DH, $path)) {
            throw_error("opendir($path)", $!);
            return();
        }
	# destroy the directory contents
        while (defined($name = readdir(DH))) {
            next if $name =~ /^\.\.?$/;
	    next unless $name =~ /^(.*)$/;
	    $name = $1; # untainted now...
	    unless (destroy("$path/$name")) {
		$_EC->rethrow_error();
		return();
	    }
        }
	unless (closedir(DH)) {
            throw_error("closedir($path)", $!);
            return();
	}
	# remove the (now) empty directory
	unless (LC::Fatal::rmdir($path)) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    # destroy something else
    else {
	unless (LC::Fatal::unlink($path)) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    # success
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# change several file stat() attributes: mode, atime, mtime, uid and gid       #
#                                                                              #
#---############################################################################

sub change_stat ($@) {
    my($path, @stat) = @_;

    unless (LC::Fatal::chmod($stat[ST_MODE] & S_IALLUGO, $path)) {
	$_EC->rethrow_error();
	return();
    }
    unless (LC::Fatal::utime($stat[ST_ATIME], $stat[ST_MTIME], $path)) {
	$_EC->rethrow_error();
	return();
    }
    unless (LC::Fatal::chown($stat[ST_UID], $stat[ST_GID], $path)) {
	$_EC->rethrow_error();
	return();
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# copy a file, following symlink (this is loosely based on Camel's syswrite)   #
#                                                                              #
#---############################################################################

sub copy ($$;%) {
    my($from, $to, %opt) = @_;
    my($mode, $preserve, @stat, $buffer, $length, $done, $offset);
    local(*FROM, *TO);

    # option parsing
    $mode = $opt{append} ? ">>" : ">";
    delete($opt{append});
    $preserve = $opt{preserve};
    delete($opt{preserve});
    if (keys(%opt)) {
	throw_error("invalid option", (keys(%opt))[0]);
	return();
    }
    # init
    if ($preserve) {
	unless (@stat = LC::Fatal::stat($from)) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    unless (open(FROM, "<" . path_for_open($from))) {
	throw_error("open($from)", $!);
	return();
    }
    unless (binmode(FROM)) {
	throw_error("binmode($from)", $!);
	return();
    }
    if ($mode eq ">") {
	unless (remove($to)) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    unless (open(TO, $mode . path_for_open($to))) {
	throw_error("open($mode$to)", $!);
	return();
    }
    unless (binmode(TO)) {
	throw_error("binmode($to)", $!);
	return();
    }
    # copy
    $buffer = "";
    while (1) {
	$length = sysread(FROM, $buffer, SYSBUFSIZE);
        unless (defined($length)) {
	    throw_error("sysread($from)", $!);
	    goto CLEAN_AND_GIVEUP;
	}
	last unless $length;
        $offset = 0;
        while ($length) {
            $done = syswrite(TO, $buffer, $length, $offset);
            unless (defined($done)) {
		throw_error("syswrite($to)", $!);
		goto CLEAN_AND_GIVEUP;
	    }
            $length -= $done;
            $offset += $done;
        }
    }
    # close
    unless (close(TO)) {
	throw_error("close($to)", $!);
	goto CLEAN_AND_GIVEUP;
    }
    unless (close(FROM)) {
	throw_error("close($from)", $!);
	goto CLEAN_AND_GIVEUP;
    }
    # maybe preserve stat info
    if ($preserve) {
	unless (change_stat($to, @stat)) {
	    $_EC->rethrow_error();
	    goto CLEAN_AND_GIVEUP;
	}
    }
    # so far so good
    return(SUCCESS);
  CLEAN_AND_GIVEUP:
    unlink($to) or throw_warning("unlink($to)", $!);
    return();
}

#+++############################################################################
#                                                                              #
# move a file, following the /bin/mv algorithm: rename or copy+unlink          #
# (except that the second argument cannot be a directory)                      #
#                                                                              #
#---############################################################################

sub move ($$) {
    my($from, $to) = @_;

    # we first try to rename the file
    rename($from, $to) and return(SUCCESS);
    # did it fail because of a cross-device link?
    unless ($! == EXDEV) {
	throw_error("rename($from, $to)", $!);
	return();
    }
    # we now try to copy and preserve mode, owner...
    unless (copy_preserve($from, $to)) {
	throw_error("copy_preserve($from, $to)", $_EC->error());
	return();
    }
    # we finally remove the source
    unless (LC::Fatal::unlink($from)) {
	unlink($to) or throw_warning("unlink($to)", $!);
        $_EC->rethrow_error();
	return();
    }
    # succes
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# recursively make directories with mode 0755 by default                       #
#                                                                              #
#---############################################################################

sub makedir ($;$) {
    my($dir, $mode) = @_;

    $dir =~ s=/+$==;
    unless ($dir eq "" or -d $dir) {
	$mode = 0755 unless defined($mode);
        if ($dir =~ m=^(.+)/[^/]+$=) {
            unless (makedir($1, $mode)) {
		$_EC->rethrow_error();
		return();
	    }
        }
	unless (LC::Fatal::mkdir($dir, $mode)) {
	    $_EC->rethrow_error();
	    return();
	}
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# restricted version of Perl's glob(): does not fork any shell and does not    #
# trigger automounters but only handles a single * as full directory wildcard  #
# and does not follow symbolic links                                           #
#                                                                              #
#---############################################################################

sub rglob ($) {
    my($pattern) = @_;
    my($before, $after, $list, $name, @result);

    # check the pattern
    unless ($pattern =~ /^(.*)\*(.*)$/) {
	throw_error("invalid pattern (no *)", $pattern);
	return();
    }
    ($before, $after) = ($1, $2);
    if ($before =~ /\*/ or $after =~ /\*/) {
	throw_error("invalid pattern (too many *)", $pattern);
	return();
    }
    if (length($before) and $before !~ /\/$/) {
	throw_error("invalid pattern (no dir before *)", $pattern);
	return();
    }
    if (length($after) and $after !~ /^\//) {
	throw_error("invalid pattern (no dir after *)", $pattern);
	return();
    }
    # read the directory
    if ($before) {
	# it's not an error if the directory does not exist
	return([]) unless -d $before;
	$list = directory_contents($before);
    } else {
	$list = directory_contents(".");
    }
    unless ($list) {
	# oops, error while reading directory...
        $_EC->rethrow_error();
	return();
    }
    # check directory contents
    @result = ();
    foreach $name (@$list) {
	# skip files starting with a dot
	next if $name =~ /^\./;
	# skip symbolic links
	next if -l "$before$name";
	# test if what is after the * matches
	next if $after and not -e "$before$name$after";
	# ok for this one
	push(@result, "$before$name$after");
    }
    return(\@result);
}

#+++############################################################################
#                                                                              #
# create a file or a directory with a random name                              #
#                                                                              #
#---############################################################################

sub random_file ($;$) {
    my($template, $mode) = @_;
    throw_error("not yet implemented");

    unless ($_OPENFLAGS) {
	my($name, $bit, $func);
	$_OPENFLAGS = POSIX::O_CREAT() | POSIX::O_EXCL() | POSIX::O_RDWR();
	foreach $name (qw(BINARY LARGEFILE)) {
	    no strict "refs";
	    $bit = 0;
	    $func = "POSIX::O_$name";
	    eval {
		local $SIG{__DIE__}  = sub {};
		local $SIG{__WARN__} = sub {};
		$bit = &$func();
		1;
	    };
	    $_OPENFLAGS |= $bit unless $@;
	}
    }
}

sub random_directory ($;$) {
    my($template, $mode) = @_;
    my($count, $path);

    unless ($template =~ /X/) {
        throw_error("invalid template (no Xs)", $template);
        return();
    }
    $mode = 0755 unless defined($mode);
    $count = 100;
    while ($count-- > 0) {
	$path = $template;
	$path =~ s/X+/random_name()/eg;
	unless (LC::Fatal::mkdir($path, $mode)) {
	    if ($_EC->error()->reason() == EEXIST) {
		$_EC->ignore_error();
		next;
	    }
	    $_EC->rethrow_error();
	    return();
	}
	return($path);
    }
    throw_error("failed to generate a unique name");
    return();
}

#+++############################################################################
#                                                                              #
# lock management                                                              #
#                                                                              #
#---############################################################################

#
# try to get an exclusive lock for the given path
#
# we use a very simple method (create a separate file with O_EXCL) that all
# the other programs must respect, i.e. they should use the same algorithm.
# this should work fine on a local filesystem or in AFS, even across multiple
# machines, however this does not work in NFS. you've been warned ;-)
#

sub lock ($;%) {
    my($path, %opt) = @_;
    my($lock, @stat);
    local(*LOCK);

    # sanity checks
    @stat = grep($_ !~ /^(attempts|max_age|sleep|suffix)$/, keys(%opt));
    if (@stat) {
	throw_error("invalid option", $stat[0]);
	return();
    }
    $opt{suffix} = ".lock" unless defined($opt{suffix});
    $lock = $path . $opt{suffix};
    while (1) {
	if (sysopen(LOCK, $lock, O_RDONLY|O_CREAT|O_EXCL)) {
	    # at this point we consider that we have obtained the lock
	    $_Lock{$path} = $lock;
	    unless (close(LOCK)) {
		# this is weird, but we simply warn as we (should) have the lock
		throw_warning("close($lock)", $!);
	    }
	    return(SUCCESS);
	}
	# we could not create the lock, check why
	if ($! != EEXIST) {
	    # this is weird, we immediately give up
	    throw_error("open($lock)", $!);
	    return();
	}
	# now we know that the lock already exists
	@stat = lstat($lock);
	unless (@stat) {
	    if ($! == ENOENT) {
		# ooops, the lock has been removed between sysopen() and lstat()
		# same player shoot again ;-)
		next;
	    }
	    # this is weird, we immediately give up
	    throw_error("lstat($lock)", $!);
	    return();
	}
	unless (S_ISREG($stat[ST_MODE])) {
	    # this is weird, the lock exists and is not a plain file!
	    throw_error("unexpected type for lock $lock", file_type($stat[ST_MODE]));
	    return();
	}
	if (defined($opt{max_age}) and $stat[ST_MTIME] < time() - $opt{max_age}) {
	    # this lock is too old, we try to steal/remove it
	    unless (unlink($lock)) {
		# this is bad, we could not remove the old lock
		throw_error("unlink($lock)", $!);
		return();
	    }
	    # so far so good, we issue a warning and try (again) to get the lock
	    throw_warning("removed old lock", $lock);
	    next;
	}
	# so we could not get or steal the lock this time, shall we try again?
	if (defined($opt{attempts}) and --$opt{attempts} <= 0) {
	    # no, we give up, but without throwing an error
	    return(0);
	}
	# let's try again but we should maybe sleep a bit before
	select(undef, undef, undef, $opt{sleep}) if $opt{sleep};
    }
}

#
# remove a lock previously obtained with lock()
#

sub unlock ($) {
    my($path) = @_;

    unless ($_Lock{$path}) {
	throw_error("file is not locked", $path);
	return();
    }
    unless (unlink($_Lock{$path})) {
	throw_error("unlink($_Lock{$path})", $!);
	return();
    }
    delete($_Lock{$path});
    return(SUCCESS);
}

#
# make sure the locks are removed
#

END {
    my($path, $ignored);

    # we should probably warn here as the locks should have been removed before
    # but it is probably a bit risky to throw a warning from an END block
    # so we silently try to remove all the locks and ignore any error
    foreach $path (values(%_Lock)) {
	$ignored = unlink($path);
    }
}

1;

__END__

=head1 NAME

LC::File - assorted file and filesystem utilities

=head1 SYNOPSIS

    use LC::File qw(destroy copy);
    copy("/etc/passwd", "/etc/passwd.old", "preserve" => 1);
    destroy("/tmp/junk") or die;

=head1 DESCRIPTION

This package provides the following functions:

=over

=item change_stat(PATH, STAT_LIST)

change the file status (mode, atime, mtime, uid and gid) accoring to
the given stat() list; return true on success

=item copy(OLDPATH, NEWPATH[, OPTIONS])

copy a file; return true on success; options:
preserve (preserve the mode, atime, mtime, uid and gid),
append (append instead of overwriting destination)

=item destroy(PATH)

recursively destroy a path; return true on success

=item directory_contents(PATH)

read the given directory and return a reference to the list of entries
except C<.> and C<..>; return false on failure

=item differ(PATH1, PATH2)

return true if the two given files differ; return undef on failure

=item file_contents(PATH)

read the given file and return its contents as a single string;
return undef on failure

=item file_contents(PATH, STRING)

write the given string to the given path; return true on success

=item lock(PATH[, OPTIONS...)

try to obtain an exclusive lock for the given PATH with an ad-hoc algorithm;
options are:
C<attempts> (number of times to try before giving up, default is forever),
C<max_age> (maximum allowed age for the lock file in seconds,
after this the lock can be stolen),
C<sleep> (number of seconds to sleep between attempts, can be fractional),
C<suffix> (suffix to add to the path to get the lock path, default is C<.lock>)

=item makedir(PATH[, MODE])

recursively make directories; return true on success

=item move(OLDPATH, NEWPATH)

move a file; return true on success

=item path_for_open(PATH)

transform a path string into something safe to give to open(),
escaping E<gt> and other dangerous characters

=item random_directory(TEMPLATE[, MODE])

create a directory with a random name (derived from TEMPLATE replacing
every sequence of C<X> characters by 8 random characters) and with the
given mode (or C<0755> if not specified); return the path of the
created directory

=item remove(PATH)

remove a file, handling busy files by renaming them;
return true on success

=item rglob(PATTERN)

restricted globing function understanding only a single C<*> in the
pattern (on the other hand it does not fork, trigger automounters or
follow symlinks), return a reference to the result; return false on failure

=item unlock(PATH)

release the lock previously obtained using lock()

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: File.pm,v 1.22 2009/12/04 15:17:19 cons Exp $

=cut
