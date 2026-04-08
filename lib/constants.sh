#!/bin/bash
# Shared constants for taskgrind and zshrc dvb functions.
# Single source of truth for Devin session configuration.
# Usage: source "$(cd "$(dirname "$0")/.." && pwd)/lib/constants.sh"

# Variables below are sourced by bin/taskgrind and home/zshrc.
# shellcheck disable=SC2034  # used by sourcing scripts

# Default AI model — must match ANTHROPIC_MODEL in home/zshrc
DVB_DEFAULT_MODEL="claude-opus-4-6-thinking"

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
