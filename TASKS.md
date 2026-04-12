# Tasks

## P0

## P1
- [ ] Avoid double final-sync pushes during signal shutdown
  **ID**: dedupe-final-sync-on-signal-shutdown
  **Tags**: bug, git, shutdown, logging
  **Details**: Recent logs also show duplicate `final_sync pushing...` and `final_sync push_ok` lines on SIGINT/SIGTERM shutdown. The signal path should perform one final push/log cycle, not one from `graceful_shutdown` and another from the EXIT trap.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/signals.bats`
  **Acceptance**: Add a failing test first; signal-driven shutdown emits at most one `final_sync` block per run; pending commits are still pushed before exit.
- [ ] Sync repos whose primary branch is not named main
  **ID**: support-nonmain-primary-branch-during-sync
  **Tags**: bug, git, multi-repo
  **Details**: Log review found `/Users/fivanishche/apps/ideas` hitting `git_sync checkout_failed: error: pathspec 'main' did not match any file(s) known to git` even though the session itself completed normally. The sync path should detect the repo's real primary branch (current branch, origin HEAD, or another safe fallback) instead of assuming `main`.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`
  **Acceptance**: Add a failing test first; git sync succeeds in a repo whose primary branch is `master` or another non-`main` name; logs no longer emit `checkout_failed ... pathspec 'main'` for that case.
- [ ] Recover cleanly from TASKS.md-only rebase conflicts during git sync
  **ID**: recover-from-tasks-md-sync-conflicts
  **Tags**: bug, git, tasks, multi-agent
  **Details**: Log review found `/Users/fivanishche/apps/oncall-hub-app` hitting `git_sync rebase_failed` because concurrent agents both edited `TASKS.md`. Taskgrind should treat queue-file conflicts as a common multi-agent case and recover without leaving the repo mid-rebase or silently degrading future sessions.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/resume.bats`
  **Acceptance**: Add a failing test first; a rebase conflict isolated to `TASKS.md` is either auto-resolved safely or aborted with a clean recovery path; later sessions start from a healthy git state and the logs explain what happened.
- [ ] Align GitHub Actions test caching with the current Makefile cache files
  **ID**: align-github-actions-test-cache
  **Tags**: ci, performance, maintenance
  **Details**: `.github/workflows/check.yml` still caches `.test-passed`, but `make test` now reads and writes per-target `.test-cache-*` files. Update CI so cache hits warm the files the Makefile actually uses and invalidate when shared test inputs change.
  **Files**: `.github/workflows/check.yml`, `Makefile`
  **Acceptance**: The workflow caches the active `.test-cache-*` files instead of stale paths, the cache key matches the current test inputs, and comments/docs reference only the live cache behavior.

## P2
- [ ] Bring the task-format docs up to the full tasks.md spec
  **ID**: document-full-tasks-md-metadata
  **Tags**: docs, onboarding, tasks
  **Details**: The README task-format example only shows `**ID**` and `**Details**`, even though this repo requires `**Tags**`, `**Files**`, and `**Acceptance**` metadata too. Update the docs so contributors can copy a valid task block without checking external rules first.
  **Files**: `README.md`, `CONTRIBUTING.md`, `man/taskgrind.1`
  **Acceptance**: The primary docs include a valid tasks.md example with the required metadata fields and explain optional `**Blocked by**` usage without contradicting the repo rules.
- [ ] Make the local audit workflow match the advertised empty-queue sweep
  **ID**: align-audit-target-with-sweep-contract
  **Tags**: audit, docs, dx
  **Details**: `README.md` and `CONTRIBUTING.md` describe `make audit` as the local version of the empty-queue audit, but the target only scans TODO/FIXME markers, runs shellcheck, and prints a docs queue. Either expand the target or narrow the docs so contributors know exactly which audit checks it reproduces.
  **Files**: `Makefile`, `README.md`, `CONTRIBUTING.md`, `docs/architecture.md`
  **Acceptance**: `make audit` output and repo docs describe the same checklist, and the documented local audit path is accurate for the empty-queue sweep behavior taskgrind advertises.
- [ ] Log the concrete cause when `productive_zero_ship` is triggered by queue churn
  **ID**: log-productive-zero-ship-cause
  **Tags**: logging, queue, reliability
  **Details**: Recent cross-repo log-audit sessions show `productive_zero_ship` still fires for normal queue maintenance when a task block was removed in another repo or sibling queue churn masked the local task delta. `taskgrind-2026-04-11-1835-taskgrind-28400.log` session 1 and session 23 both recorded `productive_zero_ship` despite real commits and task removals elsewhere, which keeps sending later sessions back to the same audit loop without telling the operator whether the zero-ship came from a local queue miss, a cross-repo task removal, or concurrent task injection. Split the old stuck accounting task into a smaller slice that only improves the classification and logging path.
  **Reviewed 2026-04-12 session 27**: `taskgrind-2026-04-11-1835-taskgrind-28400.log` session 26 still ended as `productive_zero_ship` immediately after a tasks-only audit refresh, and the current queue evidence no longer points to a forgotten task removal. The stale signal is still the shared shipped-session accounting path misclassifying productive queue maintenance, so keep the fix centralized in `taskgrind`.
  **Files**: `bin/taskgrind`, `tests/diagnostics.bats`, `tests/session.bats`
  **Acceptance**: When `productive_zero_ship` fires, the log explains whether the session removed no local task, removed a task in another repo, or lost the task delta because concurrent queue changes offset it; the reason text is specific enough to explain long zero-ship streaks in `.taskgrind-state`; regression coverage locks the new reason text.
- [ ] Stop launching repeated `remaining=0m` sessions after the deadline has already expired
  **ID**: stop-expired-deadline-zero-minute-loop
  **Tags**: deadline, runtime, reliability
  **Details**: The temporary repo logs from the latest audit still show taskgrind burning multiple no-op sessions with `remaining=0m` before it finally bails out. Examples include `taskgrind-2026-04-11-1805-repo-60489.log` (five back-to-back zero-minute sessions), `taskgrind-2026-04-11-1824-repo-18279.log`, and `taskgrind-2026-04-11-1939-repo-31627.log`. Replace the old broad expired-deadline follow-up with a tighter startup/loop guard so taskgrind notices an already-expired deadline before launching another backend session.
  **Reviewed 2026-04-12 session 27**: Re-reading the persisted temporary-repo logs still shows the same repeated launch pattern (`session=1..5 remaining=0m` in `repo-60489`, `session=1..3` in `repo-18279`, `session=1..4` in `repo-31627`). No newer downstream queue work displaced this fix; it remains a direct `taskgrind` runtime bug.
  **Reviewed 2026-04-12 session 31**: The same three persisted temp logs still show pure startup churn with no intervening useful work — exactly five `remaining=0m` launches in `repo-60489`, three in `repo-18279`, and four in `repo-31627`. This remains a repo-local runtime bug, so no downstream queue changes were added.
  **Files**: `bin/taskgrind`, `tests/session.bats`, `tests/diagnostics.bats`
  **Acceptance**: If the deadline is already in the past when a session would start, taskgrind exits cleanly without launching the backend or incrementing the session counter, and tests cover both startup-time and post-session expiry edges.
- [ ] Stop counting cross-repo task-only audit sessions as zero-ship stalls
  **ID**: stop-cross-repo-audit-zero-ship-stalls
  **Tags**: queue, audit, accounting, reliability
  **Details**: The latest log audit shows taskgrind's state accounting still treats some productive audit cycles as consecutive zero-ship sessions even when the operator is intentionally updating another repo's `TASKS.md` or running a standing queue-filling loop outside the local repo. During the latest review, `agentbrew/.taskgrind-state` still reported `status=running`, `session=30`, `tasks_shipped=5`, `sessions_zero_ship=25`, and `consecutive_zero_ship=23` while the shared audit flow was still producing queue work. Logging alone will help diagnosis, but taskgrind also needs a behavior change so cross-repo task-only sessions do not poison stall detection or keep replaying the same audit forever.
  **Reviewed 2026-04-12 session 27**: The downstream repos implicated by the logs are currently bad handoff targets for more queue churn, not new owners of the bug: `agentbrew`, `bosun`, and `ideas` all have live dirty worktrees, and the earlier repo-local log-audit task IDs are absent from their current `TASKS.md` snapshots. Keep the behavior fix centralized in `taskgrind` until the shipped-session accounting stops poisoning cross-repo audit runs.
  **Reviewed 2026-04-12 session 31**: The downstream ownership check still says "keep it centralized." `agentbrew`, `bosun`, and `ideas` all have active dirty worktrees, and the newest persisted `taskgrind` log keeps pointing at centralized accounting drift rather than a missing repo-local follow-up. `agentbrew/.taskgrind-state` climbing to `consecutive_zero_ship=32` while work continues is the clearest current reproduction.
  **Files**: `bin/taskgrind`, `.taskgrind-state`, `tests/session.bats`, `tests/diagnostics.bats`
  **Acceptance**: Taskgrind distinguishes a true local zero-ship stall from a productive cross-repo task-only audit cycle; `.taskgrind-state` no longer accumulates misleading consecutive zero-ship counts for that case; regression tests cover the new accounting path and preserve real stall detection.

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
