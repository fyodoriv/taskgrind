# Tasks

## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.

## P3

- [ ] Error messages for common failures include actionable next-step guidance
  **ID**: test-error-message-quality
  **Tags**: tests, error-messages, ux
  **Details**: Several taskgrind error paths surface a reason but not a remediation. Examples: `Error: --model requires a name` (line 161) doesn't show a valid model; `Backend binary not found (devin)` (line 664) doesn't point at install docs. Most users see these once and bounce. Raise the floor by covering 5+ error paths with tests that assert each message mentions (a) what went wrong, (b) what to do next, (c) a doc link or example where relevant. The test itself becomes the spec for "a good error message" in this repo.
  **Files**: `tests/diagnostics.bats`, `bin/taskgrind`
  **Acceptance**: At least five error paths (missing backend, invalid model, invalid numeric env var, missing repo path, unsupported backend) have tests asserting the error includes both the cause and an actionable next step. Any new error path added after this task is expected to pass the same pattern.
