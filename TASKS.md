# Tasks

## P0

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

## P1

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

  - [ ] Verification confirms the documented flow matches the implementation

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
