#
# $Id: specfile.spec,v 1.7 2008/06/30 15:27:48 poleggi Exp $
#
# taken from Lionel Cons, modified prefix (for EDG compatibility)
#
#
Name: @NAME@
Version: @VERSION@
Release: @RELEASE@
Summary: @DESCR@
License: GPL
Packager: @AUTHOR@
Group: System Environment/Libraries
Url: http://cern.ch/lionel.cons/perl
BuildArch: noarch
BuildRoot: /var/tmp/%{name}-build
Source: @TARFILE@
@PROVIDES@
#Provides: edg-perl-LC = @VERSION@
Obsoletes: edg-perl-LC

%description
Lionel Cons' collection of Perl modules for various purposes. All
modules are home-grown and use a consistent exception handling
mechanism.

EDG release version for quattor system management toolsuite

%prep
%setup

%build
make

%install
rm -rf $RPM_BUILD_ROOT
make PREFIX=$RPM_BUILD_ROOT install

%clean
rm -rf $RPM_BUILD_ROOT

#
# list only the ones needed for EDG usage
#
%files
%defattr(-,root,root)
@QTTR_PERLLIB@/LC/Cached.pm
@QTTR_PERLLIB@/LC/Check.pm
@QTTR_PERLLIB@/LC/Exception.pm
@QTTR_PERLLIB@/LC/Fatal.pm
@QTTR_PERLLIB@/LC/File.pm
@QTTR_PERLLIB@/LC/Find.pm
@QTTR_PERLLIB@/LC/ISO88591.pm
@QTTR_PERLLIB@/LC/Option.pm
@QTTR_PERLLIB@/LC/Process.pm
@QTTR_PERLLIB@/LC/Secure.pm
@QTTR_PERLLIB@/LC/Spool.pm
@QTTR_PERLLIB@/LC/Stat.pm
@QTTR_PERLLIB@/LC/Sysinfo.pm
@QTTR_PERLLIB@/LC/Syslog.pm
@QTTR_PERLLIB@/LC/Util.pm

@QTTR_MAN@/man3/LC::Cached.3pm.gz
@QTTR_MAN@/man3/LC::Check.3pm.gz
@QTTR_MAN@/man3/LC::Exception.3pm.gz
@QTTR_MAN@/man3/LC::Fatal.3pm.gz
@QTTR_MAN@/man3/LC::File.3pm.gz
@QTTR_MAN@/man3/LC::Find.3pm.gz
@QTTR_MAN@/man3/LC::ISO88591.3pm.gz
@QTTR_MAN@/man3/LC::Option.3pm.gz
@QTTR_MAN@/man3/LC::Process.3pm.gz
@QTTR_MAN@/man3/LC::Secure.3pm.gz
@QTTR_MAN@/man3/LC::Spool.3pm.gz
@QTTR_MAN@/man3/LC::Stat.3pm.gz
@QTTR_MAN@/man3/LC::Sysinfo.3pm.gz
@QTTR_MAN@/man3/LC::Syslog.3pm.gz
@QTTR_MAN@/man3/LC::Util.3pm.gz
