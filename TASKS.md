# Tasks

## P0

## P1
- [ ] Align installer update guidance with the repo's rebase-based sync instructions (@devin-1)
  **ID**: align-installer-update-guidance
  **Tags**: install, docs, git, consistency
  **Details**: `install.sh` still tells users with an existing install to run `git pull`, while the README already documents `git pull --rebase` for manual updates. Tighten that user-facing guidance so fresh installs and reinstall checks point to the same safer update flow.
  **Files**: `install.sh`, `tests/install.bats`, `tests/installer-output.bats`
  **Acceptance**: Existing-install output recommends `git pull --rebase`; regression tests cover the normal path and an install directory containing spaces.

- [ ] Recover cleanly when git sync rebases across concurrent `TASKS.md` edits
  **ID**: recover-from-tasks-md-sync-conflicts
  **Tags**: git-sync, tasks-md, reliability
  **Details**: The 2026-04-12 `oncall-hub-app` grind logs (`taskgrind-2026-04-12-0806-oncall-hub-app-21210.log` and `taskgrind-2026-04-12-1109-oncall-hub-app-32431.log`) repeatedly show `git_sync rebase_failed` / `git_sync rebase_aborted` because replayed commits hit `TASKS.md` content conflicts while multiple sessions were removing or decomposing task blocks. The same family shows up in the `taskgrind` audit log (`taskgrind-2026-04-12-0806-taskgrind-19844.log`) and the later `bosun` run (`taskgrind-2026-04-12-0807-bosun-22061.log`), where the repo kept looping through the same `TASKS.md` conflict family at 08:34, 09:03, 10:54, and even a later `pre_session_recovery rebase_aborted` at 15:25. Add a conflict-tolerant sync path for `TASKS.md` so routine queue churn does not poison the entire sync cycle.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/session.bats`, `README.md`, `docs/resume-state.md`
  **Acceptance**: A targeted sync test reproduces concurrent `TASKS.md` edits and shows taskgrind preserving local queue changes without leaving the repo mid-rebase; logs explain the recovery path; normal non-conflict sync behavior remains unchanged.

- [ ] Classify git-sync rebase conflicts consistently in operator logs
  **ID**: classify-git-sync-rebase-conflicts
  **Tags**: git-sync, logging, reliability
  **Details**: The 2026-04-12 `agentbrew` log (`taskgrind-2026-04-12-0806-agentbrew-19027.log`) shows `git_sync rebase_failed` on `docs/COMPETITION.md` with no machine-readable conflict class, and the later `bosun` log (`taskgrind-2026-04-12-0807-bosun-22061.log`) repeats raw `TASKS.md` conflict failures without the queue-specific class at 08:34, 09:03, and 10:54 before ending with another unclassified `pre_session_recovery rebase_aborted` at 15:25. Meanwhile the later `oncall-hub-app` log (`taskgrind-2026-04-12-1109-oncall-hub-app-32431.log`) already emits `class=queue_only paths=TASKS.md` for the same rebase-failure family. Make the conflict classification consistent across git-sync and pre-session recovery paths so operators can immediately tell whether a rebase failed on queue churn (`TASKS.md`) or a broader repo conflict that needs manual attention.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/session.bats`, `README.md`
  **Acceptance**: Rebase-failure logs always include a stable conflict class plus the conflicting paths; tests cover both `TASKS.md`-only conflicts and non-queue file conflicts; pre-session recovery and regular git-sync reuse the same logging format.

- [ ] Surface the root stash failure instead of only logging `stash_pop_failed`
  **ID**: surface-git-stash-failures
  **Tags**: git-sync, logging, reliability
  **Details**: The 2026-04-12 `agentbrew` log (`taskgrind-2026-04-12-0806-agentbrew-19027.log`) and `bosun` log (`taskgrind-2026-04-12-0807-bosun-22061.log`) both hit repeated `git_sync stash_pop_failed (stash preserved)` lines without the original `git stash` error. The agentbrew run hit it at least twice (12:03 and 13:33), while the bosun run hit the same opaque message multiple times again later in the day (11:51, 14:29, and 15:07), so the operator still cannot tell whether the stash command failed, the pop failed after a successful stash, or dirty-state bookkeeping was wrong. Teach git sync to log the actual stash failure reason and only attempt `stash pop` when a stash was created successfully.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `README.md`
  **Acceptance**: Git-sync logs the original stash failure stderr when stash creation fails; `stash pop` is skipped unless a stash was actually created; targeted tests cover both stash-create failure and stash-pop failure paths without regressing normal dirty-tree sync.

## P2
## P3
