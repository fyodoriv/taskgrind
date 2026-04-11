# Tasks

## P0
- [ ] Make `make lint` pass cleanly with the current dynamic source layout
  **ID**: restore-shellcheck-green
  **Tags**: quality, lint, shellcheck
  **Details**: `make lint` currently fails on ShellCheck `SC1091` because `bin/taskgrind` sources `lib/constants.sh` and `lib/fullpower.sh` through `TASKGRIND_DIR`, which ShellCheck cannot resolve. Fix the lint path so local runs and CI are green without weakening useful checks.
  **Files**: `Makefile`, `bin/taskgrind`
  **Acceptance**: `make lint` exits 0 locally; the fix preserves source-path checking for real issues and does not break runtime path resolution.

## P1
- [ ] Expand resume coverage for malformed and incompatible saved states
  **ID**: harden-resume-validation-tests
  **Tags**: tests, resume, reliability
  **Details**: `tests/resume.bats` only covers a small slice of the resume contract. Add focused red/green tests for malformed numeric fields, non-`running` statuses, repo mismatch, and backend/model/skill override mismatches so future resume changes do not silently reopen rejected states.
  **Files**: `tests/resume.bats`, `bin/taskgrind`
  **Acceptance**: New tests fail before the fix and pass afterward; each documented rejection path in `bin/taskgrind` has an executable regression test.

- [ ] Add executable coverage for the installer flow
  **ID**: test-install-script-flow
  **Tags**: tests, install, distribution
  **Details**: `install.sh` is user-facing but has no dedicated bats coverage. Add tests for missing `git`, existing-install short-circuit behavior, clone destination handling, executable-bit repair, and the final PATH/install instructions so install regressions are caught before release.
  **Files**: `install.sh`, `tests/install.bats`, `tests/test_helper.bash`
  **Acceptance**: A new bats suite exercises the happy path and key failure paths for `install.sh` without touching the network; `make test` includes the suite.

- [ ] Distinguish real zero-ship sessions from task-count races in multi-agent runs
  **ID**: reconcile-productive-zero-ship-accounting
  **Tags**: reliability, metrics, concurrency
  **Details**: Recent logs for `bosun`, `ideas`, and `agentbrew` show `productive_zero_ship` firing even when the session output says the task block was removed or code was successfully shipped. In the same windows the logs also record `tasks_added=` external injections or temporary add/remove subtask workflows, so a plain `tasks_before - tasks_after` comparison is misclassifying productive sessions as zero-ship. Tighten shipped accounting and log messaging so concurrent queue growth or temporary subtask churn does not look like a failed session. Keep the log report explicit about whether zero-ship came from unchanged queue length, concurrent task injection, or a temporary add/remove decomposition loop so future audits do not need to reconstruct the cause by hand.
  **Files**: `bin/taskgrind`, `tests/taskgrind.bats`, `tests/logging.bats`
  **Acceptance**: Sessions that commit and remove a task block are not flagged as `productive_zero_ship` solely because other tasks were injected or a temporary subtask was added and removed in the same session; logs make the reason for any remaining zero-ship classification explicit; regression tests cover concurrent task additions and temporary subtask flows.

- [ ] Make parallel bats cleanup robust after interrupted or high-job runs
  **ID**: harden-bats-tempdir-cleanup
  **Tags**: tests, reliability, ci
  **Details**: Current verify logs still show intermittent cleanup failures after parallel bats runs, including `rm: .../parallel_output: Directory not empty` in `/tmp/taskgrind-p0-verify.log` and `/tmp/taskgrind-test-jobs6-clean.log`, plus `make: *** [test-force] Terminated: 15` in the same window. Tighten the test harness and cleanup path so interrupted or high-concurrency runs do not leave temp directories behind or turn cleanup noise into a failed verify.
  **Files**: `Makefile`, `tests/test_helper.bash`, `tests/*.bats`
  **Acceptance**: Repeated local `make test` and `make check` runs at the default parallelism do not fail with `Directory not empty` cleanup errors or follow-on `signal 15` terminations caused by leftover bats temp state.

- [ ] Stabilize the repo-deletion abort regression so reruns do not flap
  **ID**: stabilize-repo-deletion-abort-test
  **Tags**: tests, reliability, regression
  **Details**: The current log set shows `repo deletion mid-marathon aborts gracefully` passing in some runs (`/tmp/taskgrind-check.log`, `/tmp/taskgrind-fix-stash-masking-make-check.log`) and failing in others (`/tmp/taskgrind-detect-invalid-model-make-check.log`, `/tmp/taskgrind-full-test.log`, `/tmp/taskgrind-fix-stash-masking-make-check-rerun.log`). Audit the test timing and runtime behavior around repo disappearance so this regression reflects one deterministic contract instead of flapping across verify runs.
  **Files**: `bin/taskgrind`, `tests/session.bats`, `tests/test_helper.bash`
  **Acceptance**: The repo-deletion abort regression passes consistently across repeated targeted and full-suite runs, and its assertions describe the intended abort contract without timing-sensitive flakes.

## P2
- [ ] Add behavioral tests for macOS priority boosting and Linux no-op fallback
  **ID**: cover-fullpower-runtime
  **Tags**: tests, macos, runtime
  **Details**: `lib/fullpower.sh` is sourced in production to call `taskpolicy`, but there is no focused behavior test around `boost_priority`. Add coverage that proves taskgrind attempts the boost on macOS-capable systems and stays harmless when `taskpolicy` is unavailable.
  **Files**: `lib/fullpower.sh`, `tests/session.bats`, `tests/test_helper.bash`
  **Acceptance**: Tests demonstrate the boost path is invoked when `taskpolicy` exists and skipped cleanly otherwise, without introducing platform-specific flakes.

## P3
- [ ] Add a small audit helper target for repository sweeps
  **ID**: add-audit-helper-target
  **Tags**: tooling, docs, maintenance
  **Details**: Empty-queue sweeps are part of the product story, but there is no maintainer shortcut for running the same local checks this audit used (`TODO`/`FIXME` scan, shellcheck, focused docs review). Add a lightweight `make audit` or documented equivalent that helps contributors reproduce repo audits consistently.
  **Files**: `Makefile`, `CONTRIBUTING.md`, `README.md`
  **Acceptance**: Contributors have one documented command for the repo-audit workflow, and it completes using existing local tooling without network-only dependencies.

- [ ] Make `--dry-run` show the same completion and autonomy guidance as live sessions (@devin)
  **ID**: expose-dry-run-session-protocol
  **Tags**: usability, diagnostics, prompts
  **Details**: `taskgrind --dry-run` prints only a thin prompt preview, so maintainers cannot see the completion protocol and autonomy instructions that real sessions receive. Expand the dry-run prompt preview and add regression coverage so audit/debug loops can inspect the effective session protocol without launching a backend.
  **Files**: `bin/taskgrind`, `tests/diagnostics.bats`
  **Acceptance**: `taskgrind --dry-run` prints the completion protocol and autonomy guidance alongside the prompt preview; regression tests fail before the change and pass after it.
