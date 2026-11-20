CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
LDLIBS ?= -ljson-c -lsystemd
DESTDIR ?=
PREFIX ?= /usr

all: mjolnir-fleet

mjolnir-fleet: fleet.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

install: mjolnir-fleet
	install -Dm755 mjolnir-fleet "$(DESTDIR)$(PREFIX)/bin/mjolnir-fleet"

clean:
	rm -f mjolnir-fleet

.PHONY: all install clean
