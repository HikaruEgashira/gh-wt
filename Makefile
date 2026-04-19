# Top-level Makefile — dispatches to the right per-platform build.
#
#   make all    → Linux: shell syntax + shellcheck (mirrors CI shell-lint).
#                 macOS: delegates to macos/Makefile `all` (helper + bundle).
#   make lint   → shell syntax + shellcheck (both platforms).
#   make test   → Linux: parity suite (needs root + OverlayFS).
#                 macOS: OverlayCoreTests via `swift test`.
#
# The macOS bundle targets (helper / extension / app / sign / install) live
# in macos/Makefile; run them with `$(MAKE) -C macos <target>` or cd in.

UNAME_S := $(shell uname -s)

SHELL_SCRIPTS := gh-wt $(wildcard lib/*.sh) tests/parity/run.sh
CASE_SCRIPTS  := $(wildcard tests/parity/cases/*.sh)

.PHONY: all lint syntax shellcheck test clean help

ifeq ($(UNAME_S),Darwin)
all:
	$(MAKE) -C macos all
else
all: lint
endif

lint: syntax shellcheck

syntax:
	@set -e; for f in $(SHELL_SCRIPTS) $(CASE_SCRIPTS); do bash -n "$$f"; done
	@echo "bash -n: OK"

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck -S warning $(SHELL_SCRIPTS); \
	    shellcheck -S warning --shell=bash $(CASE_SCRIPTS); \
	    echo "shellcheck: OK"; \
	else \
	    echo "shellcheck: not installed, skipping"; \
	fi

ifeq ($(UNAME_S),Darwin)
test:
	$(MAKE) -C macos test
else
test:
	sudo ./tests/parity/run.sh
endif

clean:
ifeq ($(UNAME_S),Darwin)
	$(MAKE) -C macos clean
endif

help:
	@echo "Targets:"
	@echo "  all        — platform-appropriate default build / check"
	@echo "  lint       — bash -n + shellcheck on shell sources"
	@echo "  test       — Linux: parity suite; macOS: swift test"
	@echo "  clean      — remove macOS build artefacts"
