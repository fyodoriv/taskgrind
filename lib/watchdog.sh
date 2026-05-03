#!/bin/bash
# Watchdog escalation helper for taskgrind session/sweep/repair caps.
#
# Single source of truth for the SIGINT -> SIGTERM -> SIGKILL escalation
# sequence used by `bin/taskgrind`. Three call sites (per-session watchdog,
# sweep watchdog, supervisor repair watchdog) historically inlined the
# same ~20-line subshell — that copy-pasted body had two correctness gaps
# that combined into a 15x cap overrun on the 2026-05-01 dotfiles grind:
#
#  1. No SIGKILL escalation. The watchdog stopped at SIGTERM, so a backend
#     that ignored both SIGINT and SIGTERM (e.g. claude-code stuck inside
#     an unresponsive HTTP retry loop) ran indefinitely.
#  2. Self-disarm on spurious signals. The trap `kill $! 2>/dev/null;
#     exit 0` exited the watchdog on any external signal, leaving the
#     backend unsupervised and the parent's `wait` blocked forever.
#
# This helper fixes both, plus adds a wall-clock ceiling fallback so a
# pathological clock-skew or signal-storm scenario cannot let the
# watchdog run unbounded.
#
# Usage (from `bin/taskgrind`, inside `( ... ) &`):
#
#   ( dvb_watchdog_run "session" "$max_session" "$_dvb_pid" ) &
#   _dvb_timeout_pid=$!
#
# Reads globals: log_file (optional — log markers silently no-op when unset).
#
# shellcheck shell=bash

# DVB_DEFAULT_SESSION_GRACE / DVB_DEFAULT_WATCHDOG_KILL_GRACE are defined
# in lib/constants.sh. This file is sourced after constants so the
# defaults are available; the per-call DVB_* env-var overrides still
# take precedence.

# dvb_watchdog_run — enforce a cap on a backend PID with three-stage
# escalation and a wall-clock fallback. Cannot be silently disarmed by
# spurious signals.
#
# Args:
#   $1 context        Log-marker prefix (e.g. "session", "sweep",
#                     "supervisor_repair"). Forms `<context>_watchdog
#                     escalation=...` lines so post-mortems can identify
#                     which watchdog fired.
#   $2 cap_seconds    Hard cap on backend wall-clock time. After this
#                     elapses, the escalation begins.
#   $3 target_pid     Backend PID to monitor. Watchdog exits early when
#                     this PID is gone, so a graceful backend exit
#                     finishes the watchdog within one poll interval.
#   $4 legacy_marker  (optional) Log line emitted verbatim at the moment
#                     the cap fires (just before SIGINT). Used to keep
#                     the legacy `session_timeout session=N max=Ms`
#                     marker that the grind-log-analyze skill greps for.
#                     Empty/unset for sweep and supervisor_repair contexts.
#
# Reads env:
#   DVB_SESSION_GRACE         — seconds between SIGINT and SIGTERM
#                               (default: $DVB_DEFAULT_SESSION_GRACE,
#                               provided by lib/constants.sh).
#   DVB_WATCHDOG_KILL_GRACE   — seconds between SIGTERM and SIGKILL
#                               (default: $DVB_DEFAULT_WATCHDOG_KILL_GRACE).
dvb_watchdog_run() {
  local context="$1"
  local cap="$2"
  local target_pid="$3"
  local legacy_marker="${4:-}"
  local grace kill_grace start now elapsed remaining s wall_cap sleep_pid

  grace="${DVB_SESSION_GRACE:-${DVB_DEFAULT_SESSION_GRACE:-15}}"
  kill_grace="${DVB_WATCHDOG_KILL_GRACE:-${DVB_DEFAULT_WATCHDOG_KILL_GRACE:-5}}"
  start=$(date +%s)

  # Wall-clock ceiling: cap + grace + kill_grace + 60s buffer. Even if
  # internal accounting drifts (sleep() shorter than nominal under load,
  # SIGCHLD storms interrupting sleep loops, etc.), the watchdog will
  # exit no later than this ceiling — never unbounded.
  wall_cap=$(( cap + grace + kill_grace + 60 ))

  # Signal handling: TERM and INT mean two different things depending on
  # backend state, and the trap has to honor both:
  #
  #   - Backend already dead — the parent has finished `wait $_dvb_pid`
  #     and is sending TERM to clean up the watchdog. Exit cleanly so the
  #     parent's `wait $_dvb_timeout_pid` returns immediately and the
  #     next session can launch without paying a ~5s tear-down latency
  #     per session (a 12s rotation test would otherwise fit only one
  #     session instead of three).
  #   - Backend still alive — the signal is spurious. The previous
  #     `trap 'kill $! 2>/dev/null; exit 0' TERM` always treated TERM as
  #     "exit cleanly", which silently disarmed the watchdog and let a
  #     wedged backend run unbounded (2026-05-01 dotfiles grind: 14.95x
  #     cap overrun). Ignore the signal in that case and keep enforcing
  #     the cap.
  trap 'if ! kill -0 "$target_pid" 2>/dev/null; then exit 0; fi' TERM INT

  # Phase 1: wait for cap to elapse, but exit early if backend dies.
  # Poll granularity is intentionally short (5s) so a graceful backend
  # exit unblocks the parent's `wait $_dvb_timeout_pid` quickly.
  remaining="$cap"
  while (( remaining > 0 )); do
    s=$(( remaining > 5 ? 5 : remaining ))
    sleep "$s" &
    sleep_pid=$!
    # Do NOT `exit 0` on wait failure — the previous `wait $! 2>/dev/null
    # || exit 0` was the self-disarm bug. Re-check the cap and the
    # backend health on every iteration.
    wait "$sleep_pid" 2>/dev/null || true
    remaining=$(( remaining - s ))
    if ! kill -0 "$target_pid" 2>/dev/null; then
      return 0
    fi
    # Hard wall-clock fallback even if remaining accounting drifts.
    now=$(date +%s)
    if (( now - start >= wall_cap )); then
      break
    fi
  done

  # Phase 2: SIGINT for graceful shutdown.
  if ! kill -0 "$target_pid" 2>/dev/null; then return 0; fi
  if [[ -n "$legacy_marker" ]]; then
    _dvb_watchdog_log_raw "$legacy_marker"
  fi
  _dvb_watchdog_log "$context" "escalation=SIGINT pid=$target_pid cap=${cap}s"
  kill -INT "$target_pid" 2>/dev/null || true

  remaining="$grace"
  while (( remaining > 0 )); do
    s=$(( remaining > 5 ? 5 : remaining ))
    sleep "$s" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || true
    remaining=$(( remaining - s ))
    if ! kill -0 "$target_pid" 2>/dev/null; then return 0; fi
  done

  # Phase 3: SIGTERM (and pkill child group) if still alive.
  _dvb_watchdog_log "$context" "escalation=SIGTERM pid=$target_pid grace=${grace}s"
  kill "$target_pid" 2>/dev/null || true
  pkill -TERM -P "$target_pid" 2>/dev/null || true

  remaining="$kill_grace"
  while (( remaining > 0 )); do
    s=$(( remaining > 1 ? 1 : remaining ))
    sleep "$s" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || true
    remaining=$(( remaining - s ))
    if ! kill -0 "$target_pid" 2>/dev/null; then return 0; fi
  done

  # Phase 4: SIGKILL — last resort. The escalation marker required by
  # the cap-overrun post-mortem contract is emitted on this branch only
  # (graceful exits never log SIGKILL).
  if kill -0 "$target_pid" 2>/dev/null; then
    elapsed=$(( $(date +%s) - start ))
    _dvb_watchdog_log "$context" "escalation=SIGKILL pid=$target_pid elapsed=${elapsed}s"
    kill -KILL "$target_pid" 2>/dev/null || true
    pkill -KILL -P "$target_pid" 2>/dev/null || true
  fi
  return 0
}

# Internal helper — append an escalation log line to the active log
# file, if any. Silent no-op when `log_file` is unset (e.g. unit tests
# that exercise the function directly without booting the full grind).
_dvb_watchdog_log() {
  local context="$1"
  local detail="$2"
  _dvb_watchdog_log_raw "${context}_watchdog ${detail}"
}

# Internal helper — append a fully-formed log line (caller-supplied,
# without the `[pid=N] [HH:MM]` prefix) to the active log file. Used by
# the optional `legacy_marker` argument so callers can emit pre-existing
# markers (e.g. `session_timeout session=N max=Ms`) without bypassing
# the file-existence guard.
_dvb_watchdog_log_raw() {
  local detail="$1"
  if [[ -n "${log_file:-}" ]]; then
    echo "[pid=$$] [$(date '+%H:%M')] ${detail}" \
      >> "$log_file" 2>/dev/null || true
  fi
}
