# Architecture — Design Decisions

Why taskgrind works the way it does. One paragraph per decision — not a tutorial, but a "why" doc for contributors.

## Why self-copy (bash lazy reading)

Bash reads scripts lazily by byte offset rather than loading them entirely into memory. If a grind session modifies the taskgrind script itself (e.g., when grinding the dotfiles repo where taskgrind originated), the running process reads from shifted offsets and crashes with bizarre syntax errors. To prevent this, taskgrind copies itself to a temp file in `$TMPDIR` and `exec`s from the copy before doing anything else. The `_DVB_SELF_COPY` guard prevents infinite re-exec, and `TASKGRIND_DIR` is preserved before the copy so relative paths (`lib/constants.sh`, etc.) still resolve correctly from the temp location.

## Why caffeinate -ms not -dims

The `-ms` flags prevent system sleep (`-s`) and disk sleep (`-m`) while allowing the display to sleep and lock. Using `-dims` would additionally prevent display sleep (`-d`) and idle sleep (`-i`), which is wasteful — there's no reason to keep the monitor lit during an autonomous 8-hour grind. The machine stays awake, the disk stays spinning, but the screen locks after the normal timeout. This is the right trade-off for unattended overnight runs.

## Why git sync every N not every 1

Git sync (fetch, rebase, branch cleanup) introduces overhead and can create rebase conflicts that need recovery. Running it after every session wastes time, especially when sessions are short. The default of every 5 sessions (`DVB_SYNC_INTERVAL=5`) balances staying current with origin against minimizing disruption. For fast-moving repos where freshness matters, set `DVB_SYNC_INTERVAL=0` to sync every session. The sync includes stash/restore for dirty trees, automatic rebase abort on conflicts, and a configurable timeout (`DVB_GIT_SYNC_TIMEOUT`) to prevent hanging on slow remotes.

## Why per-task retry cap uses ID tracking

Earlier versions tracked stall by counting total tasks before and after each session. This broke when sessions added new tasks while working — the count could stay the same even though work was done. ID-based tracking fixes this: after each session, taskgrind extracts `**ID**:` values from TASKS.md and diffs them against the previous set. Each surviving task ID gets an attempt counter incremented. After 3 attempts, the task ID is added to a skip list in the next session's prompt. This correctly handles the common pattern where a session scouts new tasks while shipping one, and prevents infinite loops on tasks that consistently fail.

## Why empty-queue sweep then exit

When TASKS.md is empty, taskgrind runs a single sweep session that audits the repo for work (TODOs, test gaps, lint warnings) and populates TASKS.md. If the sweep finds tasks, the grind continues normally. If the sweep finds nothing, taskgrind exits. The `_sweep_done` flag prevents infinite sweep loops, but resets whenever a task is shipped — so a grind that empties the queue can sweep again after clearing all work. This ensures the grind discovers all available work without wasting sessions on repeated empty sweeps.

## Why next-task over custom grind skill

Taskgrind orchestrates the marathon: deadline management, network resilience, git sync, stall detection, task tracking. It deliberately does not understand task prioritization, decomposition, or implementation — that's the skill's job. The default `next-task` skill is a general-purpose task picker that reads TASKS.md, selects the highest-priority unblocked task, and implements it. By keeping the prompt thin (`"Run the $skill skill."`) and delegating everything to the skill, taskgrind stays composable. Users can swap in `--skill fleet-grind` for pipeline management or any custom skill without changing taskgrind itself.
