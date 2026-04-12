# Tasks

## P0

## P1
## P2
- [ ] Log the concrete cause when `productive_zero_ship` is triggered by queue churn
  **ID**: log-productive-zero-ship-cause
  **Tags**: logging, queue, reliability
  **Details**: Recent cross-repo log-audit sessions show `productive_zero_ship` still fires for normal queue maintenance when a task block was removed in another repo or sibling queue churn masked the local task delta. `taskgrind-2026-04-11-1835-taskgrind-28400.log` session 1 and session 23 both recorded `productive_zero_ship` despite real commits and task removals elsewhere, which keeps sending later sessions back to the same audit loop without telling the operator whether the zero-ship came from a local queue miss, a cross-repo task removal, or concurrent task injection. Split the old stuck accounting task into a smaller slice that only improves the classification and logging path.

  **Reviewed 2026-04-12 session 27**: `taskgrind-2026-04-11-1835-taskgrind-28400.log` session 26 still ended as `productive_zero_ship` immediately after a tasks-only audit refresh, and the current queue evidence no longer points to a forgotten task removal. The stale signal is still the shared shipped-session accounting path misclassifying productive queue maintenance, so keep the fix centralized in `taskgrind`.
  **Files**: `bin/taskgrind`, `tests/diagnostics.bats`, `tests/session.bats`
  **Acceptance**: When `productive_zero_ship` fires, the log explains whether the session removed no local task, removed a task in another repo, or lost the task delta because concurrent queue changes offset it; the reason text is specific enough to explain long zero-ship streaks in `.taskgrind-state`; regression coverage locks the new reason text.

## P3
- [ ] Add a small audit helper target for repository sweeps
  **ID**: add-audit-helper-target
  **Tags**: tooling, docs, maintenance
  **Details**: Empty-queue sweeps are part of the product story, but there is no maintainer shortcut for running the same local checks this audit used (`TODO`/`FIXME` scan, shellcheck, focused docs review). Add a lightweight `make audit` or documented equivalent that helps contributors reproduce repo audits consistently. Latest log audit note: `taskgrind-2026-04-11-1358-taskgrind-37400.log` hit the skip threshold for this ID again in session 20 while another instance already had overlapping `Makefile` and doc edits in flight, so keep this as the queued owner instead of spawning more duplicate audit tasks.
  **Files**: `Makefile`, `CONTRIBUTING.md`, `README.md`
  **Acceptance**: Contributors have one documented command for the repo-audit workflow, and it completes using existing local tooling without network-only dependencies.

- [ ] Document `--resume` in the man-page synopsis and lock it with a regression test
  **ID**: document-resume-synopsis
  **Tags**: docs, manpage, testing
  **Details**: The man-page synopsis should match the CLI and README by listing `--resume`, and the repo should keep a small regression test that catches future drift in `man/taskgrind.1`.
  **Files**: `man/taskgrind.1`, `tests/basics.bats`
  **Acceptance**: `man/taskgrind.1` lists `--resume` in the synopsis and `tests/basics.bats` fails if that entry disappears.
