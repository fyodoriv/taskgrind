.PHONY: lint test test-force check audit help install uninstall

PREFIX ?= /usr/local
TESTS ?= tests/*.bats
AUTO_TEST_JOBS = $(shell jobs=$$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4); expr "$$jobs" + 0 >/dev/null 2>&1 || jobs=4; if [ "$$jobs" -gt 6 ]; then jobs=6; fi; if [ "$$jobs" -lt 2 ]; then jobs=2; fi; echo "$$jobs")
TEST_JOBS ?= $(AUTO_TEST_JOBS)
TEST_CACHE_BASENAME = .test-cache

# Files that affect test outcomes — used for git-based cache
TEST_SHARED_DEPS = bin/taskgrind lib/constants.sh lib/fullpower.sh tests/test_helper.bash
TEST_TARGET_KEY = $(subst /,_,$(subst *,_all_,$(TESTS)))
TEST_CACHE = $(TEST_CACHE_BASENAME)-$(TEST_TARGET_KEY)
RUN_BATS = run_tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/taskgrind-bats.XXXXXX") || exit 1; trap '. ./tests/test_helper.bash; remove_with_retries "$$run_tmp"' EXIT INT TERM; TMPDIR="$$run_tmp" bats --jobs $(TEST_JOBS) $(TESTS)

help:
	@echo "Available targets:"
	@echo "  make audit      — run the local repo audit workflow"
	@echo "  make lint       — run shellcheck on all scripts"
	@echo "  make test       — run tests (cached, skips if unchanged)"
	@echo "                    set TESTS=<glob-or-file> for targeted reruns"
	@echo "                    set TEST_JOBS=<n> to override the auto-capped parallelism ($(AUTO_TEST_JOBS) by default)"
	@echo "  make test-force — run tests (ignore cache)"
	@echo "  make check      — lint + test (run before committing)"
	@echo "  make install    — symlink taskgrind to $(PREFIX)/bin and install man page"
	@echo "  make uninstall  — remove symlink and man page"

lint:
	@echo "═══ Shellcheck ═══"
	@cd bin && shellcheck -x taskgrind
	@shellcheck lib/constants.sh lib/fullpower.sh
	@shellcheck install.sh
	@echo "✓ All scripts pass shellcheck"

test:
	@set -- $(TESTS); \
	_test_deps="$(TEST_SHARED_DEPS) $$*"; \
	_hash=$$(printf '%s\n' "$(TESTS)" "$(TEST_JOBS)"; cat $$_test_deps 2>/dev/null | shasum | cut -d' ' -f1); \
	_hash=$$(printf '%s' "$$_hash" | shasum | cut -d' ' -f1); \
	if [ -f $(TEST_CACHE) ] && [ "$$(cat $(TEST_CACHE) 2>/dev/null)" = "$$_hash" ]; then \
		echo "═══ Tests (cached) ═══"; \
		echo "✓ No changes since last pass — skipping (use 'make test-force' to override)"; \
	else \
		echo "═══ Tests ($(TESTS)) ═══"; \
		$(RUN_BATS) && echo "$$_hash" > $(TEST_CACHE); \
	fi

test-force:
	@echo "═══ Tests ($(TESTS)) ═══"
	@$(RUN_BATS)
	@set -- $(TESTS); \
	{ printf '%s\n' "$(TESTS)" "$(TEST_JOBS)"; cat $(TEST_SHARED_DEPS) $$* 2>/dev/null | shasum | cut -d' ' -f1; } | shasum | cut -d' ' -f1 > $(TEST_CACHE)

check: lint test

audit:
	@echo "═══ Audit: TODO:/FIXME: scan ═══"
	@grep -RInE 'TODO:|FIXME:' bin lib docs README.md CONTRIBUTING.md SECURITY.md AGENTS.md Agentfile.yaml man/taskgrind.1 .devin/skills/standing-audit-gap-loop/SKILL.md .devin/skills/grind-log-analyze/SKILL.md 2>/dev/null || true
	@echo "═══ Audit: shellcheck ═══"
	@$(MAKE) lint
	@echo "═══ Audit: docs review queue ═══"
	@printf '%s\n' README.md CONTRIBUTING.md SECURITY.md AGENTS.md Agentfile.yaml docs/architecture.md docs/resume-state.md docs/user-stories.md man/taskgrind.1 .devin/skills/standing-audit-gap-loop/SKILL.md .devin/skills/grind-log-analyze/SKILL.md

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
