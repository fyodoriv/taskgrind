# Tasks

## P0

- [ ] Allow multiple taskgrind instances on the same repo via instance slots
  **ID**: multi-instance-same-repo
  **Tags**: feature, stability, dx
  **Details**: The current per-repo exclusive lock (`taskgrind-lock-<hash>`) prevents running two taskgrinds on the same repo simultaneously. The user wants to run a second instance with a read-only audit role (produce tasks, commit, push — no code changes) alongside a code-producing instance. The lock exists to prevent: (1) git conflicts on TASKS.md and working tree, (2) the between-session sync (stash/rebase) stomping the other agent's uncommitted work, (3) two agents picking the same task.

  The right solution is **instance slots + per-instance worktrees** or **a `--no-lock` / `TG_INSTANCE` escape hatch with conflict-avoidance hints** injected into the prompt. The simpler path (no worktrees) is:

  1. Replace the single lock with a numbered slot system: `taskgrind-lock-<repohash>-<N>` where N is 0, 1, 2… Up to `TG_MAX_INSTANCES` (default 1, set to 2+ to allow concurrent). Each new invocation claims the lowest free slot. The slot number becomes the instance ID.
  2. Add `TG_INSTANCE_ID=<N>` (or `TG_SLOT=<N>`) to the session environment and inject it into the prompt so the agent knows it is instance N.
  3. Inject conflict-avoidance rules into the prompt for slots ≥1: "You are instance N of M running on this repo. Avoid modifying the same files as instance 0. Before committing, do `git pull --rebase` to absorb concurrent commits. Do not run the between-session git sync (it is managed by instance 0)."
  4. Disable the between-session git stash/rebase for all slots ≥1 (only slot 0 owns sync). Each slot still does a final push.
  5. Add `--instance` / `TG_MAX_INSTANCES` flag docs and a `--preflight` check that reports how many slots are in use.

  The task description passed by the user already handles semantic separation (audit-only vs code-changes) — taskgrind just needs to stop blocking the second launch and give each instance enough context to avoid trampling each other.
  **Files**: bin/taskgrind, tests/taskgrind.bats, README.md, man/taskgrind.1
  **Acceptance**:
  - [ ] `TG_MAX_INSTANCES=2 taskgrind` on the same repo as an existing grind succeeds (no lock error)
  - [ ] Each instance gets a unique slot number (0, 1, …) written to its log and banner
  - [ ] Slot ≥1 instances skip the between-session git sync (stash/rebase/checkout)
  - [ ] Slot ≥1 instances have conflict-avoidance language injected into every session prompt
  - [ ] `--preflight` reports active slot count for the repo
  - [ ] A third launch with `TG_MAX_INSTANCES=2` still errors (slots full)
  - [ ] All existing single-instance tests pass unchanged
  - [ ] At least one test covers two concurrent instances acquiring different slots

- [ ] Resolve short model aliases to their most powerful variant
  **ID**: model-alias-resolution
  **Tags**: ux, models
  **Details**: When a user writes `--model opus` or puts `opus` in `.taskgrind-model`, taskgrind passes it straight to the devin CLI which maps it to a generic alias — not necessarily the most powerful variant. Add a resolution layer in `_refresh_model()` (and at startup before `_startup_model` is set) that maps short names to the strongest currently-available model ID. Mapping table (as of 2026-04): `opus` → `claude-opus-4-6-thinking`, `sonnet` → `claude-sonnet-4.6`, `haiku` → `claude-haiku-4.5`, `swe` → `swe-1.6`, `codex` → `gpt-5.3-codex`, `gpt` → `gpt-5.4`. Unknown names are passed through unchanged (the CLI will reject them with a useful error). Store the mapping in `lib/constants.sh` as `DVB_MODEL_ALIASES` (an associative array) so it's easy to update when new models ship. Print the resolved name in the session banner so the user sees `model=claude-opus-4-6-thinking` rather than `model=opus`. Keep raw name in log for traceability: `live_model=claude-opus-4-6-thinking (alias: opus)`.
  **Files**: lib/constants.sh, bin/taskgrind, tests/taskgrind.bats
  **Acceptance**:
  - [ ] `--model opus` resolves to `claude-opus-4-6-thinking` before the first session
  - [ ] `.taskgrind-model` containing `opus` also resolves on live reload
  - [ ] Session banner shows the resolved model ID, not the alias
  - [ ] Log entry includes both resolved name and original alias
  - [ ] Unknown model names pass through unchanged (no silent failure)
  - [ ] Mapping table lives in `lib/constants.sh` (single source of truth)
  - [ ] Test: `--model opus` → session uses `claude-opus-4-6-thinking` in devin args
  - [ ] Test: live `.taskgrind-model` with `sonnet` → resolves to `claude-sonnet-4.6`
  - [ ] All existing tests pass

- [ ] Show active model on every session banner line
  **ID**: show-model-on-session-banner
  **Tags**: ux, visibility
  **Details**: The session banner (bin/taskgrind line 1096) prints `🔄 Session N — Xh Ym remaining — T tasks queued` but omits the active model. The startup banner (line 842) shows the initial model, but after a live model switch via `.taskgrind-model` the only indication is a separate `   Model: <name> (live override)` line that only fires when the model differs from startup. The user has no way to see at a glance what model is actually running for the current session. Change the session banner to always include the model: `🔄 Session N — Xh Ym remaining — T tasks queued — model=<name>`. Remove the separate "live override" line since the banner now makes it visible. Update the log_write on line 1097 to also include `model=`. Keep the test for the "live override" message updated.
  **Files**: bin/taskgrind, tests/taskgrind.bats
  **Acceptance**:
  - [ ] Session banner always includes `model=<name>` for every session
  - [ ] When model is the startup default, banner shows it with no extra annotation
  - [ ] When model is a live override, banner shows it (the separate "live override" echo can be removed or kept minimal)
  - [ ] `log_write` for session start includes `model=<name>`
  - [ ] Test verifies model name appears in the session banner output
  - [ ] All existing tests pass

- [ ] Detect and surface invalid model errors before starting the session loop (@devin)
  **ID**: detect-invalid-model
  **Tags**: stability, error-handling
  **Details**: When the devin CLI rejects the model (e.g. `Error: Unknown model: 'gpt-5.4 xhigh thinking fast'`), every session exits in <1s with exit=1, burning through the fast-failure budget and terminating the grind with zero useful output. The root fix (correct model ID) already landed, but taskgrind itself has no guard: it passes the model string blindly and only learns it's wrong after the first session fails. Add a preflight check that validates the configured model by running `devin --model "$model" --help` (or a cheap equivalent) and exits immediately with a clear error if the model is rejected — before any session starts. Also capture and surface the backend's model-rejection message in the fast-failure log so it's obvious what went wrong without reading the raw log.
  **Files**: bin/taskgrind, tests/taskgrind.bats
  **Plan**:
  - [ ] Add a preflight model validation step that fails fast with the backend's rejection message
  - [ ] Capture backend stderr in the per-session log so invalid-model failures are diagnosable after the fact
  - [ ] Verify the new behavior with targeted regression tests and the full `make check` gate
  **Acceptance**:
  - [ ] Preflight check validates the model and exits with a clear error for unknown models
  - [ ] The rejection message from the backend is included in the error output
  - [ ] Fast-failure log captures the backend stderr (including model errors) per session
  - [ ] Test: unknown model triggers preflight failure before any session runs
  - [ ] All existing tests pass

- [ ] Speed up test suite 5x by splitting into parallel bats files
  **ID**: parallel-test-suite
  **Tags**: dx, test, performance
  **Details**: `make test` takes ~21 minutes for 397 tests (single-file serial run). All tests are already isolated (each gets its own `mktemp -d` tmpdir in `setup()`), so they are safe to parallelize. bats 1.13 supports `--jobs N` with GNU parallel, which is already installed at `/usr/local/bin/parallel`. The blocker is that bats only parallelizes *across* files — the 397 tests all live in one monolithic `tests/taskgrind.bats`. The fix is to split by feature group into ~8 files (e.g. `tests/model.bats`, `tests/git-sync.bats`, `tests/network.bats`, `tests/prompt.bats`, `tests/session-loop.bats`, `tests/preflight.bats`, `tests/signals.bats`, `tests/misc.bats`), move `setup()`/`teardown()` + shared helpers into `tests/test_helper.bash` (it already exists but is nearly empty), update `Makefile` to run `bats --jobs 8 tests/` so all files run in parallel, and update CI (`.github/workflows/`) to match. Target: ≤5 minutes wall-clock on a MacBook with 8 cores. The `--no-parallelize-within-files` flag is fine to keep if needed for ordering-sensitive tests.
  **Files**: tests/taskgrind.bats, tests/test_helper.bash, Makefile, .github/workflows/
  **Acceptance**:
  - [ ] Tests are split into ≥6 `.bats` files organized by feature group
  - [ ] `setup()` and `teardown()` live in `test_helper.bash` and are loaded by all files
  - [ ] `make test` runs `bats --jobs 8 tests/` and completes in ≤5 minutes
  - [ ] All 397 tests still pass (same count, no tests lost or duplicated)
  - [ ] CI workflow updated to use `--jobs` flag
  - [ ] No test relies on ordering between files (each is fully isolated)

- [ ] Surface git push error output in final_sync
  **ID**: surface-push-errors
  **Tags**: stability, git
  **Details**: `final_sync()` at bin/taskgrind:676 discards git push stderr with `2>/dev/null`. When push fails (non-fast-forward, auth, etc.), the log says `final_sync push_failed` but the actual error is lost. Capture stderr to the log so users can debug without re-running manually.
  **Files**: bin/taskgrind
  **Acceptance**:
  - [ ] `git push` stderr is captured and written to the log file
  - [ ] The user-visible warning message includes the first line of the git error
  - [ ] Existing final_sync tests still pass

## P1

- [ ] Test coverage for per-task skip list (attempt tracking)
  **ID**: test-skip-list
  **Tags**: test, stability
  **Details**: The per-task attempt tracking system (bin/taskgrind:1099-1104, 1282-1297) has ZERO test coverage. This is the largest uncovered feature. When a task survives 3+ sessions, it gets added to a skip list in the prompt. No test verifies the skip list appears in prompts, that `task_skip_threshold` is logged, or that temp files are cleaned up.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test: fake devin that never removes a task ID — verify `task_skip_threshold` logged after 3 sessions
  - [ ] Test: verify `SKIP these stuck tasks:` appears in session 4's prompt
  - [ ] Test: verify `_task_attempts_file.new` temp file is not leaked after the run
  - [ ] All existing tests still pass

- [ ] Test coverage for TG_ prefix precedence on remaining 16 env vars
  **ID**: test-tg-prefix
  **Tags**: test
  **Details**: Only `TG_MODEL`, `TG_SKILL`, and `TG_PROMPT` have behavioral precedence tests. The other 16 TG_ vars (LOG, NOTIFY, BACKEND, COOL, DEVIN_PATH, MAX_SESSION, MAX_FAST, MAX_ZERO_SHIP, etc.) have no behavioral test confirming TG_X overrides DVB_X at runtime. The mapping loop at bin/taskgrind:91-101 is structurally tested but not exercised.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Behavioral tests for at least: TG_BACKEND, TG_COOL, TG_LOG, TG_NOTIFY, TG_EARLY_EXIT_ON_STALL, TG_MAX_SESSION
  - [ ] Each test sets TG_X and DVB_X to different values, runs grind, asserts TG_ value took effect
  - [ ] All existing tests still pass

- [ ] Fix git stash failure masking in sync subshell
  **ID**: fix-stash-masking
  **Tags**: stability, git
  **Details**: In the git sync subshell (bin/taskgrind:1403), if `git stash` fails, `_dirty=1` is still set unconditionally. The subsequent `git stash pop` then fails, and the user sees "stash pop failed" but never learns why the initial stash failed. Only set `_dirty=1` if stash actually succeeds, and log the stash failure reason.
  **Files**: bin/taskgrind
  **Acceptance**:
  - [ ] `_dirty=1` only set when `git stash` exits 0
  - [ ] Stash failure is logged with the error message
  - [ ] `stash pop` is not attempted when stash failed
  - [ ] Existing git sync tests still pass

- [ ] Add test for sync_interval > 0 modulo logic
  **ID**: test-sync-interval
  **Tags**: test
  **Details**: All git-sync tests set `DVB_SYNC_INTERVAL=0`. The modulo path at bin/taskgrind:1389 (`session % sync_interval`) and the `git_sync skipped` log path (line 1483) are never exercised. A test with `DVB_SYNC_INTERVAL=3` and a 4-session run should verify sessions 1-2 log `git_sync skipped` and session 3 logs `git_sync ok`.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test with `DVB_SYNC_INTERVAL=3`: sessions 1,2 skip sync; session 3 runs sync
  - [ ] Test verifies `git_sync skipped` log entries for non-sync sessions
  - [ ] All existing tests still pass

- [ ] Document multi-word model strings require quoting
  **ID**: doc-model-quoting
  **Tags**: docs
  **Details**: The README (line 96) shows `--model gpt-5-4` as an example. Multi-word model strings like `--model "gpt-5-4 XHigh thinking fast"` work when properly quoted (the value flows through bash arrays safely), but unquoted multi-word strings break because only the first word is captured by `$2`. Add a note to README, man page, and --help header.
  **Files**: README.md, man/taskgrind.1, bin/taskgrind
  **Acceptance**:
  - [ ] README shows a quoted multi-word model example
  - [ ] Man page documents quoting requirement
  - [ ] --help header shows a quoted example
  - [ ] Add a test that verifies a quoted multi-word model string passes through correctly

## P2

- [ ] Add SIGTERM graceful shutdown behavioral test
  **ID**: test-sigterm
  **Tags**: test
  **Details**: All graceful-shutdown behavioral tests only send SIGINT (tests/taskgrind.bats). No test sends SIGTERM to a running grind and verifies the session finishes. SIGTERM uses the same `graceful_shutdown` function but with exit code 143 instead of 130.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test sends SIGTERM to a running grind, verifies session completes
  - [ ] Verifies exit code is 143
  - [ ] Verifies "Grind complete" summary is printed

- [ ] Add concurrent lock rejection end-to-end test
  **ID**: test-lock-contention
  **Tags**: test
  **Details**: Lock tests verify hash math but never actually start two grind processes on the same repo. No test confirms the second instance is rejected with "another taskgrind is already running".
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test starts two grind processes on the same repo simultaneously
  - [ ] Verifies the second process exits with "another taskgrind is already running"
  - [ ] First process completes normally

- [ ] Log on task-attempts file write failure
  **ID**: log-attempts-failure
  **Tags**: stability
  **Details**: At bin/taskgrind:1289, `mv "$_new_attempts" "$_task_attempts_file" 2>/dev/null || true` silently loses the session's attempt increments on disk-full. Stuck tasks won't be added to the skip list. Add a `log_write` on failure.
  **Files**: bin/taskgrind
  **Acceptance**:
  - [ ] Failed `mv` of attempts file writes a log entry
  - [ ] Skip list still functions when individual writes fail (graceful degradation)

- [ ] Add AUTONOMY prompt block test
  **ID**: test-autonomy-prompt
  **Tags**: test
  **Details**: The `AUTONOMY:` prompt block (bin/taskgrind:1073) is appended to every session but never tested. Only `COMPLETION PROTOCOL` is verified. This prompt is critical — without it, agents defer tasks claiming "requires manual steps".
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test verifies `AUTONOMY:` appears in the session prompt
  - [ ] Test verifies key phrases: "browser automation", "MCP tools", "do not leave tasks"

- [ ] Extract shared test helpers to reduce duplication
  **ID**: extract-test-helpers
  **Tags**: test, chore
  **Details**: `tests/test_helper.bash` is effectively empty (6 lines, no functions). The fake-devin creation pattern, git-repo initialization pattern, and network sentinel setup are duplicated across 384+ tests. Extract into named helper functions.
  **Files**: tests/test_helper.bash, tests/taskgrind.bats
  **Acceptance**:
  - [ ] `test_helper.bash` provides: `create_fake_devin`, `init_test_repo`, `setup_network_sentinel`
  - [ ] At least 10 tests refactored to use shared helpers
  - [ ] All tests still pass
  - [ ] Net reduction in test file line count

- [ ] Add preflight disk space threshold tests
  **ID**: test-disk-thresholds
  **Tags**: test
  **Details**: Preflight disk space checks (bin/taskgrind:442-450) have three branches: >1GB pass, 512MB-1GB warn, <512MB fail. Only the string "Disk space" is verified. The warn and fail thresholds have no behavioral coverage.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test for disk space warning (<1GB)
  - [ ] Test for disk space failure (<512MB)
  - [ ] Tests may need to mock `df` output

## P3

- [ ] Make network check URL configurable via TG_NET_CHECK_URL
  **ID**: configurable-net-url
  **Tags**: feature, config
  **Details**: The fallback connectivity check URL at bin/taskgrind:297 is hardcoded to `https://connectivitycheck.gstatic.com/generate_204`. This may be blocked in corporate environments. Add a `TG_NET_CHECK_URL` env var for users to override.
  **Files**: bin/taskgrind, README.md, man/taskgrind.1
  **Acceptance**:
  - [ ] `TG_NET_CHECK_URL` overrides the default connectivity URL
  - [ ] Default behavior unchanged when env var is unset
  - [ ] Documented in README, man page, and --help
  - [ ] Test verifies custom URL is used

- [ ] Make watchdog SIGINT-to-SIGTERM grace configurable via TG_SESSION_GRACE
  **ID**: configurable-session-grace
  **Tags**: feature, config
  **Details**: The 15-second grace period between SIGINT and SIGTERM in the session timeout watchdog (bin/taskgrind:1141) is hardcoded. This is distinct from `TG_SHUTDOWN_GRACE` (user Ctrl-C grace). Some backends need more time to commit.
  **Files**: bin/taskgrind, README.md, man/taskgrind.1
  **Acceptance**:
  - [ ] `TG_SESSION_GRACE` overrides the 15s default
  - [ ] Validated as numeric at startup
  - [ ] Documented in README, man page, and --help
  - [ ] Test verifies custom value is used

- [ ] Add .taskgrind-prompt race condition guard
  **ID**: prompt-file-race-guard
  **Tags**: stability
  **Details**: In `_refresh_prompt()`, `wc -c` and `cat` are separate operations. If the file is deleted between the size check and the read, `cat` silently fails and the prompt is dropped. Use a single `cat` with size check on the captured content instead.
  **Files**: bin/taskgrind
  **Acceptance**:
  - [ ] Read file once into variable, then check size
  - [ ] File deletion between reads does not silently drop the prompt
  - [ ] Existing prompt tests still pass

- [ ] Add architecture doc for live prompt and model injection
  **ID**: doc-live-injection-arch
  **Tags**: docs
  **Details**: The architecture doc (docs/architecture.md) covers self-copy, caffeinate, git sync, retry caps, empty-queue sweep, and next-task skill. Missing: rationale for live prompt injection via `.taskgrind-prompt`, the prompt combination logic (CLI + file), and the 10KB guard. Also add rationale for the planned `.taskgrind-model` feature.
  **Files**: docs/architecture.md
  **Acceptance**:
  - [ ] New section: "Why .taskgrind-prompt for live injection"
  - [ ] Covers: re-read timing, CLI+file combination, size guard rationale
  - [ ] Mentions .taskgrind-model if implemented

- [ ] Add user story for live prompt injection workflow
  **ID**: doc-live-prompt-story
  **Tags**: docs
  **Details**: docs/user-stories.md has 5 stories but none covering the live prompt injection workflow. Add a story showing: start a grind, realize you want to shift focus mid-run, create `.taskgrind-prompt`, see the change take effect.
  **Files**: docs/user-stories.md
  **Acceptance**:
  - [ ] New story: "Redirecting focus mid-grind"
  - [ ] Shows command sequence and expected log output
  - [ ] Mentions that changes apply at next session start, not current

- [ ] Add user story for model switching workflow
  **ID**: doc-model-switch-story
  **Tags**: docs
  **Details**: No user story covers the `--model` flag or model switching during a grind. Add a story showing: start with opus for complex tasks, switch to sonnet mid-grind for faster iterations on simpler remaining tasks.
  **Files**: docs/user-stories.md
  **Acceptance**:
  - [ ] New story: "Switching models mid-grind"
  - [ ] Shows --model flag usage and .taskgrind-model file usage
  - [ ] Explains when each model is appropriate
