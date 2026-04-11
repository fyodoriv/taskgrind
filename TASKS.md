# Tasks

## P0
- [ ] Make `make lint` pass cleanly with the current dynamic source layout
  **ID**: restore-shellcheck-green
  **Tags**: quality, lint, shellcheck
  **Details**: `make lint` currently fails on ShellCheck `SC1091` because `bin/taskgrind` sources `lib/constants.sh` and `lib/fullpower.sh` through `TASKGRIND_DIR`, which ShellCheck cannot resolve. Fix the lint path so local runs and CI are green without weakening useful checks.
  **Files**: `Makefile`, `bin/taskgrind`
  **Acceptance**: `make lint` exits 0 locally; the fix preserves source-path checking for real issues and does not break runtime path resolution.

## P1
- [ ] Analyze recent taskgrind logs and refresh repo tasks (@instance-1)
  **ID**: audit-recent-grind-logs
  **Tags**: audit, logs, maintenance
  **Details**: Review the newest unanalyzed taskgrind logs, capture actionable reliability findings, and update the task queues for the affected repos so future sessions work from the observed failures instead of rediscovering them.
  **Files**: `TASKS.md`
  **Acceptance**: The recent logs have been reviewed; resulting follow-up tasks are recorded in the relevant task queues; this tracking block is removed once the audit update lands.

- [ ] Reconcile resumable-state docs with the implemented on-disk contract
  **ID**: align-resume-state-docs
  **Tags**: docs, resume, reliability
  **Details**: `docs/resume-state.md` still specifies a JSON resume file with fields such as `schema_version`, `saved_at`, and `task_attempts`, but `bin/taskgrind` currently writes and reads a flat `key=value` file with a much smaller field set. Update the design doc to match reality or expand the implementation, then make the README/man-page resume guidance point at the same contract.
  **Files**: `docs/resume-state.md`, `README.md`, `man/taskgrind.1`, `bin/taskgrind`
  **Acceptance**: Resume documentation matches the actual file format and validation rules; a contributor can inspect the docs and correctly predict what `--resume` persists and rejects.

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

- [ ] Document the runtime status JSON schema and example lifecycle transitions
  **ID**: document-status-file-schema
  **Tags**: docs, observability, monitoring
  **Details**: README mentions `TG_STATUS_FILE` but does not spell out the emitted JSON fields or how values change across startup, active sessions, network waits, and completion. Add a field reference plus one realistic example so operators can build external monitors without reverse-engineering `write_status_file`.
  **Files**: `README.md`, `man/taskgrind.1`, `bin/taskgrind`
  **Acceptance**: Docs enumerate the status payload fields written by `write_status_file`; at least one example matches the current runtime shape and phase transitions.

- [ ] Stop launching no-op sessions once the deadline is already exhausted
  **ID**: guard-expired-deadline-launch
  **Tags**: reliability, runtime, logs
  **Details**: Several 2026-04-11 grind logs against temporary fixture repos (`taskgrind-2026-04-11-1805-repo-60489.log`, `...-1810-repo-46402.log`, `...-1824-repo-18279.log`, `...-1825-repo-39851.log`) show taskgrind starting with `remaining=0m` and still running one to four empty sessions before finally stopping. Add an early deadline guard so an already-expired run exits before launching the session loop, logs why it skipped work, and avoids generating misleading stall warnings or repeated zero-ship retries.
  **Files**: `bin/taskgrind`, `tests/taskgrind.bats`, `tests/session.bats`
  **Acceptance**: A run with an already-expired deadline exits without launching a session; the log records the expired-deadline skip; no stall-warning or extra zero-ship sessions are emitted in that case.

- [ ] Distinguish real zero-ship sessions from task-count races in multi-agent runs
  **ID**: reconcile-productive-zero-ship-accounting
  **Tags**: reliability, metrics, concurrency
  **Details**: Recent logs for `bosun`, `ideas`, and `agentbrew` show `productive_zero_ship` firing even when the session output says the task block was removed or code was successfully shipped. In the same windows the logs also record `tasks_added=` external injections or temporary add/remove subtask workflows, so a plain `tasks_before - tasks_after` comparison is misclassifying productive sessions as zero-ship. Tighten shipped accounting and log messaging so concurrent queue growth or temporary subtask churn does not look like a failed session.
  **Files**: `bin/taskgrind`, `tests/taskgrind.bats`, `tests/logging.bats`
  **Acceptance**: Sessions that commit and remove a task block are not flagged as `productive_zero_ship` solely because other tasks were injected or a temporary subtask was added and removed in the same session; logs make the reason for any remaining zero-ship classification explicit; regression tests cover concurrent task additions and temporary subtask flows.

## P2
- [ ] Add behavioral tests for macOS priority boosting and Linux no-op fallback
  **ID**: cover-fullpower-runtime
  **Tags**: tests, macos, runtime
  **Details**: `lib/fullpower.sh` is sourced in production to call `taskpolicy`, but there is no focused behavior test around `boost_priority`. Add coverage that proves taskgrind attempts the boost on macOS-capable systems and stays harmless when `taskpolicy` is unavailable.
  **Files**: `lib/fullpower.sh`, `tests/session.bats`, `tests/test_helper.bash`
  **Acceptance**: Tests demonstrate the boost path is invoked when `taskpolicy` exists and skipped cleanly otherwise, without introducing platform-specific flakes.

- [ ] Close the doc gap around multi-instance conflict handling and git-sync ownership
  **ID**: explain-multi-instance-conflict-rules
  **Tags**: docs, concurrency, git
  **Details**: README explains slot ownership at a high level, but it does not show what higher-slot sessions are told to do differently or when slot 0 alone performs git sync. Add an operator-focused example for `TG_MAX_INSTANCES` runs, including the preflight slot report and the conflict-avoidance expectations for nonzero slots.
  **Files**: `README.md`, `docs/user-stories.md`, `man/taskgrind.1`
  **Acceptance**: A reader can understand how slot assignment, preflight reporting, and slot-0-only git sync behave during concurrent grinds without reading the shell script.

## P3
- [ ] Add a small audit helper target for repository sweeps
  **ID**: add-audit-helper-target
  **Tags**: tooling, docs, maintenance
  **Details**: Empty-queue sweeps are part of the product story, but there is no maintainer shortcut for running the same local checks this audit used (`TODO`/`FIXME` scan, shellcheck, focused docs review). Add a lightweight `make audit` or documented equivalent that helps contributors reproduce repo audits consistently.
  **Files**: `Makefile`, `CONTRIBUTING.md`, `README.md`
  **Acceptance**: Contributors have one documented command for the repo-audit workflow, and it completes using existing local tooling without network-only dependencies.
