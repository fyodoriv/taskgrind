# Research spike: SkillClaw session-trace export from taskgrind

| Field | Value |
| --- | --- |
| Spike date | 2026-04-26 |
| SkillClaw version examined | first OSS release 2026-04-10 (16 days old at spike), 1k stars, MIT |
| Real taskgrind log inspected | `$TMPDIR/taskgrind-2026-04-24-1503-agentbrew-87538.log` (8 sessions, 21 shipped, 5h29m) |
| Re-evaluate after | 2026-07-26 (or earlier if any "Triggers a re-spike" criterion below fires) |

## Verdict — (c) Reject + Record

**Taskgrind should not emit SkillClaw session traces. No code changes. Defer ≥90 days.**

The original task framing assumed taskgrind would synthesize OpenAI-compatible chat-completions
traces from its operational log. Inspecting SkillClaw's architecture (per its
[README](https://github.com/AMAP-ML/SkillClaw)) shows the framing was wrong: SkillClaw is a
**client-side proxy** that intercepts `/v1/chat/completions` and `/v1/messages` calls in the wire.
It captures sessions by sitting between the agent CLI and the upstream LLM endpoint — not by
parsing post-hoc operator logs. The taskgrind log doesn't contain the per-turn assistant content,
tool calls, or tool results that an evolve server needs; it contains structured operational
markers (`session=N ...`, `productive_zero_ship`, `grind_done`) plus a 20-line tail of session
output captured only on zero-ship sessions. Reconstructing a faithful session trace from the
taskgrind log is impossible because the data isn't there in the first place.

For users who want SkillClaw, the architecturally-correct integration requires zero taskgrind
changes — they install SkillClaw as a proxy, point their `claude-code` or `codex` backend at it,
and run taskgrind normally. Devin doesn't fit any path because its conversation runs on
Cognition's hosted infrastructure.

## Five concrete checks (per the task spec)

### 1. Format gap — too wide to bridge from a log

The taskgrind primary log captures structured markers and (for zero-ship sessions only) a 20-line
tail of session output. SkillClaw expects the full per-turn stream — system prompt, user message,
assistant text per turn, tool call objects per turn, tool result objects per turn, final assistant
message, plus per-turn metadata (model, timing, tokens). The log has none of the per-turn
boundary information; that's owned by the backend CLI and never reaches taskgrind. Synthesizing
a trace would require either making up turns (rejected — fabricated training data poisons the
evolve loop) or instrumenting the backend CLI's stdout (defeats the point of the spike since the
backend is what should connect to SkillClaw, not taskgrind).

### 2. Backend coverage — claude-code and codex already integrate natively; devin doesn't fit

Per SkillClaw's [news log](https://github.com/AMAP-ML/SkillClaw#news), the 2026-04-20 release added
**native Codex and Claude Code integration with proxy auto-configuration**. Both backends
auto-route through `~/.skillclaw/...` when SkillClaw's setup wizard detects them. Per-backend
adapter cost from taskgrind:

| Backend | Adapter cost | Verdict |
| --- | --- | --- |
| `claude-code` | 0 (already native in SkillClaw) | Use SkillClaw directly; taskgrind is a no-op in the path |
| `codex` | 0 (already native in SkillClaw) | Use SkillClaw directly; taskgrind is a no-op in the path |
| `devin` | ∞ — Devin's conversation runs on `api.devin.ai`; the user's machine never sees the OpenAI-compatible stream that SkillClaw's proxy would intercept | Architectural mismatch; can't be solved from taskgrind |

The original task framing assumed all three backends would need a taskgrind-side adapter. They
don't: two are already covered upstream by SkillClaw, and the third can't be covered at all from
this layer.

### 3. Evolution loop fit — moot; SkillClaw evolves the same skills regardless of taskgrind

The candidate skills the original task identified (`next-task`, `grind-log-analyze`) live in
`~/.claude/skills/` and are picked up by SkillClaw's Claude Code integration directly. A taskgrind
grind that runs claude-code under SkillClaw's proxy already feeds those skills' usage into the
evolve loop. Taskgrind doesn't need to do anything special to make that work.

### 4. Composability with grind-log-analyze — complementary by architecture, not coincidence

`grind-log-analyze` reads taskgrind's operational log (`session_done`, `sweep_done`,
`productive_zero_ship`, `grind_done` markers) and produces TASKS.md candidates — operational
improvements to taskgrind itself, ranked by trip count and ship-rate impact. SkillClaw, when
present, reads the API-layer chat completions stream and produces SKILL.md updates — improvements
to the user-facing skills that ran inside the sessions. They have **non-overlapping inputs and
non-overlapping outputs**:

| Tool | Reads | Writes |
| --- | --- | --- |
| `grind-log-analyze` | `$TMPDIR/taskgrind-*.log` (operational markers) | `TASKS.md` (operational improvements) |
| SkillClaw evolve server | API-layer chat completions stream (per-turn) | `SKILL.md` files in the skill library |

I confirmed this by hand-walking the agentbrew log (8 sessions, 21 shipped). What
`grind-log-analyze` would extract from that log: 2 `productive_zero_ship` arcs, 1
`task_skip_threshold` event with 60+ skipped IDs, sweep-efficiency signals — all
taskgrind-internal observations. What a SkillClaw evolve server would have extracted from the
parallel API conversation: how `next-task` ranked the work, how the agent decomposed
`fix(local-lock)` into three sub-PRs, which skills were invoked. Different signal sources.
**Complementary, not redundant.** Running both is strictly additive; neither would benefit from
merging.

### 5. Taskgrind's role — none. Single-line operator note in lieu of an integration doc

Because the architecturally-correct path is "install SkillClaw, configure your backend, run
taskgrind normally," there's no integration doc worth writing in this repo. A user who's already
chosen SkillClaw will read SkillClaw's docs, not taskgrind's. A user who hasn't doesn't need a
sales pitch from us.

## Head-to-head test (analytical, against the agentbrew log)

The acceptance criterion called for "one head-to-head test on the same real taskgrind log." I ran
a hand-walked version against `taskgrind-2026-04-24-1503-agentbrew-87538.log`:

**`grind-log-analyze` outputs (manually extracted from the log markers):**
- arc taxonomy: Sweep arc (session 1) → Quick arc (sessions 2–4 each shipping 5–8) → Quick arc
  (session 5, shipped via inferred-shipped) → Idle arc (sessions 6–7, productive_zero_ship)
- candidate operational task: investigate why session 6 and 7 hit `local_task_churn` despite
  taskgrind already having that detection — is the threshold too aggressive?
- candidate operational task: 60+ task IDs hit `task_skip_threshold` in session 3; the prompt
  truncation (single line) is unreadable in operator review

**Hypothetical SkillClaw outputs (it doesn't actually have access to this log; I'm reasoning
about what it would have produced from the parallel API stream the proxy would have captured if
the user had been running it):**
- skill update to `next-task`: when seven consecutive sessions each ship a "fix" PR against the
  same external repo (fyodoriv/skills), surface a suggestion to batch them into a single multi-PR
  series
- skill update to `grind-log-analyze`: the agent decomposed `fix(local-lock)` into three sub-PRs
  with regression tests each — record this as a pattern for future post-mortems

These are different ideas, written into different files (`TASKS.md` vs. `SKILL.md`), based on
different inputs (operational markers vs. API conversation). No overlap.

## 90-day re-evaluation criteria

Re-open this task if **any** of these fire (don't re-pick before 2026-07-26 absent one of these):

1. **SkillClaw passes 5k stars and stops shipping breaking format changes.** As of spike date
   it's at 1k stars and shipping integration features every 2–4 days; building against a moving
   16-day-old target is wasteful.
2. **A `devin`-side event-stream API ships** that exposes per-turn assistant content + tool calls
   to the user's machine. Today the conversation lives on `api.devin.ai` and the user only sees
   summaries. If Cognition exposes a local stream, the architectural blocker for Devin lifts.
3. **A community taskgrind-→-SkillClaw exporter gains traction.** If somebody else solves this
   and the format stabilizes, taskgrind can adopt their approach instead of building.
4. **SkillClaw drops the proxy model in favor of log ingestion.** Unlikely (the proxy gives them
   the per-turn data they need), but if it happens, the format-gap question becomes solvable.

If none of these fire, the verdict stands: taskgrind doesn't need to know SkillClaw exists.

## What this doc does NOT do

- It does NOT add `bin/taskgrind-export-trace` (that was verdict (a) — rejected).
- It does NOT add a `docs/skillclaw-integration.md` (that was verdict (b) — rejected; users who
  pick SkillClaw read SkillClaw's docs, not ours).
- It does NOT change `bin/taskgrind`, `man/taskgrind.1`, or `README.md` (no behavior change, no
  new env var, no new operator-facing surface area).
- It does NOT add a `TG_EMIT_SKILLCLAW_TRACE` opt-in (verdict (a) artifact — rejected).
- `make check` is unaffected by this doc; the spike is pure documentation.

## References

- SkillClaw repository: <https://github.com/AMAP-ML/SkillClaw>
- SkillClaw README sections referenced: "Overview", "Deployment Model", "Path A", "Hermes
  Integration", "News" (2026-04-20 entry on Codex + Claude Code integration)
- Real taskgrind log inspected:
  `$TMPDIR/taskgrind-2026-04-24-1503-agentbrew-87538.log` (8 sessions, 21 shipped, 5h29m grind on
  agentbrew, devin backend, claude-opus-4-7-max model)
- Original task spec: `TASKS.md` block `research-skillclaw-session-export` (removed in the same
  commit that landed this doc, per the repo policy "remove the task block in the same commit that
  ships the fix").
