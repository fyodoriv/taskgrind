# Tasks

## P2

- [ ] `extract_task_signatures()` and `extract_task_checkbox_changes()` have direct unit-style test coverage
  **ID**: test-queue-churn-helpers-coverage
  **Tags**: tests, queue, churn-detection, shipped-inference
  **Details**: `extract_task_signatures()` (`bin/taskgrind:1448`) produces a sorted `task_line|||task_id` snapshot used to detect productive zero-ship work, and `extract_task_checkbox_changes()` (`bin/taskgrind:1485`) scans a commit range for `- [ ]` additions/removals in a given `TASKS.md` path. They power the `shipped_inferred` and `productive_zero_ship` log markers that keep stall detection honest when the queue churns. Today they are only exercised through the integration tests in `tests/session.bats` (`inferred shipped: *`, `productive zero-ship: *`). Add table-driven unit tests that extract each function via `awk` and run it against fixture files / fixture git repos so a regression surfaces with a clear diff.
  **Files**: `tests/session.bats`, `tests/task-attempts.bats`
  **Acceptance**: (1) `extract_task_signatures` is covered for: no tasks, one task without `**ID**:`, one task with `**ID**:`, multiple tasks (sorted output), and a task with Windows-style line endings. (2) `extract_task_checkbox_changes` is covered for: no commits in range, commit that only adds `- [ ]`, commit that only removes `- [ ]`, commit that does both, commit that touches a different file. (3) Tests follow the `awk '/^<fn>\(\) \{/,/^}$/'` extract pattern established elsewhere in the suite.

- [ ] `format_conflict_paths_for_log()` and `emit_rebase_conflict_logs()` have direct unit-style test coverage
  **ID**: test-rebase-conflict-log-formatters
  **Tags**: tests, git, rebase, logging
  **Details**: `format_conflict_paths_for_log()` (`bin/taskgrind:1723`) and `emit_rebase_conflict_logs()` (`bin/taskgrind:1741`) turn raw `git status --porcelain` conflict output into the structured `rebase_conflict paths=<...> class=<queue_only|repo|unknown>` log line the `grind-log-analyze` skill parses (`.devin/skills/grind-log-analyze/SKILL.md:104-117`). The only current coverage is a structural grep in `tests/features.bats:509`. A silent regression in the log format would break every downstream post-mortem without any bats failure. Add direct tests that source the function, feed conflict path fixtures (single queue path, multiple queue paths, mixed queue + repo file, CRLF line endings, binary-only conflict), and assert the exact log line shape.
  **Files**: `tests/git-sync.bats`
  **Acceptance**: New tests cover at least five fixture inputs for `format_conflict_paths_for_log` and three for `emit_rebase_conflict_logs`, asserting both the emitted log substring (`rebase_conflict paths=...`) and its category (`queue_only`, `repo`, `unknown`). The `grind-log-analyze` skill's parser expectations at `.devin/skills/grind-log-analyze/SKILL.md:104-117` keep matching the exercised formatter outputs.

- [ ] `slot_lock_pid()` and `slot_lock_active()` have direct unit-style test coverage
  **ID**: test-slot-lock-helpers
  **Tags**: tests, multi-instance, locking
  **Details**: `slot_lock_pid()` (`bin/taskgrind:641`) and `slot_lock_active()` (`bin/taskgrind:647`) are the probe helpers that `--preflight` uses to report `slots: N/M active` and that the multi-instance path uses to detect stale locks. They are tested only through the full concurrent grind flows in `tests/multi-instance.bats`. A regression that always returned "lock not active" would silently break the "all slots full" refusal and pass the higher-level tests. Add direct coverage: write a fake lock file with a live pid (the bats runner itself) vs a dead pid (a recycled pid that no longer exists) and assert the return code / printed pid.
  **Files**: `tests/multi-instance.bats`
  **Acceptance**: (1) A test proves `slot_lock_pid` prints the pid from a valid lock file and returns 1 on a missing/empty file. (2) A test proves `slot_lock_active` returns 0 for a live pid and 1 for a clearly-dead pid (use a fixture pid that is guaranteed not to exist, e.g. the highest unused value on Linux/macOS). (3) Tests source the functions via `awk` extract, matching the existing pattern.

- [ ] `grind-log-analyze` skill parses every log marker `bin/taskgrind` actually emits today
  **ID**: audit-grind-log-analyze-markers
  **Tags**: docs, skills, grind-log, log-format
  **Details**: `.devin/skills/grind-log-analyze/SKILL.md` lists the log events the parser should extract (Phase 2.2 / 2.3 / 2.4). Recently added markers — `task_skip_threshold ids=<id>`, `productive_timeout session=N shipped=X timeout=Ys new_timeout=Zs (at cap)`, `auto_resolve_tasks_conflicts`, `live_model=...`, `live_prompt=...`, `graceful_shutdown duplicate_signal`, `final_sync push_ok`/`push_failed`, and the `blocked_wait`/`audit_focus_blocked`/`queue_refilled` phase markers — are all referenced by docs but the skill's parse table may be stale. Grep the script and the user stories for every `log_write`/status `set_phase` marker, cross-check against the skill, and either expand the parser tables so the skill matches reality or add a regression guard (bats test that lists every known marker and asserts the skill mentions each one).
  **Files**: `.devin/skills/grind-log-analyze/SKILL.md`, `tests/basics.bats`, `tests/features.bats`
  **Acceptance**: (1) The skill's Phase 2 parser tables mention every `log_write` marker currently emitted by `bin/taskgrind`, including the `task_skip_threshold`, `productive_timeout … (at cap)`, `auto_resolve_tasks_conflicts`, `live_model`/`live_prompt`, `graceful_shutdown duplicate_signal`, `final_sync push_*`, and `queue_refilled` / `blocked_wait` / `audit_focus_blocked` phase markers. (2) A bats test extracts the set of marker tokens from `bin/taskgrind` and fails when one is missing from the skill's markdown tables, so future additions can't drift again.

## P3

- [ ] Repo ships a `.editorconfig` so contributors get consistent indentation in shell, bats, and markdown files
  **ID**: add-editorconfig
  **Tags**: dx, style, onboarding
  **Details**: The taskgrind tree mixes `bin/` bash (2-space indent), `tests/*.bats` (2-space indent), `lib/*.sh` (2-space indent), and markdown. Contributors using editors that honor `.editorconfig` (VS Code, JetBrains, Vim plugins) would set indentation correctly on first open. Today there is none. Both the `dotfiles` and `tasks.md` sibling repos ship one. Add `.editorconfig` with one entry per file type and document it in `CONTRIBUTING.md`.
  **Files**: `.editorconfig`, `CONTRIBUTING.md`
  **Acceptance**: A new `.editorconfig` covers `*.{sh,bash,bats}` (2-space indent, LF line endings, final newline), `*.md` (preserve trailing spaces for hard breaks, LF line endings, final newline), and `Makefile` (tab indentation, 8-char width). `CONTRIBUTING.md` mentions it in the Quick Start or Project Structure section. `make check` still passes.


