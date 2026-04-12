# Tasks

## P0

## P1
## P2
- [ ] Add taskgrind startup coverage for the fullpower helper
  **ID**: cover-fullpower-session-integration
  **Tags**: tests, runtime, macos
  **Details**: The direct `boost_priority` behavior now has dedicated coverage, but the `bin/taskgrind` startup path still lacks an integration assertion that it sources `lib/fullpower.sh` and attempts the boost during process startup. Add a focused regression test around the startup wiring without depending on real macOS `taskpolicy`.
  **Files**: `bin/taskgrind`, `tests/session.bats`, `tests/test_helper.bash`
  **Acceptance**: A targeted test proves taskgrind sources the helper and tries to boost its own PID when a fake `taskpolicy` is available, without platform-specific flakes.

## P3
- [ ] Add a small audit helper target for repository sweeps
  **ID**: add-audit-helper-target
  **Tags**: tooling, docs, maintenance
  **Details**: Empty-queue sweeps are part of the product story, but there is no maintainer shortcut for running the same local checks this audit used (`TODO`/`FIXME` scan, shellcheck, focused docs review). Add a lightweight `make audit` or documented equivalent that helps contributors reproduce repo audits consistently. Latest log audit note: `taskgrind-2026-04-11-1358-taskgrind-37400.log` hit the skip threshold for this ID again in session 20 while another instance already had overlapping `Makefile` and doc edits in flight, so keep this as the queued owner instead of spawning more duplicate audit tasks.
  **Files**: `Makefile`, `CONTRIBUTING.md`, `README.md`
  **Acceptance**: Contributors have one documented command for the repo-audit workflow, and it completes using existing local tooling without network-only dependencies.
