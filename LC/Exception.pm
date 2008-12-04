#+##############################################################################
#                                                                              #
# File: Exception.pm                                                           #
#                                                                              #
# Description: exception manipulation                                          #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Exception;
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
@EXPORT_OK = qw(SUCCESS throw_error throw_warning
		throw_parent_error throw_parent_warning
		throw_mutable_error throw_mutable_warning);

#
# used modules
#

use overload '""' => \&format;

#
# public constants
#

use constant SUCCESS => 1;    # handy return value for successful functions

#
# public variables
#

our(
    $Formatter,	      # code to format (i.e. stringify) an exception
    $WarningPrefix,   # prefix to format warnings
    $ErrorPrefix,     # prefix to format errors
    $Reporter,	      # code to report an exception to the user
);

$WarningPrefix = "*";
$ErrorPrefix = "***";

#+++############################################################################
#                                                                              #
# stack frame object                                                           #
#                                                                              #
#---############################################################################

package LC::Exception::StackFrame;
use strict;
use warnings;

#
# object contructor, @info _must_ be the result of caller()
#

sub new : method {
    my($class, @info) = @_;

    bless(\@info, $class);
    return(\@info);
}

#
# (some) field access methods, see caller() documentation
#

sub package : method {
    my($self) = @_;

    return($self->[0]);
}

sub filename : method {
    my($self) = @_;

    return($self->[1]);
}

sub line : method {
    my($self) = @_;

    return($self->[2]);
}

sub subroutine : method {
    my($self) = @_;

    return($self->[3]);
}

#+++############################################################################
#                                                                              #
# exception object                                                             #
#                                                                              #
#---############################################################################

package LC::Exception;
use strict;
use warnings;

#
# constants for the object flags (whenever you can, use the methods instead)
#

use constant FLAG_FATAL    => 1 << 0; # is an error, not a warning
use constant FLAG_MUTABLE  => 1 << 1; # fatality can be changed
use constant FLAG_REPORTED => 1 << 2; # has already been reported to the user

#
# other constants
#

use constant INSIDE_DESTRUCTION => 1; # value to pass to the report method
use constant WITHOUT_PREFIX => 1;     # value to pass to the format method

#
# object contructor, remember the stack frames, depth is what to skip
#

sub new : method {
    my($class, $depth) = @_;
    my($self, @info, @stack);

    $depth = 0 unless $depth;
    while (@info = caller($depth++)) {
	push(@stack, LC::Exception::StackFrame->new(@info));
    }
    $self = {
	"_s" => \@stack,
    };
    bless($self, $class);
    return($self);
}

#
# object destructor
#

sub DESTROY {
    my($self) = @_;

    return if $self->has_been_reported;
    # oops, unreported exception being destroyed... report it!
    $self->report(INSIDE_DESTRUCTION);
}

#
# field access methods
#

sub stack : method {
    my($self) = @_;

    return($self->{"_s"});
}

sub package : method {
    my($self) = @_;
    my($frame);

    $frame = $self->{"_s"}[0];
    return() unless $frame;
    return($frame->package);
}

sub filename : method {
    my($self) = @_;
    my($frame);

    $frame = $self->{"_s"}[0];
    return() unless $frame;
    return($frame->filename);
}

sub line : method {
    my($self) = @_;
    my($frame);

    $frame = $self->{"_s"}[0];
    return() unless $frame;
    return($frame->line);
}

sub text : method {
    my($self, $text) = @_;

    if (@_ > 1) {
	# always remove trailing spaces when storing
	$text =~ s/\s+$//;
	$self->{"_t"} = $text;
    }
    return($self->{"_t"});
}

sub reason : method {
    my($self, $reason) = @_;

    if (@_ > 1) {
	# always remove trailing spaces when storing (but only for strings)
	if (ref($reason)) {
	    if (UNIVERSAL::isa($reason, "LC::Exception")) {
		# reason is an exception: do nothing
	    } else {
		# reason is a reference but not an exception: we stringify it!
		$reason = "$reason";
	    }
	} else {
	    # reason is a string: strip leading and trailing spaces
	    $reason =~ s/^\s+//;
	    $reason =~ s/\s+$//;
	}
	$self->{"_r"} = $reason;
    }
    return($self->{"_r"});
}

sub flags : method {
    my($self, $flags) = @_;

    $self->{"_f"} = $flags if @_ > 1;
    return($self->{"_f"});
}

sub height : method {
    my($self, $height) = @_;

    $self->{"_h"} = $height if @_ > 1;
    return($self->{"_h"});
}

#
# other methods
#

sub _flags_test : method {
    my($self, $flag) = @_;

    return() unless $self->flags;
    return($self->flags & $flag);
}

sub _flags_set : method {
    my($self, $flag) = @_;

    if ($self->flags) {
	$self->flags($self->flags | $flag);
    } else {
	$self->flags($flag);
    }
}

sub _flags_clear : method {
    my($self, $flag) = @_;

    if ($self->flags) {
	$self->flags($self->flags & ~$flag);
    } else {
	# nothing to do!
    }
}

sub is_error : method {
    my($self, $yes) = @_;

    return($self->_flags_test(FLAG_FATAL)) unless @_ > 1;
    # set it
    if ($yes) {
	$self->_flags_set(FLAG_FATAL);
    } else {
	$self->_flags_clear(FLAG_FATAL);
    }
    return($yes);
}

sub is_warning : method {
    my($self, $yes) = @_;

    return(not $self->_flags_test(FLAG_FATAL)) unless @_ > 1;
    # set it
    if ($yes) {
	$self->_flags_clear(FLAG_FATAL);
    } else {
	$self->_flags_set(FLAG_FATAL);
    }
    return($yes);
}

sub has_been_reported : method {
    my($self, $yes) = @_;
    my($reason);

    return($self->_flags_test(FLAG_REPORTED)) unless @_ > 1;
    # set it
    if ($yes) {
	$self->_flags_set(FLAG_REPORTED);
    } else {
	$self->_flags_clear(FLAG_REPORTED);
    }
    # also set it recursively if reason is an object
    $reason = $self->reason;
    $reason->has_been_reported($yes) if $reason and ref($reason);
    return($yes);
}

sub is_mutable : method {
    my($self, $yes) = @_;

    return($self->_flags_test(FLAG_MUTABLE)) unless @_ > 1;
    # set it
    if ($yes) {
	$self->_flags_set(FLAG_MUTABLE);
    } else {
	$self->_flags_clear(FLAG_MUTABLE);
    }
    return($yes);
}

#+++############################################################################
#                                                                              #
# exception formatting                                                         #
#                                                                              #
#---############################################################################

#
# short formatter (goal is being compact)
#
# *** foo(): bar(1): Permission denied
# 
# *** evaluate(gag): failed
# *** bogus regexp gag
#

sub format_short : method {
    my($self, $noprefix) = @_;
    my($reason, $string, $prefix);

    $string = $self->text;
    $reason = $self->reason;
    if (defined($reason)) {
	$string .= ": ";
	if (ref($reason)) {
	    # reason is an exception
	    $string .= $reason->format_short(WITHOUT_PREFIX);
	} else {
	    # reason is a string
	    $string .= $reason;
	}
    }
    unless ($noprefix) {
	# all lines are prefixed
	$prefix = $self->is_error ? $ErrorPrefix : $WarningPrefix;
	$string =~ s/^/$prefix /mg if length($prefix);
    }
    return($string);
}

#
# long formatter (goal is being complete)
#
# *** foo(): called at foo.pm line 17
# ***  bar(1): Permission denied at Bar.pm line 123
#

sub format_long : method {
    my($self, $noprefix) = @_;
    my($reason, $string, $prefix, $where);

    $string = $self->text;
    $reason = $self->reason;
    $where  = " at " . $self->filename . " line " . $self->line;
    if (defined($reason)) {
	$string .= ": ";
	if (ref($reason)) {
	    # reason is an exception
	    $string .= "called" . $where . "\n ";
	    $string .= $reason->format_long(WITHOUT_PREFIX);
	} else {
	    # reason is a string
	    $string .= $reason . $where;
	}
    } else {
	$string .= $where;
    }
    unless ($noprefix) {
	# all lines are prefixed
	$prefix = $self->is_error ? $ErrorPrefix : $WarningPrefix;
	$string =~ s/^/$prefix /mg if length($prefix);
    }
    return($string);
}

#
# exception format method, it's used to stringify exceptions
#

sub format : method {
    my($self, $noprefix) = @_;

    if ($Formatter) {
	return($Formatter->($self, $noprefix));
    } elsif ($ENV{"LC_FLAGS"} and $ENV{"LC_FLAGS"} =~ /\blongexcept\b/) {
	return($self->format_long($noprefix));
    } else {
	return($self->format_short($noprefix));
    }
}

#+++############################################################################
#                                                                              #
# exception reporting                                                          #
#                                                                              #
#---############################################################################

#
# standard reporter: print on STDERR and exit in case of errors
# (and print the calling stack trace for uncaught exceptions)
#

sub report_standard : method {
    my($self, $uncaught) = @_;
    my($stack, $depth, $frame);

    if ($uncaught) {
	print(STDERR "Uncaught exception!!! Calling stack is:\n");
	$stack = $self->stack;
	$depth = 0;
	while ($frame = $stack->[$depth]) {
	    print(STDERR "\t", $frame->subroutine, " called at ",
		  $frame->filename, " line ", $frame->line, "\n");
	    $depth++;
	}
    }
    print(STDERR $self->format, "\n");
    exit(1) if $self->is_error;
}

#
# exception report method, it's used to report an exception to the user
#

sub report : method {
    my($self, $uncaught) = @_;

    # first set the reported flag
    $self->has_been_reported(1);
    # then report the exception
    if ($Reporter) {
	$Reporter->($self, $uncaught);
    } else {
	$self->report_standard($uncaught);
    }
}

#+++############################################################################
#                                                                              #
# exception throwing                                                           #
#                                                                              #
#---############################################################################

#
# throw an exception object to the proper context, if any
#

sub throw : method {
    my($self) = @_;
    my($ec, $stack, $height, $package);

    # initialisation
    $stack  = $self->stack;
    $height = $self->height;
    # check the height
    if ($height) {
	# already thrown, start one level upper (if not already out of stack)
	$height++ if $stack->[$height];
    } else {
	# not thrown yet, start at height 1
	$height = 1;
    }
    # scan stack for the first active exception context
    if (@$stack == 1 and not $self->height) {
	# special case for toplevel calls
	$ec = LC::Exception::Context::active("main");
    } else {
	# normal case
	while ($stack->[$height]) {
	    $package = $stack->[$height]->package;
	    $ec = LC::Exception::Context::active($package);
	    last if $ec;
	    $height++;
	}
    }
    # remember the height that we've reached this time
    $self->height($height);
    # maybe use the exception context
    return() unless $ec;
    return($ec->handle($self));
}

#
# create and throw an exception (internal)
#

sub _throw_exception ($$$$$) {
    my($depth, $text, $reason, $error, $mutable) = @_;
    my($exception);

    # create an exception object
    $exception = LC::Exception->new($depth);
    $exception->text($text);
    $exception->reason($reason) if defined($reason);
    $exception->is_error($error);
    $exception->is_mutable($mutable);
    # throw it
    return($exception->throw);
}

#
# create and throw an exception (public)
#

sub throw_error ($;$)
    { return(_throw_exception(2, $_[0], $_[1], 1, 0)) }

sub throw_warning ($;$)
    { return(_throw_exception(2, $_[0], $_[1], 0, 0)) }

sub throw_mutable_error ($;$)
    { return(_throw_exception(2, $_[0], $_[1], 1, 1)) }

sub throw_mutable_warning ($;$)
    { return(_throw_exception(2, $_[0], $_[1], 0, 1)) }

sub throw_parent_error ($;$)
    { return(_throw_exception(3, $_[0], $_[1], 1, 0)) }

sub throw_parent_warning ($;$)
    { return(_throw_exception(3, $_[0], $_[1], 0, 0)) }

#+++############################################################################
#                                                                              #
# exception context                                                            #
#                                                                              #
#---############################################################################

package LC::Exception::Context;
use strict;
use warnings;

#
# variables
#

our(
    %_Active,		  # per-package, last activated exception context
    %_PkgSymTab,	  # per-package, reference to the symbol table
    $_EC,		  # global exception context to access the local one
);

#
# function to return a reference to the symbol table of the given package
#

sub _symtab ($);
sub _symtab ($) {
    my($package) = @_;
    my($ref);

    unless (exists($_PkgSymTab{$package})) {
	if ($package =~ /^(.+)::(\w+)$/) {
	    $ref = _symtab($1);
	    $_PkgSymTab{$package} = $ref ? $ref->{$2 . "::"} : undef;
	} elsif ($package =~ /^(\w+)$/) {
	    $_PkgSymTab{$package} = $::{$1 . "::"};
	} else {
	    $_PkgSymTab{$package} = undef;
	}
    }
    return($_PkgSymTab{$package});
}

#
# function to activate in the given package the given exception context
#

sub activate ($$) {
    my($package, $ec) = @_;

    $_Active{$package} = $ec;
}

#
# function to deactivate the last activated exception context in the package
#

sub deactivate ($) {
    my($package) = @_;

    $_Active{$package} = undef;
}

#
# function to check and return the active exception context in the package
#

sub active ($) {
    my($package) = @_;
    my($ref);

    # try to check the local exception context
    $ref = _symtab($package);
    if ($ref and $ref->{__EC__}) {
	*_EC = $ref->{__EC__};
	return($_EC) if $_EC and ref($_EC) and ref($_EC) eq __PACKAGE__;
    }
    # otherwise check the last one activated in this package
    return($_Active{$package});
}

#
# object contructor, optionally taking the package to use
#

sub new : method {
    my($class, $package) = @_;
    my($self);

    # first, make sure we know the package
    $package = caller unless $package;
    # then create and activate the new exception context
    $self = {};
    bless($self, $class);
    activate($package, $self);
    return($self);
}

#
# field access methods
#

sub error : method {
    my($self, $error) = @_;

    $self->{"_e"} = $error if @_ > 1;
    return($self->{"_e"});
}

sub warnings : method {
    my($self, @warnings) = @_;

    $self->{"_w"} = \@warnings if @_ > 1;
    return() unless $self->{"_w"};
    return(@{$self->{"_w"}});
}

sub error_handler : method {
    my($self, $handler) = @_;

    $self->{"_eh"} = $handler if @_ > 1;
    return($self->{"_eh"});
}

sub warning_handler : method {
    my($self, $handler) = @_;

    $self->{"_wh"} = $handler if @_ > 1;
    return($self->{"_wh"});
}

#
# other methods
#

sub clear_error : method {
    my($self) = @_;

    delete($self->{"_e"});
}

sub clear_warnings : method {
    my($self) = @_;

    delete($self->{"_w"});
}

sub add_warning : method {
    my($self, $warning) = @_;

    if ($self->{"_w"}) {
	push(@{$self->{"_w"}}, $warning);
    } else {
	$self->{"_w"} = [ $warning ];
    }
}

#
# standard handlers
#

sub report_exception : method {
    my($self, $exception) = @_;

    $exception->report;
    return();
}

sub store_exception : method {
    my($self, $exception) = @_;

    if ($exception->is_error) {
	$self->error($exception);
    } else {
	$self->add_warning($exception);
    }
    return();
}

#
# methods to manipulate handlers
#

sub will_report_errors : method {
    my($self) = @_;

    $self->error_handler(\&report_exception);
    return($self);
}

sub will_report_warnings : method {
    my($self) = @_;

    $self->warning_handler(\&report_exception);
    return($self);
}

sub will_report_all : method {
    my($self) = @_;

    $self->error_handler(\&report_exception);
    $self->warning_handler(\&report_exception);
    return($self);
}

sub will_store_errors : method {
    my($self) = @_;

    $self->error_handler(\&store_exception);
    return($self);
}

sub will_store_warnings : method {
    my($self) = @_;

    $self->warning_handler(\&store_exception);
    return($self);
}

sub will_store_all : method {
    my($self) = @_;

    $self->error_handler(\&store_exception);
    $self->warning_handler(\&store_exception);
    return($self);
}

#
# clear the error in this context and re-throw it higher
# (we clear it first because the upper context may be us again!)
#

sub rethrow_error : method {
    my($self) = @_;
    my($error);

    $error = $self->error;
    return unless $error;
    $self->clear_error;
    $error->throw;
}

#
# ignore the error caught (i.e. delete and set the reported flag)
#

sub ignore_error : method {
    my($self) = @_;
    my($error);

    $error = $self->error;
    return unless $error;
    $self->clear_error;
    $error->has_been_reported(1);
}

#
# ignore the warnings caught so far (i.e. delete and set the reported flag)
#

sub ignore_warnings : method {
    my($self) = @_;
    my(@warnings, $warning);

    @warnings = $self->warnings;
    return unless @warnings;
    $self->clear_warnings;
    foreach $warning (@warnings) {
	$warning->has_been_reported(1);
    }
}

#
# handle an exception
#

sub handle : method {
    my($self, $exception) = @_;
    my($handler);

    if ($exception->is_error) {
	$handler = $self->error_handler;
    } else {
	$handler = $self->warning_handler;
    }
    # zero handler means don't catch the exceptions at this level
    return($exception->throw) unless $handler;
    # call the user supplied handler
    return($handler->($self, $exception));
}

1;

__END__

=head1 NAME

LC::Exception          - exception manipulation

LC::Exception::Context - exception contexts manipulation

=head1 SYNOPSIS

=head2 caller

    $ec = LC::Exception::Context->new->will_store_errors;
    ...
    foo(@args) or $ec->error->report;

=head2 callee

    use LC::Exception qw(SUCCESS throw_error);
    ...
    unless ($ok) {
	throw_error("rm -fr / failed");
	return();
    }
    return(SUCCESS);

=head1 DESCRIPTION

This package eases exception throwing and catching.

=head2 Exceptions

An exception is an unwanted event occurring somewhere in a program or module.

It contains a text given by the programmer, a file name and line number (in
order to locate it for debugging), a reason explaining it and some flags.

It can either be an error (i.e. fatal, the called routine or program should
normally stop) or a warning (i.e. non fatal, it can normally continue).

The flags contain: the fatal status, whether it's mutable
(i.e. fatality can be changed) and whether it has been reported
already.

The reason is any extra information useful to understand why the
exception occured: C<$!>, C<$@>, another exception...

Exception querying:

	printf "oops at %s line %d\n", $e->filename, $e->line;
	die $e->text if $e->is_error and not $e->has_been_reported;

=head2 Exception Formatting (C<format> method)

Formatting is transforming an exception object into a string.
Note that we use the overload pragma to make it magic, this eases debugging.

This process can be customised by setting the global variable
C<$Formatter> to a function reference doing the job.

In addition to the exception, formatters must take an extra argument
telling whether or not to add a prefix.

The default formatter just concatenates a prefix, the exception text
and reason.

The default prefixes are C<*> for warnings (but this can be changed by
changing the global variable C<$WarningPrefix>) and C<***> for errors
(global variable C<$ErrorPrefix>).

The result is B<not> newline terminated.

=head2 Exception Reporting (C<report> method)

Reporting is showing the formatted exception to the user.

This process can be customised by setting the global variable
C<$Reporter> to a function reference doing the job.

In addition to the exception, reporters must take an argument telling
whether or not the exception was uncaught (see below).

The default reporter prints the formatted exception on C<stderr> and
exits if it's an error.

Exceptions are always reported. If not naturally, they get reported
upon object destruction which can occur in two situations:

=over

=item untrapped exception

Nobody traps the exception so it gets destroyed immediately, usually
with the message "Callback called exit" for errors.

=item unreported stored exception

Nobody reports the stored exception so it gets destroyed either when
the program terminates (usually with the message "Callback called exit
during global destruction" for errors) or when an other exception
replaces the currently stored one (usually with the message "Callback
called exit" for errors).

=back

=head2 Exception Throwing (C<throw> method)

Upon problem, the callee should create and then throw an exception.
This is usually done in one step with the functions C<throw_error> or
C<throw_warning> but the callee could also create its exception by
hand and throw it with the method C<throw>.

Up to the caller to then handle it properly, see the exception
contexts below.

Note: if there is an active exception context that has a custom
handler, the return value of C<throw*> is the return value of this
handler. A true return value is assumed to mean that the exception has
been mutated (i.e. that the handler wants the callee to change the
fatality of the exception and react accordingly). See the advanced
examples below.

Examples:

	throw_error("unlink($path)", $!);

	throw_warning("skipping $foo");

	$e = LC::Exception->new;
	$e->text("whatever");
	$e->reason($another_exception);
	$e->is_error(1);
	$e->is_mutable(1);
	$e->throw;

=head2 Exception Contexts

An exception context is a per-package object that catches exceptions
and knows what to do with them. The exceptions caught are the ones
thrown by routines called from this package (at any depth).

By default, a new exception context does nothing so exceptions get
passed higher in the calling stack. Methods are available to change
this behaviour:

	# store any error caught for further analysis
	$ec->will_store_errors;
	# store any warning caught for further analysis
	$ec->will_store_warnings;
	# store any exception caught for further analysis
	$ec->will_store_all;

	# report any error caught immediately
	$ec->will_report_errors;
	# report any warning caught immediately
	$ec->will_report_warnings;
	# report any exception caught immediately
	$ec->will_report_all;

	# example
	$ec = LC::Exception::Context->new->will_store_all;
	...
	foreach $warning ($ec->warnings) { ... }
	$ec->clear_warnings;

An exception context can call user supplied hooks when an exception is
caught. They can be registered with the C<error_handler> and
C<warning_handler> methods.

=head1 ADVANCED EXAMPLES

=head2 caller filtering exceptions

    use LC::Exception qw(throw_error);
    $ec = LC::Exception::Context->new;
    $ec->error_handler(\&my_handler);
    ...
    unless (foo(@args)) {
	if ($ec->error) {
            # we report this error higher
	    throw_error("foo(@args)", $ec->error);
	    return();
	}
    }
    ...
    sub my_handler {
	my($ec, $e) = @_;
	if ($e->reason =~ /whatever/) {
	    # ignore this error
	    $e->has_been_reported(1);
	    return();
	} elsif ($e->reason =~ /not_so_important/) {
	    # turn this error into a warning and throw it higher
	    $e->is_warning(1);
	    $e->throw;
	    return(1);
	} else {
	    # otherwise store it
	    $ec->error($e);
	    return();
	}
    }

=head2 callee accepting to continue on error

    use LC::Exception qw(throw_error);
    ...
    unless ($ok) {
	$muted = throw_mutable_error("mkdir($dir)", $!);
        # we continue anyway if this error has been muted into a warning
	goto skip_mkdir if $muted;
	# this is indeed an error, we abort the execution
	return();
    }
    return($result);

=head1 NOTES

From the callee point of view, exception throwing is very easy
provided that you follow some rules. First you should return true (or
at least a defined value) on success, either by using the C<SUCCESS>
constant or by returning something useful to the caller. If you return
a list that can be empty, you should return the list reference on
success so that it's easy to detect failures.

If you don't use an exception context that stores errors in your
module, throwing an exception should look like:

    unless ($ok) {
	throw_error("foo(@args)", "bad weather");
	return();
    }

If you do use an exception context that stores errors and the error
has been generated by a routine below, throwing an exception should
look like:

    # simply pass the error higher with no added value
    unless ($ok) {
	$_EC->rethrow_error;
	return();
    }

    # or add some information
    unless ($ok) {
	throw_error("foo(@args)", $_EC->error);
	return();
    }

=head1 ENVIRONMENT

=over

=item LC_FLAGS

If it contains the word C<longexcept>, the exception formatter will be
the long one instead of the short one by default.

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Exception.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=head1 TODO

=over

=item * option/environment to print the stack?

=item * document that one can use $__EC__ locally in a package

=item * document more methods

=item * add an option to avoid the trimming of spaces for the reason field

=back

=cut
