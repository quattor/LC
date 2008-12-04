#+##############################################################################
#                                                                              #
# File: Cached.pm                                                              #
#                                                                              #
# Description: cached access to expensive information                          #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Cached;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.2 $ =~ /(\d+)\.(\d+)/);

#
# used modules
#

use LC::Exception qw(throw_error);

#
# constants
#

use constant DEBUG_CACHE_HIT  => 1 << 0;
use constant DEBUG_CACHE_MISS => 1 << 1;
use constant DEBUG_MEMOISE    => 1 << 2;
use constant DEBUG_CODE       => 1 << 3;
use constant DEBUG_CACHE      => DEBUG_CACHE_HIT | DEBUG_CACHE_MISS;

#
# variables
#

our(
    $DefaultTtl,	# default ttl
    %_Registered,	# registered caches
    $_Debug,		# debugging flags for this module
);

#+++############################################################################
#                                                                              #
# manipulate time-to-live                                                      #
#                                                                              #
#---############################################################################

sub ttl ($;$) {
    my($name, $ttl) = @_;

    if (@_ > 1) {
	$_Registered{$name}{"ttl"} = $ttl;
    } else {
	$ttl = $_Registered{$name}{"ttl"};
    }
    return(defined($ttl) ? $ttl : $DefaultTtl);
}

#+++############################################################################
#                                                                              #
# create a function wrapping the expensive one and handling the cache          #
#                                                                              #
#---############################################################################

sub memoise ($;$) {
    my($sub, $pkg) = @_;
    my($name, $code, $sref, $proto, $call, $args);

    # initial checks
    $pkg = (caller)[0] unless defined($pkg);
    $sub = "${pkg}::$sub" unless $sub =~ /::/;
    $name = $sub;
    $name =~ s/.*::// or $name =~ s/^&//;
    print("# memoise: sub=$sub pkg=$pkg name=$name\n")
	if $_Debug and $_Debug & DEBUG_MEMOISE;
    unless ($name =~ /^\w+$/) {
	throw_error("invalid subroutine name", $name);
	return();
    }
    if ($name =~ /^(_debug|ttl|memoise|import)$/) {
	throw_error("reserved subroutine name", $name);
	return();
    }
    # find information about the wrapped subroutine
    if (defined(&$sub)) {
	# user subroutine
	$sref = \&$sub;
	$proto = prototype($sref);
	$call = "\$sref->";
    } else {
	# CORE subroutine
        $proto = eval { prototype("CORE::$name") };
	if ($@) {
	    throw_error("not a Perl builtin", $name);
	    return();
	}
	unless (defined($proto)) {
	    throw_error("non-overridable Perl builtin", $name);
	    return();
	}
	$call = "CORE::$name";
    }
    # prepare the code
    if (defined($proto)) {
	unless ($proto =~ /^\$+$/) {
	    throw_error("unsupported prototype", $proto);
	    return();
	}
	$args = join(", ", map("\$_\[$_\]", 0 .. length($proto)-1));
	$code = "sub $name ($proto) {\n";
	print("# memoise: call=$call proto=$proto args=$args\n")
	    if $_Debug and $_Debug & DEBUG_MEMOISE;
    } else {
	$args = "\@_";
	$code = "sub $name {\n";
	print("# memoise: call=$call proto= args=$args\n")
	    if $_Debug and $_Debug & DEBUG_MEMOISE;
    }
    $code .= <<EOC;
    my(\$wantarray, \$key, \$cache, \$ttl, \$miss);

    # check the arguments
    \$wantarray = wantarray;
    unless (\@_) {
	throw_error("missing arguments");
	return();
    }
    # find the key
    if (\@_ > 1) {
	\$key = join(\$;, \@_);
    } else {
	\$key = \$_[0];
    }
    # check the cache
    \$ttl = ttl("$name");
    if (\$wantarray) {
	\$_Registered{"$name"}{"array"} ||= {};
	\$cache = \$_Registered{"$name"}{"array"};
    } else {
	\$_Registered{"$name"}{"scalar"} ||= {};
	\$cache = \$_Registered{"$name"}{"scalar"};
    }
    if (\$cache->{\$key}) {
	\$miss = time() > \$cache->{\$key}[0] if \$ttl;
    } else {
	\$miss = 1;
    }
    # maybe call the lookup code
    if (\$miss) {
        print("# LC::Cached::$name(\@_) miss\\n")
	    if \$_Debug and \$_Debug & DEBUG_CACHE_MISS;
	\$cache->{\$key}[0] = time() + \$ttl if \$ttl;
	\$cache->{\$key}[1] = \$wantarray ?
EOC
    $code .= "\t\t[ $call\($args\) ] :\n";
    $code .= "\t\t  $call\($args\);\n";
    $code .= <<EOC;
    } else {
        print("# LC::Cached::$name(\@_) hit\\n")
	    if \$_Debug and \$_Debug & DEBUG_CACHE_HIT;
    }
    # use the cache
    return(\$cache->{\$key}[1]) unless \$wantarray;
    return() unless \$cache->{\$key}[1];
    return(\@{\$cache->{\$key}[1]});
}
EOC
    # evaluate the code
    print($code) if $_Debug and $_Debug & DEBUG_CODE;
    {
	local $SIG{__WARN__} = sub { die($_[0]) };
	$code = eval($code);
	if ($@) {
	    throw_error("compilation failed for $name", $@);
	    return();
	}
    }
    return($code);
}

#+++############################################################################
#                                                                              #
# hacks to hook into Perl's magic                                              #
#                                                                              #
#---############################################################################

# trap: use Cached foo => 30;
sub import (@) {
    my($self, %ttl) = @_;
    my($name, $pkg, $sub);
    $pkg = (caller)[0];
    foreach $name (keys(%ttl)) {
	if ($name =~ /^ttl$/i) {
	    $DefaultTtl = $ttl{$name};
	} elsif ($name =~ /^_debug$/i) {
	    $_Debug = $ttl{$name};
	} elsif ($name =~ /^memoise$/i) {
	    foreach $sub (@{$ttl{$name}}) {
		memoise($sub, $pkg);
	    }
	} else {
	    memoise($name, $pkg);
	    ttl($name, $ttl{$name});
	}
    }
};

# trap: Cached::foo(x, y)
our $AUTOLOAD;
sub  AUTOLOAD {
    my($name);
    $name = $AUTOLOAD;
    $name =~ s/.*:://;
    memoise($name, (caller)[0]);
    goto &$AUTOLOAD;
}

1;

__END__

=head1 NAME

LC::Cached - cached access to expensive information

=head1 SYNOPSIS

    # core Perl routines
    use LC::Cached gethostbyname => 30;
    ...
    $addr = LC::Cached::gethostbyname($host);

    # default time-to-live for several functions
    use LC::Cached TTL => 10, MEMOISE => [ qw(getpwuid getgrgid) ];

    # user routines not declared at compile time (autoload magic)
    sub foo { ... }
    LC::Cached::ttl("foo", 180);
    ...
    @result = LC::Cached::foo(1, 2);

=head1 DESCRIPTION

This module caches calls to expensive information lookup routines such as
gethostbyname(). It can handle different calling contexts (scalar or list)
and a per-cache time-to-live.

If you want to profit from the prototype checking, you must use one of
the first two types of declaration (with C<use>) which happens at
compilation time. However, the wrapped function prototype must be
known by Perl at compilation time. This is always the case for core
Perl routines and it is the case for routines exported by other
modules or wrapped inside a C<BEGIN> block...

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Cached.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=head1 TODO

=over

=item * improve documentation

=item * implement a garbage collector

=back

=cut
