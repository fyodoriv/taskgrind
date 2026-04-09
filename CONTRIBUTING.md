# Contributing to Taskgrind

## Quick Start

```bash
git clone https://github.com/cbrwizard/taskgrind.git
cd taskgrind
make check   # runs shellcheck + bats test suite
```

Requires [bats-core](https://github.com/bats-core/bats-core) and [shellcheck](https://www.shellcheck.net/):

```bash
# macOS
brew install bats-core shellcheck
```

## Adding a Feature

1. **Write a failing test first** — add tests to `tests/taskgrind.bats`
2. **Implement the feature** — edit `bin/taskgrind` (or `lib/*.sh` for shared code)
3. **Run `make check`** — shellcheck + all bats tests must pass
4. **Commit on `main`** — this repo uses trunk-based development for small changes

All tests use a fake devin stub via `DVB_GRIND_CMD` — they never invoke real AI backends.

## Commit Format

Use [conventional commits](https://www.conventionalcommits.org/):

```
feat: add --backend flag for multi-backend support
fix: prevent orphaned sleep processes on SIGTERM
docs: update README features section
test: add tests for --version flag
chore: update test count in AGENTS.md
```

## Env Var Naming

All environment variables use the `DVB_` prefix for backward compatibility with the original `dvb-grind` name. Do **not** rename existing vars to `TG_` — the `DVB_` prefix works and changing it would break existing users.

When adding a new env var:
- Prefix with `DVB_`
- Add validation (numeric check, allowed values, etc.)
- Document in `--help` header comment, README, and AGENTS.md
- Add tests for both valid and invalid values

## Test Conventions

- Tests live in `tests/taskgrind.bats` with helpers in `tests/test_helper.bash`
- Each test gets a fresh `$TEST_DIR` via `setup()` — no shared state between tests
- Use `DVB_DEADLINE` to control loop duration (set a few seconds in the future)
- Use `DVB_GRIND_CMD` to point at a stub script (never the real binary)
- Structural tests (`grep -q` on the script) are fine for verifying code patterns

## Known Issues

- **Flaky tests** — a handful of timing-dependent tests (network recovery, branch cleanup) may fail intermittently on slow CI. These are pre-existing and not regressions.

## Project Structure

```
bin/taskgrind           Main script (the whole tool)
lib/constants.sh        Shared constants (model, binary path, caffeinate flags)
lib/fullpower.sh        Priority boosting (taskpolicy on macOS)
tests/taskgrind.bats    Test suite
tests/test_helper.bash  Shared test helpers
Makefile                lint + test targets
```
