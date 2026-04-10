# Tasks

## P0

- [ ] Detect and surface invalid model errors before starting the session loop
  **ID**: detect-invalid-model
  **Tags**: stability, error-handling
  **Details**: When the devin CLI rejects the model (e.g. `Error: Unknown model: 'gpt-5.4 xhigh thinking fast'`), every session exits in <1s with exit=1, burning through the fast-failure budget and terminating the grind with zero useful output. The root fix (correct model ID) already landed, but taskgrind itself has no guard: it passes the model string blindly and only learns it's wrong after the first session fails. Add a preflight check that validates the configured model by running `devin --model "$model" --help` (or a cheap equivalent) and exits immediately with a clear error if the model is rejected — before any session starts. Also capture and surface the backend's model-rejection message in the fast-failure log so it's obvious what went wrong without reading the raw log.
  **Files**: bin/taskgrind, tests/taskgrind.bats
  **Acceptance**:
  - [ ] Preflight check validates the model and exits with a clear error for unknown models
  - [ ] The rejection message from the backend is included in the error output
  - [ ] Fast-failure log captures the backend stderr (including model errors) per session
  - [ ] Test: unknown model triggers preflight failure before any session runs
  - [ ] All existing tests pass

- [ ] Log git sync subshell failures instead of silently swallowing them
  **ID**: log-git-sync-failures
  **Tags**: stability, git
  **Details**: The git sync subshell (bin/taskgrind:1399-1423) redirects stderr to /dev/null and uses `|| true` on checkout, fetch, and rebase. A failed `git fetch` (auth error, network) produces zero diagnostic output — not to stdout, not to the log. The outer `wait` sees exit 0 because `|| true` masks the real exit code. Capture each git command's exit code and stderr to `$_git_out` so the outer handler can diagnose which step failed. This is the #1 silent failure mode in production.
  **Files**: bin/taskgrind
  **Acceptance**:
  - [ ] `git fetch` failure writes the error message to `$_git_out` (not /dev/null)
  - [ ] `git checkout` and `git rebase` failures similarly captured
  - [ ] Log entry distinguishes which git op failed (e.g., `git_sync fetch_failed`)
  - [ ] Existing tests pass; add a test that verifies fetch failure is logged

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
