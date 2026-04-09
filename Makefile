.PHONY: lint test test-all check help

help:
	@echo "Available targets:"
	@echo "  make lint    — run shellcheck on all scripts"
	@echo "  make test    — run bats test suite (307 tests)"
	@echo "  make check   — lint + test (run before committing)"

lint:
	@echo "═══ Shellcheck ═══"
	@cd bin && shellcheck -x taskgrind && cd ../lib && shellcheck constants.sh fullpower.sh && echo "✓ All scripts pass shellcheck"

test:
	@echo "═══ Tests ═══"
	@bats tests/taskgrind.bats

test-all: test

check: lint test
