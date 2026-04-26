# Tasks

<!-- policy: keep runtime files /bin/bash 3.2 compatible (guarded by tests/bash-compat.bats) -->
<!-- policy: run `make check` before claiming a task complete; remove the task block in the same commit that ships the fix -->

## P0

- [ ] Fix the per-task attempt counter — only increment for tasks the agent actually claimed, not for every task that survived the session
  - **ID**: attempt-counter-claim-not-survival
  - **Tags**: bug, skip-list, queue-shape, marathon, observability
  - **Details**: The per-task attempt tracker at `bin/taskgrind:2427-2445`
    walks `_ids_after` (every task ID still present in `TASKS.md` after the
    session) and increments each ID's attempt counter by one. Once a counter
    hits `3`, the task lands in the `task_skip_threshold` list and is excluded
    from the next session's prompt. The intent is "after 3 failed attempts,
    stop trying" — but the implementation counts SURVIVAL, not CLAIMS. A task
    that no agent ever read, claimed, or thought about gets skip-flagged after
    3 sessions just for sitting in the queue.
    Concrete failure mode in the 2026-04-24 agentbrew marathon log
    (`/var/folders/.../taskgrind-2026-04-24-2034-agentbrew-14949.log`): by
    session 3 (line 18) the skip list contained 50+ entries including
    `deep-dive-skillkit`, `deep-dive-skillpkg-spm`, `deep-dive-glooit`, etc.
    Several of those tasks were never even read in any session — they were
    just IDs the agent saw in the `next-task` prompt and skipped past on
    priority/output-shape grounds. They got skip-flagged anyway because they
    appeared in `_ids_after` for 3 sessions running.
    The fix needs a "was this task actually claimed?" signal. Two viable
    approaches:
    1. **Claim-marker scan**: the `next-task` skill (in `~/apps/tasks.md/`)
       claims by appending `(@<agent-id>)` to the task line. Parse `_ids_after`
       and only increment counters for IDs whose line still has a
       `(@<agent-id>)` marker — i.e., the agent claimed it but didn't ship it.
       Tasks that were never claimed never get incremented. This is the
       cheapest fix because the marker convention already exists.
    2. **Session-output scan**: parse the session output (already captured at
       `bin/taskgrind:1973-2005` for productive-zero-ship detection) for
       lines like `claimed task <ID>` or `working on <ID>`. Increment only
       those IDs. Higher signal but also more brittle (depends on agent
       phrasing).
    Approach 1 is preferred — the claim marker is already a documented part
    of the spec (`~/apps/tasks.md/spec.md`) and is independent of agent
    output style. Implementation: replace the `while IFS= read -r _tid; do`
    loop at `bin/taskgrind:2429-2433` with a loop that reads
    `$repo/TASKS.md`, picks lines matching `^- \[[ x]\] .*\(@[^)]+\)`,
    extracts the ID via the existing `extract_task_ids` helper at
    `bin/taskgrind:2360`, and intersects with `_ids_after`. Only the
    intersection gets incremented.
    Stale-claim safety: if a previous agent claimed a task and the
    current run never touches it, the marker survives across sessions and
    the counter would still increment unfairly. Mitigation: also clear the
    counter for IDs whose marker disappears between `_ids_before` and
    `_ids_after` (i.e., another agent un-claimed). Edge case is rare; log
    the occurrence rather than silently drop.
    Test coverage: extend `tests/session.bats` (or wherever attempt-counter
    behavior currently has bats coverage — search for `task_attempts_file`
    first and pick the existing suite) with two cases: (a) a task that's
    present in `_ids_after` but unclaimed never increments; (b) a task
    that's claimed in session 1, survives unshipped through sessions 2 and
    3, hits the threshold and lands in the skip list at session 3. The
    existing 3-survival regression case must be updated (it currently
    asserts the wrong behavior).
    Documentation: the `bin/taskgrind` comment block at line 2424
    (currently `Track how many sessions each task ID has survived without
    being shipped`) is now wrong — replace with `Track how many times each
    task ID was claimed but didn't ship`. The grind-log-analyze field table
    at `.devin/skills/grind-log-analyze/SKILL.md:115` (the `task_skip_threshold`
    row) gets a one-line note: "claim-based, not survival-based — see
    `bin/taskgrind:2427-2445`."
  - **Files**: `bin/taskgrind` (the loop at 2427-2445 plus the comment at
    2424), `tests/session.bats` or sibling, `.devin/skills/grind-log-analyze/SKILL.md`,
    `docs/architecture.md` (one-line note in the stall-detection section
    if it exists)
  - **Acceptance**: A bats case asserts that a task surviving 3 sessions
    *unclaimed* never appears in `task_skip_threshold`; another asserts a
    task claimed and unshipped 3 times *does* land there; the existing
    survival-only regression is removed or rewritten; `make check` passes;
    the comment at `bin/taskgrind:2424` matches the new behavior.

## P1

- [ ] Honour `diminishing_returns` by default — stop the marathon when the rolling 5-session ship window stays at zero for 2 windows in a row
  - **ID**: diminishing-returns-default-exit
  - **Tags**: budget, stall, marathon, observability
  - **Details**: The diminishing-returns detector at `bin/taskgrind:2591-2611`
    tracks shipped counts in a rolling 5-session window. When the window
    total drops below 2, it logs `diminishing_returns window=5 shipped=N`
    and exits — but **only if** `DVB_EARLY_EXIT_ON_STALL=1` is set. By
    default the harness keeps spinning even after the detector correctly
    diagnoses queue exhaustion.
    Concrete failure mode in the 2026-04-24 agentbrew marathon: the
    detector fired at sessions 8, 9, 10, 12, and 13 (10:39, 12:39, 13:00,
    14:21, 15:30 in log time). Without the env var, the harness launched
    5 more sessions across the next 4 hours, each shipping 0 or 1 task.
    The cumulative cost of ignoring the signal: ~4 hours of session time
    (~$$ in API costs) for ~3 ships, when the detector knew at session 8
    that the run was done.
    Two changes:
    1. **Default to exit on consecutive trips**: change the gate at
       `bin/taskgrind:2604` so the harness exits when
       `diminishing_returns` fires AND `_consecutive_diminishing_returns
       >= 2`, regardless of `DVB_EARLY_EXIT_ON_STALL`. Add a new counter
       `_consecutive_diminishing_returns` that increments when the
       detector fires, resets on any session that ships ≥1 task. Keep
       `DVB_EARLY_EXIT_ON_STALL=1` as an "exit on first trip" override
       for users who want stricter behavior; rename or alias it to
       `TG_EXIT_ON_STALL` per the `TG_`-primary policy in AGENTS.md
       rule 3, with `DVB_EARLY_EXIT_ON_STALL` kept as a backward-compat
       alias.
    2. **Make the override observable**: the existing log line `early_exit_stall`
       at `bin/taskgrind:2606` only fires if the env var is set. Add a
       sibling `diminishing_returns_exit consecutive=2 reason=default-2x`
       log line for the new default-exit path so post-mortems can tell
       which trigger fired.
    User-control matters: a marathon kicked off with an explicit prompt
    that anticipates audit-cascade work (e.g. "find all dead code") may
    legitimately have low ship rates. Add a `TG_NO_STALL_EXIT=1` opt-OUT
    for that case (mirrors the existing opt-IN). The env table in
    `README.md` and `man/taskgrind.1` documents both.
    Operator-on-the-loop alternative: instead of (or in addition to) the
    auto-exit, the harness could write a "stall confirmation" prompt
    file and pause for human ack before continuing — out of scope for
    this task; file as a scout if useful.
    Test coverage: extend the bats suite with three cases — (a) two
    consecutive diminishing-returns trips with default env: exits with
    new `diminishing_returns_exit` log line; (b) one trip then a
    productive session: counter resets, no exit; (c)
    `TG_NO_STALL_EXIT=1` set: harness continues past 2 consecutive
    trips even with low throughput. Reuse `tests/session.bats` or the
    closest existing focused file.
    Documentation: env-var table in `README.md` and `man/taskgrind.1`
    name both `TG_EXIT_ON_STALL` (opt-IN, exit on first trip) and
    `TG_NO_STALL_EXIT` (opt-OUT, never auto-exit). The
    `grind-log-analyze` skill's field table at
    `.devin/skills/grind-log-analyze/SKILL.md:115` lists the new
    `diminishing_returns_exit` log marker.
  - **Files**: `bin/taskgrind` (gate + counter + log line +
    env-var registration block near 208-224), `README.md` env-var table,
    `man/taskgrind.1`, `tests/session.bats` or sibling,
    `.devin/skills/grind-log-analyze/SKILL.md`
  - **Acceptance**: A bats case asserts that 2 consecutive
    `diminishing_returns` trips trigger an exit with the new
    `diminishing_returns_exit` log line under default env; another
    case asserts `TG_NO_STALL_EXIT=1` keeps the harness going past
    the trips; the env-var table in `README.md` and the man page name
    both `TG_EXIT_ON_STALL` and `TG_NO_STALL_EXIT` with their defaults;
    `make check` passes.

- [ ] Cap sweep-session duration with `TG_SWEEP_MAX` so a runaway sweep can't burn 14 % of a 10-hour budget
  - **ID**: cap-sweep-session-duration
  - **Tags**: budget, sweep, observability
  - **Details**: Sweep sessions today inherit the same `max_session`
    watchdog as grind sessions (see `bin/taskgrind:2034` and the productive-
    timeout escalation at `bin/taskgrind:2410-2421`), which by mid-run can
    reach the 7200 s cap. In the 2026-04-24 grind log the second sweep ran
    `sweep_done exit=0 elapsed=4954s` (82 minutes) and emitted
    `sweep_found tasks=7`, while the first sweep that day finished in
    `elapsed=1794s` with `tasks=12`. That makes one sweep alone cost ~14 %
    of a 10 h budget for fewer tasks than the cheaper one. Two improvements
    that belong together: (a) introduce `TG_SWEEP_MAX` (default `1800`,
    parsed and validated next to `max_session` near `bin/taskgrind:208-224`)
    and use it for the watchdog block at the sweep launch path so the
    sweep is bounded independently of the grind cap; (b) at
    `bin/taskgrind:2058` and `bin/taskgrind:2083` also emit a derived
    `sweep_efficiency tasks_per_min=…` marker (or fold it into
    `sweep_done`) so the `grind-log-analyze` skill can see the trend
    across runs. Make sure the cap is honoured even when the sweep skill
    forks long-running subagents — the existing graceful-shutdown grace
    period after SIGINT is the right model. Document the new env var in
    `README.md` and `man/taskgrind.1` in the same edit.
  - **Files**: `bin/taskgrind`, `tests/sweep.bats` (or wherever sweep
    coverage lives — pick the existing focused file before adding a new
    one), `README.md`, `man/taskgrind.1`,
    `.devin/skills/grind-log-analyze/SKILL.md`
  - **Acceptance**: A new bats case launches a sweep that would otherwise
    overrun, exports `TG_SWEEP_MAX=2`, and asserts the sweep is killed at
    the cap with `sweep_done exit=…` logged within tolerance; the
    `sweep_found`/`sweep_done` lines (or a sibling marker) carry a
    tasks-per-minute number; `taskgrind --help`, `man taskgrind`, and
    `README.md` all name `TG_SWEEP_MAX` with its default; the
    grind-log-analyze field table at
    `.devin/skills/grind-log-analyze/SKILL.md:115` lists the new field;
    `make check` passes.

## P2

- [ ] Fix the `ship_rate` formula so tasks added mid-run no longer produce >100 % completion rates
  - **ID**: ship-rate-include-added-tasks
  - **Tags**: metric, accuracy, observability
  - **Details**: `bin/taskgrind:1321-1323` computes
    `ship_rate = tasks_shipped * 100 / tasks_starting`, where
    `tasks_starting` is captured exactly once on the first iteration at
    `bin/taskgrind:1929`. In the 2026-04-24 grind that produced the
    summary line `ship_rate=253% (33/13)` because two sweeps and an
    in-session injection added 19 net tasks that the denominator never
    saw — making the headline metric mathematically vacuous. Track a
    cumulative `tasks_added_total` across the loop (sum of every
    `_tasks_added_during_session` at `bin/taskgrind:2389-2396` plus the
    `tasks_found` reported at `bin/taskgrind:2083`) and divide by
    `tasks_starting + tasks_added_total`, capped at 100 %. Update both
    the human-readable summary at `bin/taskgrind:1330` and the
    `grind_done` log marker at `bin/taskgrind:1334` so the analyze skill
    keeps working. Keep `tasks_shipped`/`tasks_starting` visible in the
    summary for transparency, but the percentage label must reflect the
    full denominator. The grind-log-analyze field table that names
    `ship_rate` at `.devin/skills/grind-log-analyze/SKILL.md:198` must be
    updated in the same edit.
  - **Files**: `bin/taskgrind`,
    `.devin/skills/grind-log-analyze/SKILL.md`, the bats suite that
    asserts on the `grind_done` line (search for `grind_done` under
    `tests/` and pick the closest existing file before adding a new one)
  - **Acceptance**: A bats case simulates a run where
    `tasks_starting=10` and 5 tasks are added mid-run, ships 12 of 15,
    and asserts `ship_rate=80%` (not >100 %); the human summary shows
    the same percentage with `12/15` (not `12/10`); the analyze skill
    documents the new denominator; `make check` passes.

- [ ] Surface aggregate sweep cost in the `grind_done` summary line so post-mortems don't have to manually sum elapsed values
  - **ID**: grind-done-sweep-accounting
  - **Tags**: observability, log-analysis
  - **Details**: The grind summary at `bin/taskgrind:1328-1334` reports
    sessions, shipped, remaining, ship_rate, avg_session, elapsed,
    duration, rate, and sessions_zero_ship — but no breakdown of how
    much wall time went into sweep sessions versus productive grind
    sessions. In the 2026-04-24 log the two sweeps consumed
    `1794s + 4954s = 6748s` out of `elapsed=37434s` (18 % of budget),
    and the only way to see that today is to grep every `sweep_done`
    line and add them by hand. Introduce two counters initialised
    alongside the existing `tasks_shipped`/`tasks_starting` block at
    `bin/taskgrind:967-970` (`_sweep_count=0`, `_sweep_seconds=0`),
    increment them at the existing `sweep_done` log site at
    `bin/taskgrind:2058`, and emit `sweeps=N sweep_seconds=Ns` in both
    the human-readable summary at `bin/taskgrind:1330` and the
    `grind_done` log marker at `bin/taskgrind:1334`. Keep the field
    order stable and append the new fields at the end so existing
    parsers stay forward-compatible. The grind-log-analyze field table
    at `.devin/skills/grind-log-analyze/SKILL.md:198` must list both
    new fields in the same edit so the skill knows about them.
  - **Files**: `bin/taskgrind`,
    `.devin/skills/grind-log-analyze/SKILL.md`, the bats suite that
    asserts on the `grind_done` line (reuse the same file picked for
    `ship-rate-include-added-tasks` if the suites overlap)
  - **Acceptance**: A bats case runs a fake-backend grind with two
    sweeps and asserts the summary contains `sweeps=2` and a non-zero
    `sweep_seconds`; the analyze skill's field table lists both new
    fields with their meaning; `make check` passes.

- [ ] Direct unit coverage for `resolve_script_path()` locks the symlink-resolution contract for `make install`
  - **ID**: resolve-script-path-direct-coverage
  - **Tags**: test, install, symlink
  - **Details**: `resolve_script_path()` at `bin/taskgrind:67-82` runs before
    any constants are sourced, walks symlink chains to resolve the real script
    path, and is what lets `make install` symlink `/usr/local/bin/taskgrind` →
    `bin/taskgrind` while still letting the executable resolve
    `$TASKGRIND_DIR/lib/constants.sh` correctly. A regression here breaks
    `make install`, brew packaging, and every caller that runs taskgrind via a
    wrapper symlink — but there is no direct unit-style coverage today. Add a
    bats suite that extracts the function via the awk pattern already used for
    `extract_first_task_context` and `format_conflict_paths_for_log`, sources
    it in a subshell, and asserts the resolver handles: plain file (no
    symlink), single-hop relative symlink, single-hop absolute symlink, nested
    symlink chains two and three hops deep, a symlink whose target is in a
    parent directory (`../bin/taskgrind`), and a symlink whose target is in a
    sibling directory. Use `mktemp -d` per test and clean up in `teardown()`.
    The goal is to pin behavior so a future edit to the `while [[ -L ]]` loop
    can't silently break packaging.
  - **Files**: `tests/install.bats` (or a new focused
    `tests/resolve-script-path.bats`), `bin/taskgrind`
  - **Acceptance**: New `@test` cases exercise `resolve_script_path` directly
    without spawning a grind; each supported topology above has at least one
    assertion on the resolved absolute path; `make test TESTS=tests/<file>.bats`
    plus `make check` both pass.

- [ ] Document the exported `TG_INSTANCE_ID` contract for child sessions and wrapper scripts
  - **ID**: document-tg-instance-id
  - **Tags**: docs, multi-instance, env-var
  - **Details**: `bin/taskgrind:1404` does
    `export TG_INSTANCE_ID="$_dvb_slot"` so any AI session, skill, or
    supervisor that inspects its own environment can tell which slot claimed
    the lock (slot 0 owns git sync; higher slots should defer). There is a
    structural test guarding the export in
    `tests/multi-instance.bats:227-236`, but no user-facing doc mentions the
    variable at all — `README.md` shows only `TG_MAX_INSTANCES`, the Env table
    stops at `TG_SESSION_GRACE`, and `taskgrind --help` / `man taskgrind`
    never name it. That makes the contract agent-only tribal knowledge,
    exactly the kind of doc drift the repo policy flags. Add a short
    subsection (or one row in the env var table) that states: (a) `TG_INSTANCE_ID`
    is taskgrind-set, not user-set; (b) its value equals the claimed slot
    (`0` owns between-session git sync, `1+` skip it); (c) skills and wrapper
    scripts can read it to coordinate. Mirror the same wording in `man/taskgrind.1`
    under the multi-instance section and in `README.md` under "Concurrent
    instances on one repo". Do **not** promise it as a user-settable input —
    only as a read-only export.
  - **Files**: `README.md`, `man/taskgrind.1`, `docs/architecture.md`
  - **Acceptance**: `README.md` and the man page both mention `TG_INSTANCE_ID`
    with the read-only / slot-tied contract wording; a new `tests/basics.bats`
    assertion (or extension to `tests/multi-instance.bats`) greps for the
    string in both docs so future edits can't silently drop it; `make check`
    passes.

- [ ] Classify each session/sweep arc in `grind-log-analyze` output using the 7-pattern taxonomy from Roth's "543 Hours" study
  - **ID**: grind-log-analyze-arc-taxonomy
  - **Tags**: post-mortem, observability, grind-log-analyze, classification, methodology
  - **Details**: Michael Roth's [543 Hours study](https://michael.roth.rocks/research/543-hours/#10) (Oct 2025 – Jan 2026, 14,926 prompts, 2,314 sessions, 543 autonomous hours from one practitioner) clustered 650 work arcs into **seven distinct patterns** with a **power-law distribution**: 5% of arcs (Release pattern) produce 48% of autonomous hours. Today taskgrind's `grind-log-analyze` skill (`.devin/skills/grind-log-analyze/SKILL.md`) parses session events and writes tasks but doesn't classify what KIND of work each session was. Adopting the article's taxonomy gives users a sharper view of where their grind hours actually went.
    **The 7 patterns** ([direct quote from the study](https://michael.roth.rocks/research/543-hours/#10), avg duration in parens):
    | Pattern | % Arcs | % Hours | Avg Duration | Trigger |
    |---|---|---|---|---|
    | **Release** | 4.5% | 48% | 10.3h | "burn down tasks in Release X" — orchestrator reads task graph, spawns waves of agents |
    | **Feature** | 11.8% | 23% | 112min | "implement X" (multi-task) — 2-5 agents work through related tasks |
    | **Build** | 14.5% | 8% | 33min | "run tests" / "fix the build" — iterative fix-test-fix cycles until green |
    | **Review** | 24.9% | 10% | 23min | "review this code" — human-guided review, AI executes checks |
    | **Interactive** | 20.9% | 12% | 33min | discussion, questions, no agents |
    | **Quick** | 22% | 2% | 5min | single small task, fast execution |
    | **Debug** | 1.4% | 3% | 118min | "investigate X" / "fix this bug" — hypothesis testing, trace analysis |
    The headline insight — *"5% of arcs produce 48% of hours"* — is exactly the kind of signal taskgrind's post-mortem should surface so users can tell whether a marathon was dominated by long Release-pattern arcs (high leverage) or by Quick/Build noise (low leverage).
    **What `grind-log-analyze` produces today** (from `.devin/skills/grind-log-analyze/SKILL.md`): structured field table including `tasks_starting`, `ship_rate`, `sweep_done`, etc. Each session has duration, ships, tool counts. **No classification of session kind** beyond grind-vs-sweep.
    **The classification heuristic** (cheap, signal-driven — no LLM call needed):
    1. **Duration buckets**: ≤8min → Quick candidate; 8–60min → Build/Review/Interactive candidate; 60–180min → Feature/Debug candidate; ≥180min → Release candidate.
    2. **Tool-call mix** (already captured per session): high test/build tool fraction → Build; high read-only tool fraction with low edit count → Review or Interactive; multi-task ship count + design-tool calls → Release; single-task ship → Feature or Quick by duration; investigation pattern (many reads, few edits, long duration) → Debug.
    3. **Ship count**: 0 ships + long duration → Debug or Interactive (disambiguate by tool mix); 1 ship → Feature or Quick by duration; ≥3 ships → Release.
    4. **Sweep arcs**: classify separately as `Sweep` (taskgrind-specific, not in the article's taxonomy — keep separate, don't force-fit into one of the 7).
    Output the per-session classification in the post-mortem markdown plus the aggregate distribution: *"This marathon: 23% Release / 31% Build / 18% Quick / 28% other (n=13 sessions, 537min total)."* If the distribution shows Quick > 40% or Release < 5% by hours, flag it as a potential leverage gap (lots of short noise, few long-leverage arcs) — the article's central thesis.
    **Out of scope** (track separately if they prove valuable):
    - Replicating Roth's full multi-model review-gate pattern (Claude proposes, Gemini validates with `review_plan` / `review_design` / `review_code`). That's orchestrator-level, not log-analysis-level. taskgrind doesn't run reviewers; bosun's `orchestrator-reviewer` does.
    - Building a knowledge base of decisions ("rulings file" pattern) — separate from log analysis. Track in tasks.md companion-pattern doc instead.
    - Per-prompt classification (the article clusters at arc level; per-prompt is too noisy for taskgrind's session-shaped logs).
    **Reference tooling — don't reinvent**: Roth open-sourced his analyzer at [github.com/mrothroc/claude-code-log-analyzer](https://github.com/mrothroc/claude-code-log-analyzer). It targets `~/.claude/projects/` (Claude Code session logs), which is a DIFFERENT format from taskgrind's grind logs at `$TMPDIR/taskgrind-<date>-<repo>-<pid>.log`. **Do not depend on the analyzer as a runtime requirement** — taskgrind is self-contained per AGENTS.md; pull dependencies break that. Instead: read the analyzer's clustering algorithm (open source), port the heuristic (small, ~rule-based), and credit the source in `grind-log-analyze/SKILL.md` and the post-mortem output.
    **Coordination with existing tasks**: this task **does not** depend on `research-skillclaw-session-export` (the SkillClaw spike below) — they're independent. SkillClaw is about feeding session traces to a separate evolve server; this is about classifying within taskgrind's existing post-mortem flow. Both can ship without the other.
    **Cheap, falsifiable check before locking the heuristic**: re-classify ~3 recent real grind logs from `$TMPDIR/taskgrind-*.log` using the heuristic above. Hand-score whether each session's classification matches your intuition. Iterate the thresholds until matching is ≥80%. This is dev-machine-only; no test infrastructure needed yet.
  - **Files**: `.devin/skills/grind-log-analyze/SKILL.md` (extend the analysis phases with classification logic and the aggregate distribution output; add the article reference + open-source analyzer reference in the "Source" / "References" footer if one exists, otherwise add one), optionally `bin/taskgrind` (read-only — confirm the existing structured fields are sufficient for the heuristic; if classification needs a new field at `session_done` / `sweep_done`, file as a sibling task rather than bundling), tests in `tests/` (search for the file that asserts on `grind-log-analyze` output and extend; otherwise leave manual smoke testing of the skill against real logs)
  - **Acceptance**:
    - `grind-log-analyze` produces a per-session classification using the 7-pattern taxonomy (plus `Sweep` for taskgrind-specific sweeps), with the heuristic recorded in the SKILL.md so it's reproducible
    - The post-mortem output includes an aggregate distribution line (e.g., `arc_distribution: Release=15% Feature=23% Build=31% Quick=18% other=13%`) and an aggregate hours line (e.g., `arc_hours: Release=48% Feature=22% ...`) so the power-law signal surfaces
    - The classification heuristic is hand-validated against ≥3 real grind logs from `$TMPDIR/taskgrind-*.log` with ≥80% intuition-match
    - The article and the mrothroc/claude-code-log-analyzer repo are credited inline with links — this is a derivative work, not original taxonomy
    - `make check` passes — if test coverage exists for `grind-log-analyze` field tables, it's updated to allow the new fields
    - One scout task added per AGENTS.md rule #11 if the heuristic surfaces a real bug in the existing post-mortem (e.g., misattributed sweep durations, ship-rate misclassification in the source data) — the analyzer can find bugs in the analyzed thing

- [ ] Research: emit taskgrind session traces in a format that an external SkillClaw evolve server can consume
  - **ID**: research-skillclaw-session-export
  - **Tags**: research, integration, skillclaw, post-mortem, skill-evolution
  - **Details**: SkillClaw ([github.com/AMAP-ML/SkillClaw](https://github.com/AMAP-ML/SkillClaw), 1k stars, MIT, first OSS release 2026-04-10) is a skill-evolution system that turns session traces into evolved `SKILL.md` files via two engines (`workflow`: 3-stage LLM pipeline, `agent`: OpenClaw-driven). Today, **taskgrind already captures rich session data** — primary log at `$TMPDIR/taskgrind-<date>-<repo>-<pid>.log` (retained by the cleanup routine at `bin/taskgrind:871-881` precisely so `grind-log-analyze` can post-mortem it), session-output files, attempt tracking, sweep results. The gap is format and target: SkillClaw expects OpenAI-compatible chat-completions traces; taskgrind logs are stdout/stderr captures plus structured `*_done` markers (`session_done`, `sweep_done`, `grind_done`).
    **What's worth researching** (not building yet — this is a spike):
    1. **Format gap**: can taskgrind emit a sidecar `session_trace.jsonl` per session in SkillClaw's expected format, or is the gap too wide? SkillClaw's storage layer abstracts `local`, `oss`, `s3` (config: `sharing.backend local` + `sharing.local_root /path`) — so a local-only feed is the cheapest first attempt. The session trace would need: prompt text, tool calls, tool results, final assistant message, per-turn metadata. Some of this is already in the log; some (per-turn boundaries) requires backend-specific parsing.
    2. **Backend coverage**: taskgrind supports `devin`, `claude-code`, and `codex` backends (`README.md` table). Each has a different log format. Determine which one(s) emit enough structure to produce a SkillClaw trace without a heavy adapter:
       - `devin`: produces a session URL + structured event log. Probably feedable.
       - `claude-code`: stdout-streamed assistant text + tool calls. Probably feedable with a parser.
       - `codex`: similar to claude-code. Probably feedable with a parser.
       The adapter cost should be ≤1 day per backend; if it's more, this is a build, not a wrapper.
    3. **Evolution loop fit**: SkillClaw's evolve server consumes sessions and produces `SKILL.md` updates. Which skills would benefit? The `next-task` skill (selected via `next-task-context` skill at `.devin/skills/`) is a natural candidate — a long-running marathon produces hundreds of `next-task` invocations, each with different success/failure signals. The `grind-log-analyze` skill itself is a candidate: every post-mortem teaches what to look for next time. Lower-priority candidates: anything that's repo-specific (the audit cascade skills).
    4. **Composability with existing post-mortem**: `grind-log-analyze` already produces tasks from a log. SkillClaw would produce skill edits from the same log. **They are complementary, not redundant** — tasks live in `TASKS.md`, evolved skills live in `~/.skillclaw/skills/` (or `~/.claude/skills/`, depending on the integration). Confirm no overlap by running both on the same log and diffing the outputs.
    5. **Taskgrind's role in the integration** — minimal: emit the trace, let SkillClaw consume it. Don't add a SkillClaw client to taskgrind itself. Don't add evolve-server orchestration to taskgrind. The user installs SkillClaw separately (via the [`catalog-add-skillclaw` task](../agentbrew/TASKS.md) in agentbrew, when that lands), points its `sharing.local_root` at taskgrind's session log directory, and runs `skillclaw-evolve-server` themselves.
    **What's explicitly out of scope**:
    - Adding a SkillClaw daemon or client process to taskgrind itself — taskgrind stays a self-contained shell tool.
    - Implementing the evolve loop in taskgrind — that's SkillClaw's job.
    - Multi-user / OSS / S3 storage — single-user / local-only is the only mode worth researching here.
    - Replacing `grind-log-analyze` — the two are complementary; don't merge them.
    **Cheap, falsifiable dev-machine checks** (≤1 day, budget-bounded):
    1. Install SkillClaw locally per the README (`bash scripts/install_skillclaw.sh`). Verify `skillclaw setup` completes and `skillclaw start --daemon` runs. Check that `skillclaw-evolve-server --use-skillclaw-config --interval 300 --port 8787` consumes a synthetic session.
    2. Hand-craft one `session_trace.jsonl` from a recent taskgrind log (use a real `taskgrind-<date>-<repo>-*.log` from `$TMPDIR`). Drop it into `~/.skillclaw/local-share/<group_id>/sessions/`. Confirm the evolve server picks it up and produces a sane `SKILL.md` candidate.
    3. Time-box the format mapping per backend at ≤30 minutes. If devin's structured log can't be mapped to SkillClaw's format in 30 minutes, the gap is too wide for that backend; record it.
    **Outcome — three possible verdicts** documented in `docs/research/skillclaw-export.md` (new):
    - **(a) Implement minimal exporter**: a `bin/taskgrind-export-trace` helper script reads the latest log and emits the SkillClaw trace format. Add `TG_EMIT_SKILLCLAW_TRACE=1` env opt-in for users who run a SkillClaw evolve server alongside. Keep the surface area tiny — one script, one opt-in.
    - **(b) Document the integration without code**: write a `docs/skillclaw-integration.md` that explains how a user can run SkillClaw alongside taskgrind by pointing it at the existing log directory + a small awk/python parser they can copy-paste. No taskgrind changes. Cheapest option if SkillClaw matures and a community parser emerges.
    - **(c) Reject + record**: format gap too wide, or SkillClaw too young (1k stars, first OSS release April 2026) to build against today. File for ≥90-day re-evaluation; document the blocker.
    **Why P2, not P1**: this is "extends capability for users who have already adopted SkillClaw." It doesn't fix any taskgrind bug or unblock any current marathon. The two P0 / P1 tasks already in this file (the attempt-counter fix and the diminishing-returns default) are far higher value for current users.
    **Anti-pattern to avoid**: don't pre-build the exporter before the spike concludes. The format SkillClaw expects may shift in the next 90 days (very young project), and a half-built exporter against a moving target is worse than nothing. Spike first; build only after the verdict.
  - **Files**: `bin/taskgrind` (read-only during spike — for log-format inspection), `.devin/skills/grind-log-analyze/SKILL.md` (read-only during spike — for composability check), `docs/research/skillclaw-export.md` (new, ~1-page decision doc), optionally `bin/taskgrind-export-trace` (new — only if verdict is "implement"), `docs/skillclaw-integration.md` (new — only if verdict is "document")
  - **Acceptance**: `docs/research/skillclaw-export.md` exists with one of the three verdicts and one paragraph each on the five concrete checks above; the format-gap question is answered per-backend (devin / claude-code / codex) with a concrete time estimate for each adapter; one head-to-head test runs both `grind-log-analyze` and a hand-crafted SkillClaw trace on the same real taskgrind log and confirms outputs are complementary, not duplicate; if verdict is "implement", the new env opt-in `TG_EMIT_SKILLCLAW_TRACE=1` is documented in `README.md` and `man/taskgrind.1` per AGENTS.md rules 3 + 7; if verdict is "reject", the blocker is recorded so this task isn't picked up again for 90 days; `make check` passes regardless of verdict (the spike doc itself doesn't change runtime behavior)

- [ ] Document the log-file retention policy alongside the cleanup routine
  - **ID**: document-log-retention-policy
  - **Tags**: docs, logs, ops
  - **Details**: The temp-file cleanup block at
    `bin/taskgrind:871-881` purges orphaned `taskgrind-exec.*`,
    `taskgrind-lock-*`, `taskgrind-ses-*`, `taskgrind-gsy-*`,
    `taskgrind-att-*`, `taskgrind-*.session.out`, `taskgrind-*.git-sync`, and
    `taskgrind-*.task-attempts*` files older than one day, but deliberately
    leaves the primary `taskgrind-<date>-<repo>-<pid>.log` files so the
    `grind-log-analyze` skill can run post-mortems. On macOS `TMPDIR` is
    usually swept by the OS, but on Linux and in long-lived CI containers
    those log files accumulate — and today `$TMPDIR/taskgrind-*.log` already
    shows nine logs on this host dating back a day. The policy is intentional
    but undocumented, so operators reading
    `README.md#Monitoring` or `SECURITY.md` can't tell whether to add their
    own logrotate, a cron sweep, or just trust the OS. Add a short
    "Log file retention" note under `README.md#Monitoring` that (a) names the
    filename pattern, (b) says cleanup explicitly skips `.log` files, (c)
    recommends a user-owned rotation on Linux / long-lived hosts, and (d)
    reminds that the `grind-log-analyze` skill consumes these files. Mirror
    the retention bullet in `SECURITY.md` near the existing `600` permissions
    note.
  - **Files**: `README.md`, `SECURITY.md`, `bin/taskgrind` (comment near the
    cleanup block so the rationale doesn't drift)
  - **Acceptance**: README and SECURITY.md each contain a paragraph or bullet
    explicitly naming the retention policy and the reason (post-mortem
    analysis); a new doc-drift test (pattern like
    `tests/basics.bats` "README documents …") greps for the policy wording so
    future edits can't silently drop it; `make check` passes.


