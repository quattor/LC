#+##############################################################################
#                                                                              #
# File: Syslog.pm                                                              #
#                                                                              #
# Description: simplistic interface to syslog                                  #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Syslog;
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
@EXPORT_OK = qw(syslog);
%EXPORT_TAGS = (
    "LOG" => [ map("LOG_$_", qw(
        EMERG ALERT CRIT ERR WARNING NOTICE INFO DEBUG
	KERN USER MAIL DAEMON AUTH SYSLOG LPR NEWS UUCP CRON AUTHPRIV FTP
	LOCAL0 LOCAL1 LOCAL2 LOCAL3 LOCAL4 LOCAL5 LOCAL6 LOCAL7
    )) ],
);
Exporter::export_tags();

#
# used modules
#

use LC::Exception qw(throw_error SUCCESS);
use Socket qw(inet_aton sockaddr_in sockaddr_un
	      AF_INET AF_UNIX SOCK_STREAM SOCK_DGRAM);

#
# private variables
#

our(
    $_EC,    # module's exception context
);

$_EC = LC::Exception::Context->new->will_store_errors;

#+++############################################################################
#                                                                              #
# syslog constants from <syslog.h>                                             #
#                                                                              #
#---############################################################################

#
# syslogd's named pipe or UNIX-domain socket
#

use constant PATH_LOG => "/dev/log";

#
# priorities
#

use constant LOG_EMERG   => 0;	# system is unusable
use constant LOG_ALERT   => 1;	# action must be taken immediately
use constant LOG_CRIT    => 2;	# critical conditions
use constant LOG_ERR     => 3;	# error conditions
use constant LOG_WARNING => 4;	# warning conditions
use constant LOG_NOTICE  => 5;	# normal but significant condition
use constant LOG_INFO    => 6;	# informational
use constant LOG_DEBUG   => 7;	# debug-level messages

#
# facilities
#

use constant LOG_KERN     =>  0<<3; # kernel messages
use constant LOG_USER     =>  1<<3; # random user-level messages
use constant LOG_MAIL     =>  2<<3; # mail system
use constant LOG_DAEMON   =>  3<<3; # system daemons
use constant LOG_AUTH     =>  4<<3; # security/authorization messages
use constant LOG_SYSLOG   =>  5<<3; # messages generated internally by syslogd
use constant LOG_LPR      =>  6<<3; # line printer subsystem
use constant LOG_NEWS     =>  7<<3; # network news subsystem
use constant LOG_UUCP     =>  8<<3; # UUCP subsystem
use constant LOG_CRON     =>  9<<3; # clock daemon
use constant LOG_AUTHPRIV => 10<<3; # security/authorization messages (private)
use constant LOG_FTP      => 11<<3; # ftp daemon
use constant LOG_LOCAL0   => 16<<3; # reserved for local use
use constant LOG_LOCAL1   => 17<<3; # reserved for local use
use constant LOG_LOCAL2   => 18<<3; # reserved for local use
use constant LOG_LOCAL3   => 19<<3; # reserved for local use
use constant LOG_LOCAL4   => 20<<3; # reserved for local use
use constant LOG_LOCAL5   => 21<<3; # reserved for local use
use constant LOG_LOCAL6   => 22<<3; # reserved for local use
use constant LOG_LOCAL7   => 23<<3; # reserved for local use

#+++############################################################################
#                                                                              #
# syslogd connection methods                                                   #
#                                                                              #
#---############################################################################

#
# send data to the given host using UDP
#

sub _udp_syslog ($$) {
    my($host, $data) = @_;
    my($addr, $proto, $port);
    local(*SOCKET);

    unless ($addr = inet_aton($host)) {
	throw_error("unknown host", $host);
	return();
    }
    unless ($proto = getprotobyname("udp")) {
	throw_error("unknown protocol", "udp");
	return();
    }
    unless ($port = getservbyname("syslog", "udp")) {
	throw_error("unknown service", "syslog/udp");
	return();
    }
    unless (socket(SOCKET, AF_INET, SOCK_DGRAM, $proto)) {
	throw_error("socket(udp)", $!);
	return();
    }
    unless (connect(SOCKET, sockaddr_in($port, $addr))) {
	throw_error("connect($host:$port)", $!);
	return();
    }
    unless (send(SOCKET, $data, 0)) {
	throw_error("send", $!);
	return();
    }
    unless (close(SOCKET)) {
	throw_error("close", $!);
	return();
    }
    return(SUCCESS);
}

#
# send data to the local syslogd using a named pipe
#

sub _pipe_syslog ($$) {
    my($path, $data) = @_;
    local(*PIPE);

    unless (open(PIPE, ">$path")) {
	throw_error("open", $!);
	return();
    }
    unless (print(PIPE $data)) {
	throw_error("print", $!);
	return();
    }
    unless (close(PIPE)) {
	throw_error("close", $!);
	return();
    }
    return(SUCCESS);
}

#
# send data to the local syslogd using a UNIX-domain socket
#

sub _unix_syslog ($$) {
    my($path, $data) = @_;
    my($addr);
    local(*SOCKET);

    unless ($addr = sockaddr_un($path)) {
	throw_error("sockaddr_un", $!);
	return();
    }
    unless (socket(SOCKET, AF_UNIX, SOCK_STREAM, 0)) {
	throw_error("socket(stream)", $!);
	return();
    }
    unless (connect(SOCKET, $addr)) {
	# try again with SOCK_DGRAM
	unless (socket(SOCKET, AF_UNIX, SOCK_DGRAM, 0)) {
	    throw_error("socket(dgram)", $!);
	    return();
	}
	unless (connect(SOCKET, $addr)) {
	    throw_error("connect", $!);
	    return();
	}
    }
    unless (send(SOCKET, $data, 0)) {
	throw_error("send", $!);
	return();
    }
    unless (close(SOCKET)) {
	throw_error("close", $!);
	return();
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# very simple syslog                                                           #
#                                                                              #
#---############################################################################

#
# decode and check the given message type in the form err,auth
#

sub _decode_type ($) {
    my($type) = @_;
    my(@type);

    @type = split(/\W+/, $type);
    unless (@type == 2) {
	throw_error("invalid type", $type);
	return();
    }
    @type = map("LOG_\U$_", @type);
    unless (defined(&{$type[0]})) {
	throw_error("unknown type", $type[0]);
	return();
    }
    unless (defined(&{$type[1]})) {
	throw_error("unknown type", $type[1]);
	return();
    }
    # be less strict while converting to a numeric type
    no strict "refs";
    return($type[0]->() | $type[1]->());
}

#
# send the typed syslog message to the given host (local host if undef)
# type is either numeric (used as is) or a human readable string like err,auth
#

sub syslog ($$$) {
    my($host, $type, $message) = @_;
    my(@type, $data);

    # check type
    unless ($type =~ /^\d+$/) {
	# type given as text, translate it
	unless ($type = _decode_type($type)) {
	    $_EC->rethrow_error;
	    return();
	}
    }
    # build the message, what a simple protocol ;-)
    $data = "<$type>$message\0";
    if (defined($host)) {
	# always use UDP for remote logging
	unless (_udp_syslog($host, $data)) {
	    throw_error("udp_syslog($host)", $_EC->error);
	    return();
	}
    } elsif (-e PATH_LOG and -w _ and (-p _ or -S _)) {
	# try to use local IPC if possible
	if (-p _) {
	    unless (_pipe_syslog(PATH_LOG, $data)) {
		throw_error("pipe_syslog(" . PATH_LOG . ")", $_EC->error);
		return();
	    }
	} else {
	    unless (_unix_syslog(PATH_LOG, $data)) {
		throw_error("unix_syslog(" . PATH_LOG . ")", $_EC->error);
		return();
	    }
	}
    } else {
	# otherwise fall back to UDP
	unless (_udp_syslog("localhost", $data)) {
	    throw_error("udp_syslog(localhost)", $_EC->error);
	    return();
	}
    }
    return(SUCCESS);
}

#+++############################################################################
#                                                                              #
# test bed                                                                     #
#                                                                              #
#---############################################################################

unless (defined(caller)) {
    my($usage, $host, $type);
    $usage = "Usage: $0 host type message\n";
    die $usage unless @ARGV > 2;
    $host = shift(@ARGV);
    $type = shift(@ARGV);
    $host = undef if $host eq "localhost";
    syslog($host, $type, "@ARGV") or $_EC->error->report;
}

1;

__END__

=head1 NAME

LC::Syslog - simplistic interface to syslog

=head1 SYNOPSIS

    use LC::Syslog qw(syslog);
    syslog($host, "err,auth", "bad root login");

    use LC::Syslog qw(syslog :LOG);
    syslog(undef, LOG_INFO|LOG_CRON, "cron started");

=head1 DESCRIPTION

Very simplified interface to C<syslog>: a single function is used to
report something.

The module finds the best transport mechanism to reach the syslog
daemon: pipe, udp...

=over

=item syslog(HOST, TYPE, TEXT)

Send a syslog message of type TYPE and text TEXT to the syslog daemon
running on HOST. HOST can be C<undef> (meaning the local host) or any
host name or IP address. TYPE can be the nummeric type made of LOG_*
constants or the equivalent text string.

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Syslog.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=head1 TODO

=over

=item * check that the given type is really a facility + a priority

=item * enforce the common "prog:" prefix to please syslog parsers?

=item * implement some openlog() options?

=item * is PATH_LOG system specific?

=back

=cut
