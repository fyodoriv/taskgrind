# AGENTS.md — Taskgrind Codebase Guide

## What This Repo Is

Autonomous multi-session grind tool. Runs sequential AI coding sessions against any `TASKS.md` repo until a deadline. Shell script + bats tests. No build step.

## Repo Layout

```
taskgrind/
├── bin/taskgrind           Main script (runs AI sessions in a loop)
├── lib/constants.sh        Shared constants (model, backend path, caffeinate flags)
├── lib/fullpower.sh        Priority boosting (taskpolicy for macOS)
├── tests/*.bats            Focused bats suites by subsystem (session, git-sync, logging, network, ...)
├── tests/test_helper.bash  Shared test helpers
├── tests/verify-bash32-compat.sh  Bash 3.2 compatibility guard used by the bats suite
├── docs/user-stories.md    Core usage patterns
├── docs/resume-state.md    Resume-file lifecycle and stale-state notes
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
make install    # symlink to /usr/local/bin + install man page
make lint       # shellcheck (run from bin/ with -x for source resolution)
make test       # bats suite across tests/*.bats (cached, skips when unchanged)
make test-force # bats suite without cache
make test TESTS=tests/bash-compat.bats  # targeted rerun with its own cache key
make test TEST_JOBS=4                   # override the auto-capped parallelism for diagnostics
make check      # lint + test (run before committing)
make uninstall  # remove symlink and man page
```

## Rules for Editing

1. **Run `make check` before committing** — shellcheck + bats must pass
2. **Commit on `main`** — this repo doesn't use feature branches for small changes
3. **Env vars use `TG_` prefix (primary)** — `DVB_` is supported as a backward-compatible alias. Internal/test-only vars keep the `DVB_` prefix.
4. **Source paths are relative** — `$TASKGRIND_DIR/lib/constants.sh`, derived from script location
5. **Test with `DVB_GRIND_CMD`** — all tests use a fake devin stub, never the real binary
6. **Use `TESTS=...` for tight loops** — `make test TESTS=tests/bash-compat.bats` or another file reruns just that selection and caches it separately from the full suite
7. **Parallel bats is auto-capped** — `make test` / `make check` now cap `TEST_JOBS` at 6 by default to avoid local full-suite `signal 15` terminations from `bats --jobs 9`; set `TEST_JOBS=<n>` when you need to probe a different level
8. **Keep runtime files `/bin/bash` 3.2 compatible** — `tests/bash-compat.bats` smokes `/bin/bash bin/taskgrind --dry-run` and rejects common Bash-4-only syntax in sourced runtime files

## Local Test Notes

- The suite now lives in many focused `tests/*.bats` files instead of a single monolithic bats file; when you touch one subsystem, prefer `make test TESTS=tests/<file>.bats` before the full `make check` gate.
- Avoid hardcoding suite counts in docs. The total bats count changes as focused files land, so agents should treat `tests/*.bats` plus the current `make test` output as the source of truth.
- `make test` caches passing results per `TESTS` target and `TEST_JOBS` value, while `make test-force` always reruns the selected suite from scratch.
- `make test` and `make check` auto-cap `TEST_JOBS` at 6 unless you override it explicitly for diagnostics.

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
