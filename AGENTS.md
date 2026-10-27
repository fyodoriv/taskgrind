# AGENTS.md — taskgrind guide for agents

## Start here

taskgrind runs AI coding sessions one after another against any repo that keeps
its queue in `TASKS.md`, until a deadline, an empty queue, or the stall guard
stops it. It is a Bash script with bats tests and no build step. The canonical
repo is `github.com/fyodoriv/taskgrind`, branch `main`.

Read this file first. Then open only the doc that the routing table names. Do
not read `README.md` end to end; it is the user manual. `CLAUDE.md` is a symlink
to this file. The full docs map is [`docs/README.md`](docs/README.md).

## Commands

Run every command from the repo root.

| Task | Command |
|---|---|
| Gate before a commit | `env -u BASH_ENV make check` (shellcheck + the bats suite; see Gotchas) |
| One test file | `make test TESTS=tests/<file>.bats` (cached per target) |
| One test, no cache | `bats -f '<test name>' tests/<file>.bats` |
| Full suite without the cache | `make test-force` (several minutes; run it in the background) |
| Shellcheck only | `make lint` |
| Refresh the README Proof section (field data from the local usage log) | `scripts/proof.sh` |
| Repo audit (TODO scan, shellcheck, `tasks-lint` on TASKS.md, docs review queue) | `make audit` |
| Dry run of a grind | `bin/taskgrind --dry-run 1 <repo>` |
| Install locally | `make install` (symlink to `/usr/local/bin` + man page); `make uninstall` |
| Stress parallel tests | `make test TEST_JOBS=4` (diagnostics only) |

```bash
make audit      # run the local repo audit workflow (TODO scan + shellcheck + tasks-lint)
```

## Where to change what

| I want to… | Change | Update this doc too |
|---|---|---|
| Change the session loop, flags, or prompt | `bin/taskgrind` | `man/taskgrind.1`, README "Usage", [`docs/architecture.md`](docs/architecture.md) |
| Change a `TG_*` default | `lib/constants.sh` | README "Environment Variables", [`docs/defaults-rationale.md`](docs/defaults-rationale.md) |
| Change session timeouts or kill escalation | `lib/watchdog.sh` | [`docs/architecture.md`](docs/architecture.md) |
| Change macOS priority boosting | `lib/fullpower.sh` | README "Features" |
| Change resume behavior | `bin/taskgrind` resume code | [`docs/resume-state.md`](docs/resume-state.md) |
| Change preflight checks | `bin/taskgrind` preflight code | `tests/preflight.bats`, README "Troubleshooting" |
| Change install | `install.sh` | README "Install", `tests/installer-output.bats` |
| Add or change a test | `tests/<subsystem>.bats`, helpers in `tests/test_helper.bash` | none |
| Change a repo-local skill | `.agents/skills/<name>/SKILL.md` | README pointers |
| Change CI | `.github/workflows/check.yml`, `Makefile` | this file's `## Commands` |
| Change the README Proof section or the usage log | `scripts/proof.sh` (writes `docs/proof/metrics.json` and the README section), `record_usage_event` in `bin/taskgrind` | `tests/proof.bats`, `tests/usage-log.bats`; run `scripts/proof.sh` |
| Add a usage pattern | [`docs/user-stories.md`](docs/user-stories.md) | none |
| Add a doc | `docs/<name>.md` | a row in [`docs/README.md`](docs/README.md) (test-enforced) |

## Rules

1. Run `make check` before you commit. Shellcheck and bats must pass.
2. Commit on `main` for small changes; this repo does not need feature branches for them. Use a branch and PR for larger work.
3. Env vars use the `TG_` prefix. `DVB_` is a backward-compatible alias. Internal and test-only vars keep the `DVB_` prefix.
4. Source paths are relative: `$TASKGRIND_DIR/lib/constants.sh`, derived from the script location.
5. Tests use a fake backend through `DVB_GRIND_CMD`, never a real backend binary.
6. Use `TESTS=...` for tight loops. Each selection has its own cache key.
7. Parallel bats is capped at 2 by default, to match GitHub Actions. Use `TEST_JOBS=4` or `8` only for diagnostics; above 8, the macOS per-user process limit kills tests with `signal 15`.
8. Keep runtime files `/bin/bash` 3.2 compatible. `tests/bash-compat.bats` checks it.
9. Every session adds tasks. A prompt, log review, or investigation in this repo (or in `agentbrew`, `bosun`) files at least one TASKS.md task with Details, Files, and Acceptance, unless it was purely informational.

Test helper: use `run_tiny_workload` from `tests/test_helper.bash` for CLI-shape, banner, prompt, log-header, and status tests that need one session. Keep the full loop only for time and orchestration tests (watchdogs, signals, network, git sync, sweeps, rotation, workspaces, locking).

Internal and test-only env vars:

| Variable | Purpose |
|---|---|
| `DVB_GRIND_CMD` | Override the backend binary (tests) |
| `DVB_DEADLINE` | Override the deadline epoch (tests) |
| `DVB_NET_FILE` | Sentinel file for network state in tests |
| `DVB_CAFFEINATED` | Re-exec guard against double caffeinate |
| `TASKGRIND_DIR` | Repo root, found from `$0` |

User-facing env vars: `taskgrind --help`. Loop design: [`docs/architecture.md`](docs/architecture.md).

## Gotchas

- **Agent sandbox**: the bats helper's `mktemp` fails inside it (`mkdtemp failed … Operation not permitted`). Run `make test` and `bats` outside the sandbox.
- **`BASH_ENV` breaks test stubs**: dotfiles sets `BASH_ENV=~/.config/dotfiles/bash-env.sh`, which re-exports `PATH` in every child bash, so tests reach real `git`, `curl`, and backends instead of their stubs (preflight, git-sync, signals, rotation, diagnostics fail). Run `env -u BASH_ENV make check`.
- **`make test` can skip**: it caches a pass per `TESTS` and `TEST_JOBS` target and prints "(cached)". Use `make test-force` to rerun.
- **Global gitignore lists `TASKS.md`** on the owner's machine. Fixture repos must use `git add -f TASKS.md` (see `tests/git-sync.bats`), or the file is never committed.
- **Slow full suite**: `make check` runs the whole bats suite with 2 jobs; it takes about 16 minutes on this Mac. Run one file with `TESTS=` while you iterate.
- **Line-pinned audit test**: `tests/basics.bats` asserts that `make audit` prints no `TODO:` match at certain `README.md` and `CONTRIBUTING.md` line numbers. After you move text, run `make audit`.
- **Text pins**: `tests/basics.bats` greps README, CONTRIBUTING, AGENTS.md, `docs/architecture.md`, and `docs/user-stories.md` for exact phrases. Run `make test TESTS=tests/basics.bats` after any docs edit.

## Delivery

1. Small change: commit on `main` (rule 2). Larger change: branch `type/short-description` in a worktree under `~/apps/tooling/wt/`, then a PR.
2. Make the change with its tests and its docs.
3. Run `make check`. GitHub Actions also runs `make lint`, `make audit`, and the bats suite on macOS and Linux for every push and PR.
4. Commit with a conventional header (`type: description`, 72 chars max) and the pre-registered hypothesis in the body.
5. PR body: `## Summary`, `## Details`, `## Docs`, and `## Visual proof` (a pasted terminal transcript). Squash-merge when CI is green, then remove the worktree and branch.

## Docs upkeep

- Every behavior change updates its docs in the same commit or PR. The routing table names the doc. User-facing flags and env vars also go in `man/taskgrind.1`.
- A gotcha that cost you time goes into `## Gotchas`, or becomes a test when a machine can check it.
- Every PR body has a `## Docs` section: the docs you changed, or `Docs: none — <reason>`.
- A new `docs/*.md` file needs a row in [`docs/README.md`](docs/README.md). `tests/docs-contract.bats` checks this file's sections and size, the docs map, and the README opening.
- Do not write test or file counts in docs; they go stale. Treat `make test` output as the source of truth.
- Contract for any repo: agentbrew `docs/agent-guide-baseline.md`.
