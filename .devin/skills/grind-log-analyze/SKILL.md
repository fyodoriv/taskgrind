---
name: grind-log-analyze
description: >
  Deep post-mortem analysis of the next unanalyzed taskgrind log. Parses every session event,
  diagnoses root causes (stalls, crashes, stuck tasks, git issues), computes efficiency metrics,
  and writes actionable tasks to TASKS.md in every affected repo. Tracks which logs have been
  analyzed so it always picks up where you left off. Use when asked to "analyze the grind log",
  "what happened in the last grind", "post-mortem", "parse the log", "grind report", or after
  a taskgrind marathon completes. Don't use for running a grind (use next-task) or managing
  pipelines (use pipeline-ops).
triggers:
  - user
---

## Role

You are a **senior reliability engineer** performing deep post-mortem analysis on taskgrind
marathon logs. You extract every signal from the log, correlate it with the actual repo state,
and produce actionable tasks for every affected repo — including taskgrind itself. You never
guess — every finding cites specific log lines as evidence.

## Phase 1: Find the next unanalyzed log

### 1.1 — List all logs

```bash
ls -lt /tmp/taskgrind-*.log 2>/dev/null
ls -lt "${TMPDIR:-/tmp}"/taskgrind-*.log 2>/dev/null
```

### 1.2 — Check the analyzed-logs ledger

The ledger lives at `~/.local/share/taskgrind/analyzed-logs.txt` — one log path per line,
appended after successful analysis. Create the directory if it doesn't exist.

```bash
mkdir -p ~/.local/share/taskgrind
touch ~/.local/share/taskgrind/analyzed-logs.txt
```

### 1.3 — Pick the next log

Compare the log list against the ledger. Pick the **most recent unanalyzed** log.
If ALL logs have been analyzed, tell the user and stop.

```bash
# Find logs not yet in the ledger
comm -23 \
  <(ls -1 "${TMPDIR:-/tmp}"/taskgrind-*.log 2>/dev/null | sort) \
  <(sort ~/.local/share/taskgrind/analyzed-logs.txt) \
  | tail -1
```

If the user passes a specific log path, use that instead and skip the ledger check.

## Phase 2: Parse the log

Read the entire log file. Extract a structured timeline by parsing these event types:

### 2.1 — Header

```
# taskgrind started <date> <time>
# hours=N backend=<backend> skill=<skill> model=<model> repo=<path> [prompt=<text>]
```

Extract: `repo`, `hours`, `backend`, `skill`, `model`, `prompt`, `start_time`.

### 2.2 — Session lifecycle events

For each session, build a record:

| Field | Source pattern |
|-------|---------------|
| `session_num` | `session=N` from start line |
| `tasks_before` | `tasks=N` from start line |
| `remaining_min` | `remaining=Nm` from start line |
| `exit_code` | `exit=N` from ended line |
| `duration_secs` | `duration=Ns` from ended line |
| `tasks_after` | `tasks_after=N` from ended line |
| `shipped` | `shipped=N` from ended line |
| `was_timeout` | presence of `session_timeout session=N` |
| `was_sweep` | presence of `sweep_done` instead of session ended |

### 2.3 — Failure events

Collect every occurrence of:

| Event | Pattern | Fields |
|-------|---------|--------|
| Fast failure | `fast_fail consecutive=N backoff=Ns exit=N` | consecutive, backoff, exit |
| Bail out | `bail_out consecutive=N exit=N` | consecutive, exit |
| Network down | `network_down` | timestamp |
| Network restored | `network_restored waited=Ns` | wait_duration |
| Network timeout | `network_timeout waited=Ns` | wait_duration |
| Stall warning | `stall_warning consecutive_zero_ship=N` | count |
| Stall bail | `stall_bail consecutive_zero_ship=N` | count |
| Diminishing returns | `diminishing_returns window=N shipped=N` | window, shipped |
| Early exit stall | `early_exit_stall` | — |
| Repo missing | `repo_missing path=<path>` | path |
| Productive timeout | `productive_timeout session=N shipped=N timeout=Ns` | session, shipped, timeout |
| Task skip threshold | `task_skip_threshold ids=<id1> <id2>` | task IDs |

### 2.4 — Git sync events

| Event | Pattern |
|-------|---------|
| Sync OK | `git_sync ok` |
| Sync stashed | `git_sync ok (stashed dirty tree)` |
| Stash pop failed | `git_sync stash_pop_failed` |
| Rebase aborted | `git_sync rebase_aborted` |
| Timeout rebase abort | `git_sync timeout_rebase_aborted` |
| Timeout merge abort | `git_sync timeout_merge_aborted` |
| Sync failed | `git_sync failed: <reason>` |
| Sync skipped | `git_sync skipped (interval=N, session=N)` |
| Branch cleanup | `branch_cleanup done` |

### 2.5 — Session output blocks

Parse the embedded session output captures:

```
--- session N output (last 20 lines) ---
<agent output>
--- end session output ---
```

and

```
--- session N output (zero-ship, last 20 lines) ---
<agent output>
--- end session output ---
```

These are the most valuable diagnostic data — they show what the agent actually tried and
where it got stuck. Extract every block and associate it with the session number.

### 2.6 — Grind summary

```
[pid=N] [HH:MM] grind_done sessions=N shipped=N remaining=N ship_rate=N% avg_session=Nm elapsed=Ns duration=<human> rate=N/h sessions_zero_ship=N [prompt=<text>]
```

## Phase 3: Compute metrics

### 3.1 — Efficiency scorecard

| Metric | Formula |
|--------|---------|
| **Ship rate** | `shipped / queue_start * 100`% |
| **Throughput** | `shipped / (elapsed / 3600)` tasks/hour |
| **Session efficiency** | `sessions_with_ships / total_sessions * 100`% |
| **Avg session duration** | `total_elapsed / total_sessions` |
| **Productive time** | Sum of session durations where `shipped > 0` |
| **Wasted time** | Sum of session durations where `shipped == 0` |
| **Waste ratio** | `wasted_time / total_elapsed * 100`% |
| **Network downtime** | Sum of all `network_restored waited=Ns` |
| **Git sync overhead** | Count of git sync events * estimated sync time |

### 3.2 — Session-by-session timeline

Build a table:

```
| # | Duration | Shipped | Tasks | Exit | Notes |
|---|----------|---------|-------|------|-------|
| 1 | 45m      | 2       | 10→8  | 0    | — |
| 2 | 38m      | 1       | 8→7   | 0    | — |
| 3 | 3s       | 0       | 7→7   | 1    | fast_fail, network_down |
| 4 | 52m      | 0       | 7→7   | 143  | timeout, zero-ship |
```

### 3.3 — Stuck task identification

From `task_skip_threshold` events: list every task ID that hit the 3-attempt cap.
Cross-reference with the repo's current TASKS.md — are they still there?

### 3.4 — Throughput trend

Plot the rolling 5-session shipped window:
```
Sessions 1-5: 5 shipped (1.0/session)
Sessions 2-6: 3 shipped (0.6/session) ← declining
Sessions 3-7: 1 shipped (0.2/session) ← stalling
```

Identify the inflection point where throughput drops below 0.5/session.

## Phase 4: Diagnose root causes

Analyze the parsed data to identify WHY things went wrong. Check each pattern:

### 4.1 — Stall patterns

**Zero-ship stall** — 3+ consecutive `shipped=0` sessions:
- Read the session output blocks for those sessions
- Look for: "task requires manual steps", "blocked by", "I cannot", permission errors
- Check if the agent kept retrying the same task (compare tasks_before across sessions)

**Stuck tasks** — IDs that appeared in `task_skip_threshold`:
- The agent tried these 3+ times and failed each time
- Read session output around those sessions for the failure reason
- Check if these tasks are still in TASKS.md (they weren't completed)

**Diminishing returns** — `diminishing_returns` events:
- The last N sessions shipped almost nothing
- Often means only hard/blocked tasks remain

### 4.2 — Infrastructure failures

**Fast-failure cascade** — sessions dying in < 30s:
- Read the session output from fast-fail captures
- Common causes: API rate limits, auth expiry, broken binary, disk full

**Network outages** — `network_down` → `network_restored`:
- Calculate total downtime
- Check if deadline extension was applied correctly
- Look for sessions that crashed right before network_down (the trigger)

**Git sync failures** — `git_sync failed`, `rebase_aborted`, `stash_pop_failed`:
- Indicates conflicting changes between sessions
- Check if the repo was left in a dirty state

### 4.3 — Efficiency problems

**Productive timeouts** — `productive_timeout`:
- Sessions that shipped work but were killed by the timeout
- The agent could have shipped more if given more time
- Recommendation: increase `DVB_MAX_SESSION`

**Long zero-ship sessions** — sessions > 30min with `shipped=0`:
- Not a fast fail (ran full duration) but accomplished nothing
- The agent was working but didn't complete a task
- Read session output to understand what it was doing

**Sweep loops** — repeated `queue_empty → sweep → sweep_found`:
- Grind cleared the queue, swept for more, cleared again
- Not a problem per se, but worth noting if sweep quality is low

### 4.4 — Agent behavior issues

Read ALL session output blocks and look for:
- **Off-queue work**: Agent doing things not in TASKS.md
- **Forgot to remove task**: Agent says "done" but task count didn't decrease
- **Scope creep**: Agent expanding a simple task into a multi-hour project
- **Context exhaustion**: Signs the agent ran out of context (truncated output, repeated loops)
- **Permission denials**: Tool calls blocked by permission settings
- **Wrong branch**: Agent working on a feature branch when it should be on main

## Phase 5: Check repo state

For each repo mentioned in the log headers, check current state:

```bash
cd <repo>
git status --short
git branch --show-current
git log --oneline -5
cat TASKS.md | head -50
gh pr list --state open --json number,title,mergeable 2>/dev/null || true
```

Look for:
- **Not on default branch** — session left the repo on a feature branch
- **Uncommitted changes** — work in progress from a killed session
- **Open PRs** — unmerged work that should be landed or closed
- **Stale branches** — accumulated feature branches from past sessions
- **TASKS.md state** — do the remaining tasks match what the log shows?

Launch parallel subagents for each repo if there are multiple.

## Phase 6: Write tasks to affected repos

For every root cause identified, write a task to the appropriate repo's TASKS.md.

### 6.1 — Determine task destination

| Finding type | Destination |
|-------------|-------------|
| Taskgrind bug/improvement | `~/apps/taskgrind/TASKS.md` |
| Stuck task (needs decomposition) | The target repo's `TASKS.md` |
| Repo left in dirty state | That repo's `TASKS.md` |
| Agent behavior issue | `~/apps/taskgrind/TASKS.md` (prompt improvement) |
| Missing error handling in target | That repo's `TASKS.md` |
| Skill bug | The skill's repo TASKS.md |
| Configuration tuning | `~/apps/taskgrind/TASKS.md` |

### 6.2 — Task format

Follow the tasks.md spec strictly:

```markdown
- [ ] Outcome-shaped description of what needs to change
  **ID**: grind-log-<date>-<sequence>
  **Tags**: grind-analysis, <category>
  **Details**: <What the log showed>. Evidence: `<quoted log line>`. <Why this matters>.
    <What the fix should achieve>.
  **Files**: <affected file paths>
  **Acceptance**: <Mechanically verifiable criterion>
```

### 6.3 — Task categories and priorities

**P0** — Data loss, total stall, broken grind loop:
- Grind bailed out due to stall/fast-failure with 0 tasks shipped
- Repo left in broken git state (mid-rebase, detached HEAD)
- Tasks that were completed but not removed from TASKS.md (lost work)

**P1** — Efficiency and reliability:
- Stuck tasks that need decomposition (add sub-tasks or break them down)
- Productive timeouts (recommend config change)
- Git sync failures that recur across sessions
- Agent behavior issues (prompt improvements)
- Network recovery that didn't extend deadline correctly

**P2** — Optimization and hygiene:
- Stale branches to clean up
- Open PRs to merge or close
- Configuration tuning recommendations
- Low ship rate causes (tasks too large, missing acceptance criteria)

### 6.4 — Deduplication

Before writing ANY task:
1. Read the target repo's existing TASKS.md
2. Search by ID prefix `grind-log-` for previous analysis tasks
3. Search by keyword for semantically similar tasks
4. Skip duplicates — append a note to the existing task's Details instead

### 6.5 — Stuck task decomposition

For every task ID that hit the 3-attempt skip threshold:
1. Read the task from the repo's TASKS.md
2. Read the session output from attempts where the agent worked on it
3. Identify why the agent failed (scope too large, missing context, blocked dependency)
4. Write 2-4 sub-tasks that break the original into achievable pieces
5. Add a `**Plan**:` section to the original task with the sub-task checklist

## Phase 7: Produce the report

Output a structured report to stdout with these sections:

```
================================================================
  GRIND LOG ANALYSIS — <log_file_basename>
  Repo: <repo>  |  Duration: <human>  |  Sessions: N
================================================================

## Efficiency Scorecard
  Ship rate:        N% (N/N tasks)
  Throughput:       N.N tasks/hour
  Session efficiency: N% (N/N sessions productive)
  Waste ratio:      N% (Nm wasted of Nh total)
  Network downtime: Nm
  Verdict:          PERFECT | GOOD | POOR | STALL

## Session Timeline
  | # | Duration | Shipped | Queue    | Exit | Notes           |
  |---|----------|---------|----------|------|-----------------|
  | 1 | 45m      | 2       | 10 → 8  | 0    |                 |
  | 2 | 3s       | 0       | 8 → 8   | 1    | fast_fail       |
  ...

## Throughput Trend
  Sessions 1-5:  N shipped (N.N/session)
  Sessions 6-10: N shipped (N.N/session) ← declining
  Inflection at session N

## Root Causes
  1. [SEVERITY] <cause>
     Evidence: <quoted log line(s)>
     Impact: <what this cost in time/tasks>
     Fix: <what to do>

## Stuck Tasks
  - <task-id>: attempted N times, still in queue
    Agent output: "<relevant snippet from session output>"
    Recommendation: <decompose / rewrite / unblock>

## Repo State
  - Branch: <current branch> (expected: main)
  - Dirty files: N
  - Open PRs: N
  - Stale branches: N

## Tasks Written
  - <repo>/TASKS.md: N tasks added (P0: N, P1: N, P2: N)
  - ~/apps/taskgrind/TASKS.md: N tasks added

================================================================
```

## Phase 8: Update the ledger

After successful analysis, append the log path to the ledger:

```bash
echo "<log_file_path>" >> ~/.local/share/taskgrind/analyzed-logs.txt
```

This ensures the next invocation picks up the next unanalyzed log.

## Rules

1. **Evidence over speculation.** Every root cause must cite specific log lines with timestamps.
   If you can't find evidence, say "inconclusive" and suggest manual investigation.
2. **Read everything before writing.** Parse the entire log and all target TASKS.md files
   before writing a single task. You need the full picture for deduplication and prioritization.
3. **Outcome-shaped tasks.** Write "grind recovers from stale branches automatically" not
   "add git checkout main to line 452". Describe the desired end state.
4. **Cross-repo awareness.** Some issues span repos (skill + taskgrind + target repo).
   Write the task where the fix lives, reference other repos in Details.
5. **Don't analyze test logs.** Logs from temp directories (`/tmp/bats-*`, `/var/folders/`)
   are bats test artifacts. Count them and skip.
6. **Decompose stuck tasks.** Every task that hit the skip threshold (3+ attempts) gets
   broken down into sub-tasks. This is the highest-value output of the analysis.
7. **Use subagents for parallel repo checks.** Launch background subagents to check each
   repo's state while you analyze the log.
8. **Session output is gold.** The `--- session N output ---` blocks contain the agent's
   actual terminal output. Mine them for error messages, permission denials, and behavioral
   patterns that explain zero-ship sessions.
