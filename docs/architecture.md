# Architecture — Design Decisions

## TL;DR

Taskgrind stays small on purpose: the script handles marathon orchestration
such as deadlines, sync, retries, and safety guards, while the AI skill handles
task selection and implementation. The sections below explain the trade-offs
behind the shell-only architecture so contributors can extend behavior without
reintroducing the failure modes earlier versions hit.

Why taskgrind works the way it does. One paragraph per decision — not a tutorial, but a "why" doc for contributors.

## Why self-copy (bash lazy reading)

Bash reads scripts lazily by byte offset rather than loading them entirely into memory. If a grind session modifies the taskgrind script itself (e.g., when grinding the dotfiles repo where taskgrind originated), the running process reads from shifted offsets and crashes with bizarre syntax errors. To prevent this, taskgrind copies itself to a temp file in `$TMPDIR` and `exec`s from the copy before doing anything else. The `_DVB_SELF_COPY` guard prevents infinite re-exec, and `TASKGRIND_DIR` is preserved before the copy so relative paths (`lib/constants.sh`, etc.) still resolve correctly from the temp location.

## Why caffeinate -ms not -dims

The `-ms` flags prevent system sleep (`-s`) and disk sleep (`-m`) while allowing the display to sleep and lock. Using `-dims` would additionally prevent display sleep (`-d`) and idle sleep (`-i`), which is wasteful — there's no reason to keep the monitor lit during an autonomous 8-hour grind. The machine stays awake, the disk stays spinning, but the screen locks after the normal timeout. This is the right trade-off for unattended overnight runs.

## Why git sync every N not every 1

Git sync (fetch, rebase, branch cleanup) introduces overhead and can create rebase conflicts that need recovery. Running it after every session wastes time, especially when sessions are short. The default of every 5 sessions (`TG_SYNC_INTERVAL=5`) balances staying current with origin against minimizing disruption. For fast-moving repos where freshness matters, set `TG_SYNC_INTERVAL=0` to sync every session. The sync includes stash/restore for dirty trees, automatic rebase abort on conflicts, and a configurable timeout (`TG_GIT_SYNC_TIMEOUT`) to prevent hanging on slow remotes.

When sync runs, it does not assume the repo uses `main`. Taskgrind resolves the branch in descending confidence order: cached `origin/HEAD`, live `ls-remote --symref origin HEAD`, the current upstream tracking branch, the current branch if it already exists on `origin`, local `main`/`master`, then remote `main`/`master`. That keeps cross-repo grinds working in repos whose primary branch is `master`, `release`, or something custom, while the internal `DVB_DEFAULT_BRANCH` override still lets tests pin a deterministic branch without mocking every git probe.

## Why per-task retry cap uses ID tracking

Earlier versions tracked stall by counting total tasks before and after each session. This broke when sessions added new tasks while working — the count could stay the same even though work was done. ID-based tracking fixes this: after each session, taskgrind extracts `**ID**:` values from TASKS.md and diffs them against the previous set. Each surviving task ID gets an attempt counter incremented. After 3 attempts, the task ID is added to a skip list in the next session's prompt. This correctly handles the common pattern where a session scouts new tasks while shipping one, and prevents infinite loops on tasks that consistently fail.

The counter is intentionally scoped to the live queue snapshot, not to raw history. When a task ships, its ID disappears from the attempts file immediately, which clears that task's debt before any future reintroduction. When one task is replaced by a successor with a different ID, the successor starts fresh instead of inheriting the old retry count. Taskgrind also prunes the attempts file before composing the next prompt, so the skip list only names task IDs that are still present in `TASKS.md` and have actually crossed the threshold.

The same principle now applies to shipped-work accounting. Raw queue deltas are still useful, but they miss real completions when a session removes a finished task and simultaneously rolls the queue forward, when another agent injects new tasks before the session ends, or when the completed task lives in a non-root `TASKS.md`. Taskgrind therefore treats explicit task-removal evidence as authoritative enough to infer shipped work even if the queue ends at the same size. That keeps stall detection focused on genuinely unproductive sessions instead of punishing healthy queue churn.

## Why session boundaries are the context-budget guard

Taskgrind assumes each AI run is a bounded unit of work: start with fresh
context, pick one task, commit, exit, then let the next session continue from
git and `TASKS.md`. That boundary is not just a scheduling convenience; it is
also the safety rail against context exhaustion. If a session keeps accreting
logs, plans, or code review churn until the model context fills up, the process
can crash before it commits. The next session can still resume from the last
good git state, but any uncommitted edits from the crashed run are gone.

That is why taskgrind keeps repeating "commit before timeout" and why the
operator docs now warn against overstuffed sessions. The safest unattended run
is a sequence of small, shippable turns, not one heroic prompt that tries to
finish an entire epic in a single context window.

## Why empty-queue sweep then wait, then exit

When TASKS.md is empty, taskgrind runs a single sweep session that audits the repo for work (TODOs, test gaps, lint warnings) and populates TASKS.md. If the sweep finds tasks, the grind continues normally. If the sweep finds nothing, taskgrind does not exit immediately: it waits up to 10 minutes for another agent, hook, or human to inject fresh tasks, then exits if the queue is still empty. That pause makes short autonomous runs more useful in shared repos where new tasks may appear just after a cleanup session finishes.

The `_sweep_done` flag tracks that control flow. `0` means no empty-queue sweep has run yet, `1` means the sweep already ran and the grind is in its one-time wait-for-work window, and `2` means the empty-queue path is exhausted so the next loop exits cleanly. The flag resets whenever a session ships work, which lets a grind that empties the queue sweep again later instead of getting stuck in a permanent "already swept" state.

There is a separate guard for audit-only skills such as standing discovery loops. Audit-only sessions are refused unless `TASKS.md` includes a supported discovery-lane standing-loop task, because otherwise the lane can spend a whole session doing queue maintenance without any durable marker that explains why it is allowed to keep running. That safeguard keeps the normal empty-queue sweep available for autonomous backlog discovery while still forcing deliberate setup for long-lived discovery lanes.

## Why next-task over custom grind skill

Taskgrind orchestrates the marathon: deadline management, network resilience, git sync, stall detection, task tracking. It deliberately does not understand task prioritization, decomposition, or implementation — that's the skill's job. The default `next-task` skill is a general-purpose task picker that reads TASKS.md, selects the highest-priority unblocked task, and implements it. Taskgrind still delegates the actual work by starting every session with `Run the $skill skill.`, but the live prompt now layers on session metadata plus operator guardrails: the remaining time budget, the completion protocol for removing shipped tasks from `TASKS.md`, the autonomy reminder to use available tools instead of punting, the optional `FOCUS:` prompt, and the stuck-task skip list when repeated failures were detected. That richer wrapper keeps the skill handoff explicit while making each session safer and more self-directed. Users can swap in `--skill fleet-grind` for pipeline management or any custom skill without changing taskgrind itself.

## Why `.taskgrind-prompt` for live injection

Long grinds need a low-friction way to steer the next session without restarting the whole run or editing shell history. `.taskgrind-prompt` is a plain file in the repo root, so contributors can update it with any editor, script, or automation while taskgrind keeps running. Taskgrind re-reads the file at the start of each session, which gives users a predictable handoff point: the current session finishes with the prompt it already received, and the next session sees the updated instructions. That timing avoids half-applied prompt changes inside an active coding run.

The file is combined with any `--prompt` text instead of replacing it. The command-line prompt remains the stable baseline for the whole grind, while `.taskgrind-prompt` acts as a live overlay for new priorities, investigation notes, or temporary constraints. That split keeps startup commands short for common cases but still supports mid-run steering when the repo state changes.

The 10 kilobyte guard exists to keep the live-injection path safe and legible. A prompt file should carry concise session guidance, not entire specs, logs, or pasted documents. Without a size limit, a runaway redirect or accidental binary/blob write could flood every later session with junk, blow up token usage, and make the actual operator intent hard to spot. Failing fast on oversized prompt files keeps the feature useful instead of letting it become an unbounded hidden input.

The same pattern also explains `.taskgrind-model`. The startup `--model` flag sets the baseline model for the grind, while a repo-local file can steer later sessions toward a different model as the remaining work changes. That gives operators the same "baseline plus live override" behavior for both instructions and model choice, without forcing a restart.
