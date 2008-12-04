COMP=perl-LC
NAME=$(COMP)
DESCR=LC Perl Modules
VERSION=1.1.3
RELEASE=1
AUTHOR=Lionel Cons <Lionel.Cons@cern.ch>
MAINTAINER=German Cancio <German.Cancio@cern.ch>,Marco Emilio Poleggi <Marco.Poleggi@cern.ch>

ifeq ($(QTTR_OS),Linux)
QTTR_PERLLIB=/usr/lib/perl5/site_perl
ifeq ($(_rpmver),4.2.3)
PROVIDES=Provides: edg-perl-LC
endif
endif

MANSECT=3

MAN3DIR=$(QTTR_MAN)/man$(MANSECT)

DATE=14/10/08 15:58
