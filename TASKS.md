# Tasks

## P0

## P1
- [ ] Fix false-positive `no_local_task_removed` warnings after audit-style queue refresh sessions
  **ID**: fix-false-positive-no-local-task-removed
  **Tags**: reliability, logging, tasks, audits
  **Details**: The 2026-04-12 preserved fleet logs still show `productive_zero_ship ... reason=no_local_task_removed` in sessions whose transcripts explicitly say the completed task block was removed, especially when the session temporarily adds audit or decomposition tasks before deleting them again. Examples include `/var/folders/vp/xnc0myyn4dsb7trvmq61j4hw0000gp/T/taskgrind-2026-04-12-0806-agentbrew-19576.log`, `/var/folders/vp/xnc0myyn4dsb7trvmq61j4hw0000gp/T/taskgrind-2026-04-12-0806-bosun-18484.log`, and `/var/folders/vp/xnc0myyn4dsb7trvmq61j4hw0000gp/T/taskgrind-2026-04-12-1109-oncall-hub-app-32431.log`. Tighten the local queue-delta accounting so audit refresh sessions that remove the completed task block no longer get classified as completion-protocol misses, while genuine misses still keep the warning.
  **Files**: `bin/taskgrind`, `tests/logging.bats`, `tests/taskgrind.bats`
  **Acceptance**: A failing test first reproduces the false positive; sessions that add and later remove temporary audit tasks do not emit `reason=no_local_task_removed`; true completion-protocol misses still emit the warning.

- [ ] Add canonical `TG_` environment-variable coverage for prompt and status-file behavior
  **ID**: cover-canonical-tg-env-vars
  **Tags**: tests, env-vars, reliability
  **Details**: The suite exercises `DVB_PROMPT` and `DVB_STATUS_FILE`, but there are no direct tests for the documented canonical `TG_PROMPT` and `TG_STATUS_FILE` paths. Add red/green coverage for the user-facing prefix and for `TG_` taking precedence over the legacy `DVB_` values so regressions in the startup mapping cannot silently break the documented interface.
  **Files**: `tests/session.bats`, `tests/logging.bats`, `bin/taskgrind`
  **Acceptance**: New tests fail before the fix, then pass while proving `TG_PROMPT` injects the focus prompt, `TG_STATUS_FILE` writes status JSON, and both `TG_` variables override conflicting legacy `DVB_` values.

- [ ] Expand status-file phase coverage beyond startup and running-session snapshots
  **ID**: expand-status-phase-coverage
  **Tags**: tests, observability, status-file
  **Details**: `README.md` promises phase transitions such as `queue_empty_wait`, `blocked_wait`, `git_sync`, and `waiting_for_network`, but `tests/logging.bats` only asserts `running_session` and final `complete`. Add targeted tests that force each transitional path and verify the JSON file updates atomically with the expected phase and pending/completed session metadata.
  **Files**: `tests/logging.bats`, `tests/network.bats`, `tests/session.bats`, `bin/taskgrind`, `README.md`
  **Acceptance**: The status-file suite covers at least one wait state and one sync state in addition to `running_session`/`complete`, and the documented phase list in `README.md` stays aligned with the verified behavior.

- [ ] Replace timing-sensitive raw sleeps in flaky bats suites with event-driven polling helpers
  **ID**: stabilize-flaky-bats-timing
  **Tags**: tests, ci, reliability
  **Details**: `CONTRIBUTING.md` still warns that network-recovery and branch-cleanup tests can fail intermittently, and several suites rely on fixed `sleep 2`, `sleep 4`, or `sleep 0.2` delays under parallel load. Extract shared wait helpers and convert the most timing-sensitive cases in `tests/network.bats`, `tests/signals.bats`, `tests/resume.bats`, and `tests/session.bats` to poll for file/log conditions instead of betting on wall-clock sleeps.
  **Files**: `tests/network.bats`, `tests/signals.bats`, `tests/resume.bats`, `tests/session.bats`, `tests/test_helper.bash`, `CONTRIBUTING.md`
  **Acceptance**: The highest-risk timing tests use polling helpers instead of fixed sleeps, the known-flaky note in `CONTRIBUTING.md` is updated to match reality, and repeated targeted reruns of the touched suites pass without intermittent failures.

- [ ] Add a docs-parity check for CLI options and `TG_` environment variables across help, README, and man page
  **ID**: guard-cli-doc-parity
  **Tags**: tests, docs, cli
  **Details**: The repo has point checks for a few options like `--resume`, but there is no single guard that compares the authoritative help header in `bin/taskgrind` against `README.md` and `man/taskgrind.1`. Add a focused structural test so newly added flags or `TG_` variables cannot land without all three documentation surfaces being updated together.
  **Files**: `tests/basics.bats`, `bin/taskgrind`, `README.md`, `man/taskgrind.1`
  **Acceptance**: A structural test fails when any documented CLI flag or `TG_` variable exists in one surface but not the others, and the current tree passes with all three docs sources aligned.


## P2
## P3
