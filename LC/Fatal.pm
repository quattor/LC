#+##############################################################################
#                                                                              #
# File: Fatal.pm                                                               #
#                                                                              #
# Description: fatal equivalent of some core Perl functions                    #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Fatal;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.2 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(open close sysread syswrite chdir chmod chown link lstat mkdir
		readlink rename rmdir stat symlink unlink utime);

#
# used modules
#

use LC::Exception qw(SUCCESS throw_error);

#+++############################################################################
#                                                                              #
# input / output                                                               #
#                                                                              #
#---############################################################################

# transform a passed handle (prototype *) into something usable
sub _usable_handle ($) {
    my($handle) = @_;
    my($ok, $pkg);

    if (not $handle) {
	# don't know what to do with this one...
    } elsif (UNIVERSAL::isa($handle, "GLOB")) {
	# glob: foo(*HANDLE) or foo(\*HANDLE)
	$ok = $handle;
    } elsif (UNIVERSAL::isa($handle, "FileHandle")) {
	# FileHandle object
	$ok = $handle;
    } elsif (ref($handle)) {
	# don't know what to do with this one...
    } else {
	# bareword: foo(HANDLE)
	$ok = $handle;
	unless ($handle =~ /::/) {
	    # put it in the right namespace
	    $pkg = caller(1);
	    $ok = $pkg . "::" . $handle if defined($pkg);
	}
    }
    return($ok);
}

# note: only the two-arguments version is supported
sub open (*$) {
    my($fh, $what) = @_;
    my($ufh, $res);

    unless ($ufh = _usable_handle($fh)) {
	throw_error("invalid filehandle", $fh);
	return();
    }
    {
	no strict "refs"; # avoid: Can't use string (...) as a symbol ref ...
	$res = CORE::open($ufh, $what);
    }
    return($res) if defined($res);
    throw_error("open($fh, $what)", $!);
    return();
}

# note: only the one-argument version is supported
sub close (*) {
    my($fh) = @_;
    my($ufh, $res);

    unless ($ufh = _usable_handle($fh)) {
	throw_error("invalid filehandle", $fh);
	return();
    }
    {
	no strict "refs"; # avoid: Can't use string (...) as a symbol ref ...
	$res = CORE::close($ufh);
    }
    return($res) if $res;
    if ($!) {
	throw_error("close($fh)", $!);
    } else {
	throw_error("close($fh)", "status: $?");
    }
    return();
}

sub sysread (*$$;$) {
    my($fh, $dummy, $length, $offset) = @_;
    my($ufh, $res);

    unless ($ufh = _usable_handle($fh)) {
	throw_error("invalid filehandle", $fh);
	return();
    }
    $offset = 0 unless defined($offset);
    {
	no strict "refs"; # avoid: Can't use string (...) as a symbol ref ...
	$res = CORE::sysread($ufh, $_[1], $length, $offset);
    }
    return($res) if defined($res);
    throw_error("sysread($fh, \$data, $length, $offset)", $!);
    return();
}

sub syswrite (*$;$$) {
    my($fh, $dummy, $length, $offset) = @_;
    my($ufh, $res);

    unless ($ufh = _usable_handle($fh)) {
	throw_error("invalid filehandle", $fh);
	return();
    }
    $length = length($_[1]) unless defined($length);
    $offset = 0 unless defined($offset);
    {
	no strict "refs"; # avoid: Can't use string (...) as a symbol ref ...
	$res = CORE::syswrite($ufh, $_[1], $length, $offset);
    }
    return($res) if defined($res);
    throw_error("syswrite($fh, \$data, $length, $offset)", $!);
    return();
}

#+++############################################################################
#                                                                              #
# file operations                                                              #
#                                                                              #
#---############################################################################

sub chmod ($@) {
    my($mode, @paths) = @_;
    return(SUCCESS) if CORE::chmod($mode, @paths) == @paths;
    local $" = ", ";
    throw_error("chmod(0" . sprintf("%o", $mode) . ", @paths)", $!);
    return();    
}

sub chown ($$@) {
    my($uid, $gid, @paths) = @_;
    return(SUCCESS) if CORE::chown($uid, $gid, @paths) == @paths;
    local $" = ", ";
    throw_error("chown($uid, $gid, @paths)", $!);
    return();    
}

sub unlink (@) {
    my(@paths) = @_;
    return(SUCCESS) if CORE::unlink(@paths) == @paths;
    local $" = ", ";
    throw_error("unlink(@paths)", $!);
    return();    
}

sub utime ($$@) {
    my($atime, $mtime, @paths) = @_;
    return(SUCCESS) if CORE::utime($atime, $mtime, @paths) == @paths;
    local $" = ", ";
    throw_error("utime($atime, $mtime, @paths)", $!);
    return();    
}

sub readlink ($) {
    my($path, $res) = @_;
    $res = CORE::readlink($path);
    return($res) if defined($res);
    throw_error("readlink($path)", $!);
    return();
}

sub stat ($) {
    my($path, @res) = @_;
    @res = CORE::stat($path);
    return(@res) if @res;
    throw_error("stat($path)", $!);
    return();    
}

sub lstat ($) {
    my($path, @res) = @_;
    @res = CORE::lstat($path);
    return(@res) if @res;
    throw_error("lstat($path)", $!);
    return();    
}

sub rename ($$) {
    my($oldpath, $newpath) = @_;
    return(SUCCESS) if CORE::rename($oldpath, $newpath);
    throw_error("rename($oldpath, $newpath)", $!);
    return();    
}

sub link ($$) {
    my($oldpath, $newpath) = @_;
    return(SUCCESS) if CORE::link($oldpath, $newpath);
    throw_error("link($oldpath, $newpath)", $!);
    return();    
}

sub symlink ($$) {
    my($oldpath, $newpath) = @_;
    return(SUCCESS) if CORE::symlink($oldpath, $newpath);
    throw_error("symlink($oldpath, $newpath)", $!);
    return();    
}

#+++############################################################################
#                                                                              #
# directory handling                                                           #
#                                                                              #
#---############################################################################

sub chdir ($) {
    my($path) = @_;
    return(SUCCESS) if CORE::chdir($path);
    throw_error("chdir($path)", $!);
    return();
}

sub mkdir ($$) {
    my($path, $mode) = @_;
    return(SUCCESS) if CORE::mkdir($path, $mode);
    throw_error("mkdir($path, 0" . sprintf("%o", $mode) . ")", $!);
    return();
}

sub rmdir ($) {
    my($path) = @_;
    return(SUCCESS) if CORE::rmdir($path);
    throw_error("rmdir($path)", $!);
    return();
}

1;

__END__

=head1 NAME

LC::Fatal - fatal equivalent of some core Perl functions

=head1 SYNOPSIS

    use LC::Fatal qw(chdir);
    chdir($path);

=head1 DESCRIPTION

This package allows you to replace some core Perl functions with
equivalent ones that generate an exception in case of failure. The
replacement functions behave more or less like the core ones except
that:

=over

=item C<$_> is never used

=item chmod(), chown(), unlink() and utime() return success only if
the operation succeeded on _all_ the paths

=item stat() and lstat() work only on paths, not on filehandles

=back

Implemented functions:

=over

=item chdir(PATH)

=item chmod(MODE, PATH...)

=item chown(UID, GID, PATH...)

=item link(OLDPATH, NEWPATH)

=item lstat(PATH)

=item mkdir(PATH, MODE)

=item readlink(PATH)

=item rename(OLDPATH, NEWPATH)

=item rmdir(PATH)

=item stat(PATH)

=item symlink(OLDPATH, NEWPATH)

=item sysread(FILEHANDLE, SCALAR, LENGTH[, OFFSET])

=item syswrite(FILEHANDLE, SCALAR[, LENGTH[, OFFSET]])

=item unlink(PATH...)

=item utime(ATIME, MTIME, PATH...)

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Fatal.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=cut
