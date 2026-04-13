# Tasks

## P0
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
- [ ] Document live override file size guards in the user-facing docs
  **ID**: document-live-override-size-limits
  **Tags**: docs, usability, prompts
  **Details**: `bin/taskgrind` enforces a 10 KB limit for `.taskgrind-prompt` and a 1 KB limit for `.taskgrind-model`, and the tests cover those guards, but the README and user stories do not tell operators about the limits. Document the caps and the warning behavior so users know why oversized override files are ignored.
  **Files**: `README.md`, `docs/user-stories.md`, `man/taskgrind.1`
  **Acceptance**: The README, user stories, and man page all explain the live override size limits and make it clear that oversized files are skipped with a warning.

## P1
- [ ] Support paired execution and discovery lanes without a sacrificial audit task
  **ID**: paired-execution-discovery-lanes
  **Tags**: workflow, queue, docs, tests
  **Details**: The `apps/ideas` stack already treats `standing-audit-gap-loop` as the discovery lane and `taskgrind` as the execution lane, but operators trying to run that as two concurrent grinds still end up parking a repo-local `standing-audit-gap-loop` task in `TASKS.md`. That task is removed on completion, which is correct for real work items but makes the discovery lane self-destruct. Keep taskgrind narrow, but add a supported two-stream operator story once `tasks.md` lands the reusable standing-loop pattern and targeted `/next-task` behavior it is already tracking: slot 0 keeps shipping normal queue work, slot 1 keeps filling the queue with high-value discoveries, and the flow no longer depends on a permanent removable sentinel task.
  **Files**: `README.md`, `docs/user-stories.md`, `tests/session.bats`, `tests/multi-instance.bats`
  **Acceptance**: Taskgrind documents one supported two-stream workflow for a single repo; tests cover the discovery-lane guard with the standardized standing-loop pattern instead of a sacrificial repo-local task; the docs explain how discovered tasks flow back into the normal execution lane without the standing definition disappearing.

## P2
- [ ] Add canonical `TG_` precedence tests for wait and backoff env vars that only have validation coverage
  **ID**: expand-tg-precedence-coverage
  **Tags**: tests, env, compatibility
  **Details**: The repo migration to canonical `TG_` env vars is covered for many knobs, but some settings such as `TG_EMPTY_QUEUE_WAIT` still only have invalid-value tests. Add focused precedence coverage for the remaining wait/backoff-style knobs so future refactors do not silently prefer the legacy `DVB_` alias.
  **Files**: `tests/diagnostics.bats`, `tests/network.bats`, `tests/session.bats`
  **Acceptance**: The affected env vars have red/green coverage proving `TG_` overrides the matching `DVB_` value during a real run, not just in validation error paths.
## P3
