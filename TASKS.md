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
