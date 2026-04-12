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
☕ taskgrind: 4h (until 13:00) — backend=devin, skill=next-task, model=claude-opus-4-6-thinking, repo=/Users/you/apps/myproject
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
  model:    claude-opus-4-6-thinking
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
  model:    claude-opus-4-6-thinking
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

## 8. Switching models mid-grind

You start a long grind with a stronger model for ambiguous work, then switch to a faster one once the remaining tasks are mostly straightforward docs or tests.

```bash
# Start with a stronger model for harder tasks
taskgrind --model claude-opus-4-6-thinking ~/apps/myproject 6

# Later, switch future sessions to a faster model
echo "claude-sonnet-4.6" > ~/apps/myproject/.taskgrind-model
```

What happens:
- Session 1 starts with the model passed via `--model`
- Taskgrind checks `.taskgrind-model` between sessions, so the change applies at the next session start
- The current in-flight session keeps running on its original model
- When the next session picks up the change, taskgrind writes a live model log entry before the next session banner
- This is useful when you want deeper reasoning early, then faster turnaround once the queue gets simpler

Sample log:
```
[pid=38291] [09:00] session=1 remaining=360m tasks=9 model=claude-opus-4-6-thinking
[pid=38291] [09:42] session=1 ended exit=0 duration=2520s tasks_after=8 shipped=1
[pid=38291] [09:47] live_model=claude-sonnet-4.6 (startup=claude-opus-4-6-thinking)
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

Sample log:
```
[pid=38291] [14:00] session=3 remaining=240m tasks=7 model=claude-sonnet-4.6
[pid=38291] [14:36] session=3 ended exit=0 duration=2160s tasks_after=6 shipped=1
[pid=38291] [14:41] live_prompt=.taskgrind-prompt loaded bytes=58
[pid=38291] [14:41] session=4 remaining=199m tasks=6 model=claude-sonnet-4.6
```
