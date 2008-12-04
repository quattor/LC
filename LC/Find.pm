#+##############################################################################
#                                                                              #
# File: Find.pm                                                                #
#                                                                              #
# Description: an enhanced version of the File::Find module                    #
#                                                                              #
#-##############################################################################

# TODO:
# - find a better scheme for the toplevel paths
# - check flags consistency: parano=>chdir, parano=>!follow_top, follow->!nlink
# - do speed benchmarks
# - do we have to compile the finder code to speed up the search?
# - find better names!
# - document when we can rely on _ or not
# - prevent user from messing with the global variables?
# - use callbacks as filters
# - loop detection to issue warnings? nothing (just skip)?
# - same as dont_loop but for files?

#
# module definition
#

package LC::Find;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.2 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw();
%EXPORT_TAGS = (
    "FIND" => [qw(FIND_CROSS_DEV FIND_CROSS_AFS FIND_PARANOID FIND_USE_CHDIR
		  FIND_USE_NLINK FIND_SORT FIND_FOLLOW FIND_FOLLOW_TOP
		  FIND_FORGIVING FIND_DONT_LOOP)],
);
Exporter::export_tags();

#
# used modules
#

use LC::Exception qw(throw_error throw_warning
		     throw_mutable_error throw_mutable_warning SUCCESS);
use LC::Secure qw(getcwd setcwd);
use LC::Stat qw(:ST :S);
use POSIX qw(:errno_h);

#
# public constants
#

use constant FIND_CROSS_DEV   => 1 << 0;
use constant FIND_CROSS_AFS   => 1 << 1;
use constant FIND_PARANOID    => 1 << 2;
use constant FIND_USE_CHDIR   => 1 << 3;
use constant FIND_USE_NLINK   => 1 << 4;
use constant FIND_SORT        => 1 << 5;
use constant FIND_FOLLOW      => 1 << 6;
use constant FIND_FOLLOW_TOP  => 1 << 7;
use constant FIND_FORGIVING   => 1 << 8;
use constant FIND_DONT_LOOP   => 1 << 9;

#
# public variables
#

our($TopDir, $SubDir, $Name, $Path, $Depth, $Stat, $Prune);

#
# private variables
#

our(
    $_DevAFS,		# the device number of /afs
    $_Flags,		# current set of flags being used
    $_Cwd,		# working directory when find was invoked
    $_Done,		# directories already done to avoid loops
    $_FileCB,		# file callback
    $_EnterDirCB,	# directory enter callback
    $_LeaveDirCB,	# directory leave callback
);

#
# read the current directory and return a reference to its contents
# or false if one of the *dir() system calls failed
# (false being undef in case of error or 0 in case of warning)
#

sub _read_current_directory () {
    my(@list, $muted);
    local(*DIR);

    unless (opendir(DIR, $_Flags & FIND_USE_CHDIR ? "." : $Path)) {
	if ($_Flags & FIND_FORGIVING and $! == EACCES) {
	    $muted = throw_mutable_warning("opendir($Path)", $!);
	    return(0) unless $muted;
	} else {
	    $muted = throw_mutable_error("opendir($Path)", $!);
	    return(0) if $muted;
	}
	return();
    }
    @list = $_Flags & FIND_SORT ?
	sort(grep(!/^\.\.?$/, readdir(DIR))) :
	     grep(!/^\.\.?$/, readdir(DIR));
    unless (closedir(DIR)) {
	throw_error("closedir($Path)", $!);
	return();
    }
    return(\@list);
}

#
# *stat() the current path and return a reference to the result
# or false if the *stat() system call failed
# (false being undef in case of error or 0 in case of warning)
#

sub _stat_current_path () {
    my($what, @list, $muted);

    if ($Depth) {
	if ($_Flags & FIND_FOLLOW) {
	    $what =  "stat";
	    @list =   stat($_Flags & FIND_USE_CHDIR ? $Name : $Path);
	} else {
	    $what = "lstat";
	    @list =  lstat($_Flags & FIND_USE_CHDIR ? $Name : $Path);
	}
    } else {
	if ($_Flags & FIND_FOLLOW_TOP) {
	    $what =  "stat";
	    @list =   stat($Path);
	} else {
	    $what = "lstat";
	    @list =  lstat($Path);
	}
    }
    unless (@list) {
	if ($_Flags & FIND_FORGIVING and $! == EACCES) {
	    $muted = throw_mutable_warning("$what($Path)", $!);
	    return(0) unless $muted;
	} else {
	    $muted = throw_mutable_error("$what($Path)", $!);
	    return(0) if $muted;
	}
	return();
    }
    return(\@list);
}

#
# carefully change to the given directory and return true on success
# (false being undef in case of error or 0 in case of warning)
#

sub _change_directory ($$$) {
    my($cur_dir, $dst_dir, $dst_stat) = @_;
    my(@real_stat, $muted);

    unless (chdir($dst_dir)) {
	if ($_Flags & FIND_FORGIVING and $! == EACCES) {
	    $muted = throw_mutable_warning("chdir($cur_dir/$dst_dir)", $!);
	    return(0) unless $muted;
	} else {
	    $muted = throw_mutable_error("chdir($cur_dir/$dst_dir)", $!);
	    return(0) if $muted;
	}
	return();
    }
    if ($_Flags & FIND_PARANOID) {
	unless (@real_stat = lstat(".")) {
	    throw_error("lstat($cur_dir/$dst_dir/.)", $!);
	    return();
	}
	unless ($dst_stat->[ST_DEV] == $real_stat[ST_DEV] and
		$dst_stat->[ST_INO] == $real_stat[ST_INO]) {
	    throw_error("bogus $cur_dir/$dst_dir/.",
			$dst_stat->[ST_DEV].":".$dst_stat->[ST_INO] ." != ".
			 $real_stat[ST_DEV].":". $real_stat[ST_INO]);
	    return();
	}
    }
    return(SUCCESS);
}

#
# check if we are allowed to go into the current directory and
# return true on success
#

sub _cross_ok ($) {
    my($parent_stat) = @_;
    my($id);

    # detect loops
    if ($_Flags & FIND_DONT_LOOP) {
	$id = $Stat->[ST_DEV] . ":" . $Stat->[ST_INO];
	if (exists($_Done->{$id})) {
	    throw_error("loop under $Path", "was $_Done->{$id}");
	    return();
	} else {
	    $_Done->{$id} = $Path;
	}
    }
    # don't cross device mount points
    unless ($_Flags & FIND_CROSS_DEV) {
	return() if $Stat->[ST_DEV] != $parent_stat->[ST_DEV];
    }
    # don't cross AFS volume mount points (dirty hack)
    unless ($_Flags & FIND_CROSS_AFS) {
	return() if $Stat->[ST_DEV] == $_DevAFS and ($Stat->[ST_INO] % 2) == 0 and
	    ($Path =~ /^\/afs\// or $Path !~ /^\// and $_Cwd =~ /^\/afs\//);
    }
    # so far so good
    return(SUCCESS);
}

#
# maybe chdir down or up and return true on success
# (false being undef in case of error or 0 in case of warning)
#

sub _maybe_chdir_down () {
    return(SUCCESS) unless $_Flags & FIND_USE_CHDIR;
    return(_change_directory($TopDir.$SubDir, $Name, $Stat));
}

sub _maybe_chdir_up ($) {
    my($parent_stat) = @_;

    return(SUCCESS) unless $_Flags & FIND_USE_CHDIR;
    return(_change_directory($Path, "..", $parent_stat))
	unless $_Flags & FIND_FOLLOW;
    unless ($TopDir =~ /^\//) {
	# we've not been given an absolute path, we have to hop
	# through the toplevel directory first!
	unless (chdir($_Cwd)) {
	    throw_error("chdir($_Cwd)", $!);
	    return();
	}
    }
    return(_change_directory($Path, $TopDir.$SubDir, $parent_stat));
}

#
# recursively find _inside_ the given directory, return true on success
#

sub _process_directory ($); # forward self declaration
sub _process_directory ($) {
    my($dir) = @_;
    my($entries, $dir_stat, $dir_depth, $dir_subdirs, $result);

    # read current directory
    $entries = _read_current_directory();
    return() unless defined($entries);
    return(SUCCESS) unless $entries;
    # remember its stat buffer, depth and number of subdirs
    $dir_stat    = $Stat;
    $dir_depth   = $Depth;
    $dir_subdirs = $dir_stat->[ST_NLINK] - 2 if $_Flags & FIND_USE_NLINK;
    # set global variables
    local($SubDir, $Name, $Path, $Depth, $Stat);
    $SubDir = $dir;
    $Depth  = $dir_depth + 1;
    # process its entries
    while (@$entries) {
	$Name = shift(@$entries);
	$Path = "$TopDir$SubDir/$Name";
	# handle the entry (nlink optimisation)
	if ($_Flags & FIND_USE_NLINK and $dir_subdirs == 0) {
	    if ($_FileCB) {
		$Stat = undef;
		$_FileCB->();
	    }
	    next;
	}
	# stat the entry
	$Stat = _stat_current_path();
	return() unless defined($Stat);
	next unless $Stat;
	# handle the file entry
	unless (-d _) {
	    $_FileCB->() if $_FileCB;
	    next;
	}
	# handle the directory entry
	$dir_subdirs-- if $_Flags & FIND_USE_NLINK;
	next unless _cross_ok($dir_stat);
	if ($_EnterDirCB) {
	    $Prune = 0;
	    $_EnterDirCB->();
	    next if $Prune;
	}
	# chdir down
	$result = _maybe_chdir_down();
	# process recursively
	$result = _process_directory("$SubDir/$Name") if $result;
	# chdir up
	$result = _maybe_chdir_up($dir_stat) if $result;
	return() unless defined($result);
	if ($_LeaveDirCB) {
	    $Prune = !$result; # i.e. true if the directory had a warning
	    $_LeaveDirCB->();
	}
    }
    # so far so good
    return(SUCCESS);
}

#
# initialise for a toplevel path (stat + cd + set global variables),
# return true on success
# (false being undef in case of error or 0 in case of warning)
#

sub _initialise_toplevel ($) {
    my($dir) = @_;
    my($result);

    ($SubDir, $Name, $Path, $Depth) = ("", ".", $dir, 0);
    $Stat = _stat_current_path();
    return($Stat) unless $Stat;
    unless (-d _) {
	throw_error("not a directory", $Path);
	return();
    }
    ($TopDir = $Path) =~ s/\/+$//;
    if ($_Flags & FIND_USE_CHDIR and $TopDir ne ".") {
	$result = _change_directory($_Cwd, $Path, $Stat);
	return($result) unless $result;
    }
    if ($_Flags & FIND_DONT_LOOP) {
	# remember that we've been here...
	$_Done->{$Stat->[ST_DEV] . ":" . $Stat->[ST_INO]} = $Path;
    }
    return(SUCCESS);
}

#
# find recursively from the given toplevel paths
# note: these paths are handled differently:
#  - the callbacks are _not_ called
#  - $Prune is not checked
#  - FIND_CROSS_* flags are not checked
#

sub _find (@) {
    my(@paths) = @_;
    my($top, $result);
    local($TopDir, $SubDir, $Name, $Path, $Depth, $Stat, $Prune);

    # check that $_DevAFS is defined
    unless (defined($_DevAFS)) {
	if (stat("/afs")) {
	    $_DevAFS = (stat(_))[ST_DEV];
	} else {
	    $_DevAFS = 1;
	}
    }
    # process all paths in order
    foreach $top (@paths) {
	$result = _initialise_toplevel($top);
	return() unless defined($result);
	next unless $result;
	_process_directory("") or return();
	next unless $_Flags & FIND_USE_CHDIR;
	# always go back to $_Cwd when using chdir
	# because we'd better be safe than sorry...
	if ($_Flags & FIND_PARANOID) {
	    setcwd($_Cwd) or return();
	} else {
	    unless (chdir($_Cwd)) {
		throw_error("chdir($_Cwd)", $!);
		return();
	    }
	}
    }
    # so far so good
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# object oriented stuff                                                        #
#                                                                              #
#---############################################################################

#
# object contructor
#

sub new : method {
    my($class) = @_;
    my $self = {};
    bless($self, $class);
    $self->flags(0); # default flags
    return($self);
}

#
# field access methods
#

sub flags : method {
    my($self, $flags) = @_;
    $self->{"_flags"} = $flags if @_ > 1;
    return($self->{"_flags"});
}

sub cwd : method {
    my($self, $cwd) = @_;
    $self->{"_cwd"} = $cwd if @_ > 1;
    return($self->{"_cwd"});
}

sub done : method {
    my($self, $done) = @_;
    $self->{"_done"} = $done if @_ > 1;
    return($self->{"_done"});
}

sub file_callback : method {
    my($self, $callback) = @_;
    $self->{"_fc"} = $callback if @_ > 1;
    return($self->{"_fc"});
}

sub enter_directory_callback : method {
    my($self, $callback) = @_;
    $self->{"_edc"} = $callback if @_ > 1;
    return($self->{"_edc"});
}

sub leave_directory_callback : method {
    my($self, $callback) = @_;
    $self->{"_ldc"} = $callback if @_ > 1;
    return($self->{"_ldc"});
}

# shortcut
sub callback : method {
    my($self, $callback) = @_;
    $self->file_callback($callback);
    $self->enter_directory_callback($callback);
    $self->leave_directory_callback(0);
}

# reset cwd and done, may fail
sub _reset : method {
    my($self) = @_;
    $self->{"_cwd"} = getcwd() or return();
    $self->{"_done"} = {};
    return(SUCCESS)
}

#
# other methods
#

sub copy_to_global : method {
    my($self) = @_;
    $_Flags      = $self->flags;
    $_Cwd        = $self->cwd;
    $_Done       = $self->done;
    $_FileCB     = $self->file_callback;
    $_EnterDirCB = $self->enter_directory_callback;
    $_LeaveDirCB = $self->leave_directory_callback;
}

sub find : method {
    my($self, @dirs) = @_;
    local($_Flags, $_Cwd, $_Done, $_FileCB, $_EnterDirCB, $_LeaveDirCB);
    $self->_reset or return();
    $self->copy_to_global;
    return(_find(@dirs));
}

#
# other methods (playing with globals directly, caller should use local())
#

sub toplevel : method {
    my($self, $path) = @_;
    my($result, $target);
    $self->_reset or return();
    $self->copy_to_global;
    $target = LC::Find::Target->new;
    $target->finder($self);
    $target->copy_to_global;
    $result = _initialise_toplevel($path);
    return($result) unless $result;
    $target->copy_from_global;
    return($target);
}

#+++############################################################################
#                                                                              #
# target manipulation                                                          #
#                                                                              #
#---############################################################################

package LC::Find::Target;
use strict;
use warnings;

#
# object contructor
#

sub new : method {
    my($class) = @_;
    my $self = {};
    bless($self, $class);
    return($self);
}

#
# field access methods
#

sub finder : method {
    my($self, $finder) = @_;
    $self->{"_finder"} = $finder if @_ > 1;
    return($self->{"_finder"});
}

sub parent : method {
    my($self, $parent) = @_;
    $self->{"_parent"} = $parent if @_ > 1;
    return($self->{"_parent"});
}

sub top_dir : method {
    my($self, $top_dir) = @_;
    $self->{"_top_dir"} = $top_dir if @_ > 1;
    return($self->{"_top_dir"});
}

sub sub_dir : method {
    my($self, $sub_dir) = @_;
    $self->{"_sub_dir"} = $sub_dir if @_ > 1;
    return($self->{"_sub_dir"});
}

sub name : method {
    my($self, $name) = @_;
    $self->{"_name"} = $name if @_ > 1;
    return($self->{"_name"});
}

sub path : method {
    my($self, $path) = @_;
    $self->{"_path"} = $path if @_ > 1;
    return($self->{"_path"});
}

sub depth : method {
    my($self, $depth) = @_;
    $self->{"_depth"} = $depth if @_ > 1;
    return($self->{"_depth"});
}

sub last_stat : method {
    my($self, $stat) = @_;
    $self->{"_stat"} = $stat if @_ > 1;
    return($self->{"_stat"});
}

#
# other methods
#

sub copy_to_global : method {
    my($self) = @_;
    $LC::Find::TopDir = $self->top_dir;
    $LC::Find::SubDir = $self->sub_dir;
    $LC::Find::Name   = $self->name;
    $LC::Find::Path   = $self->path;
    $LC::Find::Depth  = $self->depth;
    $LC::Find::Stat   = $self->last_stat;
}

sub copy_from_global : method {
    my($self) = @_;
    $self->top_dir(  $LC::Find::TopDir);
    $self->sub_dir(  $LC::Find::SubDir);
    $self->name(     $LC::Find::Name  );
    $self->path(     $LC::Find::Path  );
    $self->depth(    $LC::Find::Depth );
    $self->last_stat($LC::Find::Stat  );
}

sub aim : method {
    my($self, $name) = @_;
    my($target, $depth);
    $target = LC::Find::Target->new;
    $target->finder($self->finder);
    $target->parent($self);
    $target->top_dir($self->top_dir);
    $depth = $self->depth;
    if ($depth) {
	$target->sub_dir($self->sub_dir . "/" . $self->name);
	$target->path($target->top_dir . $target->sub_dir . "/$name");
	$target->depth($depth + 1);
    } else {
	$target->sub_dir("");
	$target->path($target->top_dir . "/$name");
	$target->depth(1);
    }
    $target->name($name);
    # stat is unknown
    return($target);
}

sub do_readdir : method {
    my($self) = @_;
    $self->finder->copy_to_global;
    $self->copy_to_global;
    return(LC::Find::_read_current_directory());
}

sub do_stat : method {
    my($self) = @_;
    my($stat);
    $self->finder->copy_to_global;
    $self->copy_to_global;
    $LC::Find::Stat = $stat = LC::Find::_stat_current_path();
    $self->last_stat($stat);
    return($stat);
}

sub do_chdir_down : method {
    my($self) = @_;
    $self->finder->copy_to_global;
    $self->copy_to_global;
    return(LC::Find::_maybe_chdir_down());
}

sub do_chdir_up : method {
    my($self) = @_;
    $self->finder->copy_to_global;
    $self->copy_to_global;
    return(LC::Find::_maybe_chdir_up($self->parent->last_stat));
}

sub can_cross : method {
    my($self) = @_;
    $self->finder->copy_to_global;
    $self->copy_to_global;
    return(LC::Find::_cross_ok($self->parent->last_stat));
}

1;

__END__

=head1 NAME

LC::Find - an enhanced version of the File::Find module

=head1 SYNOPSIS

    use LC::Find qw(:FIND);
    $finder = LC::Find->new;
    $finder->flags(FIND_FORGIVING|FIND_PARANOID);
    $finder->callback(\&foo);
    $finder->find(@dirs) or die;

=head1 DESCRIPTION

This package allows you to traverse a file tree, optionally calling
user supplied callbacks on each file or directory.

=head2 Callbacks

The following callbacks can be set with the following methods, taking
a subroutine reference as argument:

=over

=item file_callback

for any non-directory object found

=item enter_directory_callback

for any directory, before traversing it

=item leave_directory_callback

for any directory, after having traversed it

=back

The C<callback> method is shortcut to unset the C<leave_directory_callback>
and set the C<file_callback> and C<enter_directory_callback> to the same value.

=head2 Variables

The following variables (in the C<LC::Find> namespace) are set before
calling the callbacks.

=over

=item $TopDir

top directory given to the find method (without the trailing C</>)

=item $SubDir

current sub-directory path under C<$TopDir>

=item $Name

final component of the path being looked at

=item $Path

full path of the current entry being looked at

=item $Depth

directory depth of the entry being looked at

=item $Stat

reference to the C<stat()> buffer of the entry being looked at

=item $Prune

true if the directory should be skipped (modifiable by the callback)

=back

=head2 Flags

The following flags can be given to the finder object via the C<flags>
method:

=over

=item FIND_CROSS_DEV

allow the crossing of device mount points

=item FIND_CROSS_AFS

allow the crossing of AFS mount points

=item FIND_PARANOID

be paranoid: check C<.> after a C<chdir()>

=item FIND_USE_CHDIR

use C<chdir()> to walk down the tree

=item FIND_USE_NLINK

use "nlink optimisation" to avoid unnecessary C<stat()> calls; when
set, the C<$Stat> variable is not guaranteed to contain the C<stat()>
buffer

=item FIND_SORT

alphabetically sort the directory entries before processing them

=item FIND_FOLLOW

always follow symbolic links

=item FIND_FOLLOW_TOP

follow symbolic links for top paths only

=item FIND_FORGIVING

turn permission denied errors into warnings

=item FIND_DONT_LOOP

make sure we don't loop with directories (especially useful when
C<FIND_FOLLOW> is set)

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Find.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=head1 TODO

=over

=item * document it more!

=back

=cut
