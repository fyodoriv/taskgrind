# Contributing to Taskgrind

## Quick Start

```bash
git clone https://github.com/fyodoriv/taskgrind.git
cd taskgrind
make check   # runs shellcheck + bats test suite
make audit   # runs the local repo audit workflow
make test-force TESTS=tests/bash-compat.bats  # rerun a suite without cache
make test TESTS=tests/bash-compat.bats  # targeted rerun with its own cache key
make install # symlink to /usr/local/bin + install man page
```

Requires [bats-core](https://github.com/bats-core/bats-core) and [shellcheck](https://www.shellcheck.net/). `make audit` also uses [`@tasks-md/lint`](https://www.npmjs.com/package/@tasks-md/lint), either from `PATH` or through the `npx --yes` fallback:

```bash
# macOS
brew install bats-core shellcheck

# Ubuntu / Debian
sudo apt-get update
sudo apt-get install -y npm shellcheck
sudo npm install -g bats @tasks-md/lint

# Fedora / RHEL
sudo dnf install -y bats ShellCheck
```

For Linux, the supported `bats` path is the npm install above because it
matches the GitHub Actions CI path for Linux runs.

## Adding a Feature

1. **Write a failing test first** — add coverage in the focused `.bats` file that matches the behavior under test (`tests/network.bats`, `tests/session.bats`, `tests/logging.bats`, etc.)
2. **Implement the feature** — edit `bin/taskgrind` (or `lib/*.sh` for shared code)
3. **Run `make check`** — shellcheck + all bats tests must pass
4. **Commit on `main`** — this repo uses trunk-based development for small changes

All tests use a fake devin stub via `DVB_GRIND_CMD` — they never invoke real AI backends.

## Backend Expectations

When you touch backend selection, preflight, or setup docs, keep the user-facing
guidance aligned with the actual runtime checks in `bin/taskgrind`.

| Backend | Binary resolution | Preflight model check | Failure text contributors should preserve |
|---------|-------------------|-----------------------|-------------------------------------------|
| `devin` | `devin` from `PATH`, unless `TG_DEVIN_PATH` overrides it | `devin --model <name> --help` | `Backend binary not found (devin)` and `Model rejected by devin before starting` |
| `claude-code` | `claude` from `PATH` | `claude --model <name> --help` | `Backend binary not found (claude-code)` and `Model rejected by claude-code before starting` |
| `codex` | `codex` from `PATH` | `codex --model <name> --help` | `Backend binary not found (codex)` and `Model rejected by codex before starting` |

Notes:

- Codex is the only backend with an extra compatibility warning: if the chosen
  model name still looks like a Claude model, taskgrind warns before launch and
  tells the operator to switch to an OpenAI model such as `o3` or `gpt-5.4`.
- The optional startup backend probe uses `--version` to catch stubbed or broken
  backend binaries before session 1. If you change that probe, update the docs
  when the remediation text changes.
- In tests, model validation is skipped unless the suite opts into it, so doc
  changes should be verified against production-path behavior in `tests/preflight.bats`.

## TASKS.md Format

Taskgrind expects `TASKS.md` to follow the tasks.md spec exactly. Use checkbox
tasks under the priority headings and include the required metadata fields:

```markdown
# Tasks

## P1
- [ ] Document the deployment handoff
  **ID**: document-deployment-handoff
  **Tags**: docs, onboarding
  **Details**: Capture the exact post-merge checks operators still perform by hand.
  **Files**: `README.md`, `docs/user-stories.md`
  **Acceptance**: Contributors can follow the handoff checklist without tribal knowledge.
  **Blocked by**: release-playbook-review
```

`**Blocked by**` is optional; include it only when another task or dependency
actually blocks the work. When you finish a task, remove its entire block from
`TASKS.md` instead of checking it off.

`make audit` runs the upstream `tasks-lint` validator against `TASKS.md` so any
malformed entry (missing `**ID**:`, checkbox typo, accidental `[x]`) fails the
audit before agents pick it up. To install the validator locally:

```bash
npm install -g @tasks-md/lint   # idempotent; persists across runs
# or, no install needed:
npx --yes @tasks-md/lint TASKS.md
```

`make audit` calls `tasks-lint` first if it is on `PATH`; otherwise it falls
back to `npx --yes @tasks-md/lint`. If neither is available, the audit fails
with a one-shot install hint.

## Running a Repo Audit

Use `make audit` when you want the same lightweight local audit loop that empty-queue sweeps rely on:

- Scans the repo for real `TODO` and `FIXME` task markers
- Treats only colon-suffixed task markers as actionable so audit instructions do not report themselves as backlog items
- Includes the core docs and repo-local audit skills in that actionable scan so real doc drift still shows up in the same pass
- Runs shellcheck through `make lint`
- Validates `TASKS.md` against the tasks.md spec via `tasks-lint` (`@tasks-md/lint`); the audit exits non-zero on the first malformed entry
- Prints the core docs review queue (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, `Agentfile.yaml`, `docs/architecture.md`, `docs/resume-state.md`, `docs/user-stories.md`, `man/taskgrind.1`, `.devin/skills/standing-audit-gap-loop/SKILL.md`, `.devin/skills/grind-log-analyze/SKILL.md`)

Apart from the optional `tasks-lint` install (which is cached locally and in
CI), the target is local-only and does not depend on external services at run
time.

## Commit Format

Use [conventional commits](https://www.conventionalcommits.org/):

```
feat: add --backend flag for multi-backend support
fix: prevent orphaned sleep processes on SIGTERM
docs: update README features section
test: add tests for --version flag
chore: update test count in AGENTS.md
```

## Env Var Naming

User-facing documentation and error messages use the `TG_` prefix (canonical). Internally, the script uses `DVB_` variable names for backward compatibility with the original `dvb-grind`. The `TG_` → `DVB_` mapping happens automatically at startup, so both prefixes work for users.

When adding a new env var:
- Use `DVB_` as the internal variable name in the script
- Use `TG_` in all user-facing output (error messages, `--help`, docs)
- Add validation (numeric check, allowed values, etc.)
- Document in `--help` header comment, README, man page, and AGENTS.md
- Add tests for both valid and invalid values

## Test Conventions

- Tests live in focused `tests/*.bats` files with shared helpers in `tests/test_helper.bash`
- Each test gets a fresh `$TEST_DIR` via `setup()` — no shared state between tests
- Use `DVB_DEADLINE` to control loop duration — set in the past for immediate exit (tests that validate args), or a few seconds ahead to run 1-2 sessions
- Use `DVB_GRIND_CMD` to point at a single stub executable path (never the real binary); if a helper needs a compound command, wrap it in a script first
- Use `make test TESTS=tests/<file>.bats` for tight local reruns before falling back to the full suite
- Use `make test-force TESTS=tests/<file>.bats` when you need to bypass the cache and re-run the suite from scratch
- `make test` auto-caps `TEST_JOBS` at 4 to match GitHub Actions and avoid deadline-sensitive parallel flakes; set `TEST_JOBS=<n>` when you need to probe a different level
- If you touch runtime shell code, keep it `/bin/bash` 3.2 compatible and use `tests/verify-bash32-compat.sh` plus `tests/bash-compat.bats` to catch Bash-4-only syntax before the full suite does
- Structural tests (`grep -q` on the script) are fine for verifying code patterns

## Known Issues

- **`network-watchdog`** — preflight checks for a `network-watchdog` binary (optional). If missing, taskgrind falls back to `curl` for connectivity checks. You can safely ignore the preflight warning.

## Diagnosing a Flaky Bats Test

The bats suite is split across many `tests/*.bats` files and runs with auto-capped parallelism (`TEST_JOBS=4` by default; see `Makefile`). Most flakes seen historically were timing-dependent tests with deadlines that were too tight to survive parallel CPU contention, or fake-backend fixtures that did not satisfy the startup probe contract. If a test fails intermittently:

1. **Reproduce in isolation first.** `bats tests/<file>.bats -f "<test name>"` — if it always passes alone, the failure is parallel-load specific.
2. **Force serial execution.** `make test TEST_JOBS=1 TESTS=tests/<file>.bats` — if it now passes, parallelism is the trigger.
3. **Reproduce the auto-capped CI load.** `make test-force TESTS=tests/<file>.bats TEST_JOBS=4` reproduces the bats `--jobs 4` setting that `make test` uses on CI runners.

Common root causes to check before declaring a flake:

- **Deadlines under 30s.** `DVB_DEADLINE=$(( $(date +%s) + 5 ))` will lose the race with bats fixture setup under load. Bump the deadline; the fake devin still exits in <100ms, so the test stays fast in the common case.
- **Inline fake devin missing `--version` output.** Tests that `unset DVB_GRIND_CMD` and rely on a fake on PATH must emit a non-empty pseudo-version string when called with `--version`, or `run_backend_probe` rejects the binary as a stub. See `_install_fake_backend_binary` in `tests/preflight.bats` for the canonical shape.
- **Counter-driven fixtures racing taskgrind startup.** Fixtures that increment a counter on each `git -C rev-parse HEAD` call must account for the probe and preflight paths that may also call git before session 1.

## Project Structure

```
bin/taskgrind           Main script (the whole tool)
lib/constants.sh        Shared constants (model, binary path, caffeinate flags)
lib/fullpower.sh        Priority boosting (taskpolicy on macOS)
tests/*.bats            Focused bats suites by subsystem
tests/test_helper.bash  Shared test helpers
man/taskgrind.1         Man page
docs/                   Architecture docs and user stories
.devin/skills/          Repo-local audit loop skills
.editorconfig           Indent style for shell/bats/markdown/Makefile
Makefile                lint + test targets
```

### `.editorconfig`

The repo ships an [`.editorconfig`](https://editorconfig.org) so any editor that honors it (VS Code, JetBrains IDEs, Vim/Neovim with a plugin) picks up the right indent width and line endings on first open:

- `*.{sh,bash,bats}` — 2-space indent, LF, final newline
- `*.md` — 2-space indent, LF, final newline; trailing spaces are preserved because Markdown uses `  ` at end-of-line for a hard break
- `Makefile` — tab indent, 8-char width (GNU Make requires tabs in recipe lines)
