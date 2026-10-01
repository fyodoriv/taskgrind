#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT

test_repo="$scratch_dir/repo"
mkdir -p "$test_repo"
cat > "$test_repo/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Bash compatibility smoke test
TASKS

check_disallowed_bash4_syntax() {
  local runtime_file
  for runtime_file in \
    "$repo_root/bin/taskgrind" \
    "$repo_root/lib/constants.sh" \
    "$repo_root/lib/fullpower.sh"; do
    if grep -nE \
      '(^|[[:space:]])(declare|local|typeset)[[:space:]]+-A([[:space:]=]|$)|(^|[[:space:]])(mapfile|readarray|coproc)([[:space:];]|$)|\$\{[^}]*(\^\^|,,|@[QEPAKakUuL])' \
      "$runtime_file"; then
      echo "Bash 3.2 compatibility check failed for $runtime_file" >&2
      exit 1
    fi
  done
}

check_disallowed_bash4_syntax

test_backend="$(command -v true)"
[ -n "$test_backend" ] || {
  echo "Could not find a usable 'true' test backend" >&2
  exit 1
}

DVB_GRIND_CMD="$test_backend" \
DVB_SKIP_PREFLIGHT=1 \
DVB_SKIP_SWEEP_ON_EMPTY=1 \
/bin/bash "$repo_root/bin/taskgrind" --dry-run "$test_repo" 1 >/dev/null

session_log="$scratch_dir/session.log"
session_output="$scratch_dir/session-output.txt"
DVB_COOL=0 \
DVB_DEADLINE=$(( $(date +%s) + 5 )) \
DVB_GRIND_CMD="$test_backend" \
DVB_LOG="$session_log" \
DVB_MAX_ZERO_SHIP=1 \
DVB_SKIP_PREFLIGHT=1 \
DVB_SKIP_SWEEP_ON_EMPTY=1 \
/bin/bash "$repo_root/bin/taskgrind" "$test_repo" 1 >"$session_output" 2>&1

if grep -q 'No such file or directory' "$session_output" "$session_log"; then
  echo "Bash 3.2 session smoke hit the preserved missing test-backend failure" >&2
  exit 1
fi
