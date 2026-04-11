.PHONY: lint test check help install uninstall

PREFIX ?= /usr/local

help:
	@echo "Available targets:"
	@echo "  make lint      — run shellcheck on all scripts"
	@echo "  make test      — run bats test suite (401 tests, parallel)"
	@echo "  make check     — lint + test (run before committing)"
	@echo "  make install   — symlink taskgrind to $(PREFIX)/bin and install man page"
	@echo "  make uninstall — remove symlink and man page"

lint:
	@echo "═══ Shellcheck ═══"
	@cd bin && shellcheck -x taskgrind
	@shellcheck lib/constants.sh lib/fullpower.sh
	@shellcheck install.sh
	@echo "✓ All scripts pass shellcheck"

test:
	@echo "═══ Tests (parallel) ═══"
	@bats --jobs 9 tests/*.bats

check: lint test

install:
	@echo "Installing taskgrind to $(PREFIX)..."
	@mkdir -p "$(PREFIX)/bin"
	@ln -sf "$(CURDIR)/bin/taskgrind" "$(PREFIX)/bin/taskgrind"
	@mkdir -p "$(PREFIX)/share/man/man1"
	@cp man/taskgrind.1 "$(PREFIX)/share/man/man1/taskgrind.1"
	@echo "✓ taskgrind installed"
	@echo "  binary:   $(PREFIX)/bin/taskgrind → $(CURDIR)/bin/taskgrind"
	@echo "  man page: $(PREFIX)/share/man/man1/taskgrind.1"

uninstall:
	@echo "Uninstalling taskgrind from $(PREFIX)..."
	@rm -f "$(PREFIX)/bin/taskgrind"
	@rm -f "$(PREFIX)/share/man/man1/taskgrind.1"
	@echo "✓ taskgrind uninstalled"
