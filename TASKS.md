# Tasks

## P0
## P1
## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
- [ ] Clarify resume troubleshooting docs when the original run used backend or prompt overrides
  **ID**: clarify-resume-override-recovery-docs
  **Tags**: docs, resume, troubleshooting
  **Details**: README and operator guidance currently suggest `taskgrind --resume <repo>` as the generic recovery command after crashes, network waits, or shutdown git failures. That misses the strict resume contract: interrupted runs that started with explicit backend/model/skill/prompt overrides must reuse the same baseline choices. Tighten the troubleshooting guidance and examples so operators do not hit avoidable resume rejections.
  **Files**: `README.md`, `docs/user-stories.md`, `docs/resume-state.md`, `tests/basics.bats`
  **Acceptance**: The resume docs explicitly say when a plain `--resume <repo>` is enough versus when the original overrides must be repeated, and tests pin the updated README guidance.
- [ ] Refresh AGENTS.md repo layout for the focused docs bats suites and helper scripts (@instance-1)
  **ID**: refresh-agents-repo-layout
  **Tags**: docs, agents, audit
  **Details**: The repo guide still summarizes the test tree generically even though the focused docs coverage now lives in concrete suites such as `tests/preflight.bats` and `tests/installer-output.bats`. Update the layout and local test notes so agents can find the right files quickly during docs and preflight work.
  **Files**: `AGENTS.md`, `tests/basics.bats`
  **Acceptance**: `AGENTS.md` names the focused preflight and installer-output bats suites plus the helper scripts they rely on, and a docs test fails if those references disappear again.
## P3
