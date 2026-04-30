# AGENTS.md — Taskgrind Codebase Guide

## What This Repo Is

Autonomous multi-session grind tool. Runs sequential AI coding sessions against any `TASKS.md` repo until a deadline. Shell script + bats tests. No build step.

## Repo Layout

```
taskgrind/
├── bin/taskgrind           Main script (runs AI sessions in a loop)
├── lib/constants.sh        Shared constants (model/backend/caffeinate + canonical TG_* defaults)
├── lib/fullpower.sh        Priority boosting (taskpolicy for macOS)
├── tests/*.bats            Focused bats suites by subsystem (basics, preflight, session, git-sync, logging, network, ...)
├── tests/preflight.bats    Preflight coverage for backend, repo, slot, and startup validation
├── tests/installer-output.bats  Install-script output coverage for local and PATH guidance
├── tests/test_helper.bash  Shared test helpers and fake backend/session fixtures
├── tests/verify-bash32-compat.sh  Bash 3.2 compatibility guard used by the bats suite
├── docs/user-stories.md    Core usage patterns
├── docs/resume-state.md    Resume-file lifecycle and stale-state notes
├── docs/architecture.md    Design decision rationales
├── man/taskgrind.1         Man page
├── install.sh              One-liner install script
├── .devin/skills/          Repo-local audit loop skills used by taskgrind sessions
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
make audit      # run the local repo audit workflow (TODO scan + shellcheck + tasks-lint)
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
7. **Parallel bats is auto-capped at 8** — `make test` / `make check` cap `TEST_JOBS` at 8 by default. Going past 8 historically hit `signal 15` terminations from `bats --jobs 9+` because of the macOS per-user soft process limit (~709 by default) during teardown + next-test-dispatch overlap. The `RUN_BATS` recipe in the Makefile bumps the soft limit (`ulimit -Su unlimited`) before invoking bats so that 8 workers stay inside the safe envelope; if you bump the cap higher, expect to revisit that ulimit. Set `TEST_JOBS=<n>` to probe a different level
8. **Keep runtime files `/bin/bash` 3.2 compatible** — `tests/bash-compat.bats` smokes `/bin/bash bin/taskgrind --dry-run` and rejects common Bash-4-only syntax in sourced runtime files
9. **Every session adds tasks** — any user prompt, log review, incident debrief, or interactive investigation in this repo (or its sibling personal repos `agentbrew`, `bosun`) should produce at least one TASKS.md addition. Observations that surface failure modes, ergonomic friction, missing telemetry, or "huh, that's odd" findings are durable work — file them with full Details / Files / Acceptance per the template style of existing entries before the session ends. The default state is "this prompt produced N new tasks"; "no new tasks" is acceptable only if the prompt was purely informational (`--help` / status query) and explicitly noted. Failure mode this prevents: agent reasons about a problem, the user accepts the analysis, and the lesson dies with the session because nobody filed it

## Local Test Notes

- The suite now lives in many focused `tests/*.bats` files instead of a single monolithic bats file; when you touch one subsystem, prefer `make test TESTS=tests/<file>.bats` before the full `make check` gate.
- Docs and startup work usually land in `tests/basics.bats`, `tests/preflight.bats`, or `tests/installer-output.bats`; start with the narrowest one before rerunning the whole suite.
- Avoid hardcoding suite counts in docs. The total bats count changes as focused files land, so agents should treat `tests/*.bats` plus the current `make test` output as the source of truth.
- `make test` caches passing results per `TESTS` target and `TEST_JOBS` value, while `make test-force` always reruns the selected suite from scratch.
- `make test` and `make check` auto-cap `TEST_JOBS` at 8 unless you override it explicitly for diagnostics. The `RUN_BATS` recipe also raises the per-user soft process limit (`ulimit -Su unlimited`) so the cap is real, not theoretical.

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
