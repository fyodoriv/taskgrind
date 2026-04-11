# Contributing to Taskgrind

## Quick Start

```bash
git clone https://github.com/cbrwizard/taskgrind.git
cd taskgrind
make check   # runs shellcheck + bats test suite
make install # symlink to /usr/local/bin + install man page
```

Requires [bats-core](https://github.com/bats-core/bats-core) and [shellcheck](https://www.shellcheck.net/):

```bash
# macOS
brew install bats-core shellcheck

# Ubuntu / Debian
sudo apt-get update
sudo apt-get install -y bats shellcheck

# Fedora / RHEL
sudo dnf install -y bats ShellCheck
```

## Adding a Feature

1. **Write a failing test first** — add coverage in the focused `.bats` file that matches the behavior under test (`tests/network.bats`, `tests/session.bats`, `tests/logging.bats`, etc.)
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

User-facing documentation and error messages use the `TG_` prefix (canonical). Internally, the script uses `DVB_` variable names for backward compatibility with the original `dvb-grind`. The `TG_` → `DVB_` mapping happens automatically at startup, so both prefixes work for users.

When adding a new env var:
- Use `DVB_` as the internal variable name in the script
- Use `TG_` in all user-facing output (error messages, `--help`, docs)
- Add validation (numeric check, allowed values, etc.)
- Document in `--help` header comment, README, man page, and AGENTS.md
- Add tests for both valid and invalid values

## Test Conventions

- Tests live in focused `tests/*.bats` files with shared helpers in `tests/test_helper.bash`
- Each test gets a fresh `$TEST_DIR` via `setup()` — no shared state between tests
- Use `DVB_DEADLINE` to control loop duration — set in the past for immediate exit (tests that validate args), or a few seconds ahead to run 1-2 sessions
- Use `DVB_GRIND_CMD` to point at a stub script (never the real binary)
- Use `make test TESTS=tests/<file>.bats` for tight local reruns before falling back to the full suite
- Structural tests (`grep -q` on the script) are fine for verifying code patterns

## Known Issues

- **Flaky tests** — a handful of timing-dependent tests (network recovery, branch cleanup) may fail intermittently on slow CI. These are pre-existing and not regressions.
- **`network-watchdog`** — preflight checks for a `network-watchdog` binary (optional). If missing, taskgrind falls back to `curl` for connectivity checks. You can safely ignore the preflight warning.

## Project Structure

```
bin/taskgrind           Main script (the whole tool)
lib/constants.sh        Shared constants (model, binary path, caffeinate flags)
lib/fullpower.sh        Priority boosting (taskpolicy on macOS)
tests/*.bats            Focused bats suites by subsystem
tests/test_helper.bash  Shared test helpers
man/taskgrind.1         Man page
docs/                   Architecture docs and user stories
Makefile                lint + test targets
```
