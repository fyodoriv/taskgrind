# User Stories

Real usage patterns for taskgrind. Each story shows the context, command, what happens, and sample log output.

## 1. Overnight grind on a repo with tasks

You have a repo with a `TASKS.md` full of work items. You want to leave the machine grinding overnight and come back to shipped tasks in the morning.

```bash
taskgrind ~/apps/myproject 8
```

What happens:
- Taskgrind launches AI sessions in a loop, each picking the highest-priority task from `TASKS.md`
- Each session implements a task, commits, removes it from `TASKS.md`, and exits
- Between sessions: 5s cooldown, git sync every 5 sessions
- After 8 hours (or when the queue empties), taskgrind exits with a summary

Sample log:
```
[pid=38291] [09:00] session=1 remaining=480m tasks=12
[pid=38291] [09:45] session=1 ended exit=0 duration=2700s tasks_after=11 shipped=1
[pid=38291] [09:45] session=2 remaining=435m tasks=11
...
[pid=38291] [17:00] grind_done sessions=10 shipped=8 remaining=4 ship_rate=67% avg_session=48m elapsed=28800s duration=8h rate=1.0/h sessions_zero_ship=2
```

## 2. Focused grind with --prompt

You want sessions to prioritize a specific area (e.g., test coverage) but still pick up other tasks if nothing matches.

```bash
taskgrind --prompt "focus on test coverage" ~/apps/myproject 4
```

What happens:
- Every session prompt includes priority framing: pick tasks matching the focus first, then fall back to unrelated tasks
- The focus shows in the startup banner and log header
- Useful for targeting a specific improvement area across many sessions

Sample banner:
```
☕ taskgrind: 4h (until 13:00) — backend=devin, skill=next-task, model=claude-opus-4-6, repo=/Users/you/apps/myproject
   Each session runs next-task. Git sync every 5 sessions.
   Focus: focus on test coverage
   Log: ${TMPDIR:-/tmp}/taskgrind-2025-01-15-0900-myproject-38291.log
```

## 3. Multi-repo grind

You have tasks spread across two repos. Run one grind per repo, either sequentially or in separate terminals.

```bash
# Terminal 1
taskgrind ~/apps/frontend 6

# Terminal 2
taskgrind ~/apps/backend 6
```

What happens:
- Each instance locks its repo (via `flock`) so two grinds can't run on the same repo
- Each gets its own log file (includes repo name + PID)
- Both use caffeinate to prevent system sleep

## 4. Concurrent grinds on one repo

You want two or three sessions working the same repo, but you need to know who owns git sync and what the non-primary workers should avoid.

```bash
# Terminal 1
TG_MAX_INSTANCES=3 taskgrind ~/apps/myproject 8

# Terminal 2
TG_MAX_INSTANCES=3 taskgrind ~/apps/myproject 8

# Before opening Terminal 3, check slot usage
TG_MAX_INSTANCES=3 taskgrind --preflight ~/apps/myproject
```

What happens:
- The first grind claims slot `0`; the second claims slot `1`
- `--preflight` prints `slots:    2/3 active`, so you can see one slot is still free before launching again
- Slot `0` is the only instance that runs the between-session git sync
- Slot `1` and above skip that sync and get prompt instructions to avoid overlapping edits, prefer audits/docs/queue work, and run `git pull --rebase` before committing
- If all slots are busy, taskgrind prints the current slot owners instead of starting a conflicting fourth grind

## 5. Fleet-grind for pipeline management

You're managing an orchestrator that runs multiple AI pipelines. Use the `fleet-grind` skill to monitor and fix pipelines instead of picking tasks.

```bash
taskgrind --skill fleet-grind ~/apps/bosun 10
```

What happens:
- Each session runs the `fleet-grind` skill instead of `next-task`
- The skill monitors pipelines, fixes failures, merges PRs
- Sessions may be longer (productive timeouts auto-increase the timeout cap)

## 5a. Monitoring a grind from `TG_STATUS_FILE`

You want a lightweight supervisor to watch one unattended grind, page only on
real failures, and avoid restarting healthy sessions that are simply waiting
for more work or network recovery.

```bash
TG_STATUS_FILE=/tmp/taskgrind-status.json taskgrind ~/apps/myproject 8
```

What happens:
- Taskgrind updates `/tmp/taskgrind-status.json` atomically at every important state change
- A wrapper can poll `current_phase` to decide whether to wait, alert, or start a fresh run later
- `queue_empty_wait` means "the queue is empty, keep watching for refills", not "the grind is broken"
- `waiting_for_network` means "pause and keep the deadline alive", so alert only if that phase outlives your expected outage budget
- `failed` means the wrapper should inspect the log immediately, while `complete` usually means the run ended cleanly and only needs a restart if new work arrived

Example watchdog:

```bash
python3 - <<'PY'
import json
from pathlib import Path

payload = json.loads(Path("/tmp/taskgrind-status.json").read_text())
phase = payload["current_phase"]

if phase in {"running_session", "running_sweep", "cooldown", "git_sync"}:
    print("healthy: keep waiting")
elif phase in {"queue_empty_wait", "blocked_wait"}:
    print("idle: wait for new tasks or an unblock")
elif phase == "waiting_for_network":
    print("degraded: alert only if the outage lasts too long")
elif phase == "failed":
    print("page now and inspect the log")
elif phase == "complete":
    print("finished cleanly; restart only if you want another pass")
else:
    print(f"inspect manually: unexpected phase {phase}")
PY
```

Why this helps:
- Dashboards can show the latest phase without scraping logs
- `launchd` or `systemd` units can distinguish "idle but healthy" from "needs intervention"
- A simple watchdog can restart only after `complete`, instead of interrupting a productive session
- You can combine `current_phase` with `last_session.result` to detect repeated zero-ship sessions before escalating

## 6. Dry-run / preflight to check before committing

Before starting an 8-hour grind, verify everything is set up correctly.

```bash
# Check config without running
taskgrind --dry-run 8 ~/apps/myproject

# Run health checks
taskgrind --preflight ~/apps/myproject
```

Dry-run output:
```
taskgrind --dry-run
  hours:    8
  repo:     /Users/you/apps/myproject
  backend:  devin
  skill:    next-task
  model:    claude-opus-4-6
  cooldown: 5s
  log:      ${TMPDIR:-/tmp}/taskgrind-2025-01-15-0900-myproject-38291.log
  notify:   1
  max_session: 3600s
  early_exit_on_stall: 1
```

Preflight output:
```
taskgrind --preflight
  repo:     /Users/you/apps/myproject
  backend:  devin
  skill:    next-task
  model:    claude-opus-4-6
  slots:    0/2 active

Preflight checks for: /Users/you/apps/myproject

  ✓ Backend binary (devin): /usr/local/bin/devin
  ✓ Network connectivity
  ✓ Git state clean
  ✓ Git remote reachable
  ✓ Disk space: 42GB free
  ✓ TASKS.md found (12 open tasks)
  ✓ network-watchdog available

  Results: 7 passed, 0 warnings, 0 failed
  ✓ Preflight passed — ready to grind.
```

## 7. Resuming an interrupted grind

Your terminal crashes or the machine reboots mid-session, but you want to keep the same deadline and session counters instead of starting from scratch.

```bash
# Continue the interrupted run in the same repo
taskgrind --resume ~/apps/myproject
```

What happens:
- Taskgrind loads `~/apps/myproject/.taskgrind-state` and validates that it still belongs to the same repo and active run
- The resumed grind restores the original deadline, session counter, shipped-task totals, zero-ship counters, backend, skill, and model
- If the saved deadline already expired or the saved state is incompatible, taskgrind exits with a clear reason instead of silently mixing runs
- On clean completion, taskgrind removes the state file again

Sample output:
```
☕ taskgrind: 6h (until 15:00) — backend=devin, skill=next-task, model=gpt-5.4, repo=/Users/you/apps/myproject
   Resuming: session=3 shipped=2 zero-ship=1
   Each session runs next-task. Git sync every 5 sessions.
   Log: ${TMPDIR:-/tmp}/taskgrind-2025-01-15-0900-myproject-38291.log
```

## 7a. Recovering a grind that looks stuck or blocked

You wake up to an unattended grind that stopped shipping tasks. You need to
decide whether it is healthy-but-idle, blocked by another worker, waiting on the
network, or actually failed.

```bash
status_file="${TMPDIR:-/tmp}/taskgrind-status.json"
python3 - <<'PY' "$status_file"
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
print(payload.get("current_phase", "missing"))
print(payload.get("last_session", {}).get("result", "none"))
print(payload.get("slot", "unknown"))
PY
tail -n 20 "${TMPDIR:-/tmp}"/taskgrind-*.log
taskgrind --preflight ~/apps/myproject
```

What happens:
- `queue_empty_wait` or `blocked_wait` means the grind is still healthy; refill or unblock `TASKS.md` instead of restarting immediately
- `waiting_for_network` means the deadline is paused for a short outage, so restore connectivity before intervening
- `failed` means you should read the log right away and fix the reported git, repo, or backend issue
- `--preflight` shows slot ownership, so you can tell whether another grind already owns the repo sync lane
- Once the underlying problem is fixed, `taskgrind --resume ~/apps/myproject` keeps the original deadline and counters

Recovery cheat sheet:

| Symptom | Signal to inspect | Recommended action |
|-------|---------|---------|
| Empty queue or blocked queue | `current_phase=queue_empty_wait` or `blocked_wait` | Add or unblock tasks, then let the next wait cycle refill naturally |
| Slot contention | `slots: N/M active` plus slot owners in `--preflight` | Wait for a free slot or raise `TG_MAX_INSTANCES`; keep higher slots on non-overlapping work |
| Repeated zero-ship sessions | `last_session.shipped`, `productive_zero_ship`, `shipped_inferred` in the log | Check whether another agent changed `TASKS.md`; split or unblock the task before resuming |
| Resume rejected | `taskgrind --resume` stderr | Fix the saved-state mismatch or start a fresh grind if the deadline expired |
| Final push rejected | Last `git push` line in the log | Repair the branch with `git pull --rebase`, then rerun `--resume` |

## 8. Switching models mid-grind

You start a long grind with a stronger model for ambiguous work, then switch to a faster one once the remaining tasks are mostly straightforward docs or tests.

```bash
# Start with a stronger model for harder tasks
taskgrind --model claude-opus-4-6 ~/apps/myproject 6

# Later, switch future sessions to a faster model
echo "claude-sonnet-4.6" > ~/apps/myproject/.taskgrind-model
```

What happens:
- Session 1 starts with the model passed via `--model`
- Taskgrind checks `.taskgrind-model` between sessions, so the change applies at the next session start
- The current in-flight session keeps running on its original model
- When the next session picks up the change, taskgrind writes a live model log entry before the next session banner
- This is useful when you want deeper reasoning early, then faster turnaround once the queue gets simpler
- Delete `.taskgrind-model` later to fall back to the startup model without restarting the grind

Sample log:
```
[pid=38291] [09:00] session=1 remaining=360m tasks=9 model=claude-opus-4-6
[pid=38291] [09:42] session=1 ended exit=0 duration=2520s tasks_after=8 shipped=1
[pid=38291] [09:47] live_model=claude-sonnet-4.6 (startup=claude-opus-4-6)
[pid=38291] [09:47] session=2 remaining=313m tasks=8 model=claude-sonnet-4.6
```

## 9. Redirecting focus mid-grind

You start a grind, then realize the next few sessions should focus on a specific bug or subsystem. Instead of stopping the run, you drop a `.taskgrind-prompt` file into the repo so the next session picks up the new direction.

```bash
# Start the grind normally
taskgrind ~/apps/myproject 6

# Mid-run, redirect the next sessions
cat > ~/apps/myproject/.taskgrind-prompt <<'EOF'
Focus on flaky tests in the checkout flow before any other work.
EOF
```

What happens:
- The current session keeps running with its original prompt
- Taskgrind checks `.taskgrind-prompt` between sessions, so the new focus applies at the next session start
- Future sessions prepend that prompt to the skill instructions until you edit or remove the file
- This is useful when production issues or new priorities show up during a long grind
- Delete `.taskgrind-prompt` to stop injecting the extra focus text and return to the startup prompt only

Sample log:
```
[pid=38291] [14:00] session=3 remaining=240m tasks=7 model=claude-sonnet-4.6
[pid=38291] [14:36] session=3 ended exit=0 duration=2160s tasks_after=6 shipped=1
[pid=38291] [14:41] live_prompt=.taskgrind-prompt loaded bytes=58
[pid=38291] [14:41] session=4 remaining=199m tasks=6 model=claude-sonnet-4.6
```
