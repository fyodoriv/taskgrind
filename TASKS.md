# Tasks

## P1

- [ ] An operator pressing Ctrl+C during a long grind has a user story showing what they will see
  **ID**: doc-graceful-shutdown-user-story
  **Tags**: docs, shutdown, user-stories, operator-facing
  **Details**: The README mentions "Graceful shutdown — SIGINT/SIGTERM waits for running session, pushes commits, ignores duplicate shutdown signals, then exits", and the code implements a 120 s grace period (`TG_SHUTDOWN_GRACE`, validated at `bin/taskgrind:236`) plus a 15 s per-session grace (`TG_SESSION_GRACE`, validated at `bin/taskgrind:239`) before force-kill. `docs/user-stories.md` does not show what the terminal looks like from the moment the operator hits ^C to the final "grind_done" summary — when the grind is safe to rerun, what the log says, how duplicate ^C is ignored. Add a story (e.g., "Interrupting a grind with Ctrl+C") walking through the happy path and the timeout path with sample output.
  **Files**: `docs/user-stories.md`, `README.md`
  **Acceptance**: A new user-stories entry shows: (1) the "Waiting for session to finish" message, (2) the grace-period countdown, (3) session finishes vs. times out, (4) final summary line, (5) sample log lines with `graceful_shutdown` markers, (6) when it's safe to rerun. `tests/user-stories-docs.bats` still passes.

## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.

- [ ] `all_tasks_blocked()` has direct unit-style test coverage across TASKS.md edge cases
  **ID**: test-all-tasks-blocked-coverage
  **Tags**: tests, blocking, queue-state
  **Details**: `all_tasks_blocked()` (`bin/taskgrind:1804`) decides whether every task has a `**Blocked by**:` and drives the blocked-wait path. Today it is only exercised indirectly through `session.bats` asserting log output. Direct coverage would catch regressions like a malformed `**Blocked by**:` being counted as a block or an unblocked task being missed. Add tests that call the function against fixture TASKS.md files: empty queue, single blocked task, mixed blocked/unblocked, malformed metadata, `**Blocked**:` (reason-only) vs. `**Blocked by**:` (dependency) — and verify return code plus counter output.
  **Files**: `tests/session.bats`, `tests/features.bats`
  **Acceptance**: New tests exercise six scenarios (empty, all-blocked, single-blocked, mixed, malformed, reason-vs-dependency) with clear expected return codes. `make check` passes.

- [ ] `wait_for_network()` deadline-extension and timeout behavior is covered by focused tests
  **ID**: test-wait-for-network-coverage
  **Tags**: tests, network, resilience
  **Details**: `wait_for_network()` (`bin/taskgrind:1835`) pauses the marathon timer, polls for recovery, extends the deadline by the actual wait duration, and returns 1 when `TG_NET_MAX_WAIT` is exceeded. `tests/network.bats` covers the integration but not the deadline-extension math or the `network_timeout` / `network_restored` / `waiting_for_network` phase transitions. Add focused tests so a refactor that drops the extension or swaps the phase marker gets caught.
  **Files**: `tests/network.bats`
  **Acceptance**: Tests verify (1) deadline increases by exactly the wait duration on recovery, (2) function exits 0 on recovery, (3) exits 1 and logs `network_timeout` past `TG_NET_MAX_WAIT`, (4) phase marker is `waiting_for_network` during the wait and `network_restored` on recovery.

- [ ] `detect_default_branch()` has test coverage for each fallback rung
  **ID**: test-detect-default-branch-coverage
  **Tags**: tests, git, sync
  **Details**: `detect_default_branch()` (`bin/taskgrind:1608`) walks `origin/HEAD` → `ls-remote --symref` → upstream → local → `main` → `master`. `tests/git-sync.bats` covers the happy integration path. A missed fallback rung would manifest as "rebase failed — unknown branch" in production. Add tests that set up repo fixtures for each rung and verify the function returns the expected branch plus logs which method was used.
  **Files**: `tests/git-sync.bats`
  **Acceptance**: Each of the six fallbacks has a test that forces that rung to fire and asserts the returned branch name plus the detection-method log marker.

- [ ] `auto_resolve_tasks_rebase_conflicts()` has focused tests for the TASKS.md-only path
  **ID**: test-auto-resolve-tasks-conflicts
  **Tags**: tests, git, rebase, conflict-resolution
  **Details**: `auto_resolve_tasks_rebase_conflicts()` (`bin/taskgrind:1765`) keeps the local TASKS.md when a rebase conflict touches only that file, preventing the queue-churn deadlock. `tests/git-sync.bats` tests the end-to-end sync; the function itself has no direct coverage. A bug here (e.g., accidentally auto-resolving conflicts in other files) would silently drop changes. Add tests for: (1) TASKS.md-only conflict is auto-resolved, (2) TASKS.md + another file conflict is NOT auto-resolved, (3) local TASKS.md content is preserved, (4) log line `auto_resolve_tasks_conflicts` appears.
  **Files**: `tests/git-sync.bats`
  **Acceptance**: Four targeted tests exercise the auto-resolve path directly against fixture git repos.

- [ ] Boolean `TG_*` env vars reject non-0/1 values with an actionable error message
  **ID**: test-early-exit-stall-validation
  **Tags**: tests, validation, error-messages
  **Details**: Numeric `TG_*` vars like `TG_COOL` and `TG_MAX_SESSION` are validated with clear errors (`bin/taskgrind:216–240`). `TG_EARLY_EXIT_ON_STALL` is used as a boolean (`if [[ ... == "1" ]]`) with no up-front validation, so `TG_EARLY_EXIT_ON_STALL=yes` silently means "disabled". Add validation after line 240 rejecting non-0/1 with a clear error (`must be 0 or 1, got 'X'`), matching the existing pattern. Add tests in `tests/diagnostics.bats`.
  **Files**: `bin/taskgrind`, `tests/diagnostics.bats`
  **Acceptance**: (1) `TG_EARLY_EXIT_ON_STALL=yes taskgrind ~/repo` exits 1 with a clear error; (2) `0` and `1` still work; (3) same pattern applied to any other boolean `TG_*` knob that today accepts garbage. Tests pin the behavior.

## P3

- [ ] Error messages for common failures include actionable next-step guidance
  **ID**: test-error-message-quality
  **Tags**: tests, error-messages, ux
  **Details**: Several taskgrind error paths surface a reason but not a remediation. Examples: `Error: --model requires a name` (line 161) doesn't show a valid model; `Backend binary not found (devin)` (line 664) doesn't point at install docs. Most users see these once and bounce. Raise the floor by covering 5+ error paths with tests that assert each message mentions (a) what went wrong, (b) what to do next, (c) a doc link or example where relevant. The test itself becomes the spec for "a good error message" in this repo.
  **Files**: `tests/diagnostics.bats`, `bin/taskgrind`
  **Acceptance**: At least five error paths (missing backend, invalid model, invalid numeric env var, missing repo path, unsupported backend) have tests asserting the error includes both the cause and an actionable next step. Any new error path added after this task is expected to pass the same pattern.
