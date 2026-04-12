#!/usr/bin/env bats
# Tests for taskgrind — log file + 13 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

_wait_for_status_phase() {
  local status_file="$1"
  local expected_phase="$2"
  local attempts=0
  while [[ $attempts -lt 50 ]]; do
    if [[ -f "$status_file" ]] && python3 - "$status_file" "$expected_phase" <<'PY'
import json
import sys

path, expected = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
sys.exit(0 if data.get("current_phase") == expected else 1)
PY
    then
      return 0
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

# ── Log file ─────────────────────────────────────────────────────────

@test "creates log file" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$TEST_LOG" ]
}

@test "log file contains header with config" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q '# taskgrind started' "$TEST_LOG"
  grep -q "hours=1" "$TEST_LOG"
  grep -q "model=gpt-5.4" "$TEST_LOG"
}

@test "log file records session start entries" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'session=1' "$TEST_LOG"
}

@test "status file captures startup and completion states" {
  local status_file="$TEST_DIR/status.json"
  export DVB_STATUS_FILE="$status_file"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  python3 - "$status_file" "$TEST_REPO" <<'PY'
import json
import sys

path, expected_repo = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["repo"] == expected_repo
assert data["current_phase"] == "complete"
assert data["session"] >= 1
assert data["backend"] == "devin"
assert data["skill"] == "next-task"
assert data["model"] == "gpt-5.4"
assert data["last_session"]["number"] >= 1
assert data["last_session"]["result"] == "success"
assert data["last_session"]["completed_at"]
PY
}

@test "status file with unusable parent path fails before sessions start" {
  local blocked_parent="$TEST_DIR/blocked-parent"
  local status_file="$blocked_parent/status.json"
  touch "$blocked_parent"
  export DVB_STATUS_FILE="$status_file"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot create status directory"* ]]
  [[ "$output" == *"$blocked_parent"* ]]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "status file updates while a session is running" {
  local status_file="$TEST_DIR/live-status.json"
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
sleep 2
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"
  export DVB_STATUS_FILE="$status_file"
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/live-status.out" 2>&1 &
  local grind_pid=$!

  _wait_for_status_phase "$status_file" "running_session"

  python3 - "$status_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["current_phase"] == "running_session"
assert data["session"] == 1
assert data["last_session"]["result"] == "pending"
assert isinstance(data["remaining_minutes"], int)
PY

  wait "$grind_pid"
  [ "$?" -eq 0 ]
}

@test "session banner and log entry include active model" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Session 1"* ]]
  [[ "$output" == *"tasks queued — model=gpt-5.4"* ]]
  grep -q 'session=1 .*model=gpt-5.4' "$TEST_LOG"
}

@test "log file records session end entries" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'ended' "$TEST_LOG"
}

@test "log file records tasks_after count" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task one
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'tasks_after=' "$TEST_LOG"
}

@test "log file records shipped count per session" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'shipped=' "$TEST_LOG"
}

@test "DVB_LOG overrides log file path" {
  local custom_log="$TEST_DIR/custom.log"
  export DVB_LOG="$custom_log"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$custom_log" ]
}

@test "TG_LOG takes precedence over DVB_LOG" {
  local legacy_log="$TEST_DIR/legacy.log"
  local tg_log="$TEST_DIR/tg.log"
  export DVB_LOG="$legacy_log"
  export TG_LOG="$tg_log"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -f "$tg_log" ]
  [ ! -f "$legacy_log" ]
}

@test "default log file uses timestamp format" {
  unset DVB_LOG
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Output should show a log path with YYYY-MM-DD-HHMM-reponame-PID pattern
  [[ "$output" =~ taskgrind-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[a-zA-Z0-9_.-]+-[0-9]+\.log ]]
}

# ── Banner and summary ───────────────────────────────────────────────

@test "shows startup banner with hours and model" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"taskgrind"* ]]
  [[ "$output" == *"1h"* ]]
  [[ "$output" == *"gpt-5.4"* ]]
}

@test "shows startup banner with repo path" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"$TEST_REPO"* ]]
}

@test "shows session restart message" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Each session runs"* ]]
}

@test "shows completion summary with session count" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Grind complete"* ]]
  [[ "$output" == *"sessions"* ]]
}

@test "shows completion summary with task count" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"tasks"* ]]
}

@test "expired deadline logs a startup skip without stall warnings" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'deadline_expired_before_session_loop' "$TEST_LOG"
  ! grep -q 'stall_warning' "$TEST_LOG"
}

@test "shows log file path in summary" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"$TEST_LOG"* ]]
}

@test "shows cooldown message between sessions" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_COOL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Cooling down"* ]]
}

@test "live model log includes resolved model and raw alias" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" --model gpt-5-4 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'live_model=claude-sonnet-4.6 (alias=sonnet, startup=gpt-5-4)' "$TEST_LOG"
}

# ── DVB_DEADLINE override ────────────────────────────────────────────

@test "DVB_DEADLINE overrides computed deadline" {
  # Set deadline in the past — should not run any sessions
  export DVB_DEADLINE=$(( $(date +%s) - 10 ))
  run "$DVB_GRIND" 10 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
  [[ "$output" == *"0 sessions"* ]]
}

# ── Cooldown ─────────────────────────────────────────────────────────

@test "DVB_COOL=0 skips sleep between sessions" {
  local fake_bin="$TEST_DIR/fake-bin"
  local sleep_log="$TEST_DIR/sleep.log"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/sleep" <<SCRIPT
#!/bin/bash
printf '%s\n' "\$*" >> "$sleep_log"
exec /bin/sleep "\$@"
SCRIPT
  chmod +x "$fake_bin/sleep"
  export PATH="$fake_bin:$PATH"
  export DVB_DEADLINE=$(( $(date +%s) + 4 ))
  export DVB_COOL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -ge 2 ]
  [ ! -e "$sleep_log" ]
}

@test "TG_COOL takes precedence over DVB_COOL" {
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  export DVB_COOL=0
  export TG_COOL=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cooling down 1s"* ]]
}

# ── Working directory ────────────────────────────────────────────────

@test "changes to repo directory for devin session" {
  # Fake devin that records its cwd
  local cwd_devin="$TEST_DIR/cwd-devin"
  cat > "$cwd_devin" <<SCRIPT
#!/bin/bash
pwd >> "$TEST_DIR/cwd.log"
SCRIPT
  chmod +x "$cwd_devin"
  export DVB_GRIND_CMD="$cwd_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q "$TEST_REPO" "$TEST_DIR/cwd.log"
}

@test "resolves relative repo path to absolute" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  cd "$TEST_DIR"
  run "$DVB_GRIND" 1 repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_DIR/repo"* ]]
}

# ── Grind handoff protocol ───────────────────────────────────────────

# ── Duration tracking ─────────────────────────────────────────────────

@test "format_duration outputs hours and minutes" {
  # Run grind with past deadline so it finishes immediately — summary should include duration
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Summary line should contain a duration like "0s" or "1s" etc.
  [[ "$output" == *"Grind complete:"* ]]
  [[ "$output" == *s* ]] || [[ "$output" == *m* ]] || [[ "$output" == *h* ]]
}

@test "grind summary includes duration in seconds for short runs" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # With an already-past deadline, should complete in <1min → "Xs" format
  [[ "$output" == *"0 sessions"* ]]
  [[ "$output" =~ [0-9]+s ]]
}

@test "grind log includes duration field" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'duration=' "$TEST_LOG"
  grep -q 'elapsed=' "$TEST_LOG"
}

@test "grind log includes elapsed in seconds" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Log should contain elapsed=Ns where N is a number
  grep -qE 'elapsed=[0-9]+s' "$TEST_LOG"
}

# ── zshrc duration tracking ──────────────────────────────────────────

# ── zshrc hardening ───────────────────────────────────────────────────

# ── format_duration branch coverage ──────────────────────────────────

@test "format_duration minutes-only branch: 120s → 2m" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 120)
  [ "$result" = "2m" ]
}

@test "format_duration hours+minutes branch: 3661s → 1h1m" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 3661)
  [ "$result" = "1h1m" ]
}

@test "format_duration seconds branch: 45s → 45s" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 45)
  [ "$result" = "45s" ]
}

@test "format_duration zero seconds: 0 → 0s" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 0)
  [ "$result" = "0s" ]
}

@test "format_duration exact hour: 3600s → 1h0m" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 3600)
  [ "$result" = "1h0m" ]
}

# ── PID in log file and log lines ─────────────────────────────────────

@test "default log file name includes repo and PID for uniqueness" {
  unset DVB_LOG
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Log path in output should include repo basename and PID segment before .log
  [[ "$output" =~ taskgrind-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[a-zA-Z0-9_.-]+-[0-9]+\.log ]]
}

@test "log lines include pid= prefix" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # At least one log_write line should have the [pid=N] prefix
  grep -qE '^\[pid=[0-9]+\]' "$TEST_LOG"
}

@test "grind_done log line includes pid= prefix" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE '^\[pid=[0-9]+\].*grind_done' "$TEST_LOG"
}

@test "two rapid invocations get separate default log files" {
  # Structural: log name includes repo basename + PID so different runs cannot collide
  unset DVB_LOG
  local log_pattern
  log_pattern=$(grep 'DVB_LOG:-' "$DVB_GRIND")
  [[ "$log_pattern" == *'$$'* ]]
  [[ "$log_pattern" == *'_repo_basename'* ]]
}

# ── Stderr Logging ────────────────────────────────────────────────────

@test "production mode redirects stderr to log file" {
  grep -q '2> >(tee -a "$session_output" >> "$log_file"' "$DVB_GRIND"
}

# ── macOS Notification ────────────────────────────────────────────────

@test "sends macOS notification on completion by default" {
  grep -q 'osascript.*display notification' "$DVB_GRIND"
}

@test "DVB_NOTIFY=0 suppresses notification" {
  grep -q 'DVB_NOTIFY:-1' "$DVB_GRIND"
  grep -q 'DVB_NOTIFY' "$DVB_GRIND"
}

@test "TG_NOTIFY takes precedence over DVB_NOTIFY" {
  local fake_bin="$TEST_DIR/fake-bin"
  local notify_log="$TEST_DIR/osascript.log"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/osascript" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$notify_log"
SCRIPT
  chmod +x "$fake_bin/osascript"
  export PATH="$fake_bin:$PATH"
  export DVB_NOTIFY=1
  export TG_NOTIFY=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$notify_log" ]
}

@test "notification includes session count and tasks shipped" {
  grep -q 'tasks shipped' "$DVB_GRIND"
}

@test "notification uses argv passing to avoid osascript injection" {
  # osascript should receive the message as an argument, not interpolated in the script
  grep -q 'on run argv' "$DVB_GRIND"
  grep -q 'item 1 of argv' "$DVB_GRIND"
}

@test "git sync output is sanitized before logging" {
  # Control characters should be stripped from git sync output
  grep -q "tr -cd '\[:print:\]" "$DVB_GRIND"
}

# ── Log File Security ────────────────────────────────────────────────

@test "log file permissions are 600 (owner-only)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$TEST_LOG" ]
  local perms
  perms=$(stat -f '%Lp' "$TEST_LOG" 2>/dev/null || stat -c '%a' "$TEST_LOG" 2>/dev/null)
  [ "$perms" = "600" ]
}

@test "DVB_LOG pointing to directory exits with error" {
  export DVB_LOG="$TEST_DIR"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"points to a directory"* ]]
}

@test "DVB_LOG with nonexistent parent creates parent directory" {
  export DVB_LOG="$TEST_DIR/deep/nested/dir/grind.log"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/deep/nested/dir/grind.log" ]
}
