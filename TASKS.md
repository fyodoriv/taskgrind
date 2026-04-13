# Tasks

## P0
- [ ] Turn final-sync edge cases into behavior-tested guarantees
  **ID**: behavior-test-final-sync-edge-cases
  **Tags**: testing, git, reliability
  **Details**: Final push protection is critical for unattended runs, but some `final_sync` paths are still mostly covered structurally instead of by realistic git behavior. Add bats coverage for duplicate-push suppression, nothing-to-push exits, and push-failure diagnostics so taskgrind can be trusted to shut down cleanly without extra operator babysitting.
  **Files**: `bin/taskgrind`, `tests/signals.bats`, `tests/git-sync.bats`
  **Acceptance**: Bats tests exercise real final-sync outcomes for duplicate attempts, zero-ahead shutdowns, and rejected pushes, and the resulting log/output expectations are locked in.
## P1
## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
- [ ] Refresh stale model examples in operator docs
  **ID**: refresh-model-example-docs
  **Tags**: docs, examples, operators
  **Details**: Several sample outputs still show older Claude model IDs in dry-run, preflight, and model-switching examples even though taskgrind now defaults to `gpt-5.4` and documents short aliases. Refresh those examples so operators do not mistake illustrative samples for the current default configuration.
  **Files**: `README.md`, `docs/user-stories.md`, `man/taskgrind.1`
  **Acceptance**: Sample output and example commands use current default-model wording or explicit alias-based examples consistently, without implying that `claude-opus-4-6` is the default.
## P3
