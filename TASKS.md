# Tasks

## P0

## P1
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

## P2
## P3
