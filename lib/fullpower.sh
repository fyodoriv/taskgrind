#!/bin/bash
# Boost process to macOS interactive scheduling tier (highest priority).
# Uses taskpolicy to set throughput tier 0 and latency tier 0.
# Usage: source "$(cd "$(dirname "$0")/.." && pwd)/lib/fullpower.sh"
#        boost_priority          # boost current shell process
#        boost_priority "$pid"   # boost a specific PID

# Boost a process to interactive scheduling tier.
# Falls back silently on Linux or if taskpolicy is unavailable.
boost_priority() {
  local pid="${1:-$$}"
  command -v taskpolicy &>/dev/null || return 0
  taskpolicy -B -t 0 -l 0 -p "$pid" 2>/dev/null || true
}
