#+##############################################################################
#                                                                              #
# File: ISO88591.pm                                                            #
#                                                                              #
# Description: ISO 8859-1 utilities                                            #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::ISO88591;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.20 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(capitalise iso2tex iso2html iso2ascii
		iso_uc1 iso_uc iso_lc iso_cmp iso_sort iso_sorti);

#
# private variables
#

our(
    %_EntityToIso,    # HTML character entity name to ISO character
    %_IsoToEntity,    # ISO character to HTML character entity name
    %_IsoToTex,	      # ISO character to TeX string
    %_IsoToHtml,      # ISO character to HTML string
    %_IsoToAscii,     # ISO character to ASCII string
    %_IsoToUpper,     # ISO character to its uppercase equivalent
    %_IsoToLower,     # ISO character to its lowercase equivalent
    %_IsoToOrder,     # ISO character to its numerical order
    %_IsoLetter,      # map of ISO letters (i.e. lowercase <> uppercase)
    $_ILRE,	      # regexp (to be put inside []) matching an ISO letter
);

#
# initialise all the tables
#

sub _init () {
    my($code, $char, $entity, $min, $max);

    # main table
    %_IsoToEntity = (
        chr(160) => "nbsp",	# non-breaking space
        chr(171) => "laquo",	# left pointing guillemet
        chr(180) => "acute",	# spacing acute
        chr(187) => "raquo",	# right pointing guillemet
        chr(188) => "OElig",	# latin capital ligature OE
        chr(189) => "oelig",	# latin capital ligature oe
        chr(190) => "Yuml",	# latin capital letter Y with diaeresis
        chr(192) => "Agrave",	# latin capital letter A with grave
        chr(193) => "Aacute",	# latin capital letter A with acute
        chr(194) => "Acirc",	# latin capital letter A with circumflex
        chr(195) => "Atilde",	# latin capital letter A with tilde
        chr(196) => "Auml",	# latin capital letter A with diaeresis
        chr(197) => "Aring",	# latin capital letter A with ring above
        chr(198) => "AElig",	# latin capital ligature AE
        chr(199) => "Ccedil",	# latin capital letter C with cedilla
        chr(200) => "Egrave",	# latin capital letter E with grave
        chr(201) => "Eacute",	# latin capital letter E with acute
        chr(202) => "Ecirc",	# latin capital letter E with circumflex
        chr(203) => "Euml",	# latin capital letter E with diaeresis
        chr(204) => "Igrave",	# latin capital letter I with grave
        chr(205) => "Iacute",	# latin capital letter I with acute
        chr(206) => "Icirc",	# latin capital letter I with circumflex
        chr(207) => "Iuml",	# latin capital letter I with diaeresis
        chr(209) => "Ntilde",	# latin capital letter N with tilde
        chr(210) => "Ograve",	# latin capital letter O with grave
        chr(211) => "Oacute",	# latin capital letter O with acute
        chr(212) => "Ocirc",	# latin capital letter O with circumflex
        chr(213) => "Otilde",	# latin capital letter O with tilde
        chr(214) => "Ouml",	# latin capital letter O with diaeresis
        chr(216) => "Oslash",	# latin capital letter O with stroke
        chr(217) => "Ugrave",	# latin capital letter U with grave
        chr(218) => "Uacute",	# latin capital letter U with acute
        chr(219) => "Ucirc",	# latin capital letter U with circumflex
        chr(220) => "Uuml",	# latin capital letter U with diaeresis
        chr(221) => "Yacute",	# latin capital letter Y with acute
        chr(224) => "agrave",	# latin small letter a with grave
        chr(225) => "aacute",	# latin small letter a with acute
        chr(226) => "acirc",	# latin small letter a with circumflex
        chr(227) => "atilde",	# latin small letter a with tilde
        chr(228) => "auml",	# latin small letter a with diaeresis
        chr(229) => "aring",	# latin small letter a with ring above
        chr(230) => "aelig",	# latin small ligature ae
        chr(231) => "ccedil",	# latin small letter c with cedilla
        chr(232) => "egrave",	# latin small letter e with grave
        chr(233) => "eacute",	# latin small letter e with acute
        chr(234) => "ecirc",	# latin small letter e with circumflex
        chr(235) => "euml",	# latin small letter e with diaeresis
        chr(236) => "igrave",	# latin small letter i with grave
        chr(237) => "iacute",	# latin small letter i with acute
        chr(238) => "icirc",	# latin small letter i with circumflex
        chr(239) => "iuml",	# latin small letter i with diaeresis
        chr(241) => "ntilde",	# latin small letter n with tilde
        chr(242) => "ograve",	# latin small letter o with grave
        chr(243) => "oacute",	# latin small letter o with acute
        chr(244) => "ocirc",	# latin small letter o with circumflex
        chr(245) => "otilde",	# latin small letter o with tilde
        chr(246) => "ouml",	# latin small letter o with diaeresis
        chr(248) => "oslash",	# latin small letter o with stroke
        chr(249) => "ugrave",	# latin small letter u with grave
        chr(250) => "uacute",	# latin small letter u with acute
        chr(251) => "ucirc",	# latin small letter u with circumflex
        chr(252) => "uuml",	# latin small letter u with diaeresis
        chr(253) => "yacute",	# latin small letter y with acute
        chr(255) => "yuml",	# latin small letter y with diaeresis
    );

    # other tables
    %_EntityToIso = reverse(%_IsoToEntity);
    foreach $code (0..255) {
        $char = chr($code);
	$entity = $_IsoToEntity{$char};
	# TeX escape
	if ($entity) {
	    if ($entity eq "nbsp") {
		$_IsoToTex{$char} = "\\ ";
	    } elsif ($entity eq "acute") {
		$_IsoToTex{$char} = "'";
	    } elsif ($entity eq "laquo") {
		$_IsoToTex{$char} = "``";
	    } elsif ($entity eq "raquo") {
		$_IsoToTex{$char} = "''";
	    } elsif ($entity =~ /^(\w)grave$/) {
		$_IsoToTex{$char} = "\\\`\{$1\}";
	    } elsif ($entity =~ /^(\w)acute$/) {
		$_IsoToTex{$char} = "\\\'\{$1\}";
	    } elsif ($entity =~ /^(\w)circ$/) {
		$_IsoToTex{$char} = "\\\^\{$1\}";
	    } elsif ($entity =~ /^(\w)uml$/) {
		$_IsoToTex{$char} = "\\\"\{$1\}";
	    } elsif ($entity =~ /^(\w)tilde$/) {
		$_IsoToTex{$char} = "\\\~\{$1\}";
	    } elsif ($entity =~ /^(\w)cedil$/) {
		$_IsoToTex{$char} = "\\c\{$1\}";
	    } elsif ($entity =~ /^(\w)ring$/) {
		$_IsoToTex{$char} = "\\mbox\{\\$1$1\}";
	    } elsif ($entity =~ /^(\w)slash$/) {
		$_IsoToTex{$char} = "\\mbox\{\\$1\}";
	    } elsif ($entity =~ /^(\w\w)lig$/) {
		$_IsoToTex{$char} = "\\mbox\{\\$1\}";
	    } else {
		$_IsoToTex{$char} = $char;
	    }
	    # we need to use a dotless lowercase i...
	    $_IsoToTex{$char} =~ s/\{i\}$/{\\i}/;
	} elsif ($char =~ /^[\#\$\%\&\_\{\}]$/) {
	    $_IsoToTex{$char} = "\\$char";
	} else {
	    $_IsoToTex{$char} = $char;
	}
	# HTML string
	if ($entity) {
	    $_IsoToHtml{$char} = "&$entity;";
	} elsif ($char eq "&") {
	    $_IsoToHtml{$char} = "&amp;";
	} elsif ($char eq "<") {
	    $_IsoToHtml{$char} = "&lt;";
	} elsif ($char eq ">") {
	    $_IsoToHtml{$char} = "&gt;";
	} else {
	    $_IsoToHtml{$char} = $char;
	}
	# ASCII string
	if ($entity) {
	    if ($entity eq "nbsp") {
		$_IsoToAscii{$char} = " ";
	    } elsif ($entity eq "acute") {
		$_IsoToAscii{$char} = "'";
	    } elsif ($entity =~ /^[lr]aquo$/) {
		$_IsoToAscii{$char} = "\"";
	    } elsif ($entity =~ /^(\w\w)lig$/) {
		$_IsoToAscii{$char} = $1;
	    } else {
		$_IsoToAscii{$char} = substr($entity, 0, 1);
	    }
	} else {
	    $_IsoToAscii{$char} = $char;
	}
	# lowercase/uppercase
	if ($entity) {
	    if ($entity eq "nbsp" or
		$entity eq "acute" or
		$entity =~ /^[lr]aquo$/) {
		$_IsoToUpper{$char} = $char;
		$_IsoToLower{$char} = $char;
	    } elsif ($entity =~ /^(\w\w)lig$/) {
		$_IsoToUpper{$char} = $_EntityToIso{uc($1)."lig"};
		$_IsoToLower{$char} = $_EntityToIso{lc($1)."lig"};
	    } else {
		$_IsoToUpper{$char} = $_EntityToIso{ucfirst($entity)} || uc($char);
		$_IsoToLower{$char} = $_EntityToIso{lcfirst($entity)} || lc($char);
	    }
	} else {
	    $_IsoToUpper{$char} = uc($char);
	    $_IsoToLower{$char} = lc($char);
	}
	$_IsoLetter{$char} = $_IsoToLower{$char} ne $_IsoToUpper{$char};
	# comparison order
	if ($entity) {
	    if ($entity eq "nbsp" or
		$entity eq "acute" or
		$entity =~ /^[lr]aquo$/) {
		$_IsoToOrder{$char} = $code;
	    } elsif ($entity =~ /^(\w)\wlig$/) {
		$_IsoToOrder{$char} = ord($1) + 0.1;
	    } else {
		$_IsoToOrder{$char} = ord(substr($entity, 0, 1));
	    }
	} else {
	    $_IsoToOrder{$char} = $code;
	}
    }

    # build $_ILRE
    $min = $max = undef;
    $_ILRE = "";
    foreach $code (0..255, -1) {
	if ($code >= 0) {
	    $char = chr($code);
	    next unless $_IsoLetter{$char};
	}
	if (defined($min)) {
	    if (defined($max)) {
		if ($code == $max+1) {
		    $max = $code;
		    next;
		} else {
		    $_ILRE .= sprintf("\\x%02x-\\x%02x", $min, $max);
		}
	    } else {
		if ($code == $min+1) {
		    $max = $code;
		    next;
		} else {
		    $_ILRE .= sprintf("\\x%02x", $min);
		}
	    }
	}
	# normal (reset) case
	$min = $code;
	$max = undef;
    }
}

#
# public routines
#

sub iso2tex ($) {
    my($string) = @_;

    $string =~ s/(.)/$_IsoToTex{$1}/egs;
    return($string);
}

sub iso2html ($) {
    my($string) = @_;

    $string =~ s/(.)/$_IsoToHtml{$1}/egs;
    return($string);
}

sub iso2ascii ($) {
    my($string) = @_;

    $string =~ s/(.)/$_IsoToAscii{$1}/egs;
    return($string);
}

sub iso_uc1 ($) {
    my($string) = @_;

    $string =~ s/(.)/$_IsoToLower{$1}/egs;
    $string =~ s/^(.)/$_IsoToUpper{$1}/es;
    return($string);
}

sub iso_uc ($) {
    my($string) = @_;

    $string =~ s/(.)/$_IsoToUpper{$1}/egs;
    return($string);
}

sub iso_lc ($) {
    my($string) = @_;

    $string =~ s/(.)/$_IsoToLower{$1}/egs;
    return($string);
}

sub iso_cmp ($$) {
    my($string1, $string2) = @_;
    my($length1, $length2, $pos, $test);

    $length1 = length($string1);
    $length2 = length($string2);
    $pos = 0;
    while ($length1 > $pos and $length2 > $pos) {
	$test = $_IsoToOrder{substr($string1, $pos, 1)}
	    <=> $_IsoToOrder{substr($string2, $pos, 1)};
	return($test) if $test;
	$pos++;
    }
    return($length1 <=> $length2);
}

sub iso_sort (@) {
    return(sort { iso_cmp($a, $b) } @_);
}

sub iso_sorti (@) {
    return(sort { iso_cmp(iso_lc($a), iso_lc($b)) } @_);
}

#
# capitalisation
#

sub _wc ($) {
    my($string) = @_;

    # boundary conditions
    return("") unless length($string);
    return(iso_uc($string)) unless length($string) > 1;
    # roman numerals -> uc
    return(iso_uc(substr($string, 0, 1)) . iso_lc(substr($string, 1)))
	if $string =~ m/^(ci|di|dix|mix)$/i;
    return(uc($string))
	if $string =~ m{ ^ m{0,3}
                           (d?c{1,3}|c?[dm]) ?
			   (l?x{1,3}|x?[lc]) ?
			   (v?i{1,3}|i?[vx]) $ }xi;
    # dj, xxl... -> uc
    return(uc($string))
	if $string =~ /^[bcdfghjklmnpqrstvwxz]{2,5}$/i;
    # mcfoo -> McFoo
    return("Mc" . uc($1) . lc($2))
	if $string =~ /^mc(\w)(\w+)$/i;
    # foo -> Foo
    return(iso_uc(substr($string, 0, 1)) . iso_lc(substr($string, 1)));
}

sub capitalise ($) {
    my($string) = @_;

    # remove control characters
    $string =~ s/[\x00-\x1f\x7f]+/ /g;
    # remove superfluous whitespace
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    $string =~ s/\s+/ /g;
    # split in words and normalise each word
    $string = join("", map(_wc($_), split(/([^$_ILRE]+)/o, $string)));
    # handle exceptions
    $string =~ s/\b(\d+)(\'?s|cc|st|nd|th|mm|cm|dm|er|\xe8re|eme|\xe8me)\b/$1\L$2\E/ig;
    $string =~ s/\b([a-z]+)\'(d|ll|m|n|re|s|t|ve)\b/$1\'\L$2\E/ig;
    $string =~ s/\b(?=dr|ft|jr|mr|mrs|pt|sr|st)(\w)(\w)\b/\u$1\l$2/ig;
    $string =~ s/(\s\'[no]\'\s)/\L$1\E/ig;
    # that's all folks
    return($string);
}

# define all the tables at load time so that we do not bother afterwards
_init();

1;

__END__

=head1 NAME

LC::ISO88591 - ISO 8859-1 utilities

=head1 SYNOPSIS

    use LC::ISO88591 qw(iso_cmp iso2html);
    $x = "français";
    print FILE "<P> x is ", iso2html($x), "\n";
    @list = qw(df ab de a dé);
    @sorted = sort { iso_cmp($a, $b) } @list;

=head1 DESCRIPTION

This package provides the following functions for strings containing
accentuated characters (as well as very few other characters such as
left and right guillemets) and encoded following the ISO 8859-1 (aka
Latin1) standard, with some characters from ISO 8859-15 (aka Latin9)
supported:

=over

=item capitalise(STRING)

cleans the given STRING (e.g. remove extra whitespace), attempts to
guess the most natural capitalisation for a name or title and returns
the result

=item iso2ascii(STRING)

returns a pure ASCII version, removing accents and cedilla, and
replacing guillemets with double-quotes

=item iso2html(STRING)

returns an HTML version using entities like C<&ccedil;>

=item iso2tex(STRING)

returns a TeX version using escapes  like C<\'a>

=item iso_lc(STRING)

same behaviour as Perl builtin's lc()

=item iso_uc(STRING)

same behaviour as Perl builtin's uc()

=item iso_uc1(STRING)

returns the string with the first character in uppercase and the rest in lowercase

=item iso_cmp(STRING)

same behaviour as Perl builtin's cmp

=item iso_sort(LIST)

same behaviour as Perl builtin's sort() but without support for a
sorting function

=item iso_sorti(LIST)

same behaviour as iso_sort() but in a case insignificant way

=back

=head1 TODO

=over

=item handle &euro; (164) &copy; (169) &reg; (174)

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: ISO88591.pm,v 1.20 2009/10/06 09:45:35 cons Exp $

=cut
