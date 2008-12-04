#+##############################################################################
#                                                                              #
# File: Spool.pm                                                               #
#                                                                              #
# Description: file spool handling with multiple readers and writers           #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Spool;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.1 $ =~ /(\d+)\.(\d+)/);

#
# used modules
#

use LC::Exception qw(throw_error throw_warning SUCCESS);
use LC::File qw(directory_contents);
use LC::Stat qw(:ST);
use LC::Util qw(random_name);
use POSIX qw(:errno_h :fcntl_h);

#+++############################################################################
#                                                                              #
# spool directory handling                                                     #
#                                                                              #
#---############################################################################

#
# check that an existing directory can be used as a spool directory
# (does not correct problems, simply report them as errors)
#

sub check ($;$) {
    my($spool, $secure) = @_;
    my(@stat, $mode);

    @stat = stat($spool);
    unless (@stat) {
	throw_error("stat($spool)", $!);
	return();
    }
    unless (-d _) {
	throw_error("stat($spool)", "Not a directory");
	return();
    }
    if ($secure) {
	$mode = $stat[ST_MODE] & LC::Stat::S_IALLUGO;
	unless ($mode == LC::Stat::S_IRWXU) {
	    throw_error("insecure mode", sprintf("%04o", $mode));
	    return();
	}
	unless ($stat[ST_UID] == $>) {
	    throw_error("insecure owner", $stat[ST_UID]);
	    return();
	}
    }
    return(SUCCESS);
}

#
# clean a spool directory:
#  - remove old temporary files
#  - rename old locked files (to move them back in)
#  - throw an error if a foreign file is found (yes, even core!)
#

sub clean ($;$) {
    my($spool, $age) = @_;
    my($names, $name, @stat, $now);

    $names = directory_contents($spool) or return();
    $now = time;
    foreach $name (@$names) {
	unless ($name =~ /^([\w\+]{8})\.(tmp|lck|ok)$/) {
	    throw_error("foreign file found", $name);
	    return();
	}
	$name = "$1.$2"; # untaint $name
	if ($age) {
	    @stat = lstat("$spool/$name");
	    unless (@stat) {
		# this can happen if the file changed after the readdir()
		# so we just throw a warning...
		throw_warning("lstat($spool/$name)", $!);
		return();
	    }
	    next if $stat[ST_ATIME] > $now - $age;
	    next if $stat[ST_MTIME] > $now - $age;
	}
	# so now we know that the file is old enough
	if ($2 eq "tmp") {
	    if (unlink("$spool/$name")) {
		throw_warning("temporary file removed", $name);
	    } else {
		throw_error("unlink($name)", $!);
		return();
	    }
	} elsif ($2 eq "lck") {
	    if (rename("$spool/$name", "$spool/$1.ok")) {
		throw_warning("lock file removed", $name);
	    } else {
		throw_error("rename($name, $1.ok)", $!);
		return();
	    }
	}
    }
    return(SUCCESS);
}

#
# return the list of names of files in the spool (.ok only, ignore the rest)
#

sub names ($) {
    my($spool) = @_;
    my($names, $name, @result);

    $names = directory_contents($spool) or return();
    foreach $name (@$names) {
	next unless $name =~ /^([\w\+]{8})\.ok$/;
	push(@result, $1);
    }
    return(\@result);
}

#+++############################################################################
#                                                                              #
# spool file handling                                                          #
#                                                                              #
#---############################################################################

#
# low level functions to manipulate files
#

sub _create_tmp ($) {
    my($spool) = @_;
    my($name, $fd);

  try_again:
    $name = random_name();
    goto try_again if -e "$spool/$name.tmp";
    goto try_again if -e "$spool/$name.ok";
    goto try_again if -e "$spool/$name.lck";
    $fd = POSIX::open("$spool/$name.tmp", O_CREAT|O_EXCL|O_WRONLY, 0644);
    unless ($fd) {
	if ($! == EEXIST) {
	    goto try_again;
	} else {
	    throw_error("open($name.tmp)", $!);
	    return();
	}
    }
    return($name, $fd);
}

sub _write_tmp ($$$$) {
    my($spool, $name, $fd, $contents) = @_;
    my($wrote, $ignored);

    while (length($contents) > 0) {
	$wrote = POSIX::write($fd, $contents, length($contents));
	unless ($wrote) {
	    throw_error("write($name.tmp)", $!);
	    $ignored = unlink("$spool/$name.tmp");
	    return();
	}
	substr($contents, 0, $wrote) = "";
    }
    return(SUCCESS);
}

sub _commit_tmp ($$$) {
    my($spool, $name, $fd) = @_;
    my($ignored);

    unless (POSIX::close($fd)) {
	throw_error("close($name.tmp)", $!);
	$ignored = unlink("$spool/$name.tmp");
	return();
    }
    unless (rename("$spool/$name.tmp", "$spool/$name.ok")) {
	throw_error("rename($name.tmp, $name.ok)", $!);
	$ignored = unlink("$spool/$name.tmp", "$spool/$name.ok");
	return();
    }
    return(SUCCESS);
}

#
# add a file to the spool (given its contents)
#

sub add ($$) {
    my($spool, $contents) = @_;
    my($name, $fd);

    ($name, $fd) = _create_tmp($spool) or return();
    _write_tmp($spool, $name, $fd, $contents) or return();
    _commit_tmp($spool, $name, $fd) or return();
    return($name);
}

#
# rename an existing file to add it to the spool
#

sub add_path ($$) {
    my($spool, $path) = @_;
    my($name);

  try_again:
    $name = random_name();
    goto try_again if -e "$spool/$name.ok";
    goto try_again if -e "$spool/$name.tmp";
    goto try_again if -e "$spool/$name.lck";
    unless (rename($path, "$spool/$name.ok")) {
	throw_error("rename($path, $name.ok)", $!);
	return();
    }
    return($name);
}

#
# lock a file in the spool (must be ok)
#

sub lock ($$) {
    my($spool, $name) = @_;

    unless (rename("$spool/$name.ok", "$spool/$name.lck")) {
	throw_error("rename($name.ok, $name.lck)", $!);
	return();
    }
    return(SUCCESS);
}

#
# unlock a file in the spool (must be locked)
#

sub unlock ($$) {
    my($spool, $name) = @_;

    unless (rename("$spool/$name.lck", "$spool/$name.ok")) {
	throw_error("rename($name.lck, $name.ok)", $!);
	return();
    }
    return(SUCCESS);
}

#
# remove a file from the spool (must be locked)
#

sub remove ($$) {
    my($spool, $name) = @_;

    unless (unlink("$spool/$name.lck")) {
	throw_error("unlink($name.lck)", $!);
	return();
    }
    return(SUCCESS);
}

#
# return the full path of a file in the spool
#

sub path ($$) {
    my($spool, $name) = @_;
    return("$spool/$name.ok")  if -f "$spool/$name.ok";
    return("$spool/$name.tmp") if -f "$spool/$name.tmp";
    return("$spool/$name.lck") if -f "$spool/$name.lck";
    return();
}

#
# test file in the spool
#

sub is_ok ($$) {
    my($spool, $name) = @_;
    return(-f "$spool/$name.ok");
}

sub is_temporary ($$) {
    my($spool, $name) = @_;
    return(-f "$spool/$name.tmp");
}

sub is_locked ($$) {
    my($spool, $name) = @_;
    return(-f "$spool/$name.lck");
}

1;

__END__

=head1 NAME

LC::Spool - file spool handling with multiple readers and writers

=head1 SYNOPSIS

    use LC::Spool;

    # common
    $path = "/var/spool/foo";
    LC::Spool::check($path);
    LC::Spool::clean($path, 60);

    # writer
    $name = LC::Spool::add($path, $data);

    # reader/cleaner
    $names = LC::Spool::names($path);
    foreach $name (@$names) {
	next unless LC::Spool::is_ok($path, $name);
        LC::Spool::lock($path, $name);
        ... do something ...
        LC::Spool::remove($path, $name);
    }

=head1 DESCRIPTION

This module provides functions to manipulate files in a spool
directory. The files can be added, locked or removed. Multiple
programs can access and modifiy the spool at the same time.

Files stored in the spool directory have a unique eight alphanumeric
characters (with also the C<+> sign) name followed by a two or three
characters extension which can be C<tmp> for temporary files (being
added to the spool), C<lck> for locked files (being removed from the
spool) or C<ok> for normal files.

This package provides the following functions (none of them are
exported):

=over

=item add(SPOOL, CONTENTS)

add the given CONTENTS to a new file in the spool and return its name

=item add_path(SPOOL, PATH)

rename an existing file so that it appears as a new file in the spool
and return its name (this is really I<rename>, use add to I<copy> a file)

=item check(SPOOL[, SECURE])

check that the spool path is suitable to be used as a spool (i.e. it
must be an existing directory); if SECURE is true, also check the
directory mode and owner

=item clean(SPOOL[, AGE])

clean the spool by removing old temporary files and renaming old
locked files (optionally older than the given AGE in seconds); extra
files in the directory will cause an error

=item is_locked(SPOOL, NAME)

return true if the file is locked

=item is_ok(SPOOL, NAME)

return true if the file is ok

=item is_temporary(SPOOL, NAME)

return true if the file is temporary

=item lock(SPOOL, NAME)

lock a file given its name (the file must be ok)

=item names(SPOOL)

return a reference to the list of available files in the spool; does
not return locked or temporary files

=item path(SPOOL, NAME)

return the full path of the file in the spool

=item remove(SPOOL, NAME)

remove a file given its name (the file must be locked)

=item unlock(SPOOL, NAME)

unlock a file given its name (the file must be locked)

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Spool.pm,v 1.1 2008/07/01 11:46:05 poleggi Exp $

=cut
