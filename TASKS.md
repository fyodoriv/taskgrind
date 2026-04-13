# Tasks

## P0
- [ ] Harden the empty-queue sweep into a fully verified operator workflow
  **ID**: harden-empty-queue-sweep-workflow
  **Tags**: reliability, testing, core-loop
  **Details**: The empty-queue sweep is taskgrind's differentiator when a repo has no queued work, but the current coverage is split across partial session/logging cases and does not fully exercise the one-time sweep, external-task injection wait window, exhausted exit path, and status-phase transitions together. Add end-to-end bats coverage so the audit loop is safe to trust in long unattended runs.
  **Files**: `bin/taskgrind`, `tests/session.bats`, `tests/logging.bats`, `README.md`
  **Acceptance**: A focused bats suite covers sweep launch, wait-for-work recovery, exhausted empty-queue exit, and the corresponding `TG_STATUS_FILE` phase changes; README examples match the verified behavior.
- [ ] Close retry-cap blind spots in per-task attempt tracking
  **ID**: close-retry-attempt-tracking-gaps
  **Tags**: reliability, testing, anti-looping
  **Details**: `tests/task-attempts.bats` currently has only two tests even though per-task retry caps are one of the main safeguards against wasted sessions. Add behavior-level coverage for shipped tasks clearing attempt debt, successor-task churn not inheriting old counts, and skip-list prompts staying scoped to still-live task IDs.
  **Files**: `bin/taskgrind`, `tests/task-attempts.bats`, `tests/session.bats`, `docs/architecture.md`
  **Acceptance**: New bats coverage proves attempt counters reset or prune correctly after shipped work and queue churn, and skip-list prompts only mention active task IDs that truly crossed the retry threshold.

- [ ] Publish a troubleshooting playbook for stuck, blocked, or conflicting grinds
  **ID**: document-operator-troubleshooting-playbook
  **Tags**: docs, operations, ux
  **Details**: The README explains features, but it does not yet give operators a single troubleshooting path for common unattended-run failures such as blocked queues, slot contention, repeated zero-ship sessions, network waits, resume rejection, or push failures. Add a concise playbook that teaches users how to inspect `TG_STATUS_FILE`, logs, slot ownership, and safe recovery commands.
  **Files**: `README.md`, `docs/user-stories.md`, `man/taskgrind.1`
  **Acceptance**: The docs include a scan-friendly troubleshooting section with concrete symptoms, the status/log signals to inspect, and the recommended recovery action for each common failure mode.
- [ ] Turn final-sync edge cases into behavior-tested guarantees
  **ID**: behavior-test-final-sync-edge-cases
  **Tags**: testing, git, reliability
  **Details**: Final push protection is critical for unattended runs, but some `final_sync` paths are still mostly covered structurally instead of by realistic git behavior. Add bats coverage for duplicate-push suppression, nothing-to-push exits, and push-failure diagnostics so taskgrind can be trusted to shut down cleanly without extra operator babysitting.
  **Files**: `bin/taskgrind`, `tests/signals.bats`, `tests/git-sync.bats`
  **Acceptance**: Bats tests exercise real final-sync outcomes for duplicate attempts, zero-ahead shutdowns, and rejected pushes, and the resulting log/output expectations are locked in.
- [ ] Make `make audit` report actionable TODO/FIXME hits instead of self-referential noise
  **ID**: audit-scan-actionable-results
  **Tags**: tooling, audit, docs
  **Details**: The current `make audit` run mostly reports README, CONTRIBUTING, architecture, and skill text that describe the audit itself, which makes empty-queue sweep output noisy and hard to act on. Tighten the scan or add exclusions so real backlog-worthy markers stand out while the docs review queue still stays visible.
  **Files**: `Makefile`, `tests/basics.bats`, `README.md`, `CONTRIBUTING.md`
  **Acceptance**: `make audit` still scans the intended repo paths, but a clean repo no longer reports the standing audit docs and skill instructions as TODO/FIXME findings unless a real marker is added.
- [ ] Add a monitoring-focused user story for status-file driven automation
  **ID**: add-status-file-monitoring-user-story
  **Tags**: docs, observability, integrations
  **Details**: Taskgrind already emits a machine-readable `TG_STATUS_FILE`, but the docs stop short of showing how to wire it into dashboards, launchd/systemd wrappers, or lightweight watchdog scripts. Add a user story that demonstrates polling the status file, interpreting phase changes, and deciding when an external supervisor should alert or restart the run.
  **Files**: `README.md`, `docs/user-stories.md`
  **Acceptance**: The docs include at least one copy-pasteable monitoring example that reads `TG_STATUS_FILE`, explains the important phases, and shows when to page, wait, or resume.
- [ ] Benchmark and document backend-specific preflight probe expectations
  **ID**: document-backend-probe-expectations
  **Tags**: docs, backends, onboarding
  **Details**: Taskgrind supports Devin, Claude Code, and Codex, but contributors still have to infer which preflight checks and probe failures are backend-specific. Add a backend matrix that explains binary detection, model validation behavior, and the most actionable setup failures for each backend so new users can get from install to first productive grind faster.
  **Files**: `README.md`, `CONTRIBUTING.md`, `man/taskgrind.1`
  **Acceptance**: Documentation clearly differentiates backend setup expectations and common preflight failures for each supported backend, with examples aligned to current CLI behavior.
- [ ] Add regression coverage for empty-queue recovery when new tasks appear during the wait window
  **ID**: test-empty-queue-wait-task-injection
  **Tags**: tests, queue, reliability
  **Details**: `bin/taskgrind` already waits after an empty sweep so another agent or human can inject work, but the suite only covers the wait itself. Add a targeted bats test that creates tasks during `queue_empty_wait` and proves the grind resumes with the refilled queue instead of exiting.
  **Files**: `tests/session.bats`, `tests/test_helper.bash`
  **Acceptance**: A focused test reproduces the "tasks appear during empty-queue wait" path, asserts the resume log/output, and fails if taskgrind exits instead of continuing.
- [ ] Document live override file size guards in the user-facing docs
  **ID**: document-live-override-size-limits
  **Tags**: docs, usability, prompts
  **Details**: `bin/taskgrind` enforces a 10 KB limit for `.taskgrind-prompt` and a 1 KB limit for `.taskgrind-model`, and the tests cover those guards, but the README and user stories do not tell operators about the limits. Document the caps and the warning behavior so users know why oversized override files are ignored.
  **Files**: `README.md`, `docs/user-stories.md`, `man/taskgrind.1`
  **Acceptance**: The README, user stories, and man page all explain the live override size limits and make it clear that oversized files are skipped with a warning.

## P2
- [ ] Align Linux Bats installation guidance with the CI path and supported versions
  **ID**: align-bats-install-docs-with-ci
  **Tags**: docs, ci, dependencies
  **Details**: Contributor docs tell Linux users to install distro `bats`, while GitHub Actions installs Bats through npm. Audit whether the distro package is still sufficient for this suite; then either pin/document the supported version or update the docs/CI so local Linux setup matches the test environment more closely.
  **Files**: `CONTRIBUTING.md`, `README.md`, `.github/workflows/check.yml`
  **Acceptance**: Linux setup guidance and CI use a consistent, documented Bats installation story, and contributors can tell which Bats version/source is supported for running `make check`.
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
## P3
