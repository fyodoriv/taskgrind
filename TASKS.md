# Tasks

## P0

## P1
- [ ] Use the repo's real default branch before queue-empty sweep recovery
  **ID**: use-default-branch-for-empty-queue-recovery
  **Tags**: bug, git, sweep, multi-repo
  **Details**: Log review found queue-empty recovery still assumes a local `main` branch even in repos that only have `master`. `taskgrind-2026-04-12-0806-ideas-17272.log` session 15 shipped the final queued task (`tasks_after=0`) and then immediately logged `git_sync checkout_failed: error: pathspec 'main' did not match any file(s) known to git` before launching the sweep session. Taskgrind already learned how to detect non-`main` sync branches for regular git sync, but the empty-queue handoff path still hardcodes `main`, which adds noisy failure logs and risks skipping cleanup in repos whose default branch differs.
  **Reviewed 2026-04-12 session 16**: The live fleet snapshot still backs this as a real follow-up, not just a stale `ideas` one-off. `taskgrind`, `agentbrew`, `bosun`, and `oncall-hub-app` all still resolve `origin/HEAD` to `main`, but `ideas` currently has no `origin/HEAD` at all and only exposes `standing-ideas-gap-loop` plus `audit/restore-ideas-delivery-remote` remote refs. With `ideas/.taskgrind-state` back to `consecutive_zero_ship=0`, the remaining risk is no longer a wedged session; it is the centralized empty-queue recovery path still assuming a local `main` checkout whenever a repo's default branch metadata differs or is missing.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/session.bats`
  **Acceptance**: Add a failing test first; when the queue reaches zero in a repo whose default branch is not `main`, taskgrind switches back to the detected default branch without `checkout_failed`; the sweep session still launches normally afterward.
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
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/resume.bats`
  **Acceptance**: Add a failing test first; a rebase conflict isolated to `TASKS.md` is either auto-resolved safely or aborted with a clean recovery path; later sessions start from a healthy git state and the logs explain what happened.
## P2
## P3
