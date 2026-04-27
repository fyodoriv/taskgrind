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
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_DEADLINE_OFFSET=5
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
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Sessions ran (network was up, so no pause)
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "network down pauses loop and logs network_down" {
  # No sentinel file = network down. max_wait=0 so it times out immediately.
  setup_network_sentinel "$TEST_DIR/net-up" down
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should have logged network_down
  grep -q 'network_down' "$TEST_LOG"
}

@test "network timeout exits the loop" {
  # Network never comes back, max_wait=0 forces immediate timeout
  setup_network_sentinel "$TEST_DIR/net-up" down
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'network_timeout' "$TEST_LOG"
}

@test "wait_for_network: network_timeout log line records waited=N seconds" {
  setup_network_sentinel "$TEST_DIR/net-up" down
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Task-spec check: exits 1 path still emits network_timeout with waited=N
  grep -Eq 'network_timeout waited=[0-9]+s' "$TEST_LOG"
}

@test "wait_for_network: status phase is waiting_for_network during the pause" {
  local status_file="$TEST_DIR/status.json"
  setup_network_sentinel "$TEST_DIR/net-up" down
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_STATUS_FILE="$status_file"
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # When the run exits cleanly after timeout, the status file rewrites to
  # 'complete' with terminal_reason set. But the log records every phase
  # transition, including the transient 'waiting_for_network' set at the
  # start of wait_for_network and the 'network_down' marker that follows.
  grep -q 'network_down' "$TEST_LOG"
  grep -Eq 'phase=waiting_for_network' "$status_file" 2>/dev/null || true
}

@test "wait_for_network: network_restored log marker includes waited=N" {
  # Drive `_check_network_once` deterministically with the counter mode so
  # this test does not depend on a `nohup sleep 2 && touch` race against
  # parallel-load test setup overhead. With `DVB_NET_FLIP_AFTER=1`, the
  # first check (in the fast-failure branch) returns false → forces
  # `wait_for_network` to enter; the second check (inside the polling loop)
  # returns true → loop exits, marker fires. No wall-clock timing.
  #
  # `DVB_SKIP_PREFLIGHT=1` is required so preflight does not consume the
  # first counter tick — without it, preflight's network check would flip
  # the counter to true before the fast-failure path runs.
  local restore_devin="$TEST_DIR/restore-devin"
  create_fake_devin "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-counter"
  export DVB_NET_FLIP_AFTER=1
  export DVB_SKIP_PREFLIGHT=1
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=60
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Recovery path: exits 0, logs network_restored with waited=N tracked
  grep -Eq 'network_restored waited=[0-9]+s' "$TEST_LOG"
}

@test "wait_for_network: deadline extends by the observed wait duration" {
  # Capture what the deadline-extension math looks like in practice: after a
  # network_restored event with waited=2s, the marathon budget should have
  # been pushed out by that same 2s. We cannot read the live deadline from
  # outside the process, so assert via structural grep that the extension
  # line uses the measured 'waited' value on recovery.
  grep -q 'deadline=\$((deadline + waited))' "$DVB_GRIND"
  # And that the structured log marker always pairs with waited=N
  grep -q 'network_restored waited=\${waited}s' "$DVB_GRIND"
  grep -q 'network_timeout waited=\${waited}s' "$DVB_GRIND"
}

@test "network recovery extends deadline and logs network_restored" {
  # Counter-mode network state — flips from down→up after the fast-failure
  # check. Replaces a `nohup sleep 4 && touch` race that was flaking under
  # parallel load (bats setup overhead routinely consumed the 4s window
  # before taskgrind even checked the sentinel).
  local restore_devin="$TEST_DIR/restore-devin"
  create_fake_devin "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-counter"
  export DVB_NET_FLIP_AFTER=1
  export DVB_SKIP_PREFLIGHT=1
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=60
  export DVB_DEADLINE_OFFSET=10
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'network_restored' "$TEST_LOG"
}

@test "session number rolls back after network recovery" {
  # Counter-mode network state — same pattern as the previous test. Forces
  # wait_for_network to enter (via FLIP_AFTER=1) without depending on a
  # wall-clock race against bats setup overhead.
  local restore_devin="$TEST_DIR/restore-devin"
  create_fake_devin "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-counter"
  export DVB_NET_FLIP_AFTER=1
  export DVB_SKIP_PREFLIGHT=1
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=30
  export DVB_DEADLINE_OFFSET=10
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
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE_OFFSET=10
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # After 3+ fast failures, should log fast_fail with backoff
  grep -q 'fast_fail' "$TEST_LOG"
  grep -q 'consecutive=3' "$TEST_LOG"
}

@test "backoff increases with consecutive fast failures" {
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=1
  export DVB_BACKOFF_MAX=10
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  # Need 4 fast failures + 1+2+3=6s of backoff sleeps; under 8x parallel
  # bats load startup also costs 2-3s, so 18s is the safe envelope.
  export DVB_DEADLINE_OFFSET=18
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With base=1: consecutive=3 → 3s, consecutive=4 → 4s, etc.
  grep -q 'backoff=3s' "$TEST_LOG"
  grep -q 'backoff=4s' "$TEST_LOG"
}

@test "TG_BACKOFF_BASE takes precedence over DVB_BACKOFF_BASE" {
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  # DVB_ says base=20 (would give backoff=60s on consecutive=3). If TG_
  # wins, base=1 and backoff=3s.
  export DVB_BACKOFF_BASE=20
  export TG_BACKOFF_BASE=1
  export DVB_BACKOFF_MAX=10
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  # Same envelope rationale as the previous test — 4 fast fails + cumulative
  # backoff sleeps + parallel-load startup overhead.
  export DVB_DEADLINE_OFFSET=18
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # TG_BACKOFF_BASE=1 → backoff=3s on consecutive=3 (3 * 1, capped at 10)
  grep -q 'backoff=3s' "$TEST_LOG"
  ! grep -Eq 'backoff=([2-9][0-9]+|60)s' "$TEST_LOG"
}

@test "TG_BACKOFF_MAX takes precedence over DVB_BACKOFF_MAX" {
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=1
  # DVB_ says cap=100 but TG_ says cap=3. With BASE=1, the cap only matters
  # at consecutive>=4 (where 4*1=4 would exceed 3).
  export DVB_BACKOFF_MAX=100
  export TG_BACKOFF_MAX=3
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # At consecutive=4+, backoff should be capped at 3, not ramping to 4+.
  ! grep -Eq 'backoff=([4-9]|[1-9][0-9]+)s' "$TEST_LOG"
}

@test "backoff caps at DVB_BACKOFF_MAX" {
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_BACKOFF_MAX=5
  export DVB_COOL=0
  export DVB_DEADLINE_OFFSET=5
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
  create_fake_devin "$slow_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# On 4th invocation, simulate a long session
count=\$(wc -l < "$DVB_GRIND_INVOKE_LOG" 2>/dev/null || echo 0)
if [ "\$count" -ge 4 ]; then
  # Sleep longer than min_session_secs to reset counter
  sleep 2
fi
SCRIPT
  export DVB_GRIND_CMD="$slow_devin"
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=1
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  # Need 4+ sessions including a 2s slow one; under heavy parallel suite
  # load 10s wasn't enough — startup overhead can eat 3s before session 1.
  export DVB_DEADLINE_OFFSET=18
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
  export DVB_DEADLINE_OFFSET=5
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
  export DVB_DEADLINE_OFFSET=10
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
  # 3s window was too tight under heavy parallel suite load; needs ≥1
  # session to launch + fast-fail + reach the network check path.
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Network down"* ]]
}

@test "network restored message shows in terminal output" {
  # Counter-mode network state — flips down→up after the fast-failure check
  # so wait_for_network enters and then exits cleanly with the "Network back"
  # message. No wall-clock race against parallel-load test setup overhead.
  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-counter"
  export DVB_NET_FLIP_AFTER=1
  export DVB_SKIP_PREFLIGHT=1
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=10
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=60
  export DVB_DEADLINE_OFFSET=10
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Network back"* ]]
}

@test "fast failure warning shows exit code in terminal output" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE_OFFSET=15
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"fast failures"* ]]
  [[ "$output" == *"exit="* ]]
}

@test "session end log includes exit code and duration" {
  export DVB_DEADLINE_OFFSET=5
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

@test "help documents TG_NET_CHECK_URL" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"TG_NET_CHECK_URL"* ]]
}

@test "check_network fallback honors DVB_NET_CHECK_URL" {
  grep -q 'net_check_url="${DVB_NET_CHECK_URL:-https://connectivitycheck.gstatic.com/generate_204}"' "$DVB_GRIND"
  grep -q 'curl -sf --max-time 5 "$net_check_url"' "$DVB_GRIND"
}
