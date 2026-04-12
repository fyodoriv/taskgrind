# Tasks

## P0

## P1
## P2
- [ ] Log the concrete cause when `productive_zero_ship` is triggered by queue churn
  **ID**: log-productive-zero-ship-cause
  **Tags**: logging, queue, reliability
  **Details**: Recent cross-repo log-audit sessions show `productive_zero_ship` still fires for normal queue maintenance when a task block was removed in another repo or sibling queue churn masked the local task delta. `taskgrind-2026-04-11-1835-taskgrind-28400.log` session 1 and session 23 both recorded `productive_zero_ship` despite real commits and task removals elsewhere, which keeps sending later sessions back to the same audit loop without telling the operator whether the zero-ship came from a local queue miss, a cross-repo task removal, or concurrent task injection. Split the old stuck accounting task into a smaller slice that only improves the classification and logging path.

  **Reviewed 2026-04-12 session 26**: The latest persisted audit still points back to `taskgrind` rather than downstream repos. `agentbrew` and `bosun` continue to show real task removals getting cancelled out by queue churn, while `ideas` mixes its no-remote workflow with the same accounting blind spot. Keep the fix here and do not spawn repo-local workaround tasks unless the logs stop pointing at shared shipped-session accounting.
  **Files**: `bin/taskgrind`, `tests/diagnostics.bats`, `tests/session.bats`
  **Acceptance**: When `productive_zero_ship` fires, the log explains whether the session removed no local task, removed a task in another repo, or lost the task delta because concurrent queue changes offset it; regression coverage locks the new reason text.

- [ ] Stop launching repeated `remaining=0m` sessions after the deadline has already expired
  **ID**: stop-expired-deadline-zero-minute-loop
  **Tags**: deadline, runtime, reliability
  **Details**: The temporary repo logs from the latest audit still show taskgrind burning multiple no-op sessions with `remaining=0m` before it finally bails out. Examples include `taskgrind-2026-04-11-1805-repo-60489.log` (five back-to-back zero-minute sessions), `taskgrind-2026-04-11-1824-repo-18279.log`, and `taskgrind-2026-04-11-1939-repo-31627.log`. Replace the old broad expired-deadline follow-up with a tighter startup/loop guard so taskgrind notices an already-expired deadline before launching another backend session.
  **Files**: `bin/taskgrind`, `tests/session.bats`, `tests/diagnostics.bats`
  **Acceptance**: If the deadline is already in the past when a session would start, taskgrind exits cleanly without launching the backend or incrementing the session counter, and tests cover both startup-time and post-session expiry edges.

## P3
- [ ] Add a small audit helper target for repository sweeps
  **ID**: add-audit-helper-target
  **Tags**: tooling, docs, maintenance
  **Details**: Empty-queue sweeps are part of the product story, but there is no maintainer shortcut for running the same local checks this audit used (`TODO`/`FIXME` scan, shellcheck, focused docs review). Add a lightweight `make audit` or documented equivalent that helps contributors reproduce repo audits consistently. Latest log audit note: `taskgrind-2026-04-11-1358-taskgrind-37400.log` hit the skip threshold for this ID again in session 20 while another instance already had overlapping `Makefile` and doc edits in flight, so keep this as the queued owner instead of spawning more duplicate audit tasks.
  **Files**: `Makefile`, `CONTRIBUTING.md`, `README.md`
  **Acceptance**: Contributors have one documented command for the repo-audit workflow, and it completes using existing local tooling without network-only dependencies.
