# Makefile — arch-system-recovery
PREFIX     ?= /usr/local
SHELL      := /bin/bash
BIN        := bin/arch-recovery bin/arch-recovery.fish bin/arch-recovery.sh
LIBS       := $(wildcard lib/*.sh)
TESTS      := $(wildcard tests/test_*.sh)
MAN        := man/arch-recovery.1
COMPLETIONS := completions/arch-recovery.bash completions/_arch-recovery \
               completions/arch-recovery.fish

.PHONY: all install uninstall check shellcheck test man clean help

all: check test

## install       — install to PREFIX (default: /usr/local)
install:
	@sudo ./install.sh --prefix "$(PREFIX)"

## uninstall     — remove installed files from PREFIX
uninstall:
	@sudo ./install.sh --prefix "$(PREFIX)" --uninstall

## check         — bash syntax check on all scripts
check:
	@echo "Running syntax checks..."
	@fail=0; \
	for f in $(BIN) $(LIBS) install.sh tests/run_tests.sh tests/helpers.sh $(TESTS); do \
	    bash -n "$$f" && echo "  ✓ $$f" || { echo "  ✗ $$f"; fail=1; }; \
	done; \
	exit $$fail

## shellcheck    — run shellcheck on all bash scripts
shellcheck:
	@if ! command -v shellcheck &>/dev/null; then \
	    echo "shellcheck not found. Install: pacman -S shellcheck"; exit 1; fi
	@shellcheck -S warning -x $(BIN) $(LIBS) install.sh \
	    tests/run_tests.sh tests/helpers.sh $(TESTS)
	@echo "  shellcheck passed."

## test          — run unit test suite
test:
	@bash tests/run_tests.sh

## man           — render manpage to terminal
man:
	@man $(MAN)

## man-html      — generate HTML version of manpage
man-html:
	@command -v groff >/dev/null || { echo "groff not found"; exit 1; }
	@groff -man -Thtml $(MAN) > /tmp/arch-recovery.html
	@echo "Generated: /tmp/arch-recovery.html"

## install-completions — install shell completions only
install-completions:
	@sudo install -d "$(PREFIX)/share/bash-completion/completions"
	@sudo install -d "$(PREFIX)/share/zsh/site-functions"
	@sudo install -d "$(PREFIX)/share/fish/vendor_completions.d"
	@sudo install -m644 completions/arch-recovery.bash \
	    "$(PREFIX)/share/bash-completion/completions/arch-recovery"
	@sudo install -m644 completions/_arch-recovery \
	    "$(PREFIX)/share/zsh/site-functions/_arch-recovery"
	@sudo install -m644 completions/arch-recovery.fish \
	    "$(PREFIX)/share/fish/vendor_completions.d/arch-recovery.fish"
	@echo "Completions installed."

## clean         — remove generated temp files
clean:
	@rm -f /tmp/recovery-toolkit.log /tmp/arch-recovery*.log
	@rm -f /tmp/arch-recovery.html
	@rm -f /tmp/arch-recovery-install-patched
	@echo "Cleaned."

## help          — show available targets
help:
	@grep -E '^## ' Makefile | sed 's/## /  make /'
