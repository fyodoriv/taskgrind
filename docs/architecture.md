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

In multi-instance runs, only slot `0` performs that between-session sync. Making every slot run its own fetch/rebase loop would create dueling sync cycles, extra stash churn, and more `TASKS.md`-only conflicts while the sessions are already trying to avoid overlapping work. Keeping one sync owner gives the repo a single rebasing lane, while higher slots stay productive on docs, audits, queue maintenance, or other non-overlapping edits and do a just-in-time `git pull --rebase` before committing.

To let child processes (the AI backend, skills, hooks, wrapper scripts) branch on the running slot without re-running `--preflight`, taskgrind exports `TG_INSTANCE_ID=<slot>` into the session environment after the slot is claimed. The variable is read-only from the child's perspective: assigning it on the command line has no effect because taskgrind overwrites it. It is intentionally absent from `taskgrind --help` and from the README/man env-var tables — surfacing it there would imply users can set it, which would race with the slot-locking logic. The README's "Concurrent instances on one repo" section and the man page's multi-instance prose document the contract for skill authors who need to gate behavior on the slot.

## Why per-task retry cap uses ID tracking

Earlier versions tracked stall by counting total tasks before and after each session. This broke when sessions added new tasks while working — the count could stay the same even though work was done. ID-based tracking fixes this: after each session, taskgrind extracts `**ID**:` values from TASKS.md and diffs them against the previous set. Each surviving task ID gets an attempt counter incremented. After 3 attempts, the task ID is added to a skip list in the next session's prompt. This correctly handles the common pattern where a session scouts new tasks while shipping one, and prevents infinite loops on tasks that consistently fail.

The counter is intentionally scoped to the live queue snapshot, not to raw history. When a task ships, its ID disappears from the attempts file immediately, which clears that task's debt before any future reintroduction. When one task is replaced by a successor with a different ID, the successor starts fresh instead of inheriting the old retry count. Taskgrind also prunes the attempts file before composing the next prompt, so the skip list only names task IDs that are still present in `TASKS.md` and have actually crossed the threshold.

The 3-attempt threshold is a built-in constant on purpose, not an env var. Making it configurable would let operators hide runaway failures by raising the cap instead of addressing the task, and the value matters less than the mechanism: three full sessions is "tried hard enough to be expensive" on any reasonable queue. When the threshold fires, taskgrind logs `task_skip_threshold ids=<id>` exactly once (only the session that crosses from 2 → 3 attempts writes the marker, not every subsequent zero-ship) and prepends `SKIP these stuck tasks (attempted 3+ times): <id1> <id2>. Work on other tasks instead.` to every following session's prompt. That phrasing is important — the skill is instructed to move on, not to halt the grind, because another task may still be shippable. Shipping any task clears its own counter the next time taskgrind prunes the attempts file (since the ID is gone from TASKS.md), which is also the reason the skip list never becomes a permanent blacklist across grinds.

The same principle now applies to shipped-work accounting. Raw queue deltas are still useful, but they miss real completions when a session removes a finished task and simultaneously rolls the queue forward, when another agent injects new tasks before the session ends, or when the completed task lives in a non-root `TASKS.md`. Taskgrind therefore treats explicit task-removal evidence as authoritative enough to infer shipped work even if the queue ends at the same size. That keeps stall detection focused on genuinely unproductive sessions instead of punishing healthy queue churn.

## Why diminishing-returns uses a 5-session rolling window

`TG_MAX_ZERO_SHIP` already covers the runaway case — 6 consecutive sessions
with no work landed means something is structurally broken. But there is a
separate, softer failure mode: a grind that ships just enough to look alive
while the actual throughput has collapsed. Picture an overnight run
where the last several sessions ship a single task between them. Zero-ship never
trips (there was one ship in there), yet the grind is clearly not making its
deadline. The diminishing-returns guard fills that gap.

The guard maintains a rolling array of per-session shipped counts and, once at
least 5 sessions have run, checks whether the last 5 added up to fewer than 2
tasks. If the window is under-threshold, taskgrind logs
`diminishing_returns window=5 shipped=N` and prints a stdout warning so
operators tailing the log see the event. The `session >= 5` gate is why new
grinds do not trigger the warning on session 1-4 even if those sessions all
return zero — there simply is not enough history yet to call that a regression.

`TG_EARLY_EXIT_ON_STALL` controls what happens next. Unset or `0` (the default)
keeps the warning advisory so operators can investigate without losing the
remainder of the marathon budget. Set to `1`, the grind also logs
`early_exit_stall`, flips the status phase to `failed`, and exits the loop. The
trade-off is that advisory mode wastes time if the queue really is broken, but
early-exit mode can fire on a genuine lull (e.g., a few hard tasks that each
need a full session to complete). The window parameters (5 sessions, 2-task
threshold) are conservative on purpose so operators who enable `early_exit_stall`
do not get false positives on architectural work that deserves the time.

Rolling counts live only in memory for the current taskgrind process. Resuming
a grind starts the window over — another reason the guard is deliberately slow
to fire after restarts.

## Why productive-timeout sessions get a bigger budget next time

The per-session timeout (`TG_MAX_SESSION`, default 5400 s) exists to stop runaway
sessions from chewing through the marathon budget, but treating it as a hard
cap punishes healthy work. A session that shipped something before the clock
ran out was not runaway — it was proving the task was real and making real
progress, then got killed mid-flight. Starting the next session with the same
ceiling would likely repeat the outcome on tasks that genuinely need more than
an hour (architectural refactors, multi-file doc sweeps, epic decomposition).

Taskgrind resolves the tension with a one-way ratchet. After any session that
reports `session_shipped > 0` but also hit `max_session`, taskgrind adds 1800
seconds (30 minutes) to `max_session` for the rest of the grind, capped at
7200 s (2 hours). The cap keeps the ratchet from drifting into "unbounded" so
no single session can burn an entire overnight window, and 7200 s fits
comfortably inside the typical autonomous run. The bump is announced on stdout
and written to the log as `productive_timeout session=N shipped=X timeout=Ys
new_timeout=Zs`, so operators watching the log or tailing the status file can
see exactly when the ratchet fired. Sessions that hit the cap log
`productive_timeout session=N shipped=X timeout=Ys (at cap)` instead, so the
log still names the event without promising another bump that will never
arrive.

This is asymmetric on purpose. Timeouts never shrink during a grind: a
productive session that finishes faster does not claw the budget back, because
the point is to match the worst-case task in the queue, not the average. The
ratchet also does not persist across taskgrind processes — every new grind
starts from the operator's `TG_MAX_SESSION`, because a fresh run usually means
the work has changed. That keeps the rule auditable ("what does `--help` say?
that is what the first session gets") while still letting long autonomous
runs adapt to tasks that need more runway than the operator originally
guessed.

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

## Why next-task over a custom skill lane

Taskgrind orchestrates the marathon: deadline management, network resilience, git sync, stall detection, task tracking. It deliberately does not understand task prioritization, decomposition, or implementation — that's the skill's job. The default `next-task` skill is a general-purpose task picker that reads TASKS.md, selects the highest-priority unblocked task, and implements it. Taskgrind still delegates the actual work by starting every session with `Run the $skill skill.`, but the live prompt now layers on session metadata plus operator guardrails: the remaining time budget, the completion protocol for removing shipped tasks from `TASKS.md`, the autonomy reminder to use available tools instead of punting, the optional `FOCUS:` prompt, and the stuck-task skip list when repeated failures were detected. That richer wrapper keeps the skill handoff explicit while making each session safer and more self-directed. Users can swap in a real installed lane such as `--skill pipeline-ops` for pipeline management, a repo-local lane such as `--skill standing-audit-gap-loop` for discovery work, or any other installed skill without changing taskgrind itself.

## Why `.taskgrind-prompt` for live injection

Long grinds need a low-friction way to steer the next session without restarting the whole run or editing shell history. `.taskgrind-prompt` is a plain file in the repo root, so contributors can update it with any editor, script, or automation while taskgrind keeps running. Taskgrind re-reads the file at the start of each session, which gives users a predictable handoff point: the current session finishes with the prompt it already received, and the next session sees the updated instructions. That timing avoids half-applied prompt changes inside an active coding run.

The file is combined with any `--prompt` text instead of replacing it. The command-line prompt remains the stable baseline for the whole grind, while `.taskgrind-prompt` acts as a live overlay for new priorities, investigation notes, or temporary constraints. That split keeps startup commands short for common cases but still supports mid-run steering when the repo state changes.

The 10 kilobyte guard exists to keep the live-injection path safe and legible. A prompt file should carry concise session guidance, not entire specs, logs, or pasted documents. Without a size limit, a runaway redirect or accidental binary/blob write could flood every later session with junk, blow up token usage, and make the actual operator intent hard to spot. Failing fast on oversized prompt files keeps the feature useful instead of letting it become an unbounded hidden input.

The same pattern also explains `.taskgrind-model`. The startup `--model` flag sets the baseline model for the grind, while a repo-local file can steer later sessions toward a different model as the remaining work changes. That gives operators the same "baseline plus live override" behavior for both instructions and model choice, without forcing a restart.

## Why no-publish mode is two-sided

The default grind is opinionated about publishing: `final_sync` pushes any outstanding commits on every exit path. That bias is correct for autonomous backlog grinding, but it makes "produce work for review" un-enforceable. `--no-push` / `TG_NO_PUSH=1` solves the problem on both sides. The agent prompt is rewritten to forbid `git push`, `gh pr create`, and `gh pr merge`, and `final_sync` short-circuits before its push call to log `final_sync would_push commits=N head=<sha>` instead of touching origin. Work still lands as local commits on the working branch, the operator reviews `git log`, then pushes manually when satisfied. The flag is preserved across `--resume` so an interrupted no-publish run cannot silently start publishing on restart, and it propagates through the caffeinate re-exec because all CLI args ride through `_orig_args`. Operators get a high-trust default for ambient grinding plus a deliberate review gate when the prompt and the script must both honour "do not publish without my approval."

## Public-write approval gate

Every taskgrind session prompt includes a `PUBLIC_WRITE_GATE` section that makes the approval requirement explicit: TASKS.md task metadata — including labels, tags, or green-list annotations — is task context only. It does NOT authorize any public write. The standard `COMPLETION PROTOCOL` no longer tells agents to "merge it first" unconditionally; instead it explicitly forbids merging pull requests, force-pushing branches, bypassing pre-push hooks with `--no-verify`, or submitting PRs without explicit operator approval in the current session. For cross-repo or upstream work, agents are told to prepare the branch and PR body locally and report `Approval needed — draft body at <path>`, not to push or submit.

The `final_sync` auto-PR creation (the fallback path that kicks in when a direct push to the default branch is blocked by branch protection) is independently gated by `TG_PUBLIC_WRITE_TOKEN`. When the token is absent (the default), `final_sync` writes the draft PR body to a temp file, prints `Approval needed — draft body at: <path>`, and falls through to `push_protected_branch_manual_recovery_needed`. Set `TG_PUBLIC_WRITE_TOKEN=<any-string>` once per grind run to authorize the specific PR creation. The PR bodies generated by the auto-PR path include a `Why this is needed` section and the canonical agent footer so reviewers have full context.
