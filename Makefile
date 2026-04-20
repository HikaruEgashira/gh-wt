# Shell-only project Makefile.
#
#   make all / make lint  → bash -n + shellcheck
#   make test             → Linux: parity suite (needs root + OverlayFS)
#                           macOS: parity suite not applicable (OverlayFS-specific)

UNAME_S := $(shell uname -s)

SHELL_SCRIPTS := gh-wt $(wildcard lib/*.sh) tests/parity/run.sh
CASE_SCRIPTS  := $(wildcard tests/parity/cases/*.sh)

.PHONY: all lint syntax shellcheck test help

all: lint

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

ifeq ($(UNAME_S),Linux)
test:
	sudo ./tests/parity/run.sh
else
test:
	@echo "parity suite is OverlayFS-specific; run on Linux"
endif

help:
	@echo "Targets:"
	@echo "  all / lint — bash -n + shellcheck on shell sources"
	@echo "  test       — Linux: parity suite"
