####################################################################
# Distribution Makefile
####################################################################

.PHONY: configure install clean

all: configure man
#
# BTDIR needs to point to the location of the build tools
#
BTDIR := ../quattor-build-tools
#
#
_btincl   := $(shell ls $(BTDIR)/quattor-buildtools.mk 2>/dev/null || \
             echo quattor-buildtools.mk)
include $(_btincl)

####################################################################
# Configure
####################################################################


NAMES =  Cached Check Exception Fatal File Find ISO88591 Option \
	Process Secure Spool Stat Sysinfo Syslog Util

SOURCES = $(addsuffix .pm,${NAMES})

MANUALS = ${foreach f,${NAMES},doc/man3/${f}.3pm }

LC    = $(addprefix LC/,${SOURCES})

configure: $(LC)

man:	docdir configure ${MANUALS}

doc/man3/%.3pm: LC/%.pm
	rm -f $@
	pod2man $(_podopt) $< > $@
	gzip -f $@

docdir:
	mkdir -p doc/man3

install: configure install_source install_doc

install_source: 
	mkdir -p $(PREFIX)/$(QTTR_PERLLIB)/LC
	cp ${LC} $(PREFIX)/$(QTTR_PERLLIB)/LC

install_doc:
	mkdir -p $(PREFIX)/$(QTTR_MAN)/man3
	${foreach f,${NAMES},cp doc/man3/${f}.3pm.gz $(PREFIX)/$(QTTR_MAN)/man3/LC::${f}.3pm.gz;}

clean::
	@echo cleaning $(NAME) files ...
	@rm -f $(COMP) $(COMP).pod



