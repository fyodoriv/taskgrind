# Taskgrind Defaults Rationale

Taskgrind keeps user-facing `TG_*` runtime defaults in
`lib/constants.sh`. `bin/taskgrind` reads those constants after resolving the
canonical `TG_` env var prefix and the backward-compatible `DVB_` aliases.

## Current defaults

| Variable | Default | Source | Failure mode sized against | Decision |
|---|---:|---|---|---|
| `TG_COOL` | 5s | `6df6a69` initial extraction | Immediate relaunch can race temp-file cleanup, hooks, and filesystem flushes. | Keep: 5s is visible but negligible in multi-hour runs. |
| `TG_MAX_SESSION` | 5400s | `31f4af8` pipelines-era refresh | Direct-edit 60m sessions were killing healthy Bosun pipeline orchestration mid-cycle. | Keep: 90m lets a session launch, monitor, and merge several pipeline cycles; productive timeouts can ratchet to 7200s. |
| `TG_SWEEP_MAX` | 1800s | `4e34f22` sweep cap | Empty-queue backlog discovery can burn a whole grind if it inherits long productive-session limits. | Keep: 30m forces large audits to split into smaller passes. |
| `TG_MIN_SESSION` | 30s | `6df6a69` initial extraction | Sub-30s exits are usually startup, auth, or network failures rather than real implementation work. | Keep: test mode still disables this unless explicitly overridden. |
| `TG_MAX_FAST` | 20 | `5a0fb8e` multi-instance/stall hardening | A broken backend can fail instantly forever, but too-low limits hide useful diagnostic patterns. | Keep: 20 samples is enough to see repeated exit classes without looping all night. |
| `TG_MAX_ZERO_SHIP` | 6 | `5a0fb8e`, tuned here | A live backend can keep producing text without removing any task. | Lower from 50: self-investigation now fires at 3 and diminishing-returns uses a 5-session window, so 6 is the hard fallback. |
| `TG_SELF_INVESTIGATE_ZERO_SHIP_STREAK` | 3 | `160b4ea` self-investigate | Several consecutive zero-ship sessions indicate structural stall before the hard bail. | Keep: 3 is early enough to warn the next prompt and rotate backends while leaving room for hard tasks. |
| `TG_BACKOFF_BASE` | 15s | `6df6a69` initial extraction | Fast crash loops can hammer a backend/API and fill logs. | Keep: backoff starts after the third fast failure, so 15s scales quickly without delaying the first diagnostics. |
| `TG_BACKOFF_MAX` | 120s | `6df6a69` initial extraction | Unbounded backoff can hide recovery and make short grinds appear idle. | Keep: 2m cap checks recovery frequently while still dampening crash storms. |
| `TG_NET_WAIT` | 30s | `6df6a69` initial extraction | Network recovery should be noticed promptly but not spam logs. | Keep: 30s is a practical Wi-Fi polling cadence. |
| `TG_NET_MAX_WAIT` | 3600s | `6df6a69`, tuned here | Local outages pause the marathon clock, but half-day waits hide real failures. | Lower from 14400: 1h covers common Wi-Fi/VPN recovery; longer outages should be resumed explicitly. |
| `TG_NET_RETRIES` | 3 | `6df6a69` initial extraction | Single DNS/HTTP hiccups should not pause the whole grind. | Keep: with 2s retry delay, false-negative detection stays under 10s. |
| `TG_NET_RETRY_DELAY` | 2s | `0d9ab70` TG-prefix docs path | Retries need to be close enough to classify transient blips quickly. | Keep: 2s × 3 attempts avoids long pre-wait stalls. |
| `TG_GIT_SYNC_TIMEOUT` | 30s | `6df6a69` initial extraction | Between-session fetch/rebase can hang on slow remotes and block the grind. | Keep: 30s is enough for normal sync; longer hangs require operator recovery. |
| `TG_SYNC_INTERVAL` | 5 | `6df6a69` initial extraction | Syncing every session wastes time and creates rebase churn; never syncing causes stale work. | Keep: every 5 sessions amortizes overhead while limiting drift. |
| `TG_MAX_INSTANCES` | 2 | `67dea6d` two-slot default | One grind may need a sync owner while another handles non-overlapping audits/docs. | Keep: 2 gives parallelism without normalizing edit conflicts. |
| `TG_EMPTY_QUEUE_WAIT` | 600s | `5483c2b` empty-sweep wait restore | An empty sweep can finish just before another agent or hook injects follow-up work. | Keep: 10m is enough for handoffs without turning empty queues into idle daemons. |
| `TG_SHUTDOWN_GRACE` | 120s | `edeb51d` configurable grace | Interrupting an active session can lose a nearly-finished commit. | Keep: 2m gives the backend time to commit and exit. |
| `TG_SESSION_GRACE` | 15s | `edeb51d` configurable grace | Timed-out sessions need a short SIGINT window before force termination. | Keep: 15s protects cleanup without hiding wedged backends. |

## Before / after benchmark

This benchmark is deterministic budget math from the defaults, not a live
backend benchmark. It measures the maximum time the old default could consume
before the guard fired.

| Candidate | Old default | New default | Budget before | Budget after | Improvement |
|---|---:|---:|---:|---:|---:|
| `TG_MAX_ZERO_SHIP` | 50 sessions | 6 sessions | 75h at 5400s/session | 9h at 5400s/session | 66h less worst-case zero-ship burn |
| `TG_NET_MAX_WAIT` | 14400s | 3600s | 4h paused per outage | 1h paused per outage | 3h less hidden outage time |

The zero-ship change intentionally matches the newer self-healing stack:
`TG_SELF_INVESTIGATE_ZERO_SHIP_STREAK=3` warns the next prompt and rotates/investigates first, then the
5-session diminishing-returns window gets one more confirmation session before
the hard zero-ship bail. The network change preserves the original "pause the
marathon clock during local outages" behavior while making half-day outages
explicit operator recovery events.
