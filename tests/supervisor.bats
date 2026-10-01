#!/usr/bin/env bats
# Tests for taskgrind — supervisor/fixer mode

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

write_watched_status() {
  local status_file="$1"
  local phase="$2"
  local watched_log="$3"
  cat > "$status_file" <<EOF
{
  "repo": "$TEST_REPO",
  "pid": 12345,
  "log_file": "$watched_log",
  "slot": 0,
  "backend": "devin",
  "skill": "next-task",
  "model": "gpt-5-5-xhigh-priority",
  "session": 2,
  "remaining_minutes": 42,
  "current_phase": "$phase",
  "terminal_reason": null,
  "targets": [],
  "updated_at": "2026-05-02T00:00:00+0000",
  "last_session": {
    "number": 1,
    "result": "success",
    "exit_code": 0,
    "shipped": 1,
    "duration_seconds": 30,
    "completed_at": "2026-05-02T00:00:00+0000"
  }
}
EOF
}

mark_file_old() {
  local path="$1"
  touch -t 202001010000 "$path" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$path"
}

@test "--supervise leaves healthy watched status alone" {
  local status_file="$TEST_DIR/watched-status.json"
  local watched_log="$TEST_DIR/watched.log"
  write_watched_status "$status_file" "running_session" "$watched_log"

  run "$DVB_GRIND" --supervise "$status_file" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"watched run healthy"* ]]
  [ ! -s "$DVB_GRIND_INVOKE_LOG" ]
  grep -q 'supervisor_observation outcome=healthy' "$TEST_LOG"
  grep -q 'reason=progressing_running_session' "$TEST_LOG"
}

@test "--supervise launches one repair session for failed watched status" {
  local status_file="$TEST_DIR/failed-status.json"
  local watched_log="$TEST_DIR/failed.log"
  write_watched_status "$status_file" "failed" "$watched_log"

  run "$DVB_GRIND" --supervise "$status_file" --no-push 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"watched run stuck"* ]]
  [ "$(grep -c 'SUPERVISOR_REPAIR' "$DVB_GRIND_INVOKE_LOG")" -eq 1 ]
  grep -Fq "$status_file" "$DVB_GRIND_INVOKE_LOG"
  grep -Fq "$watched_log" "$DVB_GRIND_INVOKE_LOG"
  grep -Fq "NO-PUBLISH MODE" "$DVB_GRIND_INVOKE_LOG"
  grep -Fq "PUBLIC_WRITE_GATE" "$DVB_GRIND_INVOKE_LOG"
  grep -q 'supervisor_repair_start reason=failed_phase' "$TEST_LOG"
  grep -q 'supervisor_repair_end status=0 reason=failed_phase' "$TEST_LOG"
}

@test "--supervise launches repair for stale active watched status" {
  local status_file="$TEST_DIR/stale-status.json"
  local watched_log="$TEST_DIR/stale.log"
  write_watched_status "$status_file" "preflight" "$watched_log"
  mark_file_old "$status_file"

  run "$DVB_GRIND" --supervise "$status_file" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ "$(grep -c 'SUPERVISOR_REPAIR' "$DVB_GRIND_INVOKE_LOG")" -eq 1 ]
  grep -q 'supervisor_repair_start reason=stale_preflight' "$TEST_LOG"
}

@test "--supervise treats missing watched status as a repairable stuck state" {
  local missing_status="$TEST_DIR/missing-status.json"

  run "$DVB_GRIND" --supervise "$missing_status" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ "$(grep -c 'SUPERVISOR_REPAIR' "$DVB_GRIND_INVOKE_LOG")" -eq 1 ]
  grep -Fq "$missing_status" "$DVB_GRIND_INVOKE_LOG"
  grep -q 'supervisor_repair_start reason=missing_status' "$TEST_LOG"
}

@test "status JSON exposes log_file for supervisor consumers" {
  local status_file="$TEST_DIR/status-with-log.json"
  export TG_STATUS_FILE="$status_file"

  run_tiny_workload

  [ "$status" -eq 0 ]
  grep -Fq '"log_file": "' "$status_file"
  grep -Fq "$TEST_LOG" "$status_file"
}
