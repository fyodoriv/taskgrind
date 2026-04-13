#!/usr/bin/env bats
# Tests for taskgrind — multi-instance slot support
# Covers TG_MAX_INSTANCES, slot locking, conflict-avoidance prompts, git sync skip

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

_setup_production_multi_instance_backend() {
  unset DVB_GRIND_CMD
  export DVB_CAFFEINATED=1
  export DVB_NOTIFY=0
  export DVB_COOL=0
  export DVB_MAX_SESSION=30
  export DVB_MAX_INSTANCES=2
  export TMPDIR="$TEST_DIR/tmp"
  mkdir -p "$TMPDIR" "$TEST_DIR/bin"

  local fake_devin="$TEST_DIR/bin/devin"
  cat > "$fake_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${PROD_FAKE_DEVIN_LOG:-/tmp/taskgrind-prod-invocations.log}"
if [[ "$*" == *"--help"* ]]; then
  exit 0
fi
sleep "${PROD_FAKE_DEVIN_SLEEP:-4}"
exit 0
SCRIPT
  chmod +x "$fake_devin"
  export DVB_DEVIN_PATH="$fake_devin"
  export PROD_FAKE_DEVIN_LOG="$TEST_DIR/production-invocations.log"
  export PROD_FAKE_DEVIN_SLEEP=4

  local fake_watchdog="$TEST_DIR/bin/network-watchdog"
  cat > "$fake_watchdog" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
  chmod +x "$fake_watchdog"
  export PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

_wait_for_slot_file() {
  local slot="$1"
  local lock_hash
  lock_hash=$(echo "$TEST_REPO" | { shasum 2>/dev/null || sha1sum; } | cut -d' ' -f1)
  local lock_file="$TMPDIR/taskgrind-lock-${lock_hash}-${slot}"
  local tries=0
  # The lock file is opened before flock succeeds, so wait for the metadata line
  # that the winning process writes after it actually owns the slot.
  while [[ "$tries" -lt 50 ]]; do
    if [[ -f "$lock_file" ]] && grep -q "slot=${slot}" "$lock_file" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
    tries=$((tries + 1))
  done
  [[ -f "$lock_file" ]] && grep -q "slot=${slot}" "$lock_file" 2>/dev/null
}

# ── Slot basics ──────────────────────────────────────────────────────

@test "default max_instances is 2" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Instance slot: 0 of 2"* ]]
}

@test "TG_MAX_INSTANCES=3 shows slot in banner" {
  export DVB_MAX_INSTANCES=3
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Instance slot: 0 of 3"* ]]
}

@test "DVB_SLOT=0 sets slot 0 in test mode" {
  export DVB_SLOT=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # slot=0 in log header
  grep -q 'slot=0' "$TEST_LOG"
}

@test "DVB_SLOT=1 sets slot 1 in test mode" {
  export DVB_SLOT=1
  export DVB_MAX_INSTANCES=2
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'slot=1' "$TEST_LOG"
}

@test "slot shows in log file header" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'slot=0' "$TEST_LOG"
}

@test "TG_MAX_INSTANCES takes precedence over DVB_MAX_INSTANCES" {
  export TG_MAX_INSTANCES=3
  export DVB_MAX_INSTANCES=2
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Instance slot: 0 of 3"* ]]
}

@test "DVB_MAX_INSTANCES=abc exits with must be positive integer error" {
  export DVB_MAX_INSTANCES=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_INSTANCES must be a positive integer"* ]]
}

@test "DVB_MAX_INSTANCES=0 exits with must be positive integer error" {
  export DVB_MAX_INSTANCES=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_INSTANCES must be a positive integer"* ]]
}

# ── Conflict-avoidance prompt injection ──────────────────────────────

@test "slot 0 does not get MULTI-INSTANCE prompt" {
  export DVB_SLOT=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'MULTI-INSTANCE' "$DVB_GRIND_INVOKE_LOG"
}

@test "slot 1 gets MULTI-INSTANCE conflict-avoidance in prompt" {
  export DVB_SLOT=1
  export DVB_MAX_INSTANCES=2
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'MULTI-INSTANCE' "$DVB_GRIND_INVOKE_LOG"
}

@test "slot 1 prompt mentions instance number and total" {
  export DVB_SLOT=1
  export DVB_MAX_INSTANCES=3
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'instance 1 of 3' "$DVB_GRIND_INVOKE_LOG"
}

@test "slot 1 prompt advises git pull --rebase" {
  export DVB_SLOT=1
  export DVB_MAX_INSTANCES=2
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git pull --rebase' "$DVB_GRIND_INVOKE_LOG"
}

@test "slot 1 discovery lane can run standing-loop audit skill" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Keep the discovery lane replenishing the queue
  **ID**: discovery-standing-loop
  **Tags**: standing-loop, audit, queue
TASKS
  export DVB_SLOT=1
  export DVB_MAX_INSTANCES=2
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill standing-audit-gap-loop
  [ "$status" -eq 0 ]
  grep -q 'standing-audit-gap-loop' "$DVB_GRIND_INVOKE_LOG"
  ! grep -q 'audit_focus_without_task' "$TEST_LOG"
}

# ── Git sync skip for slot >= 1 ──────────────────────────────────────

@test "slot 0 runs git sync normally" {
  export DVB_SLOT=0
  export DVB_SYNC_INTERVAL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  # Create a git repo with remote so sync is attempted
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" add -A
  git -C "$TEST_REPO" commit -q -m "init"
  git -C "$TEST_REPO" remote add origin "$TEST_DIR/remote.git" 2>/dev/null || true

  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # slot 0 should NOT log "only slot 0 syncs" skip message
  ! grep -q 'only slot 0 syncs' "$TEST_LOG"
}

@test "slot 1 skips git sync between sessions" {
  export DVB_SLOT=1
  export DVB_MAX_INSTANCES=2
  export DVB_SYNC_INTERVAL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync skipped.*slot=1.*only slot 0 syncs' "$TEST_LOG"
}

@test "slot 2 also skips git sync" {
  export DVB_SLOT=2
  export DVB_MAX_INSTANCES=3
  export DVB_SYNC_INTERVAL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync skipped.*slot=2.*only slot 0 syncs' "$TEST_LOG"
}

# ── TG_INSTANCE_ID export ────────────────────────────────────────────

@test "TG_INSTANCE_ID is exported to session environment" {
  # Check that the variable is exported in the script
  grep -q 'export TG_INSTANCE_ID=' "$DVB_GRIND"
}

@test "TG_INSTANCE_ID is set to slot number" {
  grep -q 'TG_INSTANCE_ID="$_dvb_slot"' "$DVB_GRIND"
}

# ── Dry run with multi-instance ──────────────────────────────────────

@test "--dry-run shows max_instances when set" {
  export DVB_MAX_INSTANCES=3
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_instances: 3"* ]]
}

@test "--dry-run shows max_instances when default is 2" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_instances: 2"* ]]
}

# ── Preflight slot reporting ─────────────────────────────────────────

@test "--preflight shows slot count" {
  _preflight_git_init
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"slots:"* ]]
  [[ "$output" == *"active"* ]]
}

@test "two concurrent grinds on same repo acquire slots 0 and 1 by default" {
  _setup_production_multi_instance_backend
  unset DVB_MAX_INSTANCES
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  local first_output="$TEST_DIR/default-slot-0.out"
  local second_output="$TEST_DIR/default-slot-1.out"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$first_output" 2>&1 &
  local first_pid=$!
  _wait_for_slot_file 0

  "$DVB_GRIND" 1 "$TEST_REPO" > "$second_output" 2>&1 &
  local second_pid=$!
  for attempt in $(seq 1 20); do
    if kill -0 "$first_pid" 2>/dev/null && kill -0 "$second_pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done

  wait "$first_pid"
  local first_status=$?
  wait "$second_pid"
  local second_status=$?

  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
  grep -q 'Instance slot: 0 of 2' "$first_output"
  grep -q 'Instance slot: 1 of 2' "$second_output"
}

@test "two concurrent grinds on same repo acquire slots 0 and 1" {
  _setup_production_multi_instance_backend
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  local first_output="$TEST_DIR/slot-0.out"
  local second_output="$TEST_DIR/slot-1.out"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$first_output" 2>&1 &
  local first_pid=$!
  _wait_for_slot_file 0

  "$DVB_GRIND" 1 "$TEST_REPO" > "$second_output" 2>&1 &
  local second_pid=$!

  wait "$first_pid"
  local first_status=$?
  wait "$second_pid"
  local second_status=$?

  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
  grep -q 'Instance slot: 0 of 2' "$first_output"
  grep -q 'Instance slot: 1 of 2' "$second_output"
}

@test "second concurrent grind errors when all 1 slot is full" {
  _setup_production_multi_instance_backend
  export DVB_MAX_INSTANCES=1
  export PROD_FAKE_DEVIN_SLEEP=6
  export DVB_DEADLINE=$(( $(date +%s) + 12 ))
  local first_output="$TEST_DIR/full-slot-0.out"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$first_output" 2>&1 &
  local first_pid=$!
  _wait_for_slot_file 0

  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"all 1 instance slot(s) are in use"* ]]
  [[ "$output" == *"hint: set TG_MAX_INSTANCES=2 to allow another instance"* ]]

  wait "$first_pid"
}

@test "--preflight reports active slots for running grinds" {
  _setup_production_multi_instance_backend
  export PROD_FAKE_DEVIN_SLEEP=6
  export DVB_DEADLINE=$(( $(date +%s) + 12 ))
  local first_output="$TEST_DIR/preflight-slot-0.out"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$first_output" 2>&1 &
  local first_pid=$!
  _wait_for_slot_file 0

  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"slots:    1/2 active"* ]]

  wait "$first_pid"
}

# ── Existing single-instance behavior preserved ──────────────────────

@test "single instance still works with default config" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sessions"* ]]
}

@test "lock error message suggests increasing TG_MAX_INSTANCES" {
  grep -q 'hint: set TG_MAX_INSTANCES=' "$DVB_GRIND"
}

@test "lock error says 'all N instance slot(s) are in use'" {
  grep -q 'all.*instance slot(s) are in use' "$DVB_GRIND"
}

@test "lock file includes slot number" {
  grep -Fq 'taskgrind-lock-${_lock_hash}-${slot}' "$DVB_GRIND"
}

@test "slot-based lock uses per-slot file descriptors" {
  grep -q '_lock_fd=$(( 9 + _slot ))' "$DVB_GRIND"
}
