# Tasks

## P0

## P1
## P2
- [ ] Add behavioral tests for macOS priority boosting and Linux no-op fallback
  **ID**: cover-fullpower-runtime
  **Tags**: tests, macos, runtime
  **Details**: `lib/fullpower.sh` is sourced in production to call `taskpolicy`, but there is no focused behavior test around `boost_priority`. Add coverage that proves taskgrind attempts the boost on macOS-capable systems and stays harmless when `taskpolicy` is unavailable.
  **Files**: `lib/fullpower.sh`, `tests/session.bats`, `tests/test_helper.bash`
  **Acceptance**: Tests demonstrate the boost path is invoked when `taskpolicy` exists and skipped cleanly otherwise, without introducing platform-specific flakes.

## P3
- [ ] Add a small audit helper target for repository sweeps
  **ID**: add-audit-helper-target
  **Tags**: tooling, docs, maintenance
  **Details**: Empty-queue sweeps are part of the product story, but there is no maintainer shortcut for running the same local checks this audit used (`TODO`/`FIXME` scan, shellcheck, focused docs review). Add a lightweight `make audit` or documented equivalent that helps contributors reproduce repo audits consistently.
  **Files**: `Makefile`, `CONTRIBUTING.md`, `README.md`
  **Acceptance**: Contributors have one documented command for the repo-audit workflow, and it completes using existing local tooling without network-only dependencies.
