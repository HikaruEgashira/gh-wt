# Shell-only project Makefile.
#
#   make all / make lint  → bash -n + shellcheck

UNAME_S := $(shell uname -s)

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

help:
	@echo "Targets:"
	@echo "  all / lint — bash -n + shellcheck on shell sources"
