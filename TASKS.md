# Tasks

## P0

- [ ] `preflight validates models through claude-code backend resolution` test fixture matches the current backend-probe contract
  **ID**: fix-preflight-claude-code-probe-fixture
  **Tags**: tests, preflight, backend-probe, regression
  **Details**: `tests/preflight.bats:257-277` installs a fake `claude` binary via `_install_fake_backend_binary` whose `--version` path writes the received argv to the invoke log and exits 0 with no stdout. After commit `e87d0ac fix: probe backend startup failures early`, `backend_probe` rejects that shape as "backend binary may be a stub or broken: exited in 0s with no output when running --version". The probe fires before model validation, so the test's expected `backend said invalid model: invalid-model` stderr is never produced. The suite currently reports `not ok 450 preflight validates models through claude-code backend resolution` under `make check`, and the same test fails deterministically in isolation (`bats tests/preflight.bats -f "preflight validates models through claude-code backend resolution"`). Either teach the fixture to emit a version string on `--version` or refactor the test to assert both the probe and the model-validation path in order. Whichever fix we pick, the fake must match the shape the probe enforces (non-empty stdout, exit 0) so model validation can still run.
  **Files**: `tests/preflight.bats`
  **Acceptance**: `bats tests/preflight.bats -f "preflight validates models through claude-code"` passes locally and under `make check` without re-disabling the probe. The fake binary still writes one line per invocation to `DVB_GRIND_INVOKE_LOG` so the invocation-count assertion at `tests/preflight.bats:274` keeps protecting the probe-then-validate ordering.

## P1

- [ ] Test flakiness in `TG_STATUS_FILE writes status snapshots` and `does not launch another session after the deadline expires during pre-session setup` is fixed or quarantined
  **ID**: stabilize-flaky-full-suite-tests
  **Tags**: tests, flakiness, ci
  **Details**: Running `make check` locally with the auto-capped `TEST_JOBS=6` reports two intermittent failures in otherwise green runs: `not ok 318 TG_STATUS_FILE writes status snapshots` (asserts `last_session.result == "success"` at `tests/logging.bats:111-123`) and `not ok 510 does not launch another session after the deadline expires during pre-session setup` (`tests/session.bats:609-615`). Both pass deterministically when run in isolation with `bats tests/logging.bats -f "TG_STATUS_FILE writes"` and `bats tests/session.bats -f "does not launch another session"`. That points at parallel-load contention (CPU pressure changing the race window rather than a real product bug). Reproduce under `TEST_JOBS=6`, find the shared-resource contention (likely `DVB_DEADLINE` timing or shared `$DVB_GRIND_INVOKE_LOG` path when tests share `$TEST_DIR` under stress), and either make the test deterministic or move the offending test into a serial phase. `CONTRIBUTING.md:133-135` already calls out flaky tests as a known issue — replace that acknowledgement with a fix.
  **Files**: `tests/logging.bats`, `tests/session.bats`, `tests/test_helper.bash`, `CONTRIBUTING.md`
  **Acceptance**: 10 consecutive `make test-force` runs at the default `TEST_JOBS=6` all pass. The `Known Issues` note in `CONTRIBUTING.md` loses the "flaky tests" bullet or references a new, tighter list that does not include tests 318 and 510.

- [ ] `make audit` runs `tasks-lint` on `TASKS.md` so malformed queue entries fail fast in CI
  **ID**: audit-runs-tasks-lint
  **Tags**: ci, audit, quality, tasks-lint
  **Details**: The repo's `TASKS.md` is required to follow the tasks.md spec (`CONTRIBUTING.md:64-84`), and the `next-task` skill + every autonomous session depend on that format. `make audit` today scans for `TODO:`/`FIXME:` markers, runs shellcheck, and lists the docs review queue, but it never runs the upstream `tasks-lint`. A missing `**ID**:`, malformed `**Blocked by**:`, or accidental `[x]` would only surface when an agent tried to pick a task and failed. Add `tasks-lint` to `make audit` (and therefore to `make check` via the CI job that runs `make audit`) using the same local-only discipline — prefer `npx --offline tasks-lint TASKS.md` if the lockfile is vendored, otherwise document the dep in CONTRIBUTING.md and cache it in CI. When `TASKS.md` only has `# Tasks`, lint must still pass.
  **Files**: `Makefile`, `.github/workflows/check.yml`, `CONTRIBUTING.md`, `AGENTS.md`, `README.md`
  **Acceptance**: (1) `make audit` fails loudly when `TASKS.md` breaks the tasks.md spec (e.g. checkbox without `**ID**:`, `**Blocked by**:` without a value), using the upstream `tasks-lint` binary or an explicit fallback documented in `CONTRIBUTING.md`. (2) `make audit` still passes on the current empty `# Tasks` stub and on a legitimate populated queue. (3) CI invokes the same target it does today and no new external network call is needed on cache hit. (4) `CONTRIBUTING.md` and `AGENTS.md` mention the new gate so new contributors know where to run `tasks-lint` locally.

- [ ] `is_audit_only_focus_request()` and `has_supported_audit_lane_task()` have direct unit-style test coverage
  **ID**: test-audit-focus-guards-coverage
  **Tags**: tests, audit-focus, discovery-lane
  **Details**: `is_audit_only_focus_request()` (`bin/taskgrind:1582`) classifies a skill + focus prompt combo as audit-only, and `has_supported_audit_lane_task()` (`bin/taskgrind:1591`) decides whether a repo's `TASKS.md` contains a discovery-lane standing-loop task. Together they gate the `audit_focus_blocked` terminal path and the "audit-only skills refuse to run without a supported discovery-lane task" flow. Today they are exercised indirectly through `tests/session.bats:484-486` and `tests/multi-instance.bats` (standing-loop discovery), so a regression such as accidentally narrowing the regex in `is_audit_only_focus_request` or dropping the `audit|log|queue|tasks\.md|sweep|refresh` alternation in `has_supported_audit_lane_task` would only surface via failure of the higher-level integration case. Add direct table-driven tests mirroring the `all_tasks_blocked` / `detect_default_branch` coverage pattern: sourcing the function via `awk` extract, feeding fixtures, and checking return code and logged markers.
  **Files**: `tests/session.bats`, `tests/multi-instance.bats`
  **Acceptance**: (1) `is_audit_only_focus_request` has tests for skill names `standing-audit-gap-loop`, `project-audit`, `full-sweep`, mixed-case `AUDIT`, prompts containing `analyze logs`, `refresh tasks`, `queue refresh`, `sweep`, plus negatives (`next-task`, empty prompt). (2) `has_supported_audit_lane_task` has tests for: missing file, empty file, task with `standing-loop` in description, task with the `audit|log|queue|tasks.md|sweep|refresh` keywords, and a task that mentions neither. (3) All tests extract the function from `bin/taskgrind` via `awk` (consistent with the existing `classify_rebase_conflicts` pattern).

- [ ] `extract_first_task_context()` has direct unit-style test coverage
  **ID**: test-extract-first-task-context
  **Tags**: tests, queue, blocked-reason
  **Details**: `extract_first_task_context()` (`bin/taskgrind:1539-1580`) walks `TASKS.md`, stops at the first `- [ ]`, and emits `task_id=<id>` and optional `blocker=<reason>` lines used when logging `audit_focus_blocked` context and when composing the blocked-wait summary (`bin/taskgrind:2124,2493`). The function has no direct test — a parsing regression (e.g. treating `- [x]` as active, stopping at the wrong task, or losing the blocker line on trailing whitespace) would silently degrade the "which task is blocking us?" operator signal. Add table-driven bats coverage sourcing the function via `awk` extract, matching the `detect_default_branch` pattern.
  **Files**: `tests/session.bats`, `tests/task-attempts.bats`
  **Acceptance**: New tests cover (1) empty `TASKS.md`, (2) one `- [ ]` with `**ID**:` only, (3) one `- [ ]` with `**ID**:` and `**Blocked by**:`, (4) two `- [ ]` tasks — function only reports the first, (5) `- [x]` (completed) blocks are ignored, (6) trailing whitespace after `**Blocked by**:` does not bleed into the blocker value. The tests extract the function via `awk '/^extract_first_task_context\(\) \{/,/^}$/'` so they stay decoupled from unrelated refactors.

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

- [ ] `CONTRIBUTING.md` has a short "Diagnosing a flaky bats test" section that matches the parallel-load reality
  **ID**: contributing-flaky-test-runbook
  **Tags**: docs, contributor-dx, tests, flakiness
  **Details**: `CONTRIBUTING.md:133-136` mentions flaky network/branch tests but offers no playbook. Given the `TEST_JOBS` auto-cap, the focused-file `make test TESTS=tests/<file>.bats` pattern, and the cache behavior, a contributor hitting a flake has to piece the recovery together from `Makefile`, AGENTS.md, and this doc. Add a short subsection that lists: (1) run the one failing test alone with `bats tests/<file>.bats -f "<name>"`, (2) rerun under `TEST_JOBS=1` to rule out parallelism, (3) rerun under `TEST_JOBS=6` (the auto cap) to reproduce. Include the specific failure modes from `CONTRIBUTING.md`'s Known Issues so the runbook and the known-issues list agree.
  **Files**: `CONTRIBUTING.md`
  **Acceptance**: `CONTRIBUTING.md` has a "Diagnosing a flaky bats test" subsection with the three-step reproduce/isolate/diagnose recipe. The existing Known Issues bullet references it instead of duplicating. `tests/basics.bats` (or the most appropriate docs test) grep-asserts the runbook still links to `TEST_JOBS` and the `-f` flag, so the subsection cannot silently drop the key guidance.
