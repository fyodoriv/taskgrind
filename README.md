# taskgrind

Autonomous multi-session grind — runs sequential AI coding sessions until a deadline. Each session starts with fresh context. State lives in [`TASKS.md`](https://github.com/tasksmd/tasks.md) + git, so sessions pick up seamlessly.

Taskgrind works with any AI coding agent that accepts a prompt (Devin, Claude Code, Cursor, etc.) and any repo that uses the [tasks.md spec](https://tasks.md) for task management.

## Install

```bash
# Clone to ~/apps (or anywhere)
git clone https://github.com/cbrwizard/taskgrind.git ~/apps/taskgrind

# Add to PATH (add to your shell rc)
export PATH="$HOME/apps/taskgrind/bin:$PATH"
```

## Usage

```bash
taskgrind                              # 8h grind (default), current dir
taskgrind 10                           # 10h grind
taskgrind ~/apps/myrepo 10             # 10h grind in specific repo
taskgrind --skill fleet-grind 10       # custom skill
taskgrind --prompt "focus on test coverage" 8  # focus prompt
taskgrind --backend claude-code 8       # use Claude Code backend
taskgrind --dry-run 8 ~/apps/myrepo    # print config without running
taskgrind --preflight ~/apps/myrepo    # run health checks only
taskgrind --help                       # show usage and environment variables
taskgrind --version                    # print version (commit hash + date)
```

Arguments can appear in any order. Hours is any bare integer 1-24.

## How It Works

1. Launches an AI session with the `next-task` skill (configurable via `--skill`, backend via `--backend`)
2. Session picks a task from `TASKS.md`, implements it, commits, and exits
3. Between sessions: cooldown, optional git sync (every N sessions)
4. Exits when: queue empty, deadline reached, or stall detected

### Task format

Taskgrind reads `TASKS.md` following the [tasks.md spec](https://github.com/tasksmd/tasks.md). Tasks use checkbox format under priority headings:

```markdown
# Tasks

## P0
- [ ] Fix critical bug in auth flow
  **ID**: fix-auth-bug
  **Details**: The OAuth callback fails when...

## P1
- [ ] Add retry logic to API calls
  **ID**: add-api-retry
```

Completed tasks are removed (not checked off). History lives in git log. See the [tasks.md spec](https://github.com/tasksmd/tasks.md/blob/main/spec.md) for the full format.

## Features

- **Multi-backend support** — works with Devin, Claude Code, and Codex via `--backend`
- **Preflight checks** — 7 health checks (binary, network, git state, remote, disk, TASKS.md, network-watchdog) before launch
- **Self-copy protection** — copies itself to `$TMPDIR` before running, survives script edits mid-grind
- **Per-repo locking** — `lockf` prevents duplicate grinds on the same repo
- **Caffeinate integration** — prevents system sleep for the duration of the grind
- **Git sync with stash/rebase** — between-session sync stashes dirty work, rebases on default branch, cleans merged branches
- **Empty-queue sweep** — when `TASKS.md` is empty, launches a sweep session to find work before exiting
- **Network resilience** — pauses on network loss, extends deadline on recovery
- **Stall detection** — bails after consecutive zero-ship sessions (configurable via `DVB_MAX_ZERO_SHIP`)
- **Per-task retry cap** — skips tasks attempted 3+ times without shipping
- **Fast-failure backoff** — linear backoff with cap when sessions crash quickly
- **Ship-rate tracking** — logs cumulative effectiveness in `grind_done` summary
- **Productive timeout warning** — detects when timeout kills sessions that were shipping
- **Unique log names** — includes repo basename + PID to prevent collisions
- **External injection detection** — logs when other processes add tasks mid-run
- **Graceful shutdown** — SIGINT/SIGTERM waits for running session, pushes commits, then exits

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DVB_BACKEND` | `devin` | AI backend: `devin`, `claude-code`, `codex` |
| `DVB_MODEL` | `claude-opus-4-6-thinking` | AI model |
| `DVB_SKILL` | `next-task` | Skill to run each session |
| `DVB_PROMPT` | (none) | Focus prompt for every session |
| `DVB_COOL` | `5` | Seconds between sessions |
| `DVB_MAX_SESSION` | `3600` | Max seconds per session |
| `DVB_MIN_SESSION` | `30` | Fast-failure threshold in seconds |
| `DVB_MAX_FAST` | `5` | Max consecutive fast failures before bail |
| `DVB_MAX_ZERO_SHIP` | `8` | Consecutive zero-ship sessions before bail |
| `DVB_BACKOFF_BASE` | `15` | Base seconds for fast-failure backoff |
| `DVB_BACKOFF_MAX` | `120` | Cap for fast-failure backoff in seconds |
| `DVB_NET_WAIT` | `30` | Network polling interval in seconds |
| `DVB_NET_MAX_WAIT` | `14400` | Max time to wait for network recovery (4h) |
| `DVB_NET_RETRIES` | `3` | Network check retry attempts before declaring down |
| `DVB_NET_RETRY_DELAY` | `2` | Seconds between network check retries |
| `DVB_GIT_SYNC_TIMEOUT` | `30` | Max seconds for between-session git sync |
| `DVB_SYNC_INTERVAL` | `5` | Git sync every N sessions (0=every) |
| `DVB_EARLY_EXIT_ON_STALL` | `0` | Exit on low throughput (1=enabled) |
| `DVB_DEVIN_PATH` | auto | Override devin binary path |
| `DVB_LOG` | auto | Override log file path |
| `DVB_NOTIFY` | `1` | macOS notification on completion |
| `DVB_SHUTDOWN_GRACE` | `120` | Seconds to wait for current session on exit |

## Monitoring

```bash
tail -f /tmp/taskgrind-*.log      # watch live progress
cat /tmp/taskgrind-*.log          # review completed sessions
```

Each session logs: start time, remaining minutes, task count, exit code, duration, and shipped count. The `grind_done` summary includes ship rate, remaining tasks, and average session duration.

## Development

```bash
make lint       # shellcheck
make test       # bats test suite (307 tests)
make check      # lint + test
```

Requires: [bats-core](https://github.com/bats-core/bats-core), [shellcheck](https://www.shellcheck.net/)

```bash
# macOS
brew install bats-core shellcheck
```

## History

Extracted from [dotfiles](https://github.com/cbrwizard/dotfiles) where it lived as `dvb-grind`. The `dvb-grind` name still works as a shell alias in dotfiles for backward compatibility.

## License

MIT
