# Tasks

## P0

## P1
- [ ] Avoid double final-sync pushes during signal shutdown
  **ID**: dedupe-final-sync-on-signal-shutdown
  **Tags**: bug, git, shutdown, logging
  **Details**: Recent logs also show duplicate `final_sync pushing...` and `final_sync push_ok` lines on SIGINT/SIGTERM shutdown. The signal path should perform one final push/log cycle, not one from `graceful_shutdown` and another from the EXIT trap.
  **Reviewed 2026-04-12 session 7**: `taskgrind-2026-04-12-0806-bosun-18073.log` still captures the same duplicate shutdown pattern in a fresh one-session run: a single `graceful_shutdown session_finished` is followed by repeated `final_sync pushing commits=7` and `final_sync push_ok` pairs. The repro is still isolated to `taskgrind`'s shutdown/final-sync interaction, not repo-local Bosun behavior.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/signals.bats`
  **Acceptance**: Add a failing test first; signal-driven shutdown emits at most one `final_sync` block per run; pending commits are still pushed before exit.
- [ ] Recover cleanly from TASKS.md-only rebase conflicts during git sync
  **ID**: recover-from-tasks-md-sync-conflicts
  **Tags**: bug, git, tasks, multi-agent
  **Details**: Log review found `/Users/fivanishche/apps/oncall-hub-app` hitting `git_sync rebase_failed` because concurrent agents both edited `TASKS.md`. Taskgrind should treat queue-file conflicts as a common multi-agent case and recover without leaving the repo mid-rebase or silently degrading future sessions.
  **Reviewed 2026-04-12 session 7**: `taskgrind-2026-04-12-0806-oncall-hub-app-21210.log` still shows the same queue-file failure mode during the 08:06 fan-out: session 5 hit `git_sync rebase_failed` on `TASKS.md CONFLICT (content)` immediately after an audit session that added and removed temporary task blocks. This remains a current multi-agent rebase recovery gap, not just a stale historical log.
  **Reviewed 2026-04-12 session 13**: The current fan-out now reproduces the same failure in `taskgrind` itself, not just downstream repos. `taskgrind-2026-04-12-0806-taskgrind-19844.log` shows session 5 ending with `git_sync rebase_failed` on `TASKS.md CONFLICT (content)` while replaying `fix: guard expired deadline relaunch`, followed by `git_sync rebase_aborted` and `pre_session_recovery rebase_aborted` before later sessions continue shipping. That means the recovery path avoids a permanently wedged worktree, but the core queue-file conflict is still reproducible and still needs a first-class resolution path plus clearer operator logging.
  **Reviewed 2026-04-12 session 15**: The latest oncall-hub-app run keeps the same conflict alive after more task-removal churn. `taskgrind-2026-04-12-0806-oncall-hub-app-21210.log` session 15 added and removed a focused deploy-env task block, then ended with `git_sync rebase_failed` on `TASKS.md CONFLICT (content)` and `git_sync rebase_aborted` again before session 16 resumed. The worktree recovery is good enough to keep the repo moving, but the TASKS-only conflict path is still reproducible in a fresh log after multiple downstream task edits.
  **Reviewed 2026-04-12 session 16**: The current cross-repo health check suggests the existing abort-and-recover path is containing fallout, but not solving the root cause. `taskgrind`, `agentbrew`, `bosun`, `ideas`, and `oncall-hub-app` all currently report a clean git state with no `REBASE_HEAD`, and every `.taskgrind-state` file is back to `consecutive_zero_ship=0`; however that just means the fleet recovered after the last conflict. The open gap is still first-class handling for the next TASKS-only rebase collision so operators get a cleaner explanation than "rebase failed, later sessions happened to recover."
  **Reviewed 2026-04-12 session 20**: `taskgrind-2026-04-12-0807-bosun-22061.log` confirms the same queue-file collision is still happening in high-throughput repos. Sessions 5 and 10 both ended with `git_sync rebase_failed` on `TASKS.md CONFLICT (content)` while replaying the audit commit `chore: record tmux session-loss audit gap AIFN-720`, then immediately logged `git_sync rebase_aborted` before later sessions resumed. That broadens the repro from `oncall-hub-app` and `taskgrind` to `bosun`, so the issue is clearly a fleet-level TASKS churn gap rather than one repo's local workflow.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/resume.bats`
  **Acceptance**: Add a failing test first; a rebase conflict isolated to `TASKS.md` is either auto-resolved safely or aborted with a clean recovery path; later sessions start from a healthy git state and the logs explain what happened.
## P2
- [ ] Classify git-sync rebase conflicts by file type in operator logs
  **ID**: classify-rebase-conflicts-in-logs
  **Tags**: bug, git, logging, multi-agent
  **Details**: The 2026-04-12 fleet logs now show two materially different conflict classes collapsing into the same `git_sync rebase_failed` / `git_sync rebase_aborted` story. `taskgrind-2026-04-12-0806-oncall-hub-app-21210.log` and `taskgrind-2026-04-12-0807-bosun-22061.log` show the known queue-only `TASKS.md CONFLICT (content)` path, while `taskgrind-2026-04-12-0806-agentbrew-19027.log` shows the same operator-facing output for a general repo conflict in `docs/COMPETITION.md`. Taskgrind should log which files conflicted and whether the failure is queue-only or a broader repo merge problem so operators know when the right next step is TASKS recovery versus manual repo conflict resolution.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/resume.bats`
  **Acceptance**: Add a failing test first; git-sync conflict logs include the conflicted path list; queue-only conflicts are labeled distinctly from general repo conflicts; general conflicts still abort cleanly into a healthy next session state.

- [ ] Drop stale skip-threshold history when task IDs disappear from the queue
  **ID**: prune-stale-skipped-task-attempts
  **Tags**: bug, tasks, logging, multi-agent
  **Details**: The latest logs still emit `task_skip_threshold` warnings for task IDs that are no longer actionable in the live queue. `taskgrind-2026-04-12-0806-ideas-17272.log` reports `control-tower-boundary-review` even though that ID is no longer in `ideas/TASKS.md`, and `taskgrind-2026-04-12-0806-taskgrind-20411.log` reports skipped IDs such as `align-audit-target-with-sweep-contract` after those temporary audit tasks were already removed. Taskgrind should prune or expire attempt history when a task ID disappears so operators do not chase stale skip-threshold noise from already-removed work.
  **Files**: `bin/taskgrind`, `tests/resume.bats`, `tests/logging.bats`
  **Acceptance**: Add a failing test first; removed task IDs stop contributing to future `task_skip_threshold` output; active long-lived skipped tasks still retain their attempt history; logs stay focused on currently actionable queue items.
## P3
