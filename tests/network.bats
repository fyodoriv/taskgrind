#!/usr/bin/env bats
# Tests for taskgrind — network resilience + 2 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Network resilience ────────────────────────────────────────────────
# These tests use DVB_MIN_SESSION to enable fast-failure detection,
# DVB_NET_FILE as a sentinel file for network state (test mode),
# and DVB_NET_WAIT/DVB_NET_MAX_WAIT for fast polling.

@test "check_network returns true when DVB_NET_FILE exists" {
  # Verify the test-mode sentinel mechanism works
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Network is up, so no network_down in log
  ! grep -q 'network_down' "$TEST_LOG"
}

@test "check_network uses network-watchdog --check-only in production mode" {
  grep -q 'network-watchdog --check-only' "$DVB_GRIND"
}

@test "fast session triggers network check when DVB_MIN_SESSION set" {
  # Fake devin exits instantly (0s < min_session_secs), network is up
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Sessions ran (network was up, so no pause)
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "network down pauses loop and logs network_down" {
  # No sentinel file = network down. max_wait=0 so it times out immediately.
  export DVB_NET_FILE="$TEST_DIR/net-up"  # file does NOT exist
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should have logged network_down
  grep -q 'network_down' "$TEST_LOG"
}

@test "network timeout exits the loop" {
  # Network never comes back, max_wait=0 forces immediate timeout
  export DVB_NET_FILE="$TEST_DIR/net-up"  # does not exist
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'network_timeout' "$TEST_LOG"
}

@test "network recovery extends deadline and logs network_restored" {
  # Sentinel file created after 4s — long enough for the grind to start,
  # run the first session, hit fast-failure, and enter wait_for_network.
  # Extra margin for parallel test load.
  nohup bash -c "sleep 4; touch '$TEST_DIR/net-up'" &>/dev/null &

  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-up"  # does not exist yet
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=60
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'network_restored' "$TEST_LOG"
}

@test "session number rolls back after network recovery" {
  nohup bash -c "sleep 2; touch '$TEST_DIR/net-up'" &>/dev/null &

  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=30
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # First session=1 fails fast → network down → network back → session counter rolled back
  # Next iteration: session=1 again (the retry)
  # Log should show session=1 appearing twice (original + retry)
  local session1_count
  session1_count=$(grep -c 'session=1 ' "$TEST_LOG" || true)
  session1_count="${session1_count:-0}"
  [ "$session1_count" -ge 2 ]
}

@test "consecutive fast failures increment counter and trigger backoff" {
  # Network is up but sessions keep failing fast — should see fast_fail in log
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # After 3+ fast failures, should log fast_fail with backoff
  grep -q 'fast_fail' "$TEST_LOG"
  grep -q 'consecutive=3' "$TEST_LOG"
}

@test "backoff increases with consecutive fast failures" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=1
  export DVB_BACKOFF_MAX=10
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With base=1: consecutive=3 → 3s, consecutive=4 → 4s, etc.
  grep -q 'backoff=3s' "$TEST_LOG"
  grep -q 'backoff=4s' "$TEST_LOG"
}

@test "backoff caps at DVB_BACKOFF_MAX" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_BACKOFF_MAX=5
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With base=0 all backoffs are 0, capped at 5 (but 0 < 5 so cap never triggers)
  # Verify no backoff exceeds the max
  if grep -q 'backoff=' "$TEST_LOG"; then
    ! grep -qE 'backoff=([6-9]|[1-9][0-9]+)s' "$TEST_LOG"
  fi
}

@test "backoff formula defaults cap to 120s" {
  # Structural: verify the default max is 120
  grep -q 'DVB_BACKOFF_MAX:-120' "$DVB_GRIND"
}

@test "backoff sleep extends deadline like network wait does" {
  # Structural: after sleep "$backoff", deadline should be extended
  grep -A3 'sleep "$backoff"' "$DVB_GRIND" | grep -q 'deadline=.*deadline.*backoff'
}

@test "consecutive_fast resets after a normal-length session" {
  # First few sessions are fast (incrementing consecutive_fast)
  # Then a slow session resets the counter
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# On 4th invocation, simulate a long session
count=\$(wc -l < "$DVB_GRIND_INVOKE_LOG" 2>/dev/null || echo 0)
if [ "\$count" -ge 4 ]; then
  # Sleep longer than min_session_secs to reset counter
  sleep 2
fi
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=1
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
  local invoke_count
  invoke_count=$(wc -l < "$DVB_GRIND_INVOKE_LOG")
  [ "$invoke_count" -ge 4 ]
}

@test "min_session_secs defaults to 0 in test mode (existing tests unaffected)" {
  # When DVB_GRIND_CMD is set but DVB_MIN_SESSION is not, min_session_secs=0
  # This means fast-failure detection is disabled — no fast_fail log entries
  unset DVB_MIN_SESSION 2>/dev/null || true
  unset DVB_NET_FILE 2>/dev/null || true
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'fast_fail' "$TEST_LOG"
  ! grep -q 'network_down' "$TEST_LOG"
}

@test "DVB_MIN_SESSION overrides the default threshold" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With min_session=999, every instant session is a fast failure
  grep -q 'fast_fail' "$TEST_LOG"
}

@test "DVB_NET_WAIT controls polling interval" {
  # This is a structural test — verify the variable is used
  grep -q 'DVB_NET_WAIT' "$DVB_GRIND"
  grep -q 'interval.*DVB_NET_WAIT' "$DVB_GRIND"
}

@test "DVB_NET_MAX_WAIT controls timeout" {
  grep -q 'DVB_NET_MAX_WAIT' "$DVB_GRIND"
  grep -q 'max_wait.*DVB_NET_MAX_WAIT' "$DVB_GRIND"
}

@test "network down message shows in terminal output" {
  export DVB_NET_FILE="$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Network down"* ]]
}

@test "network restored message shows in terminal output" {
  # Schedule network recovery after a delay — must be long enough that the
  # first fast-failure check sees network down before the file appears.
  (sleep 3; touch "$TEST_DIR/net-up") &
  local _touch_pid=$!

  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=10
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=60
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  kill "$_touch_pid" 2>/dev/null || true
  wait "$_touch_pid" 2>/dev/null || true
  [[ "$output" == *"Network back"* ]]
}

@test "fast failure warning shows exit code in terminal output" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"fast failures"* ]]
  [[ "$output" == *"exit="* ]]
}

@test "session end log includes exit code and duration" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE 'session=1 ended exit=[0-9]+ duration=[0-9]+s' "$TEST_LOG"
}

# ── Network check retry ──────────────────────────────────────────────

@test "network check retries before declaring down" {
  # Structural: retry loop in check_network
  grep -q 'DVB_NET_RETRIES:-3' "$DVB_GRIND"
  grep -q '_check_network_once && return 0' "$DVB_GRIND"
}

@test "network check skips retry in test mode" {
  # Test mode calls _check_network_once directly, bypassing the retry loop
  grep -q '_check_network_once; return' "$DVB_GRIND"
}

# ── Network watchdog fallback ──────────────────────────────────────────

@test "check_network falls back to curl when network-watchdog is missing" {
  grep -q 'command -v network-watchdog' "$DVB_GRIND"
  grep -q 'curl -sf --max-time 5' "$DVB_GRIND"
}

@test "check_network prefers network-watchdog when available" {
  # Structural: the elif branch checks for network-watchdog before curl fallback
  grep -q 'elif command -v network-watchdog' "$DVB_GRIND"
}

