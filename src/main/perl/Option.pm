#+##############################################################################
#                                                                              #
# File: Option.pm                                                              #
#                                                                              #
# Description: module to ease options handling                                 #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Option;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.49 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
BEGIN {
    # since we do need to import the OT_ constants in the sub-packages below,
    # we have to define them at compilation time here, hence this BEGIN block...
    @ISA = qw(Exporter);
    @EXPORT = qw();
    @EXPORT_OK = qw();
    %EXPORT_TAGS = (
       "OT" => [ map("OT_$_",
		     qw(COUNTER BOOLEAN STRING NUMBER INTEGER REGEXP PATH DATE IPV4)) ],
    );
    Exporter::export_tags();
}

#
# used modules
#

use LC::Exception qw(throw_error SUCCESS);
use LC::Util qw(timestamp stamptime);

#
# private variables
#

our(
    $_EC,		# exception context
);

#+++############################################################################
#                                                                              #
# option types                                                                 #
#                                                                              #
#---############################################################################

use constant OT_COUNTER => "COUNTER"; # incremented counter
use constant OT_BOOLEAN => "BOOLEAN"; # boolean value
use constant OT_STRING  => "STRING";  # any string
use constant OT_NUMBER  => "NUMBER";  # any number
use constant OT_INTEGER => "INTEGER"; # integer number
use constant OT_REGEXP  => "REGEXP";  # valid Perl regular expression
use constant OT_PATH    => "PATH";    # _existing_ path (as verified by -e)
use constant OT_DATE    => "DATE";    # date (i.e. day with optional time)
use constant OT_IPV4    => "IPV4";    # IPv4 address in numerical dotted notation

#+++############################################################################
#                                                                              #
# auxiliary routines                                                           #
#                                                                              #
#---############################################################################

#
# check if the given value is a valid date
#

sub _check_date_value ($) {
    my($value) = @_;
    my($now, $test, $time);

    $now = time();
    if ($value =~ /^\d{4}\/\d{2}\/\d{2}$/) {
	# day only
	$test = "$value-00:00:00";
	$time = stamptime($test);
	return() unless defined($time);
	return($value);
    } elsif ($value =~ /^\d{4}\/\d{2}\/\d{2}-\d{2}\:\d{2}\:\d{2}$/) {
	# day and time
	$time = stamptime($value);
	return() unless defined($time);
	return($value);
    } elsif ($value =~ /^([\+\-]?0\@)?(\d{2}\:\d{2}\:\d{2})$/) {
	# today at given time
	$test = substr(timestamp($now), 0, 10) . "-$2";
	$time = stamptime($test);
	return() unless defined($time);
	return($test);
    } elsif ($value =~ /^([\+\-]?)(\d{1,3})(\@(\d{2}\:\d{2}\:\d{2}))?$/) {
	# day offset with maybe time
	$test = $now;
	if ($1 eq "+") {
	    $test += $2 * 86400;
	} else {
	    $test -= $2 * 86400;
	}
	$test = substr(timestamp($test), 0, 10);
	if ($4) {
	    $test .= "-$4";
	    $time = stamptime($test);
	} else {
	    $time = stamptime("$test-00:00:00");
	}
	return() unless defined($time);
	return($test);
    } elsif ($value =~ /^([\+\-]?)(\.\d+|\d{1,3}(\.\d+)?)$/) {
	# fractional day offset
	$test = $now;
	if ($1 eq "+") {
	    $test += $2 * 86400.0;
	} else {
	    $test -= $2 * 86400.0;
	}
	return(timestamp($test));
    } elsif ($value =~ /^\d{9,10}$/ and $value <= 2147483647) {
	# number of seconds since the epoch
	# (we only accept "Sat Mar  3 10:46:40 1973" to "Tue Jan 19 04:14:07 2038")
	return(timestamp($value));
    } else {
	throw_error("unknown date format");
	return();
    }
}

#
# check that the given value is valid for the given type
# (WARNING: this routine will maybe _modify_ the value!)
#

sub _check_value_type ($$) {
    my($value, $type) = @_;
    my($date, $octet);

    # an option item can always be undefined
    return(SUCCESS) unless defined($value);
    # normal case
    if ($type eq OT_BOOLEAN) {
	if ($value =~ /^(1|on|yes|true|enabled?)$/i) {
	    $_[0] = 1; # given value modified!
	} elsif ($value =~ /^(0|off|no|false|disabled?)$/i) {
	    $_[0] = 0; # given value modified!
	} else {
	    throw_error("invalid boolean value", $value);
	    return();
	}
    } elsif ($type eq OT_STRING) {
	# always ok!
    } elsif ($type eq OT_NUMBER) {
	unless ($value =~ /^[\+\-]?(?=\d|\.\d)\d*(\.\d*)?([Ee][\+\-]?\d+)?$/) {
	    throw_error("invalid number value", $value);
	    return();
	}
    } elsif ($type eq OT_INTEGER or $type eq OT_COUNTER) {
	unless ($value =~ /^[\-\+]?\d+$/) {
	    throw_error("invalid integer value", $value);
	    return();
	}
    } elsif ($type eq OT_REGEXP) {
	unless (length($value)) {
	    throw_error("invalid empty regexp");
	    return();
	}
	eval { $type =~ /$value/ };
	if ($@) {
	    throw_error("invalid regexp value", $value);
	    return();
	}
    } elsif ($type eq OT_PATH) {
	unless (-e $value) {
	    throw_error("invalid existing path value", $value);
	    return();
	}
    } elsif ($type eq OT_DATE) {
	$date = _check_date_value($value);
	if (defined($date)) {
	    $_[0] = $date; # given value modified!
	} else {
	    throw_error("invalid date value ($value)", $_EC->error());
	    return();
	}
    } elsif ($type eq OT_IPV4) {
	$octet = "(?:[0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])";
	unless ($value =~ /^$octet(?:\.$octet){3}$/o) {
	    throw_error("invalid ipv4 address value", $value);
	    return();
	}
    } else {
	throw_error("invalid option type", $type);
	return();
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# option item object                                                           #
#                                                                              #
#---############################################################################

package LC::Option::Item;
use strict;
use warnings;

use LC::Exception qw(throw_error SUCCESS);
use LC::Option qw(:OT);

#
# populate the %_KnownType hash
#

our(%_KnownType);

{
    my($name, $value);

    foreach $name (@{$EXPORT_TAGS{OT}}) {
	$value = eval($name);
	$_KnownType{$value}++;
    }
}

#
# object contructor
#

sub new : method {
    my($class, $name) = @_;
    my(%data);

    unless (defined($name)) {
	throw_error("undefined option name");
	return();
    }
    unless ($name =~ /^(\w+\-)*\w+$/ and length($name) > 1) {
	throw_error("invalid option name", $name);
	return();
    }
    %data = (
	     "_name" => $name,
	     "_type" => OT_COUNTER,
	     "_desc" => "no description available",
	     );
    bless(\%data, $class);
    return(\%data);
}

#
# get the item name
#

sub name : method {
    my($self) = @_;

    return($self->{"_name"});
}

#
# get or set the item letter (must be alphanumeric)
#

sub letter : method {
    my($self, $letter) = @_;

    return($self->{"_letter"}) unless @_ > 1;
    if (defined($letter) and not $letter =~ /^\w$/) {
	throw_error("invalid option letter", $letter);
	return();
    }
    $self->{"_letter"} = $letter;
    return(SUCCESS);
}

#
# get or set the mandatory flag
#

sub mandatory : method {
    my($self, $flag) = @_;

    return($self->{"_mandy"}) unless @_ > 1;
    $self->{"_mandy"} = $flag;
    return(SUCCESS);
}

#
# get or set the hidden flag
#

sub hidden : method {
    my($self, $flag) = @_;

    return($self->{"_hidden"}) unless @_ > 1;
    $self->{"_hidden"} = $flag;
    return(SUCCESS);
}

#
# get or set the item type (OT_* value)
#

sub type : method {
    my($self, $type) = @_;

    return($self->{"_type"}) unless @_ > 1;
    unless ($_KnownType{$type}) {
	throw_error("invalid option type", $type);
	return();
    }
    $self->{"_type"} = $type;
    return(SUCCESS);
}

#
# get or set the item description
#

sub description : method {
    my($self, $description) = @_;

    return($self->{"_desc"}) unless @_ > 1;
    $self->{"_desc"} = $description;
    return(SUCCESS);
}

#
# get or set the item binding, this can be:
#  - a code ref: to be called to get or set the item value
#  - a scalar ref: that will hold the item value
#

sub binding : method {
    my($self, $binding) = @_;

    return($self->{"_bind"}) unless @_ > 1;
    unless ($binding and ref($binding) =~ /^(CODE|SCALAR)$/) {
	throw_error("invalid option binding", $binding);
	return();
    }
    $self->{"_bind"} = $binding;
    return(SUCCESS);
}

#
# get or set the item value (will handle the binding and type checking)
#

sub value : method {
    my($self, $value) = @_;
    my($binding);

    $binding = $self->binding();
    if (@_ > 1) {
	# set the value
        LC::Option::_check_value_type($value, $self->type()) or return();
	if ($binding and ref($binding) eq "CODE") {
	    return($binding->($value));
	} elsif ($binding and ref($binding) eq "SCALAR") {
	    $$binding = $value;
	} else {
	    $self->{"_value"} = $value;
	}
	return(SUCCESS);
    }
    # get the value
    if ($binding and ref($binding) eq "CODE") {
	$value = $binding->();
    } elsif ($binding and ref($binding) eq "SCALAR") {
	$value = $$binding;
    } else {
	$value = $self->{"_value"};
	# special case for counters: initially they have 0 and not undef
	$value = 0 if $self->type() eq OT_COUNTER and not defined($value);
    }
    return($value);
}

#
# increment a counter option
#

sub increment : method {
    my($self) = @_;

    unless ($self->type() eq OT_COUNTER) {
	throw_error("cannot be incremented", $self->name());
	return();
    }
    $self->value($self->value() + 1) or return();
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# option set object                                                            #
#                                                                              #
#---############################################################################

package LC::Option::Set;
use strict;
use warnings;

use LC::Exception qw(throw_error throw_warning SUCCESS);
use LC::File qw(file_contents);
use LC::Option qw(:OT);

#
# object contructor
#

sub new : method {
    my($class) = @_;
    my($set);

    $set = { "_items" => {} };
    bless($set, $class);
    $set->add_hidden();    
    return($set);
}

#
# get or set the synopsis (the first line of the help text)
#

sub synopsis : method {
    my($self, $synopsis) = @_;

    $self->{"_synop"} = $synopsis if @_ > 1;
    return($self->{"_synop"});
}

#
# get the list of known option item names
#

sub names : method {
    my($self) = @_;

    return(keys(%{ $self->{"_items"} }));
}

#
# get the list of known option items
#

sub items : method {
    my($self) = @_;

    return(values(%{ $self->{"_items"} }));
}

#
# get or set an item by name
#

sub item : method {
    my($self, $name, $item) = @_;

    $self->{"_items"}{$name} = $item if @_ > 2;
    return($self->{"_items"}{$name});
}

#
# get or set the value of an item
#

sub value : method {
    my($self, $name, $value) = @_;
    my($item);

    $item = $self->item($name);
    unless ($item) {
	throw_error("unknown option", $name);
	return();
    }
    if (@_ > 2) {
	# set
	$item->value($value) or return();
	return($value);
    }
    # get
    return($item->value());
}

#
# add an item to the set
#

sub add : method {
    my($self, $item) = @_;
    my($name);

    unless ($item and UNIVERSAL::isa($item, "LC::Option::Item")) {
	throw_error("not an option item", $item);
	return();
    }
    $name = $item->name();
    if ($self->item($name)) {
	throw_error("option item already defined", $name);
	return();
    }
    $self->item($name, $item);
    return($self);
}

#
# add all internal/default/hidden items to the set
#

sub add_hidden : method {
    my($self) = @_;
    my($item);

    $item = LC::Option::Item->new("SHOW-HIDDEN");
    $item->description("show hidden options");
    $item->hidden(1);
    $self->add($item);    

    $item = LC::Option::Item->new("SHOW-VALUES");
    $item->description("show option values");
    $item->hidden(1);
    $self->add($item);    

    $item = LC::Option::Item->new("UNDEF");
    $item->description("undefine this option");
    $item->hidden(1);
    $item->type("STRING");
    $self->add($item);    
}

#
# return a "usage message"
#

sub usage : method {
    my($self) = @_;
    my($name, $usage, $item, $what, $info, @options, $maxlen, $left, $right);

    $usage = "Usage: ";
    if ($self->synopsis()) {
	$usage .= $self->synopsis();
	$usage =~ s/\s*$/\n/;
    } else {
	$usage .= $0;
	$usage .= " [OPTIONS] [--]" if $self->names();
	$usage .= " [ARGUMENTS]\n";
    }
    $maxlen = -1;
    foreach $name (sort($self->names())) {
	$item = $self->item($name);
	next if $item->hidden() and not $self->value("SHOW-HIDDEN");
	$left = "";
	$what = $item->letter();
	if (defined($what)) {
	    $left .= "-$what,";
	} else {
	    $left .= "   ";
	}
	$what = $item->type();
	if ($what eq OT_COUNTER) {
	    $info = "";
	} else {
	    $info = "=$what";
	}
	$info .= "!" if $item->mandatory();
	$left .= " --$name$info";
	$info = length($left);
	$maxlen = $info if $info > $maxlen;
	$right = $item->description();
	if ($self->value("SHOW-VALUES")) {
	    $info = $item->value();
	    if ($what eq OT_BOOLEAN) {
		$right .= $info ? " [true]" : " [false]";
	    } else {
		$info = "<undef>" unless defined($info);
		$right .= " [$info]";
	    }
	}
	push(@options, [ $left, $right ]);
    }
    foreach $item (@options) {
	$usage .= sprintf("  %-${maxlen}s  %s\n", @$item);
    }
    return($usage);
}

#
# parse an array (this can be used to parse @ARGV)
#

sub parse_array : method {
    my($self, $array) = @_;
    my($arg, $name, $value, $item, $letter, %item, %seen);

    #
    # collect the letter shortcuts in %item
    #
    foreach $item ($self->items()) {
	$letter = $item->letter();
	next unless defined($letter);
	if ($item{$letter}) {
	    throw_error("option letter already defined", $letter);
	    return();
	}
	$item{$letter} = $item;
    }
    #
    # process the arguments one by one
    #
    while (@$array and $array->[0] =~ /^-/) {
	$arg = shift(@$array);
	last if $arg eq "--"; # end of options marker
	if ($arg =~ /^--?((?:\w+\-)*\w+)=(.*)$/) {
	    ($name, $value) = ($1, $2);
	} elsif ($arg =~ /^--?((?:\w+\-)*\w+)$/) {
	    ($name, $value) = ($1, undef);
	} else {
	    throw_error("invalid option", $arg);
	    return();
	}
	if (length($name) == 1) {
	    # letter only
	    $item = $item{$name};
	} else {
	    # word
	    $item = $self->item($name);
	}
	unless ($item) {
	    #
	    # option unknown, check if it is made of joined letters
	    # (note: only counter options are allowed to be joined,
	    #  except the last letter; this is to avoid bogus
	    #  interpretations in case of typo: -debgu=3 -> -d=ebgu=3)
	    #
	    foreach $letter (split(//, substr($name, 0, -1))) {
		$item = $item{$letter};
		next if $item and $item->type() eq OT_COUNTER;
		throw_error("unknown option", $arg);
		return();
	    }
	    $letter = substr($name, -1);
	    $item = $item{$letter};
	    unless ($item) {
		throw_error("unknown option", $arg);
		return();
	    }
	    # all letters are known, process the first ones
	    foreach $letter (split(//, substr($name, 0, -1))) {
		$item{$letter}->increment() or return();
	    }
	    # then process the last one below (as normal processing)
	}
	#
	# option fully identified, good
	#
	if ($item->type() eq OT_COUNTER) {
	    if (defined($value)) {
		throw_error("option takes no value", $item->name());
		return();
	    }
	    $item->increment() or return();
	} else {
	    unless (defined($value)) {
		# try to get value from next arg
		if (@$array) {
		    $value = shift(@$array);
		    $value = undef if $value eq "--";
		}
	    }
	    unless (defined($value)) {
		throw_error("option requires a value", $item->name());
		return();
	    }
	    if ($item->name() eq "UNDEF") {
		$item = $self->item($value);
		unless ($item) {
		    throw_error("unknown option", $value);
		    return();
		}
		$value = undef;
	    } else {
		$seen{$item->name()}++;
		if ($seen{$item->name()} == 2) {
		    # same option used more than once
		    throw_warning("option used multiple times", $item->name())
			unless $item->binding() and ref($item->binding()) eq "CODE";
		}
	    }
	    $item->value($value) or return();
	}
    }
    return(SUCCESS);
}

#
# parse a hash (this does not support letter shortcuts (yet))
#

sub parse_hash : method {
    my($self, @hash) = @_;
    my($name, $value, $item);

    unless (@hash % 2 == 0) {
	throw_error("odd number of elements in hash", scalar(@hash));
	return();
    }
    while (@hash) {
	($name, $value) = splice(@hash, 0, 2);
	$item = $self->item($name);
	unless ($item) {
	    throw_error("unknown option", $name);
	    return();
	}
	$item->value($value) or return();
    }
    return(SUCCESS);
}

#
# parse a file
#

sub parse_file : method {
    my($self, $path, $override) = @_;
    my($contents, $line, $name, $value, $item);

    $contents = file_contents($path);
    return() unless defined($contents);
    foreach $line (split(/\n/, $contents)) {
	$line =~ s/^\s+//;
	$line =~ s/\s+$//;
	next unless length($line);
	next if $line =~ /^\#/;
	unless ($line =~ /^((?:\w+-)*\w+)\s*=\s*(.*?)$/) {
	    throw_error("unexpected line in $path", $line);
	    return();
	}
	($name, $value) = ($1, $2);
	$item = $self->item($name);
	unless ($item) {
	    throw_error("unknown option in $path", $name);
	    return();
	}
	if ($override or not defined($item->value())) {
	    $item->value($value) or return();
	}
    }
    return(SUCCESS);
}

#
# handle the -help option
# (this generates an error if there is no help option, this is a feature)
#

sub handle_help : method {
    my($self, $name, $version, $date) = @_;

    # initial checks
    unless ($name and $version and $date) {
	throw_error("missing argument(s) for handle_help method");
	return();
    }
    return(SUCCESS) unless $self->value("help");
    # simplify the RCS stuff
    $version = $1
	if $version =~ /^(?:revision|version):\s+(.+?)\s*$/i;
    $date = $1
	if $date =~ /^date:\s+(.+?)\s*$/i;
    # print usage + information and exit
    print($self->usage());
    printf("(this is %s version %s released on %s)\n", $name, $version, $date);
    exit(0);
}

#
# handle the -manual option
# (this generates an error if there is no manual option, this is a feature)
#

sub handle_manual : method {
    my($self) = @_;
    my($command, $path);

    return(SUCCESS) unless $self->value("manual");
    $command = -t STDOUT ? "perldoc" : "podselect";
    $path = $1 if $0 =~ /^(.+)$/ and -f $1;
    unless ($path and system($command, $path) == 0) {
	print("Please run: $command <the-full-path-of-this-program>\n");
    }
    exit(0);
}

#
# handle the configuration file related options (-cfgfile and -cfgdir)
#

sub handle_config : method {
    my($self, $name) = @_;
    my($item, $path);

    # check -cfgfile
    $item = $self->item("cfgfile");
    $path = $item->value()
	if $item;
    unless (defined($path)) {
	# check name
	unless ($name) {
	    throw_error("missing argument for handle_config method");
	    return();
	}
	# check -cfgdir
	$item = $self->item("cfgdir");
	$path = $item->value()
	    if $item;
	unless (defined($path)) {
	    # default directory is cfg.d in the same directory as $0
	    $path = $0;
	    $path =~ s/[^\/]+$/cfg.d/;
	    unless (-d $path) {
		# ... or /etc/cfg.d if the later does not exist
		$path = "/etc/cfg.d";
	    }
	}
	$path .= "/$name";
    }
    # it is ok if there is no configuration file
    return(SUCCESS) unless -f $path;
    # parse the configuration file
    return($self->parse_file($path));
}

#
# handle the mandatory options, i.e. make sure that they are all defined
#

sub handle_mandatory : method {
    my($self) = @_;
    my($item);

    foreach $item ($self->items()) {
	next unless $item->mandatory();
	next if defined($item->value());
	throw_error("mandatory option not set", $item->name());
	return();
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# high-level interface                                                         #
#                                                                              #
#---############################################################################

package LC::Option;
use strict;
use warnings;

$_EC = LC::Exception::Context->new()->will_store_errors();

#
# define an option set with a table (list of triplet refs)
#

sub define ($@) {
    my($synopsis, @defs) = @_;
    my($def, $set, $name, $letter, $type, $flags, $binding, $descro, $item);

    $set = LC::Option::Set->new();
    $set->synopsis($synopsis) if $synopsis;
    foreach $def (@defs) {
	($name, $binding, $descro) = @$def;
	if ($name =~ /^(.+?)([\!\#]+)$/) {
	    ($name, $flags) = ($1, $2);
	} else {
	    $flags = undef;
	}
	if ($name =~ /^(.+):(\w+)$/) {
	    ($name, $type) = ($1, uc($2));
	} else {
	    $type = undef;
	}
	if ($name =~ /^(.+)=(\w)$/) {
	    ($name, $letter) = ($1, $2);
	} else {
	    $letter = undef;
	}
	$item = LC::Option::Item->new($name);
	unless ($item) {
	    $_EC->rethrow_error();
	    return();
	}
	$item->mandatory(1) if $flags and $flags =~ /\!/;
	$item->hidden(1)    if $flags and $flags =~ /\#/;
	if (defined($type)) {
	    unless ($item->type($type)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	if (defined($letter)) {
	    unless ($item->letter($letter)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	if (defined($descro)) {
	    unless ($item->description($descro)) {
		$_EC->rethrow_error();
		return();
	    }
	}
	if (defined($binding)) {
	    if (ref($binding)) {
		unless ($item->binding($binding)) {
		    $_EC->rethrow_error();
		    return();
		}
	    } else {
		unless ($item->value($binding)) {
		    $_EC->rethrow_error();
		    return();
		}
	    }
	}
	unless ($set->add($item)) {
	    $_EC->rethrow_error();
	    return();
	};
    }
    return($set);
}

#
# parse an array and print usage information in case of error
#

sub parse_array ($$) {
    my($os, $array) = @_;

    unless ($os->parse_array($array)) {
	print($os->usage());
	$_EC->rethrow_error();
	return();
    }
    return(SUCCESS);
}

#
# parse @ARGV and print usage information in case of error
#

sub parse_argv ($) {
    my($os) = @_;

    unless ($os->parse_array(\@ARGV)) {
	print($os->usage());
	$_EC->rethrow_error();
	return();
    }
    return(SUCCESS);
}

#
# parse a file and report meaningful error (and not usage info!)
#

sub parse_file ($$) {
    my($os, $path) = @_;

    unless ($os->parse_file($path)) {
	throw_error("failed to parse $path", $_EC->error());
	return();
    }
    return(SUCCESS);
}

1;

__END__

=head1 NAME

LC::Option - module to ease options handling

=head1 SYNOPSIS

  use LC::Option;
  $OS = LC::Option::define("$0 [OPTIONS] [--] [path...]",
      [ "help=h",          undef,  "show some help" ],
      [ "mac",             undef,  "report mac time" ],
      [ "mtime=m",         undef,  "report mtime" ],
      [ "limit=l:integer",     0,  "limit lines printed" ],
      [ "file:boolean",        1,  "consider plain files" ],
      [ "directory:boolean",   0,  "consider directories" ],
  );
  LC::Option::parse_argv($OS);
  $OS->handle_help($0, q$Revision: 1.49 $,
                       q$Date: 2009/11/18 11:17:50 $ );
  if ($OS->value("mac")) {
      ...
  }

=head1 DESCRIPTION

This module eases the options parsing. Once an option set (an object
describing which options are valid) is defined, one can easily parse
C<@ARGV>, an array, a hash or a file. The option set object can then
be used to retrieve the value associated with each option.

Methods are also available to check for mandatory options or to print
a nicely formatted help text with the description of all the options.

The known option types are:

=over

=item counter

the value is incremented each time the option is specified

=item boolean

the value is a boolean

=item string

the value is a string

=item number

the value is a number

=item integer

the value is an integer

=item regexp

the value is a valid Perl regular expression

=item path

the value is an I<existing> path

=item date

the value is date, i.e. a day with an optional time

=item ipv4

the value is an IPv4 address in numerical dotted notation

=back

An option set can be used to parse:

=over

=item * C<@ARGV> with the method C<parse_argv>

=item * an array with the method C<parse_array>

=item * a hash with the method C<parse_hash>

=item * a file with the method C<parse_file>

=back

After parsing, the value of an option can be retrieved using the
C<value> method.

Some high-level routines are also provided (but not exported):

=over

=item LC::Option::define(STRING, OPTIONSREF)

define a new option set (see below for a more complete description)

=item LC::Option::parse_argv(OPTIONSET)

use the given option set and parse C<@ARGV>, printing a usage message
if some invalid option has been given

=back

Finally, some handy methods are provided to ease options checking:

=over

=item handle_help(NAME, VERSION, DATE)

show a nice usage message including the program name, version and
release date; this requires an option named "help" in the option set

=item handle_manual()

run C<perldoc> on the script itself to show its embedded manual; this
requires an option named "manual" in the option set

=item handle_mandatory()

check that all the mandatory options are indeed defined

=back

=head1 OPTION SET DEFINITION

The easiest way to define an option set is to use the
C<LC::Option::define> function.

Its first argument is the first line that will be reported by the
C<usage> method. See the example above for a typical use.

Its second argument is a reference to a list of triplets: option
specification, value and description.

The option specification is a string containing the option name,
optionally followed by "=" and the equivalent option letter,
optionally followed by ":" and the option type, optionally followed by
"!" to indicate a mandatory option, optionally followed by "#" to
indicate a hidden option.

The option value is the default value or a reference to a variable
that will hold the value or a reference to a subroutine that will be
called to get or set the value.

=head1 FORMATS

Here are the supported boolean values:

=over

=item * meaning true: 1, on, yes, true, enable or enabled

=item * meaning false: 0, off, no, false, disable or disabled

=back

Here are the supported date formats:

=over

=item * day and time: 2007/12/11-09:39:30

=item * day only (meaning at 00:00:00): 2007/12/11

=item * time only (meaning today): 09:39:30

=item * time with day offset: +1@12:00:00 (i.e. tomorrow noon)

=item * day offset only (meaning at 00:00:00): -3 (i.e. 3 days ago)

=item * fractional offsets: -2.5 (i.e. 2 days 12 hours ago)

=item * Unix time (seconds since the epoch): 1245328352

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Option.pm,v 1.49 2009/11/18 11:17:50 cons Exp $

=head1 TODO

=over

=item * finish the documentation (including configuration file handling)

=item * handle synonyms/aliases?

=item * add more types such as existing file|dir|host...

=item * handle lists like -foo=bar,gag?

=item * it is probably a bad idea to have two parse_array functions...

=back

=cut
