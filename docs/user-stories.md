# User Stories

## TL;DR

These stories show how operators actually run taskgrind: a single overnight
lane, multiple concurrent lanes on one repo, live prompt and model steering,
and status-file-based supervision. Read the story closest to your setup first,
then copy its command pattern instead of reverse-engineering behavior from the
full README.

Sessions should exit before context fills; context exhaustion can crash the
process and lose uncommitted work.

Real usage patterns for taskgrind. Each story shows the context, command, what happens, and sample log output. In every case, keep sessions short enough to exit and commit before the model context fills up, because a context-exhausted crash loses that session's uncommitted work.

## 1. Overnight grind on a repo with tasks

You have a repo with a `TASKS.md` full of work items. You want to leave the machine grinding overnight and come back to shipped tasks in the morning.

```bash
taskgrind ~/apps/myproject 8
```

What happens:
- Taskgrind launches AI sessions in a loop, each picking the highest-priority task from `TASKS.md`
- Each session implements a task, commits, removes it from `TASKS.md`, and exits
- The safe operating rule is "finish before context fills": if one session grows too large and crashes from context exhaustion, any uncommitted work from that run is lost even though the next session can resume from git + `TASKS.md`
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
☕ taskgrind: 4h (until 13:00) — backend=devin, skill=next-task, model=claude-opus-4-7-max, repo=/Users/you/apps/myproject
   Each session runs next-task. Git sync every 5 sessions.
   Focus: focus on test coverage
   Log: ${TMPDIR:-/tmp}/taskgrind-2025-01-15-0900-myproject-38291.log
```

## 2a. Reusable backend and model defaults via environment

You restart the same grind pattern often from a shell wrapper, `launchd` job,
or watchdog script. You want those restarts to keep the same backend or model
without repeating long flag lists every time.

```bash
TG_BACKEND=codex TG_MODEL=o3 taskgrind ~/apps/myproject 6

# Or keep the defaults in a wrapper and launch with a short command later
export TG_BACKEND=claude-code
export TG_MODEL=sonnet
taskgrind ~/apps/myproject 6
```

What happens:
- Taskgrind reads `TG_BACKEND` and `TG_MODEL` before session 1, so the startup banner and preflight checks use those defaults exactly as if you had passed `--backend` and `--model`
- This is useful for reusable automation because a restart can inherit the same baseline choices without editing the wrapper command itself
- Model aliases such as `sonnet` still resolve to the current preferred concrete model ID at launch time
- If you need a one-off run with different settings, pass flags on that command; explicit flags stay the clearest option for ad hoc overrides you want visible in shell history
- Repo-local `.taskgrind-model` still wins later between sessions, so you can start with an env default and then steer a long-running grind without restarting it

## 3. Multi-repo grind

You have tasks spread across two repos. Run one grind per repo, either sequentially or in separate terminals.

```bash
# Terminal 1
taskgrind ~/apps/frontend 6

# Terminal 2
taskgrind ~/apps/backend 6
```

What happens:
- Each repo gets its own lock namespace, so the two repos run independently without cross-repo contention
- Each gets its own log file (includes repo name + PID)
- Both use caffeinate to prevent system sleep
- Same-repo concurrency is handled separately by the slot-based workflow in story `4`

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
- Slot `0` is the only instance that runs the between-session git sync, which avoids dueling fetch/rebase loops when multiple terminals share one repo
- Slot `1` and above skip that sync and get prompt instructions to avoid overlapping edits, prefer audits/docs/queue work or status-file supervision, and run `git pull --rebase` before committing
- If all slots are busy, taskgrind prints the current slot owners instead of starting a conflicting fourth grind

## 4a. Running an execution lane and a discovery lane together

You want one grind to keep shipping normal tasks while a second grind keeps
finding new work for the same repo without depending on a sacrificial audit task
that disappears as soon as it is "completed".

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

```bash
taskgrind ~/apps/myproject 8
TG_MAX_INSTANCES=2 taskgrind --skill standing-audit-gap-loop ~/apps/myproject 8
```

What happens:
- Slot `0` stays on the default `next-task` execution lane and keeps removing shipped work from `TASKS.md`
- Slot `1` runs the discovery skill, but taskgrind now accepts the standardized `standing-loop` task definition as the durable lane marker
- The discovery lane can add new removable tasks back into `TASKS.md` without deleting its own standing-loop definition
- Slot `1` still needs `git pull --rebase` right before each commit because slot `0` remains the only between-session sync owner
- Newly discovered tasks flow back to slot `0`, which ships them normally while the discovery lane remains available for the next pass

## 5. Custom skill lane for pipeline management

You're managing an orchestrator that runs multiple AI pipelines. Use a real
installed skill such as `pipeline-ops` to monitor and fix pipelines instead of
picking normal repo tasks.

```bash
taskgrind --skill pipeline-ops ~/apps/bosun 10
```

What happens:
- Each session runs `pipeline-ops` instead of `next-task`
- The skill monitors pipelines, fixes failures, and restarts the server when needed
- `--skill` still accepts any installed skill, so you can swap in another real lane when your workflow needs something other than normal task picking

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
- The status file complements, but does not replace, the context-budget guard: if prompts or tasks are too large, a session can still crash before it reaches a clean `complete` or `failed` handoff, so keep the work scoped to fit one session
- `startup`, `preflight`, `session_complete`, `queue_refilled`, and `network_restored` are short-lived transition phases, so treat them as healthy unless they stick around unexpectedly
- `queue_empty`, `all_tasks_blocked`, `deadline_expired`, and `audit_focus_blocked` are short-lived explanation phases that usually roll straight into `complete` after taskgrind decides to stop
- `queue_empty_wait` means "the queue is empty, keep watching for refills", not "the grind is broken"
- `git_sync_skipped` means a higher slot intentionally skipped the slot-0-only sync, so do not page just because slot `1+` reports it
- `waiting_for_network` means "pause and keep the deadline alive", so alert only if that phase outlives your expected outage budget
- `failed` means the wrapper should inspect the log immediately, while `complete` usually means the run ended cleanly and only needs a restart if new work arrived

Example watchdog:

```bash
python3 - <<'PY'
import json
from pathlib import Path

payload = json.loads(Path("/tmp/taskgrind-status.json").read_text())
phase = payload["current_phase"]

if phase in {
    "startup",
    "preflight",
    "running_session",
    "running_sweep",
    "queue_refilled",
    "session_complete",
    "cooldown",
    "git_sync",
    "git_sync_skipped",
    "network_restored",
}:
    print("healthy: keep waiting")
elif phase in {"queue_empty_wait", "blocked_wait"}:
    print("idle: wait for new tasks or an unblock")
elif phase == "waiting_for_network":
    print("degraded: alert only if the outage lasts too long")
elif phase in {"queue_empty", "all_tasks_blocked", "deadline_expired", "audit_focus_blocked"}:
    print("ending soon: inspect the reason, but do not page unless the stop was unexpected")
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
  model:    claude-opus-4-7-max
  cooldown: 5s
  log:      ${TMPDIR:-/tmp}/taskgrind-2025-01-15-0900-myproject-38291.log
  status:   disabled
  notify:   1
  max_session: 3600s
  early_exit_on_stall: 0
```

Preflight output:
```
taskgrind --preflight
  repo:     /Users/you/apps/myproject
  backend:  devin
  skill:    next-task
  model:    claude-opus-4-7-max
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

Your terminal crashes or the machine reboots mid-session, but you want to keep
the same deadline and session counters instead of starting from scratch.

```bash
# Continue the interrupted run in the same repo
taskgrind --resume ~/apps/myproject

# If the original run started with explicit overrides, repeat them
taskgrind --resume --backend codex --model o3 --skill next-task \
  --prompt "focus on tests" ~/apps/myproject
```

What happens:
- Taskgrind loads `~/apps/myproject/.taskgrind-state` and validates that it
  still belongs to the same repo and active run
- The resumed grind restores the original deadline, session counter,
  shipped-task totals, zero-ship counters, backend, skill, startup prompt
  baseline, and startup model baseline
- Resume is strict on purpose: if the saved deadline already expired, the repo
  changed, or you now ask for a different backend, model, skill, or baseline
  prompt, taskgrind exits with a clear reason instead of silently mixing runs
- Repo-local live overrides still work after resume because taskgrind restores
  the saved startup baseline and then keeps re-reading `.taskgrind-prompt` and
  `.taskgrind-model` between later sessions
- Resume continues from the last clean git state only. It cannot recover
  uncommitted edits from the interrupted session if that session crashed after
  its context filled up
- On clean completion, taskgrind removes the state file again

Sample output:
```
☕ taskgrind: 6h (until 15:00) — backend=devin, skill=next-task, model=claude-opus-4-7-max, repo=/Users/you/apps/myproject
   Resuming: session=3 shipped=2 zero-ship=1
   Each session runs next-task. Git sync every 5 sessions.
   Log: ${TMPDIR:-/tmp}/taskgrind-2025-01-15-0900-myproject-38291.log
```

Common resume failures:

- `deadline expired` → the saved run is already over; start a fresh grind
- `repo mismatch` or `state file is malformed` → the saved file is stale or damaged
- `backend override does not match saved state`, `model override does not match saved state`, `prompt override does not match saved state`, or `skill does not match saved state` → rerun with the same baseline choices as the interrupted grind

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
print(payload.get("last_session", {}).get("result", "pending"))
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
- Once the underlying problem is fixed, `taskgrind --resume ~/apps/myproject` keeps the original deadline and counters, but only if you reuse the same backend, model, skill, and baseline prompt overrides from the original run

Recovery cheat sheet:

| Symptom | Signal to inspect | Recommended action |
|-------|---------|---------|
| Empty queue or blocked queue | `current_phase=queue_empty_wait` or `blocked_wait` | Add or unblock tasks, then let the next wait cycle refill naturally |
| Slot contention | `slots: N/M active` plus slot owners in `--preflight` | Wait for a free slot or raise `TG_MAX_INSTANCES`; keep higher slots on non-overlapping work |
| Repeated zero-ship sessions | `last_session.shipped`, `productive_zero_ship`, `shipped_inferred` in the log | Check whether another agent changed `TASKS.md`; split or unblock the task before resuming |
| Productive sessions still hitting the clock | `productive_timeout session=N shipped=X timeout=Ys new_timeout=Zs` in the log | No action required — taskgrind already bumps `TG_MAX_SESSION` by 1800 s (cap 7200 s) so the next session gets more runway. If the log shows `(at cap)` and tasks still time out, split the task instead of raising the budget further. |
| Low throughput warning late in a grind | `diminishing_returns window=5 shipped=N` in the log; stdout line `⚠ Low throughput:` | Advisory by default. Inspect whether the remaining queue is blocked, overstuffed, or architecturally hard. Set `TG_EARLY_EXIT_ON_STALL=1` in advance if you want taskgrind to exit the loop (log marker `early_exit_stall`, status phase `failed`) when the same window fires again. |
| Resume rejected | `taskgrind --resume` stderr | Re-run with the original `--backend`, `--model`, `--skill`, and baseline `--prompt` / `TG_PROMPT` inputs, or start a fresh grind if the deadline expired |
| Final push rejected | Last `git push` line in the log | Repair the branch with `git pull --rebase`, then rerun `--resume` with the original startup overrides if the interrupted grind did not use pure defaults |

## 7b. Producing work for review without auto-publishing

You want a grind to build a stack of local commits you can review before
anything reaches `origin`. The default grind pushes on every exit path and
tells the agent to merge PRs, so "do not publish" only sticks when both the
script and the prompt agree.

```bash
# CLI flag
taskgrind --no-push 8 ~/apps/myproject

# Or via env (useful in launchd / cron / wrapper scripts)
TG_NO_PUSH=1 taskgrind 8 ~/apps/myproject
```

What happens:
- The session prompt's COMPLETION PROTOCOL is rewritten to NO-PUBLISH MODE:
  the agent is told not to run `git push`, `gh pr create`, or `gh pr merge`,
  and to finish each task by removing the block from `TASKS.md` and
  committing locally only
- `final_sync` no longer pushes on exit. When local commits are ahead of
  origin, taskgrind logs
  `final_sync would_push commits=N head=<sha>`
  and prints a one-line "ready for review" notice instead of running
  `git push`
- The flag survives `--resume`: an interrupted no-publish grind stays
  no-publish on restart unless you pass an explicit override
- Multi-instance grinds (`TG_MAX_INSTANCES > 1`) inherit the flag through
  the standard CLI re-exec, so every slot honours the same gate
- Between-session `git_sync` is unaffected — it still does `fetch` and
  `rebase`, both of which are read-only against origin

Operator follow-up after the grind exits:

```bash
# Review what the grind staged on main (or the working branch)
git -C ~/apps/myproject log --oneline @{u}..HEAD
git -C ~/apps/myproject diff @{u}..HEAD

# Push manually once you are satisfied
git -C ~/apps/myproject push origin HEAD
```

Sample log lines:

```
[pid=…] [HH:MM] final_sync would_push commits=4 head=<sha>
   🛑 No-publish mode: 4 local commit(s) ready for review (head=<sha>). Push manually after review.
```

## 8. Switching models mid-grind

You start a long grind with a stronger model for ambiguous work, then switch to a faster one once the remaining tasks are mostly straightforward docs or tests.

```bash
# Start with a stronger model for harder tasks
taskgrind --model opus ~/apps/myproject 6

# Later, switch future sessions to a faster model
echo "claude-sonnet-4.6" > ~/apps/myproject/.taskgrind-model
```

What happens:
- Session 1 starts with the alias-resolved model passed via `--model`
- Taskgrind checks `.taskgrind-model` between sessions, so the change applies at the next session start
- The current in-flight session keeps running on its original model
- When the next session picks up the change, taskgrind writes a live model log entry before the next session banner
- This is useful when you want deeper reasoning early, then faster turnaround once the queue gets simpler
- Delete `.taskgrind-model` later to fall back to the startup model without restarting the grind

Sample log:
```
[pid=38291] [09:00] session=1 remaining=360m tasks=9 model=claude-opus-4-7-max
[pid=38291] [09:42] session=1 ended exit=0 duration=2520s tasks_after=8 shipped=1
[pid=38291] [09:47] live_model=claude-sonnet-4.6 (startup=claude-opus-4-7-max)
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
- If `.taskgrind-prompt` grows past 10 KB, taskgrind skips it and logs a warning instead of injecting a huge blob by accident
- Delete `.taskgrind-prompt` to stop injecting the extra focus text and return to the startup prompt only

Sample log:
```
[pid=38291] [14:00] session=3 remaining=240m tasks=7 model=claude-sonnet-4.6
[pid=38291] [14:36] session=3 ended exit=0 duration=2160s tasks_after=6 shipped=1
[pid=38291] [14:41] live_prompt=.taskgrind-prompt loaded bytes=58
[pid=38291] [14:41] session=4 remaining=199m tasks=6 model=claude-sonnet-4.6
```

If the file is too large, the log instead shows a warning such as:

```
   ⚠ .taskgrind-prompt too large (12345B > 10240B) — skipping
```

The same live-session rules apply to `.taskgrind-model`: taskgrind re-reads it
between sessions, ignores files larger than 1 KB, and logs a warning like
`⚠ .taskgrind-model too large (2048B > 1024B) — skipping` when the override is
rejected.

## 10. Same task keeps failing — the skip list takes over

A grind has been running for a few hours and you notice the same task
`refactor-auth-adapter` appears in the log session after session without
shipping. Taskgrind is tracking per-task attempts and will cut the task from
the prompt once it hits 3 unproductive sessions so the remaining queue can
keep moving.

Sample log showing the transition:
```
[pid=38291] [11:00] session=4 remaining=420m tasks=9 model=claude-opus-4-7-max
[pid=38291] [11:45] session=4 ended exit=0 duration=2700s tasks_after=9 shipped=0
[pid=38291] [11:50] session=5 remaining=375m tasks=9 model=claude-opus-4-7-max
[pid=38291] [12:35] session=5 ended exit=0 duration=2700s tasks_after=9 shipped=0
[pid=38291] [12:40] session=6 remaining=330m tasks=9 model=claude-opus-4-7-max
[pid=38291] [13:25] session=6 ended exit=0 duration=2700s tasks_after=9 shipped=0
[pid=38291] [13:25] task_skip_threshold ids=refactor-auth-adapter
[pid=38291] [13:30] session=7 remaining=285m tasks=9 model=claude-opus-4-7-max
```

Session 7's prompt (shown by `taskgrind --dry-run` style expansion) now
includes:
```
Run the next-task skill. Session 7, 285 minutes remaining, timeout 3600s.
COMPLETION PROTOCOL: …
AUTONOMY: …
Previous session: session_exit=0 shipped=0 tasks_before=9 tasks_after=9.
SKIP these stuck tasks (attempted 3+ times): refactor-auth-adapter. Work on
other tasks instead. Commit before timeout. Do not exhaust context.
```

What happens:
- Sessions 4–6 each incremented the counter for `refactor-auth-adapter` by 1 because the task ID stayed in `TASKS.md`
- Session 6 crossed the 3-attempt threshold, so taskgrind logs `task_skip_threshold ids=refactor-auth-adapter` exactly once that session
- Every following session prepends the `SKIP these stuck tasks…` line until the task is removed
- Shipping the task (or deleting the block) clears its counter the next time taskgrind prunes the attempts file — the skip list does not carry across grinds or survive removal
- The 3-attempt threshold is a built-in constant today, not an env var, so operators cannot raise the cap to paper over a runaway task

Recovery options when you see this marker:
- Split the task into 2–3 sub-tasks with different IDs so each starts with a fresh counter
- Mark the task `**Blocked by**:` if it is genuinely waiting on an external event so the grind uses `blocked_wait` instead of retrying on top of the skip list
- Remove the task block if the attempt was based on stale requirements — the next session will see the queue shrink and the counter disappears with it

## 11. Interrupting a grind with Ctrl+C

An 8-hour grind is running in a terminal and you need to stop it — maybe you
realized the prompt is wrong, or a production issue needs your attention.
Hitting `^C` does not rip the running session out mid-commit. Taskgrind
converts the signal into a graceful shutdown that waits for the current
session to finish and pushes any pending commits before exiting.

Happy path — session finishes within the grace window:
```
^C
   ⏳ Waiting for session 7 to finish (up to 120s)...
   ✓ Session finished gracefully.
   📤 Pushing 2 local commit(s) to origin...
──────────────────────────────────────────
  Grind complete: 7 sessions, 4+ tasks, 2h43m
  Rate: 1.5/h  Avg session: 22m  Zero-ship: 1
  Ship rate: 57% (4/7)  Remaining: 5
  Log: /var/folders/…/taskgrind-2025-01-15-0900-myproject-38291.log
──────────────────────────────────────────
```

Matching log entries:
```
[pid=38291] [11:43] graceful_shutdown waiting pid=38502 grace=120s
[pid=38291] [11:43] graceful_shutdown session_finished after=47s
[pid=38291] [11:43] final_sync pushing commits=2
[pid=38291] [11:44] final_sync push_ok
[pid=38291] [11:44] grind_done sessions=7 shipped=4 remaining=5 …
```

Timeout path — session ignores SIGINT for longer than `TG_SHUTDOWN_GRACE`
(default 120 s):
```
^C
   ⏳ Waiting for session 7 to finish (up to 120s)...
   ⏰ Session still running after 120s — sending SIGTERM
   📤 Pushing 1 local commit(s) to origin...
──────────────────────────────────────────
  Grind complete: 7 sessions, 4+ tasks, 2h45m
  …
──────────────────────────────────────────
```

Matching log entries:
```
[pid=38291] [11:45] graceful_shutdown waiting pid=38502 grace=120s
[pid=38291] [11:47] graceful_shutdown timeout — killing pid=38502
[pid=38291] [11:47] final_sync pushing commits=1
[pid=38291] [11:47] final_sync push_ok
[pid=38291] [11:47] grind_done sessions=7 shipped=4 remaining=5 …
```

Impatient-operator path — hitting `^C` again during the grace window is a
no-op so taskgrind can finish cleanly:
```
^C
   ⏳ Waiting for session 7 to finish (up to 120s)...
^C
   (nothing new printed; taskgrind keeps waiting)
   ✓ Session finished gracefully.
```

The second signal is recorded in the log but changes nothing about the
shutdown flow:
```
[pid=38291] [11:43] graceful_shutdown waiting pid=38502 grace=120s
[pid=38291] [11:43] graceful_shutdown duplicate_signal exit=130 ignored
[pid=38291] [11:43] graceful_shutdown session_finished after=12s
```

What happens:
- Taskgrind sends `SIGINT` to the running session so the backend can commit
  its current task before exiting
- It then waits up to `TG_SHUTDOWN_GRACE` seconds (default 120) for the
  session process to exit on its own
- If the grace window expires, taskgrind sends `SIGTERM` and force-kills the
  session. Anything not committed at that point is lost — the code-change
  contract is "commit before timeout"
- `final_sync` tries one last `git push` so committed work reaches origin
  before the process exits
- Duplicate `^C` / `SIGTERM` while shutdown is in flight is logged as
  `graceful_shutdown duplicate_signal` and ignored. Spam-hitting Ctrl+C does
  not skip ahead of the grace window; the safest way to rip out is to send
  `SIGKILL` (`kill -9 <pid>`), which also loses any uncommitted work

Safe to rerun indicators:
- The `grind_done` line is printed to both stdout and the log, so seeing it
  means the marathon exited cleanly
- `final_sync push_ok` in the log means all committed work reached origin
- `final_sync push_failed` means the push was rejected (usually because
  another worker pushed first); fix the git state and either rerun
  `taskgrind --resume` or manually `git push` before starting a new grind
- The absence of `graceful_shutdown timeout` means the session got to
  commit its work naturally — a subsequent `taskgrind --resume` will pick
  up exactly where it stopped

Related environment variables:
- `TG_SHUTDOWN_GRACE` — seconds to wait for the current session before
  SIGTERM (default 120)
- `TG_SESSION_GRACE` — seconds to wait between SIGINT and SIGTERM when a
  session hits the per-session `TG_MAX_SESSION` timeout (default 15). This
  is a different code path from marathon-level Ctrl+C and only affects how
  aggressively taskgrind kills a runaway session inside the normal loop
