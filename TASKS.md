# Tasks

## P0
- [ ] Document the productive-timeout auto-increase behavior across all docs
  **ID**: doc-productive-timeout-auto-increase
  **Tags**: docs, accuracy, operator-facing
  **Details**: When a session ships work but hits the `TG_MAX_SESSION` timeout, taskgrind silently increases `max_session` by 1800 s (capped at 7200 s / 2 h) so the next session gets more runway. This behavior is not mentioned anywhere: the README feature bullet says only "detects when timeout kills sessions that were shipping", the man page `TG_MAX_SESSION` entry says only "Max seconds per session before timeout (default: 3600)", `docs/architecture.md` does not cover the rationale, and no user story shows the auto-increase log line. An operator who sets `TG_MAX_SESSION=3600` expecting a hard 1 h cap would be surprised by sessions running up to 2 h. Add the auto-increase behavior, its 7200 s ceiling, and the `productive_timeout` log marker to: the README feature bullet and env var table note, the man page `TG_MAX_SESSION` entry, a new architecture.md section explaining the design trade-off, and a brief mention in the user stories monitoring or troubleshooting context.
  **Files**: `README.md`, `man/taskgrind.1`, `docs/architecture.md`, `docs/user-stories.md`
  **Acceptance**: All four docs explain that `TG_MAX_SESSION` can auto-increase after a productive timeout, state the 7200 s cap, and mention the `productive_timeout` log marker. Existing tests in `tests/user-stories-docs.bats` or `tests/basics.bats` still pass.

- [ ] Document the diminishing-returns detection mechanism behind `TG_EARLY_EXIT_ON_STALL`
  **ID**: doc-diminishing-returns-mechanism
  **Tags**: docs, accuracy, operator-facing
  **Details**: The implementation tracks shipped counts in a rolling 5-session window and warns when throughput drops below 2 tasks in that window. If `TG_EARLY_EXIT_ON_STALL=1`, taskgrind exits. None of the docs explain the window size, threshold, warning output, or the `diminishing_returns` log marker. The README env var table says only "Exit on low throughput (1=enabled)" and the man page says "Exit early on low throughput (default: 0, 1 to enable)". Operators cannot understand what "low throughput" means or predict when the guard fires. Add the rolling-window parameters and warning behavior to: the README env var description and a brief note in the Features list, the man page `TG_EARLY_EXIT_ON_STALL` entry, a new architecture.md section explaining the design rationale, and a user story or troubleshooting entry showing what the warning and early exit look like.
  **Files**: `README.md`, `man/taskgrind.1`, `docs/architecture.md`, `docs/user-stories.md`
  **Acceptance**: All four docs explain the 5-session rolling window, the <2-shipped threshold, the warning output, and the `diminishing_returns` log marker. The env var description in the README and man page gives operators enough information to decide whether to enable the guard.

- [ ] Add `status:` field to user-stories dry-run example and align with actual output
  **ID**: doc-dry-run-status-field
  **Tags**: docs, accuracy
  **Details**: The actual `--dry-run` output prints a `status:` line showing the `TG_STATUS_FILE` path or `disabled` (line 884 of `bin/taskgrind`), but user story 6 omits it from the example output. Add `status:   disabled` to the dry-run example in `docs/user-stories.md` between the `log:` and `notify:` lines so the example matches what a user actually sees.
  **Files**: `docs/user-stories.md`
  **Acceptance**: The dry-run example in story 6 includes the `status:` field and matches the actual output of `taskgrind --dry-run` for a run without `TG_STATUS_FILE`.

- [ ] Correct the README blocked-queue feature bullet to describe the wait-and-retry behavior
  **ID**: doc-blocked-queue-wait-behavior
  **Tags**: docs, accuracy, operator-facing
  **Details**: The README Features list says "**Blocked-queue detection** — exits early when all remaining tasks have `**Blocked by**:` metadata" but the implementation actually waits 600 s (10 min, capped at remaining deadline) for an external unblock, extends the deadline by the wait duration so no time budget is lost, re-checks the queue, and only then exits if still blocked. The wait, deadline extension, `blocked_wait` status phase, and re-check are all omitted. Update the feature bullet and add a brief mention in the troubleshooting table so operators know the grind will pause before giving up.
  **Files**: `README.md`
  **Acceptance**: The README blocked-queue bullet and troubleshooting table reflect the wait duration, deadline extension, and re-check behavior. The `blocked_wait` phase is mentioned as a healthy-idle state consistent with the status-file docs.

## P1
## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
## P3
