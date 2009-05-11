#+##############################################################################
#                                                                              #
# File: Secure.pm                                                              #
#                                                                              #
# Description: secure implementations of some system functions                 #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Secure;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.10 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(ch1dir chdir getcwd setcwd forgetcwd unlink rmdir destroy);

#
# used modules
#

use LC::Exception qw(throw_error throw_warning SUCCESS);
use LC::Stat qw(:ST :S);

#
# global variables
#

our(
    $_EC,               # module's exception context
    %_CwdToId,		# path to dev:ino table for getcwd()
);

$_EC = LC::Exception::Context->new->will_store_errors;

#
# forward declarations
#

sub _destroy ($$);

#+++############################################################################
#                                                                              #
# secure environment                                                           #
#                                                                              #
#---############################################################################

#
# reset the execution environment: %ENV, %SIG...
#

sub environment () {
    # environment variables
    $ENV{PATH}  = "/bin:/usr/bin"; # reasonable path
    $ENV{SHELL} = "/bin/sh" if exists($ENV{SHELL}); # reasonable shell
    delete(@ENV{qw(PERLLIB PERL5LIB PERL5OPT PERL5DB)}); # see perlrun(1)
    delete(@ENV{qw(PERL5SHELL PERL_DEBUG_MSTATS PERL_DESTRUCT_LEVEL)});
    delete(@ENV{qw(IFS CDPATH ENV BASH_ENV)}); # see perlsec(1)
    # signal handlers
    $SIG{INT}  = "DEFAULT";
    $SIG{QUIT} = "DEFAULT";
    $SIG{TERM} = "DEFAULT";
    $SIG{TTOU} = "IGNORE";
    $SIG{CHLD} = "DEFAULT";
    # set good umask: at least drop group- and world-writable bits
    umask(umask() | S_IWGRP | S_IWOTH);
    # so far so good
    return(SUCCESS);
}

#
# hack to make "use Secure qw(environment)" actually _call_ the function
# without being imported to the caller namespace...
#

sub import (@) {
    my(@args) = @_;
    my(@rest);

    @rest = grep($_ ne "environment", @args);
    environment() if @args != @rest;
    LC::Secure->export_to_level(1, @rest);
}

#+++############################################################################
#                                                                              #
# secure directory handling                                                    #
#                                                                              #
#---############################################################################

#
# stat() information to unique file id (string)
# used to check that we are really where we should
#

sub _stat2id (@) {
    my(@stat) = @_;
    return($stat[ST_DEV] . ":" . $stat[ST_INO]);
}

#
# change one directory level (only) without crossing a symbolic link
# this is tedious because a bad guy can change things on the filesystem
# between the initial lstat() and the subsequent chdir()...
#

sub ch1dir ($) {
    my($name) = @_;
    my(@stat1, @stat2);

    # easy case: don't change directory!
    return(SUCCESS) if $name eq ".";
    # the name shouldn't contain a / (except for the root directory!)
    if ($name ne "/" and $name =~ /\//) {
	throw_error("illegal name", $name);
	return();
    }
    # where are we going?
    unless (@stat1 = lstat($name)) {
	throw_error("lstat($name)", $!);
	return();
    }
    # try to go there
    unless (CORE::chdir($name)) {
	throw_error("chdir($name)", $!);
	return();
    }
    # where are we now?
    unless (@stat2 = lstat(".")) {
	throw_error("lstat($name/.)", $!);
	return();
    }
    # did we go out of control?
    if (_stat2id(@stat1) ne _stat2id(@stat2)) {
	throw_error("symlink crossed", $name);
	return();
    }
    # so far so good
    return(SUCCESS);
}

#
# change directory without crossing any symbolic link
#

sub chdir ($) {
    my($path) = @_;
    my($cwd, @dirs, $name);

    # get the list of dirs to chdir() to ignoring // and /./
    @dirs = grep(!/^\.?$/, split(/\/+/, $path));
    unshift(@dirs, "/") if $path =~ /^\//;
    $cwd = "";
    # execute all the individual chdir() carefully
    foreach $name (@dirs) {
	# update $cwd
	if ($cwd eq "" or $cwd eq "/") {
	    $cwd .= $name;
	} else {
	    $cwd .= "/$name";
	}
	# try to change one directory level
	unless (ch1dir($name)) {
	    throw_error("chdir($cwd)", $_EC->error);
	    return();
	}
    }
    # so far so good
    return(SUCCESS);
}

#
# change to the parent directory of a path and return the entry name
# (i.e. the last part of the path)
#

sub _chdir_parent ($) {
    my($path) = @_;
    my(@dirs, $dir, $name);

    # get the list of dirs to chdir() to ignoring // and /./
    @dirs = grep(!/^\.?$/, split(/\/+/, $path));
    if (@dirs) {
	# normal case: we have the entry name
	$name = pop(@dirs);
    } else {
	# special case: / or .
	$name = ".";
    }
    if (@dirs) {
	# normal case: we have the leading path
	$dir = join("/", @dirs);
    } else {
	$dir = ".";
    }
    if ($path =~ /^\//) {
	# adjust $dir because the path is absolute
	if ($dir eq ".") {
	    $dir = "/";
	} else {
	    $dir = "/$dir";
	}
    }
    # change to the relevant "parent" directory
    unless (LC::Secure::chdir($dir)) {
	$_EC->rethrow_error;
	return();
    }
    # finally return the name, it can be false, test it with defined()!
    return($name);
}

#
# find the directory entry name that corresponds to the given id
#

sub _entry_name ($$) {
    my($path, $id) = @_;
    my($name, @stat);
    local(*DIR);

    # read the directory
    unless (opendir(DIR, $path)) {
	throw_error("opendir($path)", $!);
	return();
    }
    # find "the" name corresponding to the given id
    while (defined($name = readdir(DIR))) {
	next if $name =~ /^\.\.?$/;
	unless (@stat = lstat("$path/$name")) {
	    # "lateral" directories may be protected so don't give up
	    throw_warning("lstat($path/$name)", $!);
	    next;
	}
	last if _stat2id(@stat) eq $id;
    }
    # close the directory
    unless (closedir(DIR)) {
	throw_error("closedir($path)", $!);
	return();
    }
    # did we find it? (found => exited the while loop with last)
    unless (defined($name)) {
	throw_error("no directory matching $id found", $path);
	return();
    }
    # so far so good
    return($name);
}

#
# get the path of the current working directory, also remembering
# the path and id (i.e. dev & ino) mapping to be used later by setcwd()
#
# variables:
#  $fid = first id   = where we are
#  $cid = current id = where $path points to
#  $oid = old id     = previous value of $cid
#

sub getcwd () {
    my($oid, $cid, $fid, @stat, @path, $entry, $path);

    # check where we are
    unless (@stat = lstat(".")) {
	throw_error("lstat(.)", $!);
	return();
    }
    # initialisation
    @path = ();
    $path = "";
    $fid = $cid = _stat2id(@stat);
    # find the parent directory names
    while (1) {
	# go up in path
	$oid = $cid;
	$path .= $path ? "/.." : "..";
        unless (@stat = lstat($path)) {
            throw_error("lstat($path)", $!);
            return();
        }
        $cid = _stat2id(@stat);
	# the root of the filesystem is detected when . = ..
        last if $oid eq $cid;
	# find the entry name
	$entry = _entry_name($path, $oid);
	unless (defined($entry)) {
	    $_EC->rethrow_error;
	    return();
	}
        unshift(@path, $entry);
    }
    # success
    $path = "/" . join("/", @path);
    $_CwdToId{$path} = $fid;
    return($path);
}

#
# go back to a remembered cwd, checking where we really end up
# simply use chdir() if you didn't remember the id with getcwd()
#

sub setcwd ($) {
    my($path) = @_;
    my(@stat);

    unless (exists($_CwdToId{$path})) {
	throw_error("not remembered", $path);
	return();
    }
    unless (LC::Secure::chdir($path)) {
        throw_error("chdir($path)", $_EC->error);
        return();
    }
    unless (@stat = lstat(".")) {
	throw_error("lstat($path/.)", $!);
	return();
    }
    unless (_stat2id(@stat) eq $_CwdToId{$path}) {
	throw_error("lost directory", $path);
	return();
    }
    return(SUCCESS);
}

#
# forget about a previously remembered cwd
#

sub forgetcwd ($) {
    my($path) = @_;
    delete($_CwdToId{$path});
}

#+++############################################################################
#                                                                              #
# secure equivalents for unlink() and such but not crossing symlinks           #
#                                                                              #
#---############################################################################

#
# internal function to destroy a directory contents
# (the path is given to have better error messages)
#

sub _destroy_directory_contents ($$) {
    my($name, $path) = @_;
    my($entry, $parent);
    local(*DIR);

    # cosmetic, parent is path without any trailing slashes
    $parent = $path;
    $parent =~ s/\/+$//;
    # chdir inside
    unless (ch1dir($name)) {
	throw_error("chdir($path)", $_EC->error);
	return();
    }
    # destroy the directory contents
    unless (opendir(DIR, ".")) {
	throw_error("opendir($path)", $!);
	return();
    }
    while (defined($entry = readdir(DIR))) {
	next if $entry =~ /^\.\.?$/;
	unless (_destroy($entry, "$parent/$entry")) {
	    $_EC->rethrow_error;
	    return();
	}
    }
    unless (closedir(DIR)) {
	throw_error("closedir($path)", $!);
	return();
    }
    # chdir up
    unless (ch1dir("..")) {
	throw_error("chdir($parent/..)", $_EC->error);
	return();
    }
}

#
# internal destroy function, called on file names without a / inside
# busy files are not handled (i.e. they will cause an error)
# (the path is given to have better error messages)
#

sub _destroy ($$) {
    my($name, $path) = @_;

    # check the given name (i.e. never trust anybody)
    if ($name =~ /\//) {
	throw_error("illegal name", $name);
	return();
    }
    # lstat() to find out what to do
    unless (lstat($name)) {
        throw_error("lstat($path)", $!);
        return();
    }
    # do the right thing
    if (-d _) {
	# it's a directory: destroy its contents then the directory itself
	_destroy_directory_contents($name, $path);
	unless (CORE::rmdir($name)) {
	    throw_error("rmdir($path)", $!);
	    return();
	}
    } else {
	# it's not a directory: simply unlink() it
	unless (CORE::unlink($name)) {
	    throw_error("unlink($path)", $!);
	    return();
	}
    }
    # so far so good
    return(SUCCESS);
}

#
# secure destroy
#

sub destroy ($) {
    my($path) = @_;
    my($name);

    # check
    $name = _chdir_parent($path);
    unless (defined($name)) {
	$_EC->rethrow_error;
	return();
    }
    # destroy
    unless (_destroy($name, $path)) {
	$_EC->rethrow_error;
	return();
    }
    # success
    return(SUCCESS);
}

#
# secure unlink
#

sub unlink ($) {
    my($path) = @_;
    my($name);

    # check
    $name = _chdir_parent($path);
    unless (defined($name)) {
	$_EC->rethrow_error;
	return();
    }
    # unlink
    unless (CORE::unlink($name)) {
        throw_error("unlink($path)", $!);
        return();
    }
    # success
    return(SUCCESS);
}

#
# secure rmdir
#

sub rmdir ($) {
    my($path) = @_;
    my($name);

    # check
    $name = _chdir_parent($path);
    unless (defined($name)) {
	$_EC->rethrow_error;
	return();
    }
    # rmdir
    unless (CORE::rmdir($name)) {
        throw_error("rmdir($path)", $!);
        return();
    }
    # success
    return(SUCCESS);
}

1;

__END__

=head1 NAME

LC::Secure - secure implementations of some system functions

=head1 SYNOPSIS

    use LC::Secure qw(environment unlink);
    unlink("/tmp/foo/bar"); # this will not cross symlinks

=head1 DESCRIPTION

This module provides security related functions. One is to secure the
running environment, the others are secure wrappers around potentially
dangerous system functions.

The main problem comes from crossing symbolic links in world writable
directories such as C</tmp>: an attacker could put a symlink in the
middle of the path and we may end up acting on the wrong file...

We workaround this problem by changing directory and then running the
system command (e.g. C<unlink()>) on a path which doesn't contain a /
and therefore can't be perverted by a symlink. Use C<getcwd()> and
then C<setcwd()> if you want to preserve your working directory.

=over

=item environment()

Secure the environment of the running process: environment variables,
signal handlers, umask... This function is in fact not exported.
It is called when it appears on the "use" line or you can call it
explicitly like C<LC::Secure::environment()>.

=item ch1dir(NAME)

Change one directory level (only) without crossing a symbolic link.

=item chdir(PATH)

Change directory without crossing any symbolic link.

=item getcwd()

Return the current working directory and remember where it
is exactly (i.e. exact device number and inode).

=item setcwd(PATH)

Change directory and check that we end up where C<getcwd()> remembered.

=item forgetcwd(PATH)

Forget where PATH is to free memory, C<setcwd()> can't be used anymore
for this path.

=item unlink(PATH)

Change directory and then securely C<unlink()> the right file.

=item rmdir(PATH)

Change directory and then securely C<rmdir()> the right directory.

=item destroy(PATH)

Change directory and then securely destroy the right file (like a "rm -fr").

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Secure.pm,v 1.10 2006/04/04 12:13:58 cons Exp $

=head1 TODO

=over

=item * routine to store a path to id mapping?

=item * environment() could check the environment length?

=item * environment() could check environment variables with binary data?

=back

=cut
