# Tasks

## P1

- [ ] `startup probe aborts before session 1 when backend exits immediately with no output` is no longer flaky under parallel load
  **ID**: stabilize-startup-probe-aborts-flake
  **Tags**: tests, flakiness, ci, preflight
  **Details**: Running `make test-force` with the auto-capped `TEST_JOBS=6` reports an intermittent failure: `not ok 472 startup probe aborts before session 1 when backend exits immediately with no output (in test file tests/preflight.bats, line 346) [ "$status" -eq 1 ]' failed`. The test sets `DVB_DEADLINE=$(date +%s) + 5` then expects the run to fail with status 1 because the stub backend has no `--version` output. Under parallel load, the deadline can fire before the backend probe runs, so the script exits with 0 (`deadline_expired_before_session_loop`) instead of 1 (`backend_probe_failed`). Bump the deadline to ~30s like the P1 stabilize-flaky-full-suite-tests fix did for `tests/logging.bats`, and verify the test still finishes fast in the common case (the probe should fail and exit immediately). 10 consecutive `make test-force TESTS=tests/preflight.bats` runs at the default `TEST_JOBS=6` should all pass.
  **Files**: `tests/preflight.bats`
  **Acceptance**: 10 consecutive `make test-force` runs at the default `TEST_JOBS=6` all pass with test 472 (`startup probe aborts before session 1 when backend exits immediately with no output`) green every time. Targeted reruns under `bats tests/preflight.bats -f "startup probe aborts"` also remain green.

## P2

- [ ] `format_conflict_paths_for_log()` and `emit_rebase_conflict_logs()` have direct unit-style test coverage
  **ID**: test-rebase-conflict-log-formatters
  **Tags**: tests, git, rebase, logging
  **Details**: `format_conflict_paths_for_log()` (`bin/taskgrind:1723`) and `emit_rebase_conflict_logs()` (`bin/taskgrind:1741`) turn raw `git status --porcelain` conflict output into the structured `rebase_conflict paths=<...> class=<queue_only|repo|unknown>` log line the `grind-log-analyze` skill parses (`.devin/skills/grind-log-analyze/SKILL.md:104-117`). The only current coverage is a structural grep in `tests/features.bats:509`. A silent regression in the log format would break every downstream post-mortem without any bats failure. Add direct tests that source the function, feed conflict path fixtures (single queue path, multiple queue paths, mixed queue + repo file, CRLF line endings, binary-only conflict), and assert the exact log line shape.
  **Files**: `tests/git-sync.bats`
  **Acceptance**: New tests cover at least five fixture inputs for `format_conflict_paths_for_log` and three for `emit_rebase_conflict_logs`, asserting both the emitted log substring (`rebase_conflict paths=...`) and its category (`queue_only`, `repo`, `unknown`). The `grind-log-analyze` skill's parser expectations at `.devin/skills/grind-log-analyze/SKILL.md:104-117` keep matching the exercised formatter outputs.

- [ ] `slot_lock_pid()` and `slot_lock_active()` have direct unit-style test coverage
  **ID**: test-slot-lock-helpers
  **Tags**: tests, multi-instance, locking
  **Details**: `slot_lock_pid()` (`bin/taskgrind:641`) and `slot_lock_active()` (`bin/taskgrind:647`) are the probe helpers that `--preflight` uses to report `slots: N/M active` and that the multi-instance path uses to detect stale locks. They are tested only through the full concurrent grind flows in `tests/multi-instance.bats`. A regression that always returned "lock not active" would silently break the "all slots full" refusal and pass the higher-level tests. Add direct coverage: write a fake lock file with a live pid (the bats runner itself) vs a dead pid (a recycled pid that no longer exists) and assert the return code / printed pid.
  **Files**: `tests/multi-instance.bats`
  **Acceptance**: (1) A test proves `slot_lock_pid` prints the pid from a valid lock file and returns 1 on a missing/empty file. (2) A test proves `slot_lock_active` returns 0 for a live pid and 1 for a clearly-dead pid (use a fixture pid that is guaranteed not to exist, e.g. the highest unused value on Linux/macOS). (3) Tests source the functions via `awk` extract, matching the existing pattern.

## P3

- [ ] Repo ships a `.editorconfig` so contributors get consistent indentation in shell, bats, and markdown files
  **ID**: add-editorconfig
  **Tags**: dx, style, onboarding
  **Details**: The taskgrind tree mixes `bin/` bash (2-space indent), `tests/*.bats` (2-space indent), `lib/*.sh` (2-space indent), and markdown. Contributors using editors that honor `.editorconfig` (VS Code, JetBrains, Vim plugins) would set indentation correctly on first open. Today there is none. Both the `dotfiles` and `tasks.md` sibling repos ship one. Add `.editorconfig` with one entry per file type and document it in `CONTRIBUTING.md`.
  **Files**: `.editorconfig`, `CONTRIBUTING.md`
  **Acceptance**: A new `.editorconfig` covers `*.{sh,bash,bats}` (2-space indent, LF line endings, final newline), `*.md` (preserve trailing spaces for hard breaks, LF line endings, final newline), and `Makefile` (tab indentation, 8-char width). `CONTRIBUTING.md` mentions it in the Quick Start or Project Structure section. `make check` still passes.


