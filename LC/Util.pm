#+##############################################################################
#                                                                              #
# File: Util.pm                                                                #
#                                                                              #
# Description: miscellaneous utilities                                         #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Util;
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
@EXPORT_OK = qw($ProgramName timestamp stamptime syslogtime timelocal timegm
    rectrl unctrl base64_encode base64_decode tablify new_symbol random_name
    bytefmt past plural quantify);

#
# used modules
#

use LC::Exception qw(throw_error);

#
# public variables
#

our(
    $ProgramName,    # name (not path) of the running program
);

$ProgramName = $0;
$ProgramName =~ s#.*/##;

#
# private variables
#

our(
    $_CtrlInitialised,    # true if the following four tables are set
    %_CompactC2E,         # compact style's char to escaped seq mapping
    %_CompactE2C,         # compact style's escaped seq to char mapping
    %_PerlC2E,	          # perl style's char to escaped seq mapping
    %_PerlE2C,	          # perl style's escaped seq to char mapping
    @_B64_Enc,	          # Base64 encoding table: num => char
    %_B64_Dec,	          # Base64 decoding table: char => num
    $_LastTime,	          # last guessed time for _time2()
    @_LastLocal,	  # localtime($_LastTime)
    @_LastGm,		  # gmtime($_LastTime)
    $_TimeCount,	  # count the number of calls to {local|gm}time()
    @_MonthDays,	  # year offset for each month, in days
    %_MonthNum,	          # month number from the three-letter string
    %_Past,		  # exceptions for past()
    %_Plural,		  # exceptions for plural()
    $_SymbolCount,	  # counter used to create unique symbols
    @_ByteSuffix,	  # byte suffixes
);

@_MonthDays = qw(0 31 59 90 120 151 181 212 243 273 304 334);

@_MonthNum{qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)} = (1 .. 12);

%_Past = (
    "begin"  => "began",
    "break"  => "broke",
    "build"  => "built",
    "catch"  => "caught",
    "do"     => "did",
    "find"   => "found",
    "freeze" => "froze",
    "get"    => "got",
    "give"   => "gave",
    "grow"   => "grew",
    "keep"   => "kept",
    "leave"  => "left",
    "make"   => "made",
    "put"    => "put",
    "read"   => "read",
    "run"    => "ran",
    "send"   => "sent",
    "take"   => "took",
    "write"  => "wrote",
);

%_Plural = (
    "child"  => "children",
    "foot"   => "feet",
    "half"   => "halves",
    "index"  => "indices",
    "knife"  => "knives",
    "leaf"   => "leaves",
    "life"   => "lives",
    "man"    => "men",
    "tooth"  => "teeth",
    "woman"  => "women",
);

@_ByteSuffix = qw(B kB MB GB TB PB);

#+++############################################################################
#                                                                              #
# escape control characters so that the string can be safely printed           #
#                                                                              #
#---############################################################################

sub _ctrl_init () {
    my($code, $char);

    # main algorithm
    foreach $code (0..255) {
	$char = chr($code);
	if (32 <= $code and $code <= 126) {
	    # printable and (usually) safe
	    $_PerlC2E{$char} = $_CompactC2E{$char} = $char;
	} else {
	    # non-printable or dangerous
	    $_PerlC2E{$char} = sprintf('\x%02x', $code);
	    $_CompactC2E{$char} =
		$code < 32 ? sprintf('^%c', $code+64) : sprintf('\%02x', $code);
	}
    }
    # exceptions so that the result looks nicer
    $_PerlC2E{"\a"} = '\a';
    $_PerlC2E{"\b"} = '\b';
    $_PerlC2E{"\t"} = '\t';
    $_PerlC2E{"\n"} = '\n';
    # note: \v (i.e. VT) is not replaced as it's not known by Perl
    $_PerlC2E{"\f"} = '\f';
    $_PerlC2E{"\r"} = '\r';
    $_PerlC2E{"\e"} = '\e';
    $_CompactC2E{"\c?"} = '^?'; # i.e. DEL
    # \ and ^ have to be escaped too
    $_CompactC2E{"\\"} = $_PerlC2E{"\\"} = "\\\\";
    $_CompactC2E{"^"} = "\\^"; # only needed in compact style
    # store also the inverse maps
    %_CompactE2C = reverse(%_CompactC2E);
    %_PerlE2C = reverse(%_PerlC2E);
    # all tables are now initialised
    $_CtrlInitialised = 1;
}

sub unctrl ($;%) {
    my($string, %opt) = @_;

    _ctrl_init() unless $_CtrlInitialised;
    if ($opt{style} and $opt{style} =~ /^compact$/i) {
	$string =~ s/(.)/$_CompactC2E{$1}/egs;
	$string =~ s/ /\\s/gs if $opt{space};
    } elsif ($opt{style} and $opt{style} !~ /^perl$/i) {
	throw_error("invalid escape style", $opt{style});
	return();
    } else {
	$string =~ s/(.)/$_PerlC2E{$1}/egs;
	$string =~ s/ /\\x20/gs if $opt{space};
    }
    $string =~ s/\"/\\x22/gs if $opt{quote};
    return($string);
}

sub rectrl ($;%) {
    my($string, %opt) = @_;

    _ctrl_init() unless $_CtrlInitialised;
    if ($opt{style} and $opt{style} =~ /^compact$/i) {
	$string =~ s{
	    ( \\ (?: \\ | \^ | [\da-f]{2} | s ) | \^ [\x3f-\x5f] )
	}{
	  exists($_CompactE2C{$1}) ?
            $_CompactE2C{$1} :
            ( ($opt{space} and $1 eq "\\s") ?
              " " :
              (throw_error("invalid escape sequence", $1), return()))
	}xegs;
    } elsif ($opt{style} and $opt{style} !~ /^perl$/i) {
	throw_error("invalid escape style", $opt{style});
	return();
    } else {
	$string =~ s{
	    ( \\ (?: \\ | [abtnfre] | x[\da-f]{2} ) )
	}{
	  exists($_PerlE2C{$1}) ?
            $_PerlE2C{$1} :
            ( ($opt{space} and $1 eq "\\x20") ?
              " " :
              (throw_error("invalid escape sequence", $1), return()))
	}xegs;
    }
    return($string);
}

#+++############################################################################
#                                                                              #
# Base64 (RFC 2045) encoding and decoding                                      #
#                                                                              #
#---############################################################################

sub _b64_init () {
    @_B64_Enc = ("A" .. "Z", "a" .. "z", 0 .. 9, "+", "/");
    @_B64_Dec{ @_B64_Enc } = (0 .. 63);
}

sub base64_encode ($) {
    my($in) = @_;
    my($length, $out, $offset, $chunk);

    _b64_init() unless @_B64_Enc;
    $length = length($in);
    $out = "";
    $offset = 0;
    while ($length >= $offset + 3) {
	$chunk = unpack("N", "\0" . substr($in, $offset, 3));
	$out .= $_B64_Enc[ ($chunk & 0x00FC0000) >> 18 ];
	$out .= $_B64_Enc[ ($chunk & 0x0003F000) >> 12 ];
	$out .= $_B64_Enc[ ($chunk & 0x00000FC0) >>  6 ];
	$out .= $_B64_Enc[ ($chunk & 0x0000003F) >>  0 ];
	$offset += 3;
    }
    if ($length - $offset == 1) {
	$chunk = unpack("c", substr($in, $offset, 1));
	$out .= $_B64_Enc[ ($chunk & 0xFC) >>  2 ];
	$out .= $_B64_Enc[ ($chunk & 0x03) <<  4 ];
	$out .= "=="; # padding
    } elsif ($length - $offset == 2) {
	$chunk = unpack("n", substr($in, $offset, 2));
	$out .= $_B64_Enc[ ($chunk & 0xFC00) >> 10 ];
	$out .= $_B64_Enc[ ($chunk & 0x03F0) >>  4 ];
	$out .= $_B64_Enc[ ($chunk & 0x000F) <<  2 ];
	$out .= "="; # padding
    }
    return($out);
}

sub base64_decode ($) {
    my($in) = @_;
    my($length, $out, $offset, $chunk);

    _b64_init() unless @_B64_Enc;
    throw_error("invalid string") unless $in =~ /^[A-Za-z0-9\+\/]*={0,2}$/;
    $length = length($in);
    throw_error("invalid length", $length) unless $length % 4 == 0;
    $out = "";
    $offset = 0;
    while ($length >= $offset + 4) {
	$chunk = substr($in, $offset, 4);
	if ($chunk =~ /^..==$/) {
	    $out .= pack("C", ($_B64_Dec{substr($chunk, 0, 1)} << 2)
			     |($_B64_Dec{substr($chunk, 1, 1)} >> 4));
	} elsif ($chunk =~ /^...=$/) {
	    $out .= pack("n", ($_B64_Dec{substr($chunk, 0, 1)} << 10)
			     |($_B64_Dec{substr($chunk, 1, 1)} <<  4)
			     |($_B64_Dec{substr($chunk, 2, 1)} >>  2));
	} else {
	    $out .= substr(pack("N",
				($_B64_Dec{substr($chunk, 0, 1)} << 18)
			       |($_B64_Dec{substr($chunk, 1, 1)} << 12)
			       |($_B64_Dec{substr($chunk, 2, 1)} <<  6)
			       |($_B64_Dec{substr($chunk, 3, 1)} <<  0)), 1);
	}
	$offset += 4;
    }
    return($out);
}

#+++############################################################################
#                                                                              #
# timestamp with a nice compact (but Y2K safe) format: 2003/06/22-16:34:11     #
# the result is of fixed length and can be lexically sorted                    #
#                                                                              #
#---############################################################################

sub timestamp ($;$) {
    my($time, $gmt) = @_;
    my($sec, $min, $hour, $mday, $mon, $year);
    
    # special case if time is -1 (usually an error)
    return("????/??/??-??:??:??") if $time == 0xFFFFFFFF;
    # normal case
    ($sec, $min, $hour, $mday, $mon, $year) =
	$gmt ? gmtime($time) : localtime($time);
    return(sprintf("%04d/%02d/%02d-%02d:%02d:%02d",
                   $year+1900, $mon+1, $mday, $hour, $min, $sec));
}

#+++############################################################################
#                                                                              #
# inverse of localtime() and gmtime() similar to the one from Time::Local      #
# but much faster (less than two calls to {local|gm}time() on average)         #
# it works well around DST changes                                             #
#                                                                              #
#---############################################################################

sub _time2 ($$$$$$$) {
    my($gmt, @given) = @_;
    my($time, @guess, %tried, $target, $offset, $direction, $otime);

    # validate the input
    if (grep(/\D/, @given)) {
	throw_error("invalid date", "@given");
	return();
    }
    grep(s/^0+(\d+?)$/$1/, @given); # force numbers (i.e. 03 -> 3)
    unless (0 <= $given[0] and $given[0] <= 59) {
	throw_error("invalid second", $given[0]);
	return();
    }
    unless (0 <= $given[1] and $given[1] <= 59) {
	throw_error("invalid minute", $given[1]);
	return();
    }
    unless (0 <= $given[2] and $given[2] <= 23) {
	throw_error("invalid hour", $given[2]);
	return();
    }
    unless (1 <= $given[3] and $given[3] <= 31) {
	throw_error("invalid day", $given[3]);
	return();
    }
    unless (0 <= $given[4] and $given[4] <= 11) {
	throw_error("invalid month", $given[4]+1);
	return();
    }
    # initialise the guess
    $_LastTime = $^T
	unless $_LastTime;
    $time = $_LastTime;
    if ($gmt) {
	@_LastGm = (gmtime($_LastTime))[0..5]
	    unless @_LastGm;
	@guess = @_LastGm;
	@_LastLocal = ();
    } else {
	@_LastLocal = (localtime($_LastTime))[0..5]
	    unless @_LastLocal;
	@guess = @_LastLocal;
	@_LastGm = ();
    }
    %tried = ($time => 1);
    $target = "@given";
    $_TimeCount = 0;
    # guess
    while ($target ne "@guess") {
	$direction = $given[5] <=> $guess[5] || $given[4] <=> $guess[4] ||
	             $given[3] <=> $guess[3] || $given[2] <=> $guess[2] ||
	             $given[1] <=> $guess[1] || $given[0] <=> $guess[0];
	$offset = ($given[0] - $guess[0])              # * 1 second
	        + ($given[1] - $guess[1])  * 60        # * 1 minute
	        + ($given[2] - $guess[2])  * 3600      # * 1 hour
	        + ($given[3] - $guess[3])  * 86400     # * 1 day
	        + ($_MonthDays[$given[4]] -            # (we use the real number
		   $_MonthDays[$guess[4]]) * 86400     #  of days between months)
	        + ($given[5] - $guess[5])  * 31557600; # * 365.25 days
	if ($offset == 0 or $offset * $direction < 0) {
	    # because of our approximations around year and month boundaries,
	    # we may end up with a null offset or in the wrong direction:
	    # we move one day in the right direction to workaround this...
	    $offset = 86400 * $direction;
	}
	$otime = $time;
	$time += $offset;
	if ($offset > 0 and $otime > $time) {
	    # overflow near the end of times
	    $time = 2147483647; # 2^31 - 1
	} elsif ($offset < 0 and $otime < $time) {
	    # overflow near the begin of times
	    $time = -2147483648; # - 2^32
	}
	if ($tried{$time}++ or $_TimeCount++ > 10) {
	    throw_error("invalid date", "@given");
	    return();
	}
	if ($gmt) {
	    @guess = (gmtime($time))[0..5];
	} else {
	    @guess = (localtime($time))[0..5];
	}
    }
    # remember this (successful) guess for later use
    $_LastTime = $time;
    if ($gmt) {
	@_LastGm = @guess;
    } else {
	@_LastLocal = @guess;
    }
    return($time);
}

sub timelocal (@) {
    my(@args) = @_;

    unless (@args == 6) {
	# note: we don't use a prototype of ($$$$$$) to allow calling us with
	# a list like in timelocal(@foo)
	throw_error("invalid number of arguments", scalar(@args));
	return();
    }
    return(_time2(0, $args[0], $args[1], $args[2], $args[3], $args[4], $args[5]));
}

sub timegm (@) {
    my(@args) = @_;

    unless (@args == 6) {
	# note: we don't use a prototype of ($$$$$$) to allow calling us with
	# a list like in timegm(@foo)
	throw_error("invalid number of arguments", scalar(@args));
	return();
    }
    return(_time2(1, $args[0], $args[1], $args[2], $args[3], $args[4], $args[5]));
}

sub stamptime ($;$) {
    my($string, $gmt) = @_;

    unless ($string =~ /^(\d\d\d\d)\/(\d\d)\/(\d\d)-(\d\d):(\d\d):(\d\d)$/) {
	throw_error("invalid timestamp", $string);
	return();
    }
    return(_time2($gmt, $6, $5, $4, $3, $2-1, $1-1900));
}

sub syslogtime ($;$) {
    my($string, $year) = @_;
    my($month, @now);

    unless ($string =~ /^(\w{3})\s{1,2}(\d{1,2})\s(\d\d):(\d\d):(\d\d)$/) {
	throw_error("invalid syslog timestamp", $string);
	return();
    }
    unless ($_MonthNum{$1}) {
	throw_error("invalid syslog timestamp", $string);
	return();
    }
    $month = $_MonthNum{$1} - 1;
    if (defined($year)) {
	$year -= 1900;
    } else {
	@now = localtime(time);
	$year = $now[5];
	$year-- if $month > $now[4];
	$year-- if $month == $now[4] and $2 > $now[3];
    }
    return(_time2(0, $5, $4, $3, $2, $month, $year));
}

#+++############################################################################
#                                                                              #
# return an eight characters long quite random name                            #
#                                                                              #
#---############################################################################

sub random_name () {
    my($name, $rand, $time, $number);

    _b64_init() unless @_B64_Enc;
    $name = "";
    $rand = int(rand(0x1000000));
    $time = time();
    foreach $number ((($$ << 16) ^ ($time >> 8) ^ ($rand >> 16)),
		     ($time ^ ($rand << 8))) {
	$name .= $_B64_Enc[($number & 0xfc0000) >> 18] .
	    $_B64_Enc[($number & 0x03f000) >> 12] .
	    $_B64_Enc[($number & 0x000fc0) >> 6] .
	    $_B64_Enc[($number & 0x00003f)];
    }
    $name =~ tr#/#_#; # replace / by _ so that it can be used in file names
    return($name);
}

#+++############################################################################
#                                                                              #
# handy functions to print better English ;-)                                  #
#                                                                              #
#---############################################################################

sub past ($) {
    my($verb) = @_;

    unless ($_Past{$verb}) {
	$_Past{$verb} = $verb;
	$_Past{$verb} =~ s/e?$/ed/;
    }
    return($_Past{$verb});
}

sub plural ($) {
    my($name) = @_;

    unless ($_Plural{$name}) {
	if ($name =~ /(s|sh|x|ch)$/) {
	    $_Plural{$name} = $name . "es";
	} elsif ($name =~ /[bcdfghjklmnpqrstvwxz]o$/) {
	    $_Plural{$name} = $name . "es";
	} elsif ($name =~ /y$/) {
	    $_Plural{$name} = substr($name, 0, -1) . "ies";
	} else {
	    $_Plural{$name} = $name . "s";
	}
    }
    return($_Plural{$name});
}

sub quantify ($$) {
    my($count, $name) = @_;
    return($count . " " . ($count == 1 ? $name : plural($name)));
}

#+++############################################################################
#                                                                              #
# number formatting                                                            #
#                                                                              #
#---############################################################################

sub bytefmt ($;$) {
    my($number, $precision) = @_;
    my($index);

    $precision = 2 unless defined($precision);
    $index = 0;
    while ($_ByteSuffix[$index] and $number > 1024) {
	$index++;
	$number /= 1024.0;
    }
    return("$number $_ByteSuffix[$index]") if $number =~ /^\d+$/;
    return(sprintf("%.${precision}f %s", $number, $_ByteSuffix[$index]));
}

#+++############################################################################
#                                                                              #
# generate a new symbol                                                        #
#                                                                              #
#---############################################################################

sub new_symbol () {
    my($name, $ref);
    $_SymbolCount++;
    $name = "_Symbol_" . $_SymbolCount;
    {
	no strict "refs";
	$ref = \*{"LC::Utils::" . $name};
    }
    delete($LC::Utils::{$name});
    return($ref);
}

#+++############################################################################
#                                                                              #
# table formatting                                                             #
#                                                                              #
#---############################################################################

sub _expand ($) {
    my($line) = @_;
    my(@cols, @result, $idx, @line);

    @cols = @$line;
    while (grep(/\n/, @cols)) {
	@line = ();
	foreach $idx (0 .. @cols - 1) {
	    if ($cols[$idx] =~ /^([^\n]*)\n([\d\D]*)$/s) {
		push(@line, $1);
		$cols[$idx] = $2;
	    } else {
		push(@line, $cols[$idx]);
		$cols[$idx] = "";
	    }
	}
	push(@result, [ @line ]);
    }
    push(@result, \@cols);
    return(@result);
}

sub tablify ($%) {
    my($data, %opt) = @_;
    my($result, @colen, $headlen, $line, @list, $idx, $fmt, $len, $align);

    #
    # check the options
    #
    @list = grep($_ !~ /^(header|headchar|colchar|colspace|leftspace|strip|align\d+)$/,
		 keys(%opt));
    if (@list) {
	throw_error("invalid option", $list[0]);
	return();
    }
    if (defined($opt{headchar}) and length($opt{headchar}) != 1) {
	throw_error("invalid header character", $opt{headchar});
	return();
    }
    if (defined($opt{colchar}) and length($opt{colchar}) != 1) {
	throw_error("invalid column character", $opt{colchar});
	return();
    }
    foreach $fmt (keys(%opt)) {
	next unless $fmt =~ /^align\d+$/;
	unless ($opt{$fmt} =~ /^(left|right)$/) {
	    throw_error("invalid column alignment", $opt{$fmt});
	    return();
	}
    }
    unless (defined($opt{colspace})) {
	$opt{colspace} = defined($opt{colchar}) ? 0 : 1;
    }
    #
    # first pass to copy the data and handle newlines
    #
    if ($opt{header}) {
	@list = _expand($opt{header});
	$headlen = @list;
    } else {
	@list = ();
	$headlen = 0;
    }
    foreach $line (@$data) {
	push(@list, _expand($line));
    }
    #
    # second pass to strip and find the lengths
    #
    foreach $line (@list) {
	if (@colen and @colen != @$line) {
	    throw_error("column mismatch", @colen . " versus " . @$line);
	    return();
	}
	foreach $idx (0 .. @$line - 1) {
	    if ($opt{strip}) {
		$line->[$idx] =~ s/^\s+//;
		$line->[$idx] =~ s/\s+$//;
	    }
	    $len = length($line->[$idx]);
	    $colen[$idx] = $len
		if not defined($colen[$idx]) or $colen[$idx] < $len;
	}
    }
    unless (@colen) {
	throw_error("no data supplied");
	return();
    }
    splice(@list, $headlen, 0, [ map($opt{headchar} x $_, @colen) ])
	if defined($opt{headchar});
    #
    # third pass to format
    #
    $fmt = "";
    $fmt .= " " x $opt{leftspace} if $opt{leftspace};
    foreach $idx (0 .. @colen - 1) {
	$align = $opt{"align".($idx+1)} || "left";
	$fmt .= "%" . ($align eq "left" ? "-" : "") . $colen[$idx] . "s";
	$fmt .= " " x $opt{colspace};
	$fmt .= $opt{colchar} . " " x $opt{colspace}
	    if defined($opt{colchar});
    }
    $fmt =~ s/\s+$//;
    $result = "";
    foreach $line (@list) {
	$data = sprintf($fmt, @$line);
	$data =~ s/\s+$// if $opt{strip};
	$result .= "$data\n";
    }
    return($result);
}

1;

__END__

=head1 NAME

LC::Util - miscellaneous utilities

=head1 SYNOPSIS

  use LC::Util qw($ProgramName timestamp);
  print(timestamp(time), "\n");
  die("Usage: $ProgramName path\n") unless @ARGV == 1;
  printf("data = %s\n", LC::Util::unctrl($data, "style" => "compact"));

=head1 DESCRIPTION

This package provides the following variable and functions (none of
them being exported by default):

=over

=item $ProgramName

name of the running program (taken from C<$0>) with any leading path
information stripped out

=item base64_decode(STRING)

returns the original string that has been Base64 encoded into STRING;
it does not accept any extra character, even whitespace

=item base64_encode(STRING)

returns the Base64 encoding of the given STRING

=item bytefmt(NUMBER[, PRECISION])

returns a string representation of the given number, suitable to
represnt bytes; for instance C<2048> will give C<"2 kB">

=item new_symbol()

creates an anonymous glob and returns a reference to it; such a glob
reference can be used as a file or directory handle

=item past(STRING)

assuming that STRING is an English verb, returns its past form

=item plural(STRING)

assuming that STRING is an English noun, returns its plural form

=item quantify(NUMBER, STRING)

assuming that STRING is an English noun, returns a string saying how
much of it there is; e.g. C<quantify(2, "foot")> is C<"2 feet">

=item random_name()

returns an eight characters long and quite random name containing only
alphanumeric characters or C<+>; this is not cryptographically perfect
but it should be good enough for most applications

=item rectrl(STRING[, OPTIONS])

returns the original form of an escaped string returned by unctrl();
C<X> is always the same as C<rectrl(unctrl(X))>; the options are the
same as for unctrl()

=item stamptime(STRING[, GMT])

computes time from a timestamp as returned by timestamp()

=item syslogtime(STRING[, YEAR])

computes time from a timestamp as created by syslog (e.g. C<Jun 16
09:46:20>), if the YEAR is not given, assumes that the date is within
the last 365 days

=item tablify(DATA[, OPTIONS])

formats the given data (which must be a reference to a list of lists)
as a table and returns it as one string; options:
header (a reference to a list of headers),
headchar (the character to use to separate the header from the data),
colchar (the character to use to separate the columns),
colspace (number of space characters to put between columns),
leftspace (number of space characters to add on the left),
strip (remove leading and trailing spaces),
alignI<N> (type of alignment for column I<N>, can be "left" or "right")

=item timegm(SEC, MIN, HOUR, MDAY, MON, YEAR)

efficiently computes time from GMT time information; the parameters
have the same meaning as the ones returned by gmtime(); this can fail
on invalid dates such as February 30th

=item timelocal(SEC, MIN, HOUR, MDAY, MON, YEAR)

efficiently computes time from local time information; the parameters
have the same meaning as the ones returned by localtime(); this can
fail on invalid dates such as February 30th or betwwen DST leaps
forward (e.g. C<"2001/03/25-02:30:00"> never happened as we jumped
directly from 2 am to 3 am...)

=item timestamp(TIME[, GMT])

returns a 19 characters long timestamp string of the given time value,
for instance C<"2003/05/06-16:39:59">; the TIME is analysed for the
local time zone unless GMT is true, in which case the standard
Greenwich time zone is used

=item unctrl(STRING[, OPTIONS])

returns an escaped string equivalent to the given one but made only of
printable characters (using C<\X> and C<\xNN>); if the space option is
given (i.e. C<"space" =E<gt> 1>), also escape the space character; if
the quote option is given (i.e. C<"quote" =E<gt> 1>), also escape the
double-quote character; if the compact style option is selected
(i.e. C<"style" =E<gt> "compact">), use a more compact style using
C<^X> and C<\NN>

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Util.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=cut
