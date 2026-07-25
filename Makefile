# Build and validate Tweaks for CachyOS.
SHELL := /usr/bin/bash
GO ?= go
CC ?= cc
SHELLCHECK ?= shellcheck
MODULE_SOURCES := $(shell find modules -type f -name '*.sh' -print | sort)
SCRIPT_SOURCES := $(shell find scripts -type f -name '*.sh' -print | sort)
PACKAGING_SOURCES := $(shell find packaging -type f -print | sort)

.PHONY: all build test lint package-metadata check fmt clean

all: build

build:
	install -d build
	cd tui && CGO_ENABLED=0 $(GO) build -trimpath -ldflags='-s -w' -o ../build/tweaks-tui .
	@echo built: build/tweaks-tui

test:
	cd tui && $(GO) test ./...
	@for test in tests/*_test.sh; do bash "$$test" || exit; done

lint:
	bash -n PKGBUILD tweaks.sh lib/*.sh $(MODULE_SOURCES) $(PACKAGING_SOURCES) $(SCRIPT_SOURCES) tests/*.sh
	$(SHELLCHECK) -S warning -x tweaks.sh lib/*.sh $(MODULE_SOURCES) $(PACKAGING_SOURCES) $(SCRIPT_SOURCES) tests/*.sh
	$(CC) -std=c17 -Wall -Wextra -Wpedantic -Werror -fsyntax-only pam-auth-test.c
	cd tui && $(GO) vet ./...
	@test -z "$$(gofmt -l tui/*.go)" || { echo 'Go files need gofmt:'; gofmt -l tui/*.go; exit 1; }

package-metadata:
	@if ! command -v makepkg >/dev/null; then \
		echo 'makepkg unavailable; skipping Arch package metadata check'; \
		exit 0; \
	fi; \
	metadata=$$(mktemp); \
	trap 'rm -f -- "$$metadata"' EXIT; \
	BUILDDIR=$${TMPDIR:-/tmp} \
	PKGDEST=$${TMPDIR:-/tmp} \
	SRCDEST=$${TMPDIR:-/tmp} \
	SRCPKGDEST=$${TMPDIR:-/tmp} \
	LOGDEST=$${TMPDIR:-/tmp} \
		makepkg --printsrcinfo >"$$metadata"; \
	diff -u .SRCINFO "$$metadata"

check: lint package-metadata test build

fmt:
	gofmt -w tui/*.go

clean:
	rm -rf build
