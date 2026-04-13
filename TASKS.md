# Tasks

## P0
## P1
- [ ] Preserve terminal stop reasons in `TG_STATUS_FILE` so operators can distinguish clean completion from blocked or empty-queue exits
  **ID**: preserve-status-terminal-reasons
  **Tags**: observability, status-file, dx
  **Details**: The JSON status file currently ends at `complete` even when the grind actually stopped because the queue stayed blocked or empty. Preserve the final stop reason in the status snapshot so dashboards and humans can tell why a clean run stopped without tailing logs.
  **Files**: `bin/taskgrind`, `tests/logging.bats`, `README.md`, `man/taskgrind.1`
  **Acceptance**: A blocked-queue run leaves a machine-readable terminal reason in the status file, coverage proves it, and the operator docs explain the new field.
## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
## P3
