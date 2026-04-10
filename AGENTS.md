# AGENTS.md — Taskgrind Codebase Guide

## What This Repo Is

Autonomous multi-session grind tool. Runs sequential AI coding sessions against any `TASKS.md` repo until a deadline. Shell script + bats tests. No build step.

## Repo Layout

```
taskgrind/
├── bin/taskgrind           Main script (runs AI sessions in a loop)
├── lib/constants.sh        Shared constants (model, backend path, caffeinate flags)
├── lib/fullpower.sh        Priority boosting (taskpolicy for macOS)
├── tests/taskgrind.bats    Test suite (357 tests)
├── tests/test_helper.bash  Shared test helpers
├── docs/user-stories.md    Core usage patterns
├── docs/architecture.md    Design decision rationales
├── man/taskgrind.1         Man page
├── install.sh              One-liner install script
├── .github/workflows/      CI (shellcheck + bats on macOS + Linux)
├── Makefile                lint + test targets
├── README.md               Usage, install, env vars
├── CONTRIBUTING.md         Contributor guide
├── SECURITY.md             Security policy
├── LICENSE                 MIT license
├── TASKS.md                Task queue (present when tasks exist)
└── Agentfile.yaml          Agent config (MCP servers, skills)
```

## Development

```bash
make lint       # shellcheck (run from bin/ with -x for source resolution)
make test       # bats test suite (357 tests)
make check      # lint + test (run before committing)
```

## Rules for Editing

1. **Run `make check` before committing** — shellcheck + bats must pass
2. **Commit on `main`** — this repo doesn't use feature branches for small changes
3. **Env vars use `TG_` prefix (primary)** — `DVB_` is supported as a backward-compatible alias. Internal/test-only vars keep the `DVB_` prefix.
4. **Source paths are relative** — `$TASKGRIND_DIR/lib/constants.sh`, derived from script location
5. **Test with `DVB_GRIND_CMD`** — all tests use a fake devin stub, never the real binary
6. **Timing-sensitive tests** — a handful of network recovery and branch cleanup tests may fail intermittently under load; pre-existing, not a regression

## Architecture

The script runs a `while` loop until deadline:

```
preflight → [session: launch backend → wait → count shipped] → cooldown → git sync → repeat
```

Key subsystems:
- **Self-copy protection** — copies itself to `$TMPDIR` before running (bash reads scripts lazily by byte offset)
- **Network resilience** — pauses timer on network loss, extends deadline on recovery
- **Stall detection** — consecutive zero-ship counter + per-task retry cap via ID tracking
- **Git sync** — every N sessions (configurable), stash/checkout/rebase/restore
- **Caffeinate** — prevents system sleep (`-ms` flags: system+disk, display can sleep)

## Env Vars (internal/test-only)

| Variable | Purpose |
|----------|---------|
| `DVB_GRIND_CMD` | Override devin binary (for testing) |
| `DVB_DEADLINE` | Override deadline epoch (for testing) |
| `DVB_NET_FILE` | Sentinel file for network state in tests |
| `DVB_CAFFEINATED` | Re-exec guard to prevent double caffeinate |
| `TASKGRIND_DIR` | Repo root (auto-detected from `$0`) |

See `taskgrind --help` for user-facing env vars.
