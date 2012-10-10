#+##############################################################################
#                                                                              #
# File: Stat.pm                                                                #
#                                                                              #
# Description: easy access to stat(2) information                              #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Stat;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.8 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(file_type ls_mode major_minor);
%EXPORT_TAGS = (
    # stat(2) fields
    "ST" => [qw(ST_DEV ST_INO ST_MODE ST_NLINK ST_UID ST_GID ST_RDEV ST_SIZE
		ST_ATIME ST_MTIME ST_CTIME ST_BLKSIZE ST_BLOCKS)],
    # st_mode flags from <sys/stat.h>
    "S"  => [qw(S_IFREG S_IFBLK S_IFCHR S_IFDIR S_IFIFO  S_IFLNK S_IFNWK
	        S_IFSOCK S_IFDOOR S_IFMT
	        S_ISREG S_ISBLK S_ISCHR S_ISDIR S_ISFIFO S_ISLNK S_ISNWK
	        S_ISSOCK S_ISDOOR
	        S_ISUID S_ISGID S_ISVTX
	        S_IRUSR S_IWUSR S_IXUSR S_IRWXU
	        S_IRGRP S_IWGRP S_IXGRP S_IRWXG
	        S_IROTH S_IWOTH S_IXOTH S_IRWXO
	        S_IRWXUGO S_IALLUGO)],
);
Exporter::export_tags();

#
# private variables
#

our(
    @_ModeToFtype,	# mode to file type cache
    %_ModeToLs,		# mode to ls(1) mode string cache
);

#+++############################################################################
#                                                                              #
# access to stat(2) fields                                                     #
#                                                                              #
#---############################################################################

use constant ST_DEV     =>  0;	# device
use constant ST_INO     =>  1;	# inode
use constant ST_MODE    =>  2;	# protection
use constant ST_NLINK   =>  3;	# number of hard links
use constant ST_UID     =>  4;	# user ID of owner
use constant ST_GID     =>  5;	# group ID of owner
use constant ST_RDEV    =>  6;	# device type (if inode device)
use constant ST_SIZE    =>  7;	# total size, in bytes
use constant ST_ATIME   =>  8;	# time of last access
use constant ST_MTIME   =>  9;	# time of last modification
use constant ST_CTIME   => 10;	# time of last change
use constant ST_BLKSIZE => 11;	# blocksize for filesystem I/O
use constant ST_BLOCKS  => 12;	# number of blocks allocated

#+++############################################################################
#                                                                              #
# <sys/stat.h> usually contains such handy constants and macros                #
#                                                                              #
#---############################################################################

#
# file types
#

use constant S_IFMT   => 0170000; # type of file
use constant S_IFREG  => 0100000; # regular 
use constant S_IFBLK  => 0060000; # block special
use constant S_IFCHR  => 0020000; # character special
use constant S_IFDIR  => 0040000; # directory
use constant S_IFIFO  => 0010000; # pipe or FIFO
use constant S_IFLNK  => 0120000; # symbolic link
use constant S_IFNWK  => 0110000; # network special
use constant S_IFSOCK => 0140000; # socket
use constant S_IFDOOR => 0150000; # door (Solaris specific)

#
# file type tests
#

sub S_ISREG  ($) { return(($_[0] & S_IFMT) == S_IFREG ) }
sub S_ISBLK  ($) { return(($_[0] & S_IFMT) == S_IFBLK ) }
sub S_ISCHR  ($) { return(($_[0] & S_IFMT) == S_IFCHR ) }
sub S_ISDIR  ($) { return(($_[0] & S_IFMT) == S_IFDIR ) }
sub S_ISFIFO ($) { return(($_[0] & S_IFMT) == S_IFIFO ) }
sub S_ISLNK  ($) { return(($_[0] & S_IFMT) == S_IFLNK ) }
sub S_ISNWK  ($) { return(($_[0] & S_IFMT) == S_IFNWK ) }
sub S_ISSOCK ($) { return(($_[0] & S_IFMT) == S_IFSOCK) }
sub S_ISDOOR ($) { return(($_[0] & S_IFMT) == S_IFDOOR) }

#
# permissions
#

use constant S_ISUID  => 04000; # set user ID on execution
use constant S_ISGID  => 02000; # set group ID on execution
use constant S_ISVTX  => 01000; # save swapped text after use (sticky)

use constant S_IRUSR  =>  0400; # read by owner
use constant S_IWUSR  =>  0200; # write by owner
use constant S_IXUSR  =>  0100; # execute by owner
use constant S_IRWXU  =>  0700; # read, write, and execute by owner

use constant S_IRGRP  =>   040; # read by group
use constant S_IWGRP  =>   020; # write by group
use constant S_IXGRP  =>   010; # execute by group
use constant S_IRWXG  =>   070; # read, write, and execute by group

use constant S_IROTH  =>    04; # read by others
use constant S_IWOTH  =>    02; # write by others
use constant S_IXOTH  =>    01; # execute by others
use constant S_IRWXO  =>    07; # read, write, and execute by others

use constant S_IRWXUGO => S_IRWXU|S_IRWXG|S_IRWXO;           # normal mode bits
use constant S_IALLUGO => S_ISUID|S_ISGID|S_ISVTX|S_IRWXUGO; # all mode bits

#+++############################################################################
#                                                                              #
# mode manipulation                                                            #
#                                                                              #
#---############################################################################

use constant MODE_BITS => 12;	# how many mode bits do we have?

#
# file type as a meaningful string (from st_mode)
#

sub file_type ($) {
    my($mode) = @_;

    # maybe initialise the cache
    unless (@_ModeToFtype) {
	$_ModeToFtype[S_IFREG  >> MODE_BITS] = "plain file";
	$_ModeToFtype[S_IFBLK  >> MODE_BITS] = "block device";
	$_ModeToFtype[S_IFCHR  >> MODE_BITS] = "character device";
	$_ModeToFtype[S_IFDIR  >> MODE_BITS] = "directory";
	$_ModeToFtype[S_IFIFO  >> MODE_BITS] = "pipe";
	$_ModeToFtype[S_IFLNK  >> MODE_BITS] = "symlink";
	$_ModeToFtype[S_IFNWK  >> MODE_BITS] = "network file";
	$_ModeToFtype[S_IFSOCK >> MODE_BITS] = "socket";
	$_ModeToFtype[S_IFDOOR >> MODE_BITS] = "door";
    }
    $mode &= S_IFMT;
    $mode >>= MODE_BITS;
    return($_ModeToFtype[$mode]) if $_ModeToFtype[$mode];
    return("strange file");
}

#
# ls(1) like mode string (from st_mode)
#

sub ls_mode ($) {
    my($mode) = @_;
    my($string);

    # check cache
    $mode &= S_IFMT | S_IALLUGO;
    return($_ModeToLs{$mode}) if $_ModeToLs{$mode};
    # file type
    $string = (S_ISREG($mode)  ? "-" :
              (S_ISBLK($mode)  ? "b" :
              (S_ISCHR($mode)  ? "c" :
              (S_ISDIR($mode)  ? "d" :
              (S_ISFIFO($mode) ? "p" :
              (S_ISLNK($mode)  ? "l" :
              (S_ISNWK($mode)  ? "n" :
              (S_ISSOCK($mode) ? "s" :
              (S_ISDOOR($mode) ? "D" :
                                 "?")))))))));
    # owner permissions
    $string .= ($mode & S_IRUSR  ? "r" : "-");
    $string .= ($mode & S_IWUSR  ? "w" : "-");
    $string .= ($mode & S_IXUSR  ?
	        ($mode & S_ISUID ? "s" : "x") :
	        ($mode & S_ISUID ? "S" : "-"));
    # group permissions
    $string .= ($mode & S_IRGRP  ? "r" : "-");
    $string .= ($mode & S_IWGRP  ? "w" : "-");
    $string .= ($mode & S_IXGRP  ?
	        ($mode & S_ISGID ? "s" : "x") :
	        ($mode & S_ISGID ? "S" : "-"));
    # others permissions
    $string .= ($mode & S_IROTH  ? "r" : "-");
    $string .= ($mode & S_IWOTH  ? "w" : "-");
    $string .= ($mode & S_IXOTH  ?
	        ($mode & S_ISVTX ? "t" : "x") :
	        ($mode & S_ISVTX ? "T" : "-"));
    # update the cache
    $_ModeToLs{$mode} = $string;
    return($string);
}

#+++############################################################################
#                                                                              #
# rdev manipulation                                                            #
#                                                                              #
#---############################################################################

#
# the algorithm to transform the st_rdev field into major and minor numbers
# is very system specific and is usually done with C macros, here is what
# has been found in the include files:
#
# AIX 4.3:
#  <sys/sysmacros.h>:
#   define major(__x)        (int)((unsigned)(__x)>>16)
#   define minor(__x)        (int)((__x)&0xFFFF)
#   define major64(_devno) ((int)((_devno & 0x3FFFFFFF00000000LL) >> 32))
#   define minor64(_devno) ((int)(_devno & 0x00000000FFFFFFFFLL))
#
# HP-UX 10.20:
#  <sys/sysmacros.h>:
#   define major(x)        ((long)(((unsigned)(x)>>24)&0xff)) /* 8 bit major */
#   define minor(x)        ((long)((x)&0xffffff))            /* 24 bit minor */
#
# IRIX 6.5:
#  <sys/sysmacros.h>:
#   define L_BITSMAJOR     14       /* # of SVR4 major device bits */
#   define L_BITSMINOR     18       /* # of SVR4 minor device bits */
#   define L_MAXMAJ        0x1ff    /* Although 14 bits are reserved,
#                                   ** major numbers are currently restricted
#                                   ** to 9 bits.
#                                   */
#   define L_MAXMIN        0x3ffff /* MAX minor */
#   define major(x)        (int)(((unsigned)(x)>>L_BITSMINOR) & L_MAXMAJ)
#   define minor(x)        (int)((x)&L_MAXMIN)
#
# Linux 2.2 and 2.4:
#  <sys/sysmacros.h>:
#   define major(dev) ((int)(((dev) >> 8) & 0xff))
#   define minor(dev) ((int)((dev) & 0xff))
#
# OSF1 4.0f:
#  <sys/types.h>:
#   define major(x)        ((major_t)  (((dev_t)(x)>>20)&07777))
#   define minor(x)        ((minor_t)  ((dev_t)(x)&03777777))
#
# Solaris 2.6 and 7 (32 bits):
#  <sys/sysmacros.h>:
#   define L_BITSMAJOR     14      /* # of SVR4 major device bits */
#   define L_BITSMINOR     18      /* # of SVR4 minor device bits */
#   define L_MAXMAJ        0x3fff  /* SVR4 max major value */
#   define L_MAXMIN        0x3ffff /* MAX minor for 3b2 software drivers. */
#                                  /* For 3b2 hardware devices the minor is */
#                                  /* restricted to 256 (0-255) */
#   define getmajor(x)     (int)((unsigned)((x)>>L_BITSMINOR) & L_MAXMAJ)
#   define getminor(x)     (int)((x) & L_MAXMIN)
#

sub major_minor ($) {
    my($rdev) = @_;
    my($major, $minor);

    if ($^O eq "aix") {
	$major = $rdev >> 16;
	$minor = $rdev & 0xFFFF;
    } elsif ($^O eq "hpux") {
	$major = ($rdev >> 24) & 0xFF;
	$minor = $rdev & 0xFFFFFF;
    } elsif ($^O eq "irix") {
	$major = ($rdev >> 18) & 0x1FF;
	$minor = $rdev & 0x3FFFF;
    } elsif ($^O eq "dec_osf") {
	$major = ($rdev >> 20) & 07777;
	$minor = $rdev & 03777777;
    } elsif ($^O eq "linux") {
	$major = ($rdev >> 8) & 0xFF;
	$minor = $rdev & 0xFF;
    } elsif ($^O eq "solaris") {
	$major = ($rdev >> 18) & 0x3FFF;
	$minor = $rdev & 0x3FFFF;
    } else {
	return();
    }
    return($major, $minor);
}

1;

__END__

=head1 NAME

LC::Stat - easy access to stat(2) information

=head1 SYNOPSIS

    use LC::Stat qw(:ST :S ls_mode);
    @stat = stat($path);
    $size = $stat[ST_SIZE];
    print(ls_mode($stat[ST_MODE]), "\n") if S_ISDIR($stat[ST_MODE]);

=head1 DESCRIPTION

This module eases the manipulation of C<stat(2)> information by supplying
handy constants and macros as well as two functions:

=over

=item ST constants

They are the same as the ones from C<E<lt>sys/stat.hE<gt>>:
ST_DEV ST_INO ST_MODE ST_NLINK ST_UID ST_GID
ST_RDEV ST_SIZE ST_ATIME ST_MTIME ST_CTIME
ST_BLKSIZE ST_BLOCKS

=item S constants and macros

They are the same as the ones from C<E<lt>sys/stat.hE<gt>>:
S_IFMT
S_IFREG S_IFBLK S_IFCHR S_IFDIR
S_IFIFO S_IFLNK S_IFNWK S_IFSOCK S_IFDOOR
S_ISREG S_ISBLK S_ISCHR S_ISDIR
S_ISFIFO S_ISLNK S_ISNWK S_ISSOCK S_ISDOOR
S_ISUID S_ISGID S_ISVTX
S_IRUSR S_IWUSR S_IXUSR S_IRWXU
S_IRGRP S_IWGRP S_IXGRP S_IRWXG
S_IROTH S_IWOTH S_IXOTH S_IRWXO
S_IRWXUGO S_IALLUGO

=item file_type(MODE)

Take the C<st_mode> field of C<stat(2)> and return the type of the file as
a human-readable string such as "symlink" or "block device".

=item ls_mode(MODE)

Take the C<st_mode> field of C<stat(2)> and return the 10 character
string used by C<ls(1)> such as "-rwsr-xr-x" or "drwxr-xr-x".

=item major_minor(RDEV)

Take the C<st_rdev> field of C<stat(2)> and, if the operating system
is known, return the list of major and minor numbers. Return an empty
list otherwise.

Note: this probably works only on 32-bits architectures.

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Stat.pm,v 1.8 2006/01/10 14:56:28 cons Exp $

=cut
