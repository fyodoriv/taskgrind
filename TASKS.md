# Tasks

## P0

## P1
- [ ] Detect the repo's real default branch during git sync instead of assuming `main`
  **ID**: detect-default-branch-during-sync
  **Tags**: git-sync, reliability, multi-repo
  **Details**: The 2026-04-12 `ideas` grind log (`taskgrind-2026-04-12-0806-ideas-17272.log`) repeatedly hit `git_sync checkout_failed: error: pathspec 'main' did not match any file(s) known to git` at sessions 5, 10, 16, 20, 25, 30, 35, 40, 45, and 50. Taskgrind still hard-codes `main` in at least one sync path, which breaks repos whose primary branch is something else. Teach sync to resolve the repo's default branch from git metadata or the current upstream branch before checkout/rebase, while preserving explicit overrides for tests.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `README.md`, `docs/architecture.md`
  **Acceptance**: Git sync succeeds in a repo whose primary branch is not `main`; targeted tests cover auto-detecting the branch name; docs describe the branch-selection behavior and any override escape hatch.

- [ ] Recover cleanly when git sync rebases across concurrent `TASKS.md` edits
  **ID**: recover-from-tasks-md-sync-conflicts
  **Tags**: git-sync, tasks-md, reliability
  **Details**: The 2026-04-12 `oncall-hub-app` grind logs (`taskgrind-2026-04-12-0806-oncall-hub-app-21210.log` and `taskgrind-2026-04-12-1109-oncall-hub-app-32431.log`) repeatedly show `git_sync rebase_failed` / `git_sync rebase_aborted` because replayed commits hit `TASKS.md` content conflicts while multiple sessions were removing or decomposing task blocks. Add a conflict-tolerant sync path for `TASKS.md` so routine queue churn does not poison the entire sync cycle.
  **Files**: `bin/taskgrind`, `tests/git-sync.bats`, `tests/session.bats`, `README.md`, `docs/resume-state.md`
  **Acceptance**: A targeted sync test reproduces concurrent `TASKS.md` edits and shows taskgrind preserving local queue changes without leaving the repo mid-rebase; logs explain the recovery path; normal non-conflict sync behavior remains unchanged.

- [ ] Avoid running final git push twice during shutdown cleanup
  **ID**: dedupe-final-sync-on-signal-shutdown
  **Tags**: shutdown, git-sync, reliability
  **Details**: The 2026-04-12 logs for `oncall-hub-app` (`taskgrind-2026-04-12-0806-oncall-hub-app-21210.log`, `taskgrind-2026-04-12-0806-oncall-hub-app-21543.log`) and `bosun` (`taskgrind-2026-04-12-0806-bosun-18073.log`) show `final_sync pushing` being logged twice for the same commit set during shutdown. One run even surfaced a misleading `push_failed` line before the second push succeeded. Guard cleanup so final sync is idempotent per process and only emits one push attempt/result pair unless new commits appear after the first push.
  **Files**: `bin/taskgrind`, `tests/signals.bats`, `tests/git-sync.bats`, `README.md`
  **Acceptance**: Shutdown paths log at most one final-sync push for an unchanged commit set; tests cover both normal exit and signal-driven cleanup; misleading duplicate push failure/success pairs no longer appear in the log.

## P2
- [ ] Document the uncached `make test-force` rerun path in contributor docs (@devin)
  **ID**: document-test-force-rerun-path
  **Tags**: docs, tests, developer-experience
  **Details**: `Makefile` exposes `make test-force`, but the contributor-facing docs only mention `make test` and targeted `TESTS=...` runs. Add a regression test that enforces docs parity for the uncached rerun path, then update the relevant docs so maintainers can discover the command from the usual development references.
  **Files**: `tests/basics.bats`, `README.md`, `CONTRIBUTING.md`, `man/taskgrind.1`, `TASKS.md`
  **Acceptance**: The docs mention `make test-force` alongside the standard test workflow, and a repo test fails if that parity drifts again.

## P3
