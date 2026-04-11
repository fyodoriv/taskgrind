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

- [ ] Surface resolved model IDs and raw aliases in taskgrind output
  **ID**: model-alias-resolution-visibility
  **Parent**: model-alias-resolution
  **Tags**: ux, models
  **Details**: Once alias resolution is in place, show users the resolved model ID in the banner and preserve the original alias in logs so live model changes stay debuggable.
  **Files**: bin/taskgrind, tests/features.bats, tests/logging.bats
  **Acceptance**:
  - [ ] Startup output shows the resolved model ID instead of the short alias
  - [ ] Live model log entries include both the resolved ID and the original alias when they differ
  - [ ] Existing model banner/logging tests still pass

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

- [ ] Reduce taskgrind test turnaround for local iteration
  **ID**: improve-test-speed
  **Tags**: dx, test, performance
  **Details**: The suite is now parallelized, but local iteration is still too slow when contributors rerun `make check`, repeat a single bats file several times, or exercise timing-sensitive cases under load. Measure where wall-clock time is still going (fixed sleeps, repeated repo setup, duplicated fake-devin scaffolding, whole-suite startup overhead, and other hotspots) and make the fastest safe reductions without weakening coverage or disabling parallel execution.
  **Files**: Makefile, tests/*.bats, tests/test_helper.bash, .github/workflows/check.yml, AGENTS.md
  **Acceptance**:
  - [ ] Baseline timings are captured for `make test`, `make check`, and at least one targeted bats-file rerun
  - [ ] At least one real runtime reduction lands (for example shorter deterministic waits, shared helpers, lighter setup, or a faster targeted command path)
  - [ ] Local whole-suite or targeted rerun wall-clock time measurably improves versus the baseline
  - [ ] Parallel execution remains the primary verification path
  - [ ] Any remaining slow or timing-sensitive paths are documented in `AGENTS.md`

## P1

- [ ] Stabilize `tests/session.bats` shipped and zero-ship assertions under parallel `make check` (@devin)
  **ID**: stabilize-parallel-session-tests
  **Parent**: stabilize-parallel-check-suite
  **Tags**: test, stability
  **Details**: Recent parallel `make check` failures included `tests/session.bats` assertions around `shipped=` and zero-ship state. Tighten those assertions so they remain deterministic when other bats files run concurrently.
  **Files**: tests/session.bats, tests/test_helper.bash
  **Acceptance**:
  - [ ] `tests/session.bats` no longer intermittently misses `shipped=` or zero-ship assertions during parallel runs
  - [ ] The fix preserves the behavioral intent of the current session accounting tests
  - [ ] Targeted `tests/session.bats` runs still pass

- [ ] Stabilize the parallel bats verification harness and document any remaining limits
  **ID**: stabilize-parallel-check-harness
  **Parent**: stabilize-parallel-check-suite
  **Tags**: test, dx, stability
  **Details**: Parallel `make check` has reported full-suite terminations (`bats --jobs 9 tests/*.bats` exiting with signal 15) in addition to file-level assertion failures. Once the flaky specs are stabilized, make the verification harness reliable enough for contributor use and document any residual timing-sensitive limitations in the repo guidance.
  **Files**: Makefile, .github/workflows/check.yml, AGENTS.md
  **Acceptance**:
  - [ ] `make check` no longer terminates spuriously during local parallel verification
  - [ ] CI/local parallel bats invocation remains enabled as the primary path
  - [ ] AGENTS.md documents any remaining test limitations with exact commands or scenarios if they still exist

- [ ] Test coverage for TG_ prefix precedence on remaining 16 env vars
  **ID**: test-tg-prefix
  **Tags**: test
  **Details**: Only `TG_MODEL`, `TG_SKILL`, and `TG_PROMPT` have behavioral precedence tests. The other 16 TG_ vars (LOG, NOTIFY, BACKEND, COOL, DEVIN_PATH, MAX_SESSION, MAX_FAST, MAX_ZERO_SHIP, etc.) have no behavioral test confirming TG_X overrides DVB_X at runtime. The mapping loop at bin/taskgrind:91-101 is structurally tested but not exercised.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Behavioral tests for at least: TG_BACKEND, TG_COOL, TG_LOG, TG_NOTIFY, TG_EARLY_EXIT_ON_STALL, TG_MAX_SESSION
  - [ ] Each test sets TG_X and DVB_X to different values, runs grind, asserts TG_ value took effect
  - [ ] All existing tests still pass

- [ ] Add test for sync_interval > 0 modulo logic
  **ID**: test-sync-interval
  **Tags**: test
  **Details**: All git-sync tests set `DVB_SYNC_INTERVAL=0`. The modulo path at bin/taskgrind:1389 (`session % sync_interval`) and the `git_sync skipped` log path (line 1483) are never exercised. A test with `DVB_SYNC_INTERVAL=3` and a 4-session run should verify sessions 1-2 log `git_sync skipped` and session 3 logs `git_sync ok`.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test with `DVB_SYNC_INTERVAL=3`: sessions 1,2 skip sync; session 3 runs sync
  - [ ] Test verifies `git_sync skipped` log entries for non-sync sessions
  - [ ] All existing tests still pass

## P2

- [ ] Add resumable grind state so interrupted runs can continue without losing counters
  **ID**: resumable-grind-state
  **Tags**: feature, reliability, ux
  **Details**: Taskgrind currently treats every launch as a fresh marathon: if the terminal dies, the machine reboots, or the operator intentionally restarts the process, the new run loses session count, shipped-count history, zero-ship streaks, startup model, and the original deadline context. Adjacent long-running workflows such as `tmux`-hosted agent loops and CI/job runners preserve enough runtime state to resume after an interruption instead of starting blind. Add a small durable state file plus a `--resume` flow so taskgrind can pick up an interrupted grind for the same repo and continue with the original deadline and counters when the operator wants that behavior.
  **Files**: bin/taskgrind, lib/constants.sh, tests/taskgrind.bats, README.md, man/taskgrind.1
  **Acceptance**:
  - [ ] Taskgrind writes a durable per-repo state file that captures at least deadline, session count, shipped count, zero-ship streak, backend, skill, and model
  - [ ] `taskgrind --resume` on the same repo restores that state instead of starting a fresh session counter
  - [ ] Resume refuses stale or incompatible state with a clear operator-facing message rather than silently mixing runs
  - [ ] Clean completion and explicit abort paths remove or invalidate the saved state so later runs do not resume accidentally
  - [ ] README, man page, and `--help` document how resume works and when to prefer a fresh run
  - [ ] Tests cover save-on-progress, resume-after-interruption, and stale-state rejection

- [ ] Emit machine-readable heartbeat status for external monitors and wrappers
  **ID**: heartbeat-status-file
  **Tags**: feature, observability, ux
  **Details**: Taskgrind's only live status surface today is human-oriented stdout plus an append-only log file in `$TMPDIR`. That is hard for wrappers, launchd/systemd jobs, menu-bar tools, or watchdog scripts to consume. Adjacent supervisors and CI runners usually expose a structured status file or endpoint that external tooling can poll for health, current phase, session number, remaining minutes, and last error. Add an opt-in heartbeat/status artifact so operators can monitor a running grind without scraping prose logs.
  **Files**: bin/taskgrind, tests/taskgrind.bats, README.md, man/taskgrind.1
  **Acceptance**:
  - [ ] Taskgrind can write a structured status file (for example JSON) to a predictable path while a grind is running
  - [ ] The status includes repo, pid, slot, backend, skill, model, session number, remaining time, current phase, and the timestamp/result of the most recent session
  - [ ] The heartbeat updates on startup, before and after each session, during network waits, and on final completion/failure
  - [ ] The file is written atomically so external readers never see truncated content
  - [ ] The feature is documented, including the default path or the env var/flag used to override it
  - [ ] Tests verify heartbeat contents across at least startup, in-session, and completion states

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
  **Details**: `tests/test_helper.bash` is effectively empty (6 lines, no functions). The fake-devin creation pattern, git-repo initialization pattern, and network sentinel setup are duplicated across the large monolithic bats suite. Extract into named helper functions.
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

- [ ] Stabilize the DVB_COOL=0 timing-sensitive test under load
  **ID**: stabilize-cool-zero-test
  **Tags**: test, flake
  **Details**: The test `DVB_COOL=0 skips sleep between sessions` in `tests/taskgrind.bats` intermittently fails under normal repo load because it asserts the whole run finishes in under 8 seconds. During verification for `detect-invalid-model` on 2026-04-10, the same test passed once and failed once when rerun in isolation, matching the repo's documented timing-sensitive flake pattern. Replace the wall-clock assertion with a more deterministic signal for "no cooldown sleep happened" so `make check` can pass reliably under load.
  **Files**: tests/taskgrind.bats
  **Acceptance**:
  - [ ] Test no longer depends on a tight wall-clock threshold across the full suite
  - [ ] It still verifies that `DVB_COOL=0` skips cooldown behavior
  - [ ] Repeated isolated runs are stable under typical laptop load

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
