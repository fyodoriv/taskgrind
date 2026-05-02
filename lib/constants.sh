#!/bin/bash
# Shared constants for taskgrind.
# Single source of truth for AI session configuration.
# Usage: source "$(cd "$(dirname "$0")/.." && pwd)/lib/constants.sh"

# Variables below are sourced by bin/taskgrind.
# shellcheck disable=SC2034  # used by sourcing scripts

# Default AI model for Devin / Claude-compatible backends.
#
# Devin's "Claude Opus 4.7 Max" is the kebab-case ID `claude-opus-4-7-max`.
# Claude Code rejects the `-max` suffix (it's a Devin product label that maps
# to model `claude-opus-4-7` + max-effort thinking server-side). When taskgrind
# launches the `claude-code` backend it must drop the suffix; Devin happily
# accepts the full `-max` ID. Hence the per-backend split below.
DVB_DEFAULT_MODEL="claude-opus-4-7-max"
DVB_DEFAULT_DEVIN_MODEL="$DVB_DEFAULT_MODEL"
DVB_DEFAULT_CLAUDE_CODE_MODEL="claude-opus-4-7"
DVB_DEFAULT_CODEX_MODEL="gpt-5.5"
DVB_RESUME_STATE_VERSION="1"
DVB_RESUME_STATE_BASENAME=".taskgrind-state"
DVB_MODEL_ALIASES=$'opus=claude-opus-4-7-max\nsonnet=claude-sonnet-4.6\nhaiku=claude-haiku-4.5\nswe=swe-1.6\ncodex=gpt-5.5\ngpt=gpt-5-5-xhigh-priority'

# TG_COOL=5: short settle window between sessions without materially reducing grind time.
DVB_DEFAULT_COOL="5"
# TG_MAX_FAST=20: enough crash samples for diagnostics while still bounding a broken backend loop.
DVB_DEFAULT_MAX_FAST="20"
# TG_MAX_SESSION=5400: pipeline-era sessions need 90m to launch, monitor, and merge several Bosun cycles.
DVB_DEFAULT_MAX_SESSION="5400"
# TG_SWEEP_MAX=1800: backlog sweeps should split after 30m instead of inheriting productive-session timeouts.
DVB_DEFAULT_SWEEP_MAX="1800"
# TG_MAX_ZERO_SHIP=6: one full diminishing-returns window plus one confirmation trip before bailing.
DVB_DEFAULT_MAX_ZERO_SHIP="6"
# TG_SYNC_INTERVAL=5: amortizes fetch/rebase overhead while keeping long grinds reasonably fresh.
DVB_DEFAULT_SYNC_INTERVAL="5"
# TG_MAX_INSTANCES=2: permits one sync owner plus one conflict-avoiding worker by default.
DVB_DEFAULT_MAX_INSTANCES="2"
# TG_MIN_SESSION=30: sessions shorter than 30s are likely startup/network failures, not real work.
DVB_DEFAULT_MIN_SESSION="30"
# TG_NET_WAIT=30: frequent enough for Wi-Fi recovery, sparse enough not to spam logs.
DVB_DEFAULT_NET_WAIT="30"
# TG_NET_MAX_WAIT=3600: one hour covers common local outages without hiding half-day network failures.
DVB_DEFAULT_NET_MAX_WAIT="3600"
# TG_NET_RETRIES=3: filters transient DNS/HTTP blips before entering network-wait mode.
DVB_DEFAULT_NET_RETRIES="3"
# TG_NET_RETRY_DELAY=2: retry quickly while keeping the false-negative probe under 10s.
DVB_DEFAULT_NET_RETRY_DELAY="2"
# TG_BACKOFF_BASE=15: fast-failure loops slow down quickly without delaying the first few diagnostics.
DVB_DEFAULT_BACKOFF_BASE="15"
# TG_BACKOFF_MAX=120: caps fast-failure sleep at two minutes so recovery checks stay frequent.
DVB_DEFAULT_BACKOFF_MAX="120"
# TG_GIT_SYNC_TIMEOUT=30: fetch/rebase should be short between sessions; longer hangs need operator action.
DVB_DEFAULT_GIT_SYNC_TIMEOUT="30"
# TG_EMPTY_QUEUE_WAIT=600: gives external agents ten minutes to inject follow-up work after an empty sweep.
DVB_DEFAULT_EMPTY_QUEUE_WAIT="600"
# TG_SHUTDOWN_GRACE=120: lets an interrupted session commit and exit before force termination.
DVB_DEFAULT_SHUTDOWN_GRACE="120"
# TG_SESSION_GRACE=15: lets a timed-out backend handle SIGINT without losing the whole grind budget.
DVB_DEFAULT_SESSION_GRACE="15"
# TG_SELF_INVESTIGATE_ZERO_SHIP_STREAK=3: three zero-ship sessions is enough evidence to rotate/investigate.
DVB_DEFAULT_SELF_INVESTIGATE_ZERO_SHIP_STREAK="3"

dvb_default_model_for_backend() {
  case "$1" in
    codex) printf '%s' "$DVB_DEFAULT_CODEX_MODEL" ;;
    claude-code) printf '%s' "$DVB_DEFAULT_CLAUDE_CODE_MODEL" ;;
    *) printf '%s' "$DVB_DEFAULT_DEVIN_MODEL" ;;
  esac
}

dvb_resolve_model_alias() {
  local requested="$1"
  local entry="" alias="" resolved=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    alias="${entry%%=*}"
    resolved="${entry#*=}"
    if [[ "$requested" == "$alias" ]]; then
      printf '%s' "$resolved"
      return 0
    fi
  done <<< "$DVB_MODEL_ALIASES"
  printf '%s' "$requested"
}

# Devin CLI binary location — resolved at source-time with fallback chain:
# 1. DVB_DEVIN_PATH env override (user-set), 2. PATH lookup, 3. default install path
_dvb_default_devin="$HOME/.local/share/devin/cli/_versions/current/bin/devin"
if [[ -n "${DVB_DEVIN_PATH:-}" ]]; then
  : # User override — use as-is
elif command -v devin >/dev/null 2>&1; then
  DVB_DEVIN_PATH="$(command -v devin)"
else
  DVB_DEVIN_PATH="$_dvb_default_devin"
fi

# Caffeinate flags — prevent system + disk sleep, allow display to sleep/lock
DVB_CAFFEINATE_FLAGS="-ms"

# Format seconds into human-readable duration (e.g., "2h15m", "45m", "30s")
dvb_format_duration() {
  local secs=$1
  local h=$((secs / 3600))
  local m=$(( (secs % 3600) / 60 ))
  if [[ $h -gt 0 ]]; then
    echo "${h}h${m}m"
  elif [[ $m -gt 0 ]]; then
    echo "${m}m"
  else
    echo "${secs}s"
  fi
}

# ── Progress / spinner helpers ────────────────────────────────────────
# All helpers are TTY-aware: they show animated output only when stdout
# is a terminal. When piped or redirected they degrade to plain text.

# Detect TTY once at source time. Tests (DVB_GRIND_CMD set) force off.
if [[ -t 1 && -z "${DVB_GRIND_CMD:-}" ]]; then
  _dvb_is_tty=1
else
  _dvb_is_tty=0
fi

_dvb_spinner_pid=0

# Start a background spinner with an optional label.
# Usage: dvb_spinner_start "Checking network..."
dvb_spinner_start() {
  local label="${1:-}"
  [[ $_dvb_is_tty -eq 0 ]] && return 0
  dvb_spinner_stop  # kill any leftover spinner
  (
    trap 'exit 0' TERM INT
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while true; do
      printf '\r   %s %s ' "${chars:i%${#chars}:1}" "$label"
      i=$((i + 1))
      sleep 0.1 2>/dev/null || sleep 1
    done
  ) &
  _dvb_spinner_pid=$!
}

# Stop the spinner and clear the line.
dvb_spinner_stop() {
  if [[ $_dvb_spinner_pid -gt 0 ]] && kill -0 "$_dvb_spinner_pid" 2>/dev/null; then
    kill "$_dvb_spinner_pid" 2>/dev/null || true
    wait "$_dvb_spinner_pid" 2>/dev/null || true
  fi
  _dvb_spinner_pid=0
  if [[ $_dvb_is_tty -eq 1 ]]; then
    printf '\r\033[K'
  fi
}

# Sleep with a visible countdown.  Falls back to plain sleep when not a TTY.
# Usage: dvb_countdown_sleep 30 "Cooldown"
dvb_countdown_sleep() {
  local total="$1" label="${2:-Waiting}"
  if [[ $total -le 0 ]]; then return 0; fi
  if [[ $_dvb_is_tty -eq 0 ]]; then
    sleep "$total"
    return 0
  fi
  local remaining=$total
  while [[ $remaining -gt 0 ]]; do
    printf '\r   %s: %ss  ' "$label" "$remaining"
    sleep 1 2>/dev/null || sleep 1
    remaining=$((remaining - 1))
  done
  printf '\r\033[K'
}

# Print an elapsed timer line (overwrites in place).  Call in a loop.
# Usage: dvb_print_elapsed $start_epoch "Session 3"
dvb_print_elapsed() {
  local start="$1" label="${2:-}"
  [[ $_dvb_is_tty -eq 0 ]] && return 0
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - start))
  printf '\r   ⏳ %s — %s  ' "$label" "$(dvb_format_duration "$elapsed")"
}
