#!/usr/bin/env bats

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

@test "status file preserves blocked-queue stop reason after a clean exit" {
  local status_file="$TEST_DIR/blocked-status.json"
  export DVB_STATUS_FILE="$status_file"
  export DVB_DEADLINE_OFFSET=5
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P1
- [ ] Deploy to K8s
  **ID**: deploy-k8s
  **Blocked by**: jenkins-setup
TASKS

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  python3 - "$status_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["current_phase"] == "complete"
assert data["terminal_reason"] == "all_tasks_blocked"
PY
}
