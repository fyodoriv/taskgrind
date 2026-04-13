# Tasks

## P0
- [ ] Turn final-sync edge cases into behavior-tested guarantees
  **ID**: behavior-test-final-sync-edge-cases
  **Tags**: testing, git, reliability
  **Details**: Final push protection is critical for unattended runs, but some `final_sync` paths are still mostly covered structurally instead of by realistic git behavior. Add bats coverage for duplicate-push suppression, nothing-to-push exits, and push-failure diagnostics so taskgrind can be trusted to shut down cleanly without extra operator babysitting.
  **Files**: `bin/taskgrind`, `tests/signals.bats`, `tests/git-sync.bats`
  **Acceptance**: Bats tests exercise real final-sync outcomes for duplicate attempts, zero-ahead shutdowns, and rejected pushes, and the resulting log/output expectations are locked in.
## P1
- [ ] Align discovery-lane test wording with the current guard terminology (@devin)
  **ID**: align-discovery-lane-test-wording
  **Tags**: docs, testing, audit
  **Details**: The audit-only guard now talks about supported discovery-lane standing-loop tasks, but `tests/session.bats` still names the happy-path case as a "removable audit task". Update the stale wording so the test suite and grep-based docs checks describe the same behavior taskgrind now enforces.
  **Files**: `tests/session.bats`
  **Acceptance**: The audit-only session test names use discovery-lane terminology consistently with the current guard wording, and the targeted bats suite still passes.
## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
## P3
