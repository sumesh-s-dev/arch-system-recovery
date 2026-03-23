# Makefile — arch-system-recovery
PREFIX     ?= /usr/local
SHELL      := /bin/bash
BASH_BIN   := bin/arch-recovery bin/arch-recovery.sh
FISH_BIN   := bin/arch-recovery.fish
LIBS       := $(wildcard lib/*.sh)
TESTS      := $(wildcard tests/test_*.sh)
INTEGRATION_TESTS := $(wildcard tests/integration/*.sh)
MAN        := man/arch-recovery.1
COMPLETIONS := completions/arch-recovery.bash completions/_arch-recovery \
               completions/arch-recovery.fish
SIGNERS     := keys/release_signers.allowed

.PHONY: all install uninstall check shellcheck test integration-test man clean help dist release-manifest

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
	for f in $(BASH_BIN) $(LIBS) install.sh tests/run_tests.sh tests/helpers.sh $(TESTS) $(INTEGRATION_TESTS); do \
	    bash -n "$$f" && echo "  ✓ $$f" || { echo "  ✗ $$f"; fail=1; }; \
	done; \
	if command -v fish >/dev/null 2>&1; then \
	    for f in $(FISH_BIN); do \
	        fish -n "$$f" && echo "  ✓ $$f" || { echo "  ✗ $$f"; fail=1; }; \
	    done; \
	else \
	    echo "  ! fish not found; skipping fish syntax check ($(FISH_BIN))"; \
	fi; \
	exit $$fail

## shellcheck    — run shellcheck on all bash scripts
shellcheck:
	@if ! command -v shellcheck &>/dev/null; then \
	    echo "⚠  shellcheck not found (install: apt-get install shellcheck or pacman -S shellcheck)"; exit 0; fi
	@shellcheck -S warning -x $(BASH_BIN) $(LIBS) install.sh \
	    tests/run_tests.sh tests/helpers.sh $(TESTS) $(INTEGRATION_TESTS) || true
	@echo "  shellcheck completed."

## test          — run unit test suite
test:
	@bash tests/run_tests.sh

## integration-test — run privileged loopback integration tests
integration-test:
	@bash tests/integration/test_loopback.sh

## dist          — build verified release bundle in dist/
dist:
	@command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum not found"; exit 1; }
	@version="$$(bash bin/arch-recovery --version | awk '{print $$2}')"; \
	tag="v$${version}"; \
	archive="arch-system-recovery-$${tag}.tar.gz"; \
	root_dir="arch-system-recovery-$${version}"; \
	mkdir -p dist; \
	rm -f "dist/$${archive}" "dist/$${archive}.sha256"; \
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	    git ls-files | tar -czf "dist/$${archive}" --transform "s,^,$${root_dir}/," -T -; \
	else \
	    tar --exclude='./.git' --exclude='./dist' --exclude='./.github' \
	        -czf "dist/$${archive}" --transform "s,^\.,$${root_dir}," .; \
	fi; \
	( cd dist && sha256sum "$${archive}" > "$${archive}.sha256" ); \
		echo "Built dist/$${archive}"; \
		echo "Built dist/$${archive}.sha256"

## release-manifest — generate signed release manifest for the current version
release-manifest: dist
	@command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen not found"; exit 1; }
	@command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum not found"; exit 1; }
	@version="$$(bash bin/arch-recovery --version | awk '{print $$2}')"; \
		tag="v$${version}"; \
		archive="dist/arch-system-recovery-$${tag}.tar.gz"; \
		archive_name="$$(basename "$${archive}")"; \
		manifest="docs/releases/$${tag}.manifest"; \
		signing_key="$${SIGNING_KEY:-$$HOME/.ssh/id_ed25519}"; \
		principal="$${RELEASE_SIGNER_PRINCIPAL:-$$(awk 'NF >= 2 {print $$1; exit}' $(SIGNERS))}"; \
		[ -f "$${archive}" ] || { echo "Missing archive: $${archive}"; exit 1; }; \
		[ -f "$(SIGNERS)" ] || { echo "Missing signers file: $(SIGNERS)"; exit 1; }; \
		( cd dist && sha256sum "$${archive_name}" ) > "$${manifest}"; \
		rm -f "$${manifest}.sig"; \
		ssh-keygen -Y sign -f "$${signing_key}" -n arch-recovery -I "$${principal}" "$${manifest}" >/dev/null; \
		ssh-keygen -Y verify -f "$(SIGNERS)" -I "$${principal}" -n arch-recovery -s "$${manifest}.sig" < "$${manifest}" >/dev/null; \
		echo "Built $${manifest}"; \
		echo "Built $${manifest}.sig"

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
