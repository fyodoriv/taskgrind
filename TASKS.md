# Tasks

## P0

- [ ] Show progress/loading feedback during slow operations
  **ID**: show-loading-feedback
  **Tags**: ux, cli
  **Details**: When you run taskgrind, several operations block for seconds with zero terminal output — the user stares at a frozen terminal wondering if anything is happening. The worst offenders: (1) preflight checks — each check (network curl, git remote, disk space) can take 5+ seconds with no indication it started; (2) session launch — after printing "Session N" there's silence until devin finishes; (3) cooldown sleep between sessions; (4) git sync (fetch/rebase/push); (5) wait_for_network polling. Add inline progress: spinner or `...` dots for blocking checks, a running elapsed timer during active sessions (e.g. `⏳ Session 3 — 4m12s`), and a countdown for cooldown/backoff sleeps (e.g. `Cooldown: 28s`). Keep it minimal — single-line overwrite with `\r` or a background spinner function, not a TUI. Must degrade gracefully when stdout is not a TTY (e.g. piped to a log file — just skip the spinners).
  **Files**: bin/taskgrind
  **Acceptance**: Running `taskgrind 1` shows visible feedback within 1s of launch; no silent gaps longer than 2s during normal operation; piping to a file (`taskgrind 1 2>&1 | tee log`) still works without garbled output; `make check` passes

## P1

## P2

- [ ] Add docs/user-stories.md — real usage patterns
  **ID**: add-user-stories
  **Tags**: docs
  **Details**: Document the 5 core user stories: (1) overnight grind on a repo with tasks, (2) focused grind with --prompt, (3) multi-repo grind (run taskgrind on repo A, then repo B), (4) fleet-grind for pipeline management, (5) dry-run/preflight to check before committing to 8 hours. Each story: one sentence context, the command, what happens, sample log output.
  **Files**: docs/user-stories.md, README.md (link to it)
  **Acceptance**: Each story is copy-pasteable and matches actual tool behavior

- [ ] Add docs/architecture.md — design decisions
  **ID**: add-architecture-doc
  **Tags**: docs
  **Details**: Document why taskgrind works the way it does: (1) why self-copy (bash lazy reading), (2) why caffeinate -ms not -dims, (3) why git sync every N not every 1, (4) why per-task retry cap uses ID tracking, (5) why empty-queue exit instead of sweep, (6) why next-task over custom grind skill. One paragraph each. Not a tutorial — a "why" doc for contributors.
  **Files**: docs/architecture.md
  **Acceptance**: Each design decision has a one-paragraph rationale

- [ ] Rename DVB_ env vars to TG_ with backward compat aliases
  **ID**: rename-env-vars
  **Tags**: api, breaking-change
  **Details**: All env vars use the `DVB_` prefix (from the original `dvb-grind` name). Now that the tool is `taskgrind`, the canonical prefix should be `TG_` (e.g. `TG_MODEL`, `TG_SKILL`). Keep `DVB_` as fallback aliases: `model="${TG_MODEL:-${DVB_MODEL:-$DEFAULT_MODEL}}"`. Update --help, README, AGENTS.md. This is a low-priority cosmetic change — DVB_ works fine.
  **Files**: bin/taskgrind, lib/constants.sh, README.md, AGENTS.md
  **Acceptance**: `TG_MODEL=sonnet taskgrind --dry-run` works; `DVB_MODEL=sonnet taskgrind --dry-run` still works; --help shows TG_ as primary

- [ ] Add --version flag
  **ID**: add-version-flag
  **Tags**: cli, ux
  **Details**: `taskgrind --version` should print the git commit hash and date (same pattern as `dotfiles --version`). Use `git -C "$TASKGRIND_DIR" log -1 --format='%h %ci'` or embed version at release time.
  **Files**: bin/taskgrind
  **Acceptance**: `taskgrind --version` prints a commit hash + date; exits 0

- [ ] Add CONTRIBUTING.md
  **ID**: add-contributing
  **Tags**: docs
  **Details**: Short contributing guide: how to run tests, how to add a feature (test first), commit format, env var naming convention (DVB_ compat), and the one-flaky-test caveat.
  **Files**: CONTRIBUTING.md
  **Acceptance**: New contributor can run tests and submit a PR by following CONTRIBUTING.md

- [ ] README missing features: preflight, self-copy, locking, caffeinate
  **ID**: readme-missing-features
  **Tags**: docs
  **Details**: README Features section lists 9 features. Missing from the list: preflight checks (7 health checks before launch), per-repo locking (lockf prevents duplicate grinds), self-copy protection (survives script edits mid-grind), caffeinate integration (prevents sleep), git sync with stash/rebase/branch-cleanup. Add 1-line bullets for each.
  **Files**: README.md
  **Acceptance**: All major features visible in README Features section

- [ ] Support multiple agent backends (not just Devin)
  **ID**: multi-backend-support
  **Tags**: feature, architecture
  **Details**: Taskgrind hardcodes `devin` as the session runner (`"${devin_cmd[@]}" --model "$model" --permission-mode dangerous -p "$prompt"`). Should support other backends: Claude Code (`claude -p "$prompt"`), Cursor (background agent), Codex (`codex -q "$prompt"`). Add `DVB_BACKEND` env var (default: `devin`). Each backend needs: launch command template, timeout behavior, output capture method.
  **Files**: bin/taskgrind
  **Acceptance**: `DVB_BACKEND=claude-code taskgrind 1` launches Claude Code sessions; default behavior unchanged

## P3

- [ ] Add GitHub Actions CI
  **ID**: add-ci
  **Tags**: ci, infra
  **Details**: Add `.github/workflows/check.yml` that runs `make check` on push/PR. Matrix: macOS (primary, for caffeinate/lockf tests) + Linux (for portability). Use `bats-core` and `shellcheck` GitHub Actions.
  **Files**: .github/workflows/check.yml
  **Acceptance**: CI badge in README; PRs get lint + test checks

- [ ] Add install script (curl | sh)
  **ID**: add-install-script
  **Tags**: distribution, ux
  **Details**: One-liner install: `curl -fsSL https://raw.githubusercontent.com/cbrwizard/taskgrind/main/install.sh | sh`. Script clones to `~/apps/taskgrind` and prints PATH instructions. Check if already installed first.
  **Files**: install.sh
  **Acceptance**: Fresh machine install works with one curl command

- [ ] Linux portability: replace macOS-only commands
  **ID**: linux-portability
  **Tags**: portability
  **Details**: Several commands are macOS-only: `caffeinate` (sleep prevention), `lockf` (file locking), `osascript` (notifications), `stat -f %m` (file mtime). Add Linux fallbacks: `systemd-inhibit` or no-op for caffeinate, `flock` for lockf, `notify-send` for osascript, `stat -c %Y` for mtime. Guard with `[[ "$(uname)" == "Darwin" ]]` checks.
  **Files**: bin/taskgrind
  **Acceptance**: `taskgrind --preflight` passes on Ubuntu; full grind loop works on Linux

- [ ] Add man page
  **ID**: add-man-page
  **Tags**: docs, distribution
  **Details**: Generate a man page from --help output or write `taskgrind.1` manually. Install to standard man path. Low priority — --help is sufficient for most users.
  **Files**: man/taskgrind.1
  **Acceptance**: `man taskgrind` works after install

- [ ] Homebrew tap for easy install
  **ID**: homebrew-tap
  **Tags**: distribution
  **Details**: Create a Homebrew tap (`cbrwizard/tap`) with a formula for taskgrind. Formula clones the repo and symlinks `bin/taskgrind` to the Homebrew prefix. Depends on `bats-core` (test) and `shellcheck` (dev).
  **Files**: separate repo (homebrew-tap), README.md (update install section)
  **Acceptance**: `brew install cbrwizard/tap/taskgrind` installs and `taskgrind --help` works
