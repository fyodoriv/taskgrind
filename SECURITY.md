# Security Policy

## Supported Versions

Only the latest version on `main` is supported.

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Email the maintainer or open a [private security advisory](https://github.com/fyodoriv/taskgrind/security/advisories/new) on GitHub

We will acknowledge your report within 48 hours and provide a fix timeline.

## Security Considerations

Taskgrind runs AI coding backends with **unrestricted permissions** (e.g., `--permission-mode dangerous` for Devin, `--dangerously-skip-permissions` for Claude Code). This is by design — sessions need full filesystem and network access to implement tasks autonomously.

Before running taskgrind, ensure:

- You trust the AI backend being used
- You have reviewed the tasks in `TASKS.md`
- The repo does not contain secrets or credentials that should not be accessible to the AI
- Log files (`${TMPDIR:-/tmp}/taskgrind-*.log`) are readable only by the owner (permissions are set to `600`)
- Log files persist across grinds by design — taskgrind sweeps short-lived sidecar files (`taskgrind-exec.*`, `taskgrind-lock-*`, `taskgrind-ses-*`, `taskgrind-att-*`, `taskgrind-gsy-*`, etc.) older than one day on every startup but **explicitly leaves the primary `*.log` files in place** so the `grind-log-analyze` skill can run post-mortems. On Linux and long-lived hosts, configure your own rotation (`logrotate`, cron, `systemd-tmpfiles`) if you need bounded retention
