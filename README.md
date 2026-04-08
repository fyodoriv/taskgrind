# taskgrind

Autonomous multi-session grind — runs sequential AI coding sessions until a deadline. Each session starts with fresh context. State lives in `TASKS.md` + git, so sessions pick up seamlessly.

## Install

```bash
# Clone to ~/apps (or anywhere)
git clone https://github.com/fivanishche/taskgrind.git ~/apps/taskgrind

# Add to PATH (add to your shell rc)
export PATH="$HOME/apps/taskgrind/bin:$PATH"
```

## Usage

```bash
taskgrind                              # 8h grind (default), current dir
taskgrind 10                           # 10h grind
taskgrind ~/apps/myrepo 10             # 10h grind in specific repo
taskgrind --skill fleet-grind 10       # custom skill
taskgrind --prompt "focus on tests" 8  # focus prompt
taskgrind --dry-run 8 ~/apps/myrepo    # print config without running
taskgrind --preflight ~/apps/myrepo    # run health checks only
```

## How It Works

1. Launches a Devin session with the `next-task` skill (configurable via `--skill`)
2. Session picks a task from `TASKS.md`, implements it, commits, and exits
3. Between sessions: cooldown, optional git sync (every N sessions)
4. Exits when: queue empty, deadline reached, or stall detected

## Features

- **Empty-queue exit** — exits immediately when `TASKS.md` has no tasks
- **Network resilience** — pauses on network loss, extends deadline on recovery
- **Stall detection** — bails after 3 consecutive zero-ship sessions (configurable)
- **Per-task retry cap** — skips tasks attempted 3+ times without shipping
- **Diminishing returns** — warns when throughput drops below threshold
- **Ship-rate tracking** — logs cumulative effectiveness in `grind_done` summary
- **Unique log names** — includes repo basename + PID to prevent collisions

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DVB_MODEL` | `claude-opus-4-6-thinking` | AI model |
| `DVB_SKILL` | `next-task` | Skill to run each session |
| `DVB_PROMPT` | (none) | Focus prompt for every session |
| `DVB_COOL` | `5` | Seconds between sessions |
| `DVB_MAX_SESSION` | `3600` | Max seconds per session |
| `DVB_MAX_ZERO_SHIP` | `3` | Consecutive zero-ship sessions before bail |
| `DVB_SYNC_INTERVAL` | `5` | Git sync every N sessions (0=every) |
| `DVB_EARLY_EXIT_ON_STALL` | `0` | Exit on low throughput (1=enabled) |
| `DVB_LOG` | auto | Override log file path |
| `DVB_NOTIFY` | `1` | macOS notification on completion |

See `taskgrind --help` for the full list.

## Development

```bash
make lint       # shellcheck
make test       # bats test suite
make check      # lint + test
```

Requires: [bats-core](https://github.com/bats-core/bats-core), [shellcheck](https://www.shellcheck.net/)

## License

MIT
