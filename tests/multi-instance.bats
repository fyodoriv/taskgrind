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
# run_backend_probe treats exit=0 with empty stdout as a stub signal,
# so the fake must emit a non-empty pseudo-version string when called
# with --version. Without this the multi-instance concurrent grinds
# abort at the probe stage before ever acquiring a slot.
if [[ "$*" == *"--version"* ]]; then
  echo "fake-devin 0.0.1"
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

# ── has_supported_audit_lane_task() — direct unit-style coverage ──────
# Extract the function from bin/taskgrind via awk and call it in a clean
# subshell against fixture TASKS.md files. Confirms the discovery-lane gate
# accepts tasks tagged with standing-loop or any of the
# audit|log|queue|tasks.md|sweep|refresh keywords, and rejects queues that
# contain only normal execution-lane work. Without these, narrowing the
# regex would break `audit_focus_blocked` only via integration paths.

_extract_has_supported_audit_lane_task() {
  awk '/^has_supported_audit_lane_task\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_has_supported_audit_lane_task() {
  local tasks_file="$1"
  local fn
  fn=$(_extract_has_supported_audit_lane_task)
  # shellcheck disable=SC2016  # $fn contains the literal function definition
  bash -c "$fn"$'\n'"has_supported_audit_lane_task \"$tasks_file\""
}

@test "has_supported_audit_lane_task: missing file returns 1" {
  run _run_has_supported_audit_lane_task "$TEST_REPO/no-such-file.md"
  [ "$status" -eq 1 ]
}

@test "has_supported_audit_lane_task: empty file returns 1" {
  printf '# Tasks\n' > "$TEST_REPO/TASKS.md"
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 1 ]
}

@test "has_supported_audit_lane_task: task with standing-loop description is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Keep the discovery lane replenishing the queue
  **ID**: discovery-standing-loop
  **Tags**: standing-loop, audit, queue
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: task with 'audit' keyword is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Audit the codebase for stale references
  **ID**: codebase-audit
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: task with 'log' keyword is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Surface unexpected log lines
  **ID**: surface-logs
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: task with 'queue' keyword is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Refill the queue from upstream issues
  **ID**: refill-queue
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: task with 'tasks.md' keyword is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Sweep tasks.md for outdated references
  **ID**: tasks-md-sweep
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: task with 'sweep' keyword is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Run the full sweep across modules
  **ID**: full-sweep
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: task with 'refresh' keyword is accepted" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Refresh the docs cache after each release
  **ID**: refresh-docs
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
}

@test "has_supported_audit_lane_task: tasks with no audit keywords return 1" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Ship the feature
  **ID**: ship-feature
- [ ] Write the readme
  **ID**: write-readme
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 1 ]
}

@test "has_supported_audit_lane_task: completed [x] task with audit keywords does not satisfy the gate" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [x] Already audited the queue
  **ID**: already-audited
- [ ] Ship the feature
  **ID**: ship-feature
TASKS
  run _run_has_supported_audit_lane_task "$TEST_REPO/TASKS.md"
  [ "$status" -eq 1 ]
}

# ── slot_lock_pid() and slot_lock_active() — direct coverage ──────────
# These probe helpers back `--preflight`'s `slots: N/M active` report and
# the multi-instance path's stale-lock detection. They were previously
# only exercised through the full concurrent grind flows at the top of
# this file — a regression that always returned "not active" would
# silently break the "all slots full" refusal without any integration
# test tripping. Add direct coverage.

_extract_slot_lock_pid() {
  awk '/^slot_lock_pid\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_extract_slot_lock_active() {
  awk '/^slot_lock_pid\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  printf '\n'
  awk '/^slot_lock_active\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_slot_lock_pid() {
  local lock_file="$1"
  local fn
  fn=$(_extract_slot_lock_pid)
  run bash -c "$fn"$'\n'"slot_lock_pid \"\$1\"" _ "$lock_file"
}

_run_slot_lock_active() {
  local lock_file="$1"
  local fns
  fns=$(_extract_slot_lock_active)
  run bash -c "$fns"$'\n'"slot_lock_active \"\$1\"" _ "$lock_file"
}

@test "slot_lock_pid: missing file returns 1 and prints nothing" {
  local lock_file="$TEST_DIR/no-such-lock"
  _run_slot_lock_pid "$lock_file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "slot_lock_pid: empty lock file returns 0 but prints nothing" {
  local lock_file="$TEST_DIR/empty-lock"
  : > "$lock_file"
  _run_slot_lock_pid "$lock_file"
  # Function returns 0 (file exists) but sed finds no pid=<N> — the
  # caller is responsible for treating empty output as "no pid".
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "slot_lock_pid: file with pid=<N> prints that pid" {
  local lock_file="$TEST_DIR/valid-lock"
  printf 'repo=/tmp/foo pid=12345 start=2026-01-01T00:00:00Z\n' > "$lock_file"
  _run_slot_lock_pid "$lock_file"
  [ "$status" -eq 0 ]
  [ "$output" = "12345" ]
}

@test "slot_lock_pid: multiline file returns only the first pid=" {
  local lock_file="$TEST_DIR/multi-pid-lock"
  # Defensive: the lock writer emits one line today, but sed's `head -1`
  # keeps the function robust against accidental multi-line writes.
  printf 'pid=111\npid=222\n' > "$lock_file"
  _run_slot_lock_pid "$lock_file"
  [ "$status" -eq 0 ]
  [ "$output" = "111" ]
}

@test "slot_lock_active: live pid (the bats runner) returns 0" {
  local lock_file="$TEST_DIR/live-lock"
  # $$ is the live pid of the bash subshell running this test. kill -0
  # against it must succeed regardless of the OS.
  printf 'pid=%s\n' "$$" > "$lock_file"
  _run_slot_lock_active "$lock_file"
  [ "$status" -eq 0 ]
}

@test "slot_lock_active: clearly-dead pid returns 1" {
  local lock_file="$TEST_DIR/dead-lock"
  # Pick a pid that is vanishingly unlikely to exist on either macOS
  # (32-bit pid space capped near 2^31 - 1) or Linux (kernel.pid_max
  # default 4194304). 2147483647 is the max signed 32-bit int; no kernel
  # allocates a real pid there in normal operation, so kill -0 will fail
  # deterministically.
  printf 'pid=2147483647\n' > "$lock_file"
  _run_slot_lock_active "$lock_file"
  [ "$status" -eq 1 ]
}

@test "slot_lock_active: missing lock file returns 1" {
  local lock_file="$TEST_DIR/no-such-lock"
  _run_slot_lock_active "$lock_file"
  [ "$status" -eq 1 ]
}

@test "slot_lock_active: empty lock file returns 1" {
  # Empty file → slot_lock_pid prints nothing → slot_lock_active's
  # `[[ -n "$lock_pid" ]]` guard triggers the 1 return.
  local lock_file="$TEST_DIR/empty-lock"
  : > "$lock_file"
  _run_slot_lock_active "$lock_file"
  [ "$status" -eq 1 ]
}
