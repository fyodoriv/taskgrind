.PHONY: lint test test-all check

lint:
	@echo "═══ Shellcheck ═══"
	@shellcheck bin/taskgrind lib/constants.sh lib/fullpower.sh && echo "✓ All scripts pass shellcheck"

test:
	@echo "═══ Tests ═══"
	@bats tests/taskgrind.bats

test-all: test

check: lint test
