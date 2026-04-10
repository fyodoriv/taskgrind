.PHONY: lint test check help

help:
	@echo "Available targets:"
	@echo "  make lint    — run shellcheck on all scripts"
	@echo "  make test    — run bats test suite (357 tests)"
	@echo "  make check   — lint + test (run before committing)"

lint:
	@echo "═══ Shellcheck ═══"
	@cd bin && shellcheck -x taskgrind
	@shellcheck lib/constants.sh lib/fullpower.sh
	@shellcheck install.sh
	@echo "✓ All scripts pass shellcheck"

test:
	@echo "═══ Tests ═══"
	@bats tests/taskgrind.bats

check: lint test
