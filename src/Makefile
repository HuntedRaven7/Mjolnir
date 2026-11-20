CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
DESTDIR ?=
PREFIX ?= /usr

all: mjolnir-helper

mjolnir-helper: mjolnir.c
	$(CC) $(CFLAGS) -o $@ $<

install: mjolnir-helper
	install -Dm755 mjolnir-helper "$(DESTDIR)$(PREFIX)/bin/mjolnir-helper"

clean:
	rm -f mjolnir-helper

.PHONY: all install clean
