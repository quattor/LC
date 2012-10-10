# -*- mode: cperl -*-
# ${license-info}
# ${author-info}
# ${build-info}

=pod

=head1 Smoke test

Basic test that ensures that our module will load correctly.

B<Do not disable this test>. And do not push anything to SF without
having run, at least, this test.

=cut

use strict;
use warnings;
use Test::More;
use Readonly;


Readonly::Array my @MODULES => qw( LC::Fatal LC::Check
				   LC::Spool
				   LC::Sysinfo
				   LC::Util
				   LC::Stat
				   LC::Syslog
				   LC::Option
				   LC::Process
				   LC::Cached
				   LC::Exception
				   LC::Secure
				   LC::File
				   LC::Find
				   LC::ISO88591
				);

plan tests => scalar(@MODULES);

foreach my $mod (@MODULES) {
    use_ok($mod);
}
