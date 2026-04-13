# Tasks

## P0
## P1
## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
## P3
- [ ] Align the man page examples with the current CLI help output
  **ID**: sync-man-help-examples
  **Tags**: docs, manpage, dx
  **Details**: The README usage block follows the current `taskgrind --help` text, but `man/taskgrind.1` still shows stale examples like the old repo/hour ordering, a malformed `gpt-5-4` model string, and no `--resume` or short help/version alias examples. Update the man page examples and add regression coverage so future help-text changes do not leave the man page behind.
  **Files**: `man/taskgrind.1`, `tests/basics.bats`
  **Acceptance**: The man page example block reflects the current CLI help usage for repo/hour ordering, quoted multi-word models, `--resume`, and `--help / -h` / `--version / -V`; a bats test fails before the doc update and passes after it.
