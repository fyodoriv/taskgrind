# Tasks

<!-- policy: keep runtime files /bin/bash 3.2 compatible (guarded by tests/bash-compat.bats) -->
<!-- policy: run `make check` before claiming a task complete; remove the task block in the same commit that ships the fix -->

## P2

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


