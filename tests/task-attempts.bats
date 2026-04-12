#!/usr/bin/env bats

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

@test "attempt write failures are logged and later sessions still reach skip threshold" {
  local real_mv shim_dir state_file

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent test task
  **ID**: persistent-test-task
TASKS

  real_mv="$(command -v mv)"
  shim_dir="$TEST_DIR/shims"
  state_file="$TEST_DIR/mv-state"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/mv" <<SCRIPT
#!/bin/bash
if [[ "\$1" == *taskgrind-att-*.new && "\$2" == *taskgrind-att-* && ! -f "$state_file" ]]; then
  : > "$state_file"
  echo "simulated mv failure" >&2
  exit 1
fi
exec "$real_mv" "\$@"
SCRIPT
  chmod +x "$shim_dir/mv"

  export PATH="$shim_dir:$PATH"
  export DVB_DEADLINE=$(( $(date +%s) + 40 ))
  export DVB_MAX_SESSION=1

  run "$DVB_GRIND" 4 "$TEST_REPO"
  [ "$status" -eq 0 ]

  grep -q 'attempt_write_failed:' "$TEST_LOG"
  grep -q 'task_skip_threshold ids=' "$TEST_LOG"
}

@test "prune_task_attempts_file drops removed task IDs but keeps live ones" {
  local function_file="$TEST_DIR/prune-functions.sh"
  local attempts_file="$TEST_DIR/task-attempts"
  local tasks_file="$TEST_DIR/TASKS.md"

  python3 - <<'PY' "$DVB_GRIND" "$function_file"
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
source = source_path.read_text()
start = source.index("extract_task_ids() {")
end = source.index("# Print the first remaining task context as shell-safe assignments.")
target_path.write_text(source[start:end])
PY

  cat > "$attempts_file" <<'ATTEMPTS'
stale-task 4
live-task 3
ATTEMPTS

  cat > "$tasks_file" <<'TASKS'
# Tasks
## P0
- [ ] Live task
  **ID**: live-task
TASKS

  run bash -lc "source '$function_file'; prune_task_attempts_file '$attempts_file' '$tasks_file'; cat '$attempts_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == "live-task 3" ]]
}
