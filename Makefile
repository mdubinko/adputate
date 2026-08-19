SHELL := /bin/bash
PREFIX ?= /usr/local
DESTDIR ?=
CC ?= cc
CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=
BUILD_DIR ?= build
DNS_PROXY := $(BUILD_DIR)/adputate-dns-proxy
BUNDLE_DIR := $(DESTDIR)$(PREFIX)/libexec/adputate

.PHONY: all build check test install uninstall clean

all: build

build: $(DNS_PROXY)

$(DNS_PROXY): packaging/router/adputate-dns-proxy.c
	mkdir -p "$(BUILD_DIR)"
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wall -Wextra -Werror -pthread $< $(LDFLAGS) -o $@

check:
	bash -n bin/adputate
	bash -n libexec/adputate.sh
	bash -n packaging/router/adputate-router
	bash -n packaging/router/adputate-router.sh

test: check build
	tests/test_cli.sh

install: check build
	install -d "$(DESTDIR)$(PREFIX)/bin" \
	  "$(BUNDLE_DIR)/packaging/router" \
	  "$(BUNDLE_DIR)/packaging/launchd" \
	  "$(BUNDLE_DIR)/containers" \
	  "$(BUNDLE_DIR)/build"
	install -m 755 bin/adputate "$(DESTDIR)$(PREFIX)/bin/adputate"
	install -m 755 libexec/adputate.sh "$(BUNDLE_DIR)/adputate.sh"
	install -m 755 packaging/router/adputate-router "$(BUNDLE_DIR)/packaging/router/adputate-router"
	install -m 755 packaging/router/adputate-router.sh "$(BUNDLE_DIR)/packaging/router/adputate-router.sh"
	install -m 644 packaging/router/adputate-dns-proxy.c "$(BUNDLE_DIR)/packaging/router/adputate-dns-proxy.c"
	install -m 755 "$(DNS_PROXY)" "$(BUNDLE_DIR)/build/adputate-dns-proxy"
	cp -R packaging/launchd/. "$(BUNDLE_DIR)/packaging/launchd/"
	cp -R containers/. "$(BUNDLE_DIR)/containers/"
	install -m 644 project.env VERSION LICENSE "$(BUNDLE_DIR)/"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/adputate"
	rm -rf "$(BUNDLE_DIR)"

clean:
	rm -f "$(DNS_PROXY)"
