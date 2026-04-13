# taskgrind

[![check](https://github.com/cbrwizard/taskgrind/actions/workflows/check.yml/badge.svg)](https://github.com/cbrwizard/taskgrind/actions/workflows/check.yml)

## TL;DR

Taskgrind runs repeated AI coding sessions against any repo that keeps its queue
in `TASKS.md`, stopping when the deadline, queue state, or stall guard says the
run is done. Use `taskgrind --preflight` to verify the backend and repo before a
long run, then steer later sessions with repo-local prompt or model overrides
instead of restarting the whole grind.

Sessions should exit before context fills; context exhaustion can crash the
process and lose uncommitted work.

Autonomous multi-session grind — runs sequential AI coding sessions until a deadline. Each session starts with full context. State lives in [`TASKS.md`](https://github.com/tasksmd/tasks.md) + git, so sessions pick up seamlessly. Sessions still need to exit before the model context fills up; a context-exhausted crash can drop any uncommitted work from that session.

Taskgrind works with any AI coding agent that accepts a prompt (Devin, Claude Code, Cursor, etc.) and any repo that uses the [tasks.md spec](https://tasks.md) for task management.

For local tests and repo audit helpers, keep `DVB_GRIND_CMD` to a single executable path. If you need a compound shell command, wrap it in a helper script first so preflight and session launch can validate it correctly.

## Prerequisites

Requires **macOS** or **Linux** (or WSL on Windows).

You need at least one AI coding backend installed:

| Backend | Install |
|---------|---------|
| [Devin CLI](https://cli.devin.ai/docs) | `curl -fsSL https://cli.devin.ai/install.sh \| sh` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `npm install -g @anthropic-ai/claude-code` |
| [Codex](https://github.com/openai/codex) | `npm install -g @openai/codex` |

Taskgrind defaults to Devin. Use `--backend claude-code` or `--backend codex` to switch.

### Backend setup matrix

Use `taskgrind --preflight ~/apps/myrepo` after installing a backend. The same
checks run before a real grind starts, so this is the fastest way to confirm the
binary, model, and network assumptions for the backend you chose.

| Backend | Binary taskgrind looks for | Model validation before session 1 | Most actionable setup failures |
|---------|----------------------------|-----------------------------------|--------------------------------|
| `devin` | `devin` from `PATH`, or `TG_DEVIN_PATH` if you override it | Validates the requested model by running `devin --model "$TG_MODEL" --help` during preflight | `Backend binary not found (devin)` means the CLI is missing or `TG_DEVIN_PATH` points at the wrong file. `Model rejected by devin before starting` means the model string is wrong for your Devin install. If the startup probe says the binary is a stub or broken after `--version`, reinstall or roll back the Devin CLI before retrying. |
| `claude-code` | `claude` from `PATH` | Validates the requested model by running `claude --model "$TG_MODEL" --help` during preflight | `Backend binary not found (claude-code)` usually means `@anthropic-ai/claude-code` is not installed globally or `claude` is not on `PATH`. `Model rejected by claude-code before starting` means the selected Claude model is unavailable to that install or account. |
| `codex` | `codex` from `PATH` | Validates the requested model by running `codex --model "$TG_MODEL" --help` during preflight | `Backend binary not found (codex)` means the Codex CLI is missing from `PATH`. If you keep the default Anthropic-flavored model while using `--backend codex`, taskgrind warns before launch because Codex expects an OpenAI model such as `o3` or `gpt-5.4`. A later `Model rejected by codex before starting` failure means the chosen OpenAI model name is not accepted by your local Codex install. |

Practical examples:

```bash
taskgrind --preflight ~/apps/myrepo
taskgrind --preflight --backend claude-code --model claude-sonnet-4.6 ~/apps/myrepo
taskgrind --preflight --backend codex --model o3 ~/apps/myrepo
```

## Install

### Homebrew (macOS / Linux)

```bash
brew install cbrwizard/tap/taskgrind
```

### Manual

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/cbrwizard/taskgrind/main/install.sh | sh

# Or clone manually
git clone https://github.com/cbrwizard/taskgrind.git ~/apps/taskgrind

# Custom install directory
TASKGRIND_INSTALL_DIR=~/tools/taskgrind sh -c "$(curl -fsSL https://raw.githubusercontent.com/cbrwizard/taskgrind/main/install.sh)"

# Add to PATH (add to your shell rc)
export PATH="$HOME/apps/taskgrind/bin:$PATH"
```

To update: `brew upgrade taskgrind` (Homebrew) or `cd ~/apps/taskgrind && git pull --rebase` (manual)

Contributor audit shortcut: run `make audit` to reproduce the local repo-audit pass (an actionable scan for real task markers, plus the core docs and repo-local audit skills, shellcheck, and the core docs review queue, including `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, `Agentfile.yaml`, `docs/architecture.md`, `docs/resume-state.md`, `docs/user-stories.md`, `man/taskgrind.1`, `.devin/skills/standing-audit-gap-loop/SKILL.md`, and `.devin/skills/grind-log-analyze/SKILL.md`) without any network-only dependencies.

## Usage

```bash
taskgrind                              # 10h grind (default), current dir
taskgrind 10                           # 10h grind
taskgrind ~/apps/myrepo 10             # 10h grind in specific repo
taskgrind --model gpt-5.4 8            # use specific model
taskgrind --model "gpt-5.4 XHigh thinking fast" 8  # quote multi-word model names
taskgrind --skill fleet-grind 10       # custom skill
taskgrind --prompt "focus on test coverage" 8  # focus prompt
taskgrind --backend claude-code 8       # use Claude Code backend
taskgrind --dry-run 8 ~/apps/myrepo    # print config without running
taskgrind --preflight ~/apps/myrepo    # run health checks only
taskgrind --resume ~/apps/myrepo       # resume an interrupted grind
taskgrind --help / -h                  # show usage and environment variables
taskgrind --version / -V               # print version (commit hash + date)
TG_MAX_INSTANCES=3 taskgrind 8         # allow three concurrent grinds per repo
```

Arguments can appear in any order. Hours is any bare integer 1-24.

## How It Works

1. Launches an AI session with the `next-task` skill (configurable via `--skill`, backend via `--backend`)
2. Session picks a task from `TASKS.md`, implements it, commits, and exits
3. Between sessions: cooldown, optional git sync (every N sessions)
4. Exits when: queue empty, all remaining tasks blocked, deadline reached, or stall detected

That session boundary is also the context-budget guard: keep prompts, plans, and scope small enough that each agent run can finish and commit before its context window fills. If a session crashes from context exhaustion, taskgrind can resume from git and `TASKS.md`, but any uncommitted edits from the crashed run are gone.

### Task format

Taskgrind reads `TASKS.md` following the [tasks.md spec](https://github.com/tasksmd/tasks.md). Tasks use checkbox format under priority headings:

```markdown
# Tasks

## P0
- [ ] Fix critical bug in auth flow
  **ID**: fix-auth-bug
  **Tags**: bug, auth
  **Details**: The OAuth callback fails when...
  **Files**: `src/auth.sh`, `tests/auth.bats`
  **Acceptance**: Users can complete the OAuth callback without a retry loop.

## P1
- [ ] Add retry logic to API calls
  **ID**: add-api-retry
  **Tags**: reliability, api
  **Details**: Retries should cover transient 502/503 responses only.
  **Files**: `src/api.sh`, `tests/api.bats`
  **Acceptance**: Transient upstream failures retry with backoff and permanent failures still exit fast.
  **Blocked by**: backend-rate-limit-policy
```

Use `**Blocked by**` only when another task or external dependency truly prevents progress. Completed tasks are removed (not checked off). History lives in git log. See the [tasks.md spec](https://github.com/tasksmd/tasks.md/blob/main/spec.md) for the full format.

## Features

- **Multi-backend support** — works with Devin, Claude Code, and Codex via `--backend`
- **Model selection** — `--model gpt-5.4` or `TG_MODEL=gpt-5.4` to use any model the backend supports; quote multi-word model names such as `--model "gpt-5.4 XHigh thinking fast"`; short aliases like `opus` and `sonnet` resolve to the current preferred model IDs
- **Live model switching** — create/edit `.taskgrind-model` in the repo while running; changes take effect at the next session, including short alias resolution. Delete the file to revert to the startup model. Files larger than 1 KB are ignored with a warning.
- **Live prompt injection** — create/edit `.taskgrind-prompt` in the repo while running; changes take effect at the next session. Files larger than 10 KB are ignored with a warning.
- **Preflight checks** — 8 health checks plus active slot reporting before launch. `network-watchdog` is optional; if missing, taskgrind falls back to `curl` for connectivity checks.
- **Self-copy protection** — copies itself to `$TMPDIR` before running, survives script edits mid-grind
- **Slot-based per-repo locking** — `TG_MAX_INSTANCES` allows multiple concurrent grinds on the same repo; slot 0 owns between-session git sync, higher slots get conflict-avoidance prompt guidance
- **Blocked-queue detection** — exits early when all remaining tasks have `**Blocked by**:` metadata
- **Caffeinate integration** — prevents system sleep on macOS (`caffeinate`) and Linux (`systemd-inhibit`)
- **Git sync with stash/rebase** — between-session sync stashes dirty work, auto-detects the repo default branch from `origin/HEAD`, remote HEAD probes, upstream tracking, or local branch fallbacks, then rebases there and cleans merged branches; tests can force the branch with `DVB_DEFAULT_BRANCH`. If stash creation fails, taskgrind logs the original git error and skips `stash pop`; if `stash pop` fails after a successful stash, it leaves the stash intact for manual recovery. When a rebase conflict only touches `TASKS.md`, taskgrind now auto-resolves it by keeping the local queue edit so queue churn does not leave the repo stuck mid-rebase.
- **Empty-queue sweep** — when `TASKS.md` is empty, launches a sweep session to find work, then waits for external task injection before exiting
- **Network resilience** — pauses on network loss, extends deadline on recovery
- **Stall detection** — bails after consecutive zero-ship sessions (configurable via `TG_MAX_ZERO_SHIP`)
- **Per-task retry cap** — skips tasks attempted 3+ times without shipping
- **Fast-failure backoff** — linear backoff with cap when sessions crash quickly
- **Ship-rate tracking** — logs cumulative effectiveness in `grind_done` summary, including inferred shipped work when a session removes a completed task but concurrent queue churn keeps the raw task count flat
- **Productive timeout warning** — detects when timeout kills sessions that were shipping
- **Unique log names** — includes repo basename + PID to prevent collisions
- **External injection detection** — logs when other processes add tasks mid-run
- **Graceful shutdown** — SIGINT/SIGTERM waits for running session, pushes commits, ignores duplicate shutdown signals, then exits

## Security

Taskgrind runs AI backends with **unrestricted permissions** (`--permission-mode dangerous` for Devin, `--dangerously-skip-permissions` for Claude Code). This is required because sessions need full filesystem and network access to implement tasks autonomously.

Before deploying, ensure:
- You trust the AI backend and the tasks in `TASKS.md`
- The repo does not contain sensitive credentials that the AI should not access
- You review the `TASKS.md` queue before starting a long grind

## Environment Variables

`TG_` is the canonical prefix. `DVB_` is supported as a backward-compatible alias for all variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `TG_BACKEND` | `devin` | AI backend: `devin`, `claude-code`, `codex` |
| `TG_MODEL` | `gpt-5.4` | AI model (set to an OpenAI model when using `--backend codex`) |
| `TG_SKILL` | `next-task` | Skill to run each session |
| `TG_PROMPT` | (none) | Focus prompt for every session |
| `TG_COOL` | `5` | Seconds between sessions |
| `TG_MAX_SESSION` | `3600` | Max seconds per session |
| `TG_MIN_SESSION` | `30` | Fast-failure threshold in seconds |
| `TG_MAX_FAST` | `20` | Max consecutive fast failures before bail |
| `TG_MAX_ZERO_SHIP` | `50` | Consecutive zero-ship sessions before bail |
| `TG_BACKOFF_BASE` | `15` | Base seconds for fast-failure backoff |
| `TG_BACKOFF_MAX` | `120` | Cap for fast-failure backoff in seconds |
| `TG_NET_WAIT` | `30` | Network polling interval in seconds |
| `TG_NET_MAX_WAIT` | `14400` | Max time to wait for network recovery (4h) |
| `TG_NET_RETRIES` | `3` | Network check retry attempts before declaring down |
| `TG_NET_RETRY_DELAY` | `2` | Seconds between network check retries |
| `TG_NET_CHECK_URL` | `https://connectivitycheck.gstatic.com/generate_204` | Override the fallback curl connectivity URL when `network-watchdog` is unavailable |
| `TG_GIT_SYNC_TIMEOUT` | `30` | Max seconds for between-session git sync |
| `TG_SYNC_INTERVAL` | `5` | Git sync every N sessions (0=every) |
| `TG_EMPTY_QUEUE_WAIT` | `600` | Seconds to wait after an empty sweep before giving up |
| `TG_EARLY_EXIT_ON_STALL` | `0` | Exit on low throughput (1=enabled) |
| `TG_MAX_INSTANCES` | `2` | Max concurrent instances per repo |
| `TG_DEVIN_PATH` | auto | Override devin binary path |
| `TG_LOG` | auto | Override log file path |
| `TG_STATUS_FILE` | (disabled) | Write machine-readable runtime status JSON to this path |
| `TG_NOTIFY` | `1` | Desktop notification on completion |
| `TG_SHUTDOWN_GRACE` | `120` | Seconds to wait for current session on exit |
| `TG_SESSION_GRACE` | `15` | Seconds to wait after session SIGINT before SIGTERM |

## Monitoring

```bash
# Use the log path shown in the startup banner, or:
tail -f "${TMPDIR:-/tmp}"/taskgrind-*.log   # watch live progress
cat "${TMPDIR:-/tmp}"/taskgrind-*.log       # review completed sessions
```

Each session logs: start time, remaining minutes, task count, exit code, duration, and shipped count. When a session removes a completed task but concurrent additions, rollover, or non-local queue churn hide that work from the raw before/after task count, taskgrind logs both `productive_zero_ship` and `shipped_inferred` so operators can see why the session still counted as shipped. The `grind_done` summary includes ship rate, remaining tasks, and average session duration.

For machine-readable monitoring, set `TG_STATUS_FILE` to a JSON file path:

```bash
TG_STATUS_FILE=/tmp/taskgrind-status.json taskgrind ~/apps/myrepo 8
cat /tmp/taskgrind-status.json
```

The status file updates atomically on startup, before and after each session, during empty-queue sweeps and wait windows, during network waits, and on final completion or failure. It includes the repo, process ID, slot, backend, skill, model, current session, remaining minutes, current phase, and the most recent session result.

Supervisor example:

```bash
#!/bin/sh
status_file="${TMPDIR:-/tmp}/taskgrind-status.json"

phase=$(python3 - <<'PY' "$status_file"
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
print(payload.get("current_phase", "missing"))
print(payload.get("last_session", {}).get("result", "none"))
PY
)

current_phase=$(printf '%s\n' "$phase" | sed -n '1p')
last_result=$(printf '%s\n' "$phase" | sed -n '2p')

case "$current_phase" in
  running_session|running_sweep|preflight|cooldown|git_sync|queue_refilled|session_complete)
    echo "healthy: let the grind keep running"
    ;;
  queue_empty_wait|blocked_wait)
    echo "idle: wait unless the repo should have work right now"
    ;;
  waiting_for_network)
    echo "degraded: alert only after the outage outlives TG_NET_MAX_WAIT"
    ;;
  failed)
    echo "page now: inspect the log and resume after fixing the cause"
    ;;
  complete)
    if [ "$last_result" = "completed" ]; then
      echo "done: no restart needed unless new tasks arrived"
    else
      echo "finished with a non-success result: inspect before restarting"
    fi
    ;;
  *)
    echo "unknown phase: inspect the status file and log before acting"
    ;;
esac
```

This pattern works well in `launchd`, `systemd`, or a lightweight cron watchdog:
page on `failed`, keep waiting through `queue_empty_wait`, and only auto-restart
after `complete` when new tasks or a fresh schedule justify another grind.

Status payload fields:

| Field | Type | Meaning |
|-------|------|---------|
| `repo` | string | Absolute or user-supplied repo path being ground |
| `pid` | number | Process ID of the current `taskgrind` run |
| `slot` | number | Claimed concurrency slot for this repo (`0` owns git sync) |
| `backend` | string | Active backend such as `devin`, `claude-code`, or `codex` |
| `skill` | string | Skill prompt sent to each session |
| `model` | string | Resolved model name currently in use |
| `session` | number | Session counter for the current grind run |
| `remaining_minutes` | number | Whole minutes left until the current deadline, floored at `0` |
| `current_phase` | string | Current lifecycle phase such as `startup`, `preflight`, `running_session`, `cooldown`, `waiting_for_network`, `queue_empty_wait`, `git_sync`, `complete`, or `failed` |
| `updated_at` | string | Last write time in local ISO-like timestamp format (`%Y-%m-%dT%H:%M:%S%z`) |
| `last_session.number` | number | Most recently finished session number, or `0` before any session completes |
| `last_session.result` | string | Result label for the most recent session, such as `completed`, `timeout`, `network_wait`, or `none` before the first session |
| `last_session.exit_code` | number or `null` | Backend exit code for the most recent session, or `null` before the first completed session |
| `last_session.shipped` | number | Tasks shipped by the most recent session |
| `last_session.duration_seconds` | number | Runtime of the most recent session in seconds |
| `last_session.completed_at` | string | Completion timestamp for the most recent session, or empty string before any session completes |

Example lifecycle snapshots:

```json
{
  "repo": "/Users/alex/apps/myrepo",
  "pid": 48122,
  "slot": 0,
  "backend": "devin",
  "skill": "next-task",
  "model": "gpt-5.4",
  "session": 0,
  "remaining_minutes": 479,
  "current_phase": "preflight",
  "updated_at": "2026-04-11T18:05:12-0700",
  "last_session": {
    "number": 0,
    "result": "none",
    "exit_code": null,
    "shipped": 0,
    "duration_seconds": 0,
    "completed_at": ""
  }
}
```

```json
{
  "repo": "/Users/alex/apps/myrepo",
  "pid": 48122,
  "slot": 0,
  "backend": "devin",
  "skill": "next-task",
  "model": "gpt-5.4",
  "session": 3,
  "remaining_minutes": 451,
  "current_phase": "running_session",
  "updated_at": "2026-04-11T18:33:44-0700",
  "last_session": {
    "number": 2,
    "result": "completed",
    "exit_code": 0,
    "shipped": 1,
    "duration_seconds": 742,
    "completed_at": "2026-04-11T18:32:58-0700"
  }
}
```

```json
{
  "repo": "/Users/alex/apps/myrepo",
  "pid": 48122,
  "slot": 0,
  "backend": "devin",
  "skill": "next-task",
  "model": "gpt-5.4",
  "session": 3,
  "remaining_minutes": 449,
  "current_phase": "waiting_for_network",
  "updated_at": "2026-04-11T18:35:21-0700",
  "last_session": {
    "number": 3,
    "result": "network_wait",
    "exit_code": 1,
    "shipped": 0,
    "duration_seconds": 12,
    "completed_at": "2026-04-11T18:35:19-0700"
  }
}
```

```json
{
  "repo": "/Users/alex/apps/myrepo",
  "pid": 48122,
  "slot": 0,
  "backend": "devin",
  "skill": "next-task",
  "model": "gpt-5.4",
  "session": 7,
  "remaining_minutes": 0,
  "current_phase": "complete",
  "updated_at": "2026-04-12T02:05:01-0700",
  "last_session": {
    "number": 7,
    "result": "completed",
    "exit_code": 0,
    "shipped": 1,
    "duration_seconds": 801,
    "completed_at": "2026-04-12T02:04:55-0700"
  }
}
```

In practice, `current_phase` moves from startup and preflight into active work (`running_sweep` or `running_session`), then through transitional phases such as `queue_refilled`, `session_complete`, `cooldown`, `git_sync`, `queue_empty_wait`, or `blocked_wait`. Temporary interruptions show up as `waiting_for_network` and then `network_restored`. Sweep-only runs still record the sweep as the latest completed session before normal shutdown rewrites the file one last time as `complete`; argument or runtime failures finish as `failed`.

### Live prompt injection

While taskgrind is running, create or edit `.taskgrind-prompt` in the target repo to add instructions to every subsequent session:

```bash
echo "focus on test coverage" > ~/apps/myrepo/.taskgrind-prompt
```

The file is re-read before each session. Combined with `--prompt` if both are set. Delete the file to stop injecting.
Files larger than 10 KB are skipped as a safety guard to avoid accidentally
injecting generated output or other large blobs, and taskgrind logs a warning
like `⚠ .taskgrind-prompt too large (12345B > 10240B) — skipping` so operators
can see why the override did not apply.

### Live model switching

Switch models mid-grind without restarting — useful for switching from a powerful model to a faster one for simpler tasks:

```bash
echo "gpt-5.4" > ~/apps/myrepo/.taskgrind-model
```

The file is re-read before each session. Overrides `--model` and `TG_MODEL` when present. Short aliases such as `opus`, `sonnet`, `haiku`, `codex`, `gpt`, and `swe` resolve to the current preferred model IDs. Delete the file to revert to the original startup model. Files larger than 1 KB are skipped as a safety guard, and taskgrind logs a warning like `⚠ .taskgrind-model too large (2048B > 1024B) — skipping`.

Both override files are only applied between sessions. The current in-flight
session keeps its original prompt and model, and the next session picks up the
updated file content.

### Concurrent instances on one repo

By default, taskgrind allows two concurrent grinds on the same repo. Raise
`TG_MAX_INSTANCES` above `2` to allow more:

```bash
TG_MAX_INSTANCES=3 taskgrind ~/apps/myrepo 8
```

Each running grind claims the lowest free slot (`0`, `1`, ...). Slot 0 remains the primary instance and owns the between-session git sync. Higher slots skip that sync and get extra prompt guidance to avoid overlapping file edits.

Operator example for a three-slot run:

```bash
# Terminal 1: primary instance
TG_MAX_INSTANCES=3 taskgrind ~/apps/myrepo 8

# Terminal 2: second worker
TG_MAX_INSTANCES=3 taskgrind ~/apps/myrepo 8

# Inspect current ownership before launching a third worker
TG_MAX_INSTANCES=3 taskgrind --preflight ~/apps/myrepo
```

Expected preflight header while two grinds are already active:

```text
taskgrind --preflight
  repo:     /Users/you/apps/myrepo
  backend:  devin
  skill:    next-task
  model:    claude-opus-4-6
  slots:    2/3 active
```

Conflict-avoidance expectations by slot:

- `slot 0` is the only instance that performs the between-session `git fetch` / `rebase` sync cycle
- `slot 1+` skips that sync, rebases just before committing, and should prefer `TASKS.md` updates, audits, docs, or other non-overlapping files when slot 0 is editing code
- If all slots are occupied, taskgrind prints which process owns each slot and tells you to raise `TG_MAX_INSTANCES` before starting another grind

Supported two-stream workflow for one repo:

- Keep `slot 0` on the normal `next-task` lane so it keeps shipping removable work from `TASKS.md`
- Put `slot 1` on a discovery skill such as `standing-audit-gap-loop`, but back it with the reusable standing-loop pattern instead of a sacrificial repo-local audit task
- Define that discovery lane task in `TASKS.md` with durable metadata such as `**ID**: discovery-standing-loop` and `**Tags**: standing-loop, audit, queue`; taskgrind treats that as a valid queue-maintenance lane even though the task definition itself is meant to persist
- Let the discovery lane add normal tasks back into `TASKS.md`; `slot 0` then picks them up and removes only the shipped work items, while the standing-loop definition remains available for the next discovery pass
- If you point taskgrind at an audit-only skill without that standing-loop marker, taskgrind refuses audit-only sessions unless `TASKS.md` already contains a supported discovery-lane standing-loop task

Example standing-loop definition:

```markdown
# Tasks

## P0
- [ ] Keep the discovery lane replenishing the queue
  **ID**: discovery-standing-loop
  **Tags**: standing-loop, audit, queue
  **Details**: Continuously discover high-value follow-up work for slot 0 to ship.
  **Files**: `TASKS.md`, `docs/user-stories.md`
  **Acceptance**: The discovery lane keeps adding normal removable tasks while this standing-loop definition remains available for the next pass.
```

### Resuming an interrupted grind

If taskgrind is interrupted unexpectedly, rerun it with `--resume` in the same repo:

```bash
taskgrind --resume ~/apps/myrepo
```

Taskgrind saves resumable runtime state in `~/apps/myrepo/.taskgrind-state` while the grind is active. A resumed run restores the original deadline, session counter, shipped count, backend, skill, model, and baseline focus prompt instead of starting from session 1 again.

The saved state file is a flat `key=value` snapshot, not JSON. Today it stores
the schema `version`, absolute `repo`, resumability `status`, `deadline`,
`session`, `tasks_shipped`, `sessions_zero_ship`, `consecutive_zero_ship`,
`backend`, `skill`, `model`, `startup_model`, and `startup_prompt`. The saved
focus prompt is the baseline `--prompt` or `TG_PROMPT` text from startup;
repo-local `.taskgrind-prompt` edits still stay live-only and are re-read on
resume. See `docs/resume-state.md` for the current contract and validation
rules.

Use `--resume` when the previous run was interrupted by a terminal crash,
reboot, or similar external interruption. Prefer a fresh `taskgrind` launch
when you intentionally want a new deadline or different runtime settings. If
the saved deadline already expired, taskgrind rejects the stale state and tells
you to start fresh. Resume also requires the original `--backend`, `--model`,
`--skill`, and baseline `--prompt` / `TG_PROMPT` inputs to match. If you try to
resume with different overrides, taskgrind rejects that mismatch explicitly so
a resumed grind does not silently change direction.

## Troubleshooting

Use this playbook when an unattended grind looks stuck, blocked, or noisy. Start
with the status file when `TG_STATUS_FILE` is enabled, then confirm the same
story in the log named in the startup banner.

| Symptom | Inspect | Recovery |
|-------|---------|---------|
| Queue looks stuck even though the process is alive | `current_phase` in `TG_STATUS_FILE`; log lines containing `queue_empty_wait`, `blocked_wait`, or `running_sweep` | If the phase is `queue_empty_wait` or `blocked_wait`, leave the grind running while another agent or operator refills or unblocks `TASKS.md`. If the repo should already have work, open `TASKS.md` and fix claimed/blocking entries instead of restarting immediately. |
| Another terminal says the repo is busy or a new worker will not start | `taskgrind --preflight ~/apps/myrepo` for `slots: N/M active`; the active-slot owner list in preflight output; `current_phase` in `TG_STATUS_FILE` for the active worker | Wait for a slot to free up, or raise `TG_MAX_INSTANCES` before starting another grind. Keep slot `0` as the sync owner; point higher slots at docs, audits, `TASKS.md` maintenance, or status-file supervision instead of overlapping code edits. |
| Sessions keep ending with zero shipped tasks | `last_session.result`, `last_session.shipped`, and log markers such as `productive_zero_ship`, `shipped_inferred`, or repeated `tasks_after=` counts | Read the last few session summaries before killing the run. If the queue is churning under another agent, taskgrind may still be shipping work. If the same task is being retried without progress, tighten the prompt, split the task, or remove the blocker in `TASKS.md` before resuming. |
| Network outages pause progress for too long | `current_phase=waiting_for_network`; log lines around connectivity retries and `network_restored` | Let taskgrind hold the deadline open during short outages. If the outage exceeds `TG_NET_MAX_WAIT`, restore connectivity first, then restart with `taskgrind --resume ~/apps/myrepo` to keep the original grind context. |
| `--resume` refuses to continue | The rejection message in stderr; `.taskgrind-state`; `docs/resume-state.md` for the saved field contract | Fix the mismatch the message calls out: rerun with the same repo plus the same `--backend`, `--model`, `--skill`, and baseline `--prompt` / `TG_PROMPT` inputs, restore the missing state file, or start a fresh grind if the deadline already expired. Do not copy stale state across repos. |
| Final push or sync fails during shutdown | The final `git push` / `git pull --rebase` lines in the log; `git status --short`; `git log --oneline --decorate -5` | Resolve the git problem in the repo first, usually with `git pull --rebase` for incoming changes or by fixing the rejected push target. Then rerun `taskgrind --resume ~/apps/myrepo` if the run was interrupted mid-shutdown. |

Safe recovery loop:

1. Read `TG_STATUS_FILE` to learn whether the grind is working, waiting, or failed.
2. Tail the matching log file to confirm the latest session result and git state.
3. If slot `0` is already active, keep later slots on supervision or other non-overlapping work until the sync lane is free.
4. Run `taskgrind --preflight ~/apps/myrepo` before adding more workers or after clearing a blocker.
5. Prefer `taskgrind --resume ~/apps/myrepo` after crashes, reboots, or push failures so the original session counters and deadline survive.
6. If resume is rejected, retry with the original startup overrides or start a fresh run on purpose.

## Development

```bash
make install    # symlink to /usr/local/bin + install man page
make audit      # run the local repo audit workflow
make lint       # shellcheck
make test       # bats test suite (cached, auto-capped parallelism)
make test-force # rerun the selected bats suite without cache
make test TESTS=tests/bash-compat.bats  # targeted rerun with its own cache key
make test TEST_JOBS=4  # override the auto-capped parallelism for diagnostics
make check      # lint + test
make uninstall  # remove symlink and man page
```

Requires: [bats-core](https://github.com/bats-core/bats-core), [shellcheck](https://www.shellcheck.net/)

```bash
# macOS
brew install bats-core shellcheck

# Ubuntu / Debian
sudo apt-get update
sudo apt-get install -y npm shellcheck
sudo npm install -g bats

# Fedora / RHEL
sudo dnf install -y bats ShellCheck
```

On Linux, the supported `bats` install path is the npm flow above so local
`make check` runs match the GitHub Actions CI environment.

## History

Extracted from [dotfiles](https://github.com/cbrwizard/dotfiles) where it lived as `dvb-grind`. The `dvb-grind` name still works as a shell alias in dotfiles for backward compatibility.

## Docs

- [User Stories](docs/user-stories.md) — real usage patterns with commands and sample output
- [Architecture](docs/architecture.md) — design decisions and rationale
- [Resume State](docs/resume-state.md) — saved-state fields, validation rules, and restore behavior

## License

MIT
