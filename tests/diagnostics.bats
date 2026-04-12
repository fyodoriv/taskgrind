#!/usr/bin/env bats
# Tests for taskgrind — diagnostics and bail out + 8 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Diagnostics and bail out ──────────────────────────────────────────

@test "non-zero exit code is logged per session" {
  local failing_devin="$TEST_DIR/fail-devin"
  create_fake_devin "$failing_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 42
SCRIPT
  export DVB_GRIND_CMD="$failing_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'exit=42' "$TEST_LOG"
}

@test "exit code shows in terminal session end message" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"exit=0"* ]]
}

@test "DVB_MAX_FAST defaults to 20" {
  grep -q 'DVB_MAX_FAST:-20' "$DVB_GRIND"
}

@test "max fast failures bails out with diagnostic" {
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 15 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Giving up"* ]]
  grep -q 'bail_out' "$TEST_LOG"
}

@test "bail out stops the loop (no more sessions after)" {
  local counter_devin="$TEST_DIR/counter-devin"
  create_fake_devin "$counter_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
SCRIPT
  export DVB_GRIND_CMD="$counter_devin"
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should have exactly 3 invocations (bail at 3, not more)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 3 ]
}

@test "fast failure captures session output to log" {
  local err_devin="$TEST_DIR/err-devin"
  create_fake_devin "$err_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
if [[ "$*" == *"--help"* ]]; then
  exit 0
fi
echo "ERROR: something went wrong"
exit 1
SCRIPT
  export DVB_GRIND_CMD="$err_devin"
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=2
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'session.*output' "$TEST_LOG"
  grep -q 'ERROR: something went wrong' "$TEST_LOG"
}

@test "fast failure captures backend stderr to log" {
  local err_devin="$TEST_DIR/stderr-devin"
  create_fake_devin "$err_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
if [[ "$*" == *"--help"* ]]; then
  exit 0
fi
echo "Error: Unknown model: 'broken-model'" >&2
exit 1
SCRIPT
  export DVB_GRIND_CMD="$err_devin"
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=2
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'session.*output' "$TEST_LOG"
  grep -q "Error: Unknown model: 'broken-model'" "$TEST_LOG"
}

@test "bail out shows last session output in terminal" {
  local err_devin="$TEST_DIR/err-devin"
  create_fake_devin "$err_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "FATAL: cannot connect to API"
exit 1
SCRIPT
  export DVB_GRIND_CMD="$err_devin"
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"FATAL: cannot connect to API"* ]]
}

@test "bail out log includes exit code" {
  setup_network_sentinel "$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE 'bail_out consecutive=3 exit=[0-9]+' "$TEST_LOG"
}

# ── Argument hardening ─────────────────────────────────────────────────

@test "--skill without a value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

@test "--skill=fleet-grind equals syntax works" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill=fleet-grind
  [ "$status" -eq 0 ]
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "--skill= empty value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" "--skill="
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a non-empty name"* ]]
}

@test "--backend= empty value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" "--backend="
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

@test "--skill two-arg with empty string exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a non-empty name"* ]]
}

@test "--backend two-arg with empty string exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" --backend ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

@test "DVB_COOL=abc exits with must be numeric error" {
  export DVB_COOL=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be numeric"* ]]
}

@test "DVB_MAX_FAST=abc exits with must be numeric error" {
  export DVB_MAX_FAST=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_FAST must be numeric"* ]]
}

@test "DVB_MAX_SESSION=abc exits with must be numeric error" {
  export DVB_MAX_SESSION=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_SESSION must be numeric"* ]]
}

@test "TG_MAX_SESSION takes precedence over DVB_MAX_SESSION" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_SESSION=9
  export TG_MAX_SESSION=17
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'timeout 17s' "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_SHUTDOWN_GRACE=abc exits with must be numeric error" {
  export DVB_SHUTDOWN_GRACE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SHUTDOWN_GRACE must be numeric"* ]]
}

@test "DVB_SESSION_GRACE=abc exits with must be numeric error" {
  export DVB_SESSION_GRACE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SESSION_GRACE must be numeric"* ]]
}

@test "--help shows TG_SESSION_GRACE" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"TG_SESSION_GRACE"* ]]
}

@test "DVB_MIN_SESSION=abc exits with must be numeric error" {
  export DVB_MIN_SESSION=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MIN_SESSION must be numeric"* ]]
}

@test "DVB_NET_WAIT=abc exits with must be numeric error" {
  export DVB_NET_WAIT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_WAIT must be numeric"* ]]
}

@test "DVB_NET_MAX_WAIT=abc exits with must be numeric error" {
  export DVB_NET_MAX_WAIT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_MAX_WAIT must be numeric"* ]]
}

@test "DVB_NET_RETRIES=abc exits with must be numeric error" {
  export DVB_NET_RETRIES=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_RETRIES must be numeric"* ]]
}

@test "DVB_NET_RETRY_DELAY=abc exits with must be numeric error" {
  export DVB_NET_RETRY_DELAY=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_RETRY_DELAY must be numeric"* ]]
}

@test "DVB_BACKOFF_BASE=abc exits with must be numeric error" {
  export DVB_BACKOFF_BASE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_BACKOFF_BASE must be numeric"* ]]
}

@test "DVB_BACKOFF_MAX=abc exits with must be numeric error" {
  export DVB_BACKOFF_MAX=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_BACKOFF_MAX must be numeric"* ]]
}

@test "DVB_SYNC_INTERVAL=abc exits with must be numeric error" {
  export DVB_SYNC_INTERVAL=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SYNC_INTERVAL must be numeric"* ]]
}

@test "DVB_GIT_SYNC_TIMEOUT=abc exits with must be numeric error" {
  export DVB_GIT_SYNC_TIMEOUT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_GIT_SYNC_TIMEOUT must be numeric"* ]]
}

@test "DVB_EMPTY_QUEUE_WAIT=abc exits with must be numeric error" {
  export DVB_EMPTY_QUEUE_WAIT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_EMPTY_QUEUE_WAIT must be numeric"* ]]
}

@test "DVB_DEADLINE=abc exits with must be epoch error" {
  export DVB_DEADLINE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DVB_DEADLINE must be a Unix epoch integer"* ]]
}

@test "numeric directory name treated as repo path not hours" {
  local num_dir="$TEST_DIR/42"
  mkdir -p "$num_dir"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$num_dir" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$num_dir"* ]]
}

# ── Inter-session git pull ─────────────────────────────────────────────

@test "pulls latest changes between sessions in a git repo" {
  # Initialize the test repo as a git repo with a remote
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  # Create a bare remote and push
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin HEAD 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync ok' "$TEST_LOG"
}

@test "skips git pull for non-git repos" {
  # TEST_REPO is a plain directory (no .git)
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'git_sync' "$TEST_LOG"
}

@test "skips git pull for git repos without a remote" {
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  # No remote added

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'git_sync' "$TEST_LOG"
}

@test "fast_fail log includes exit code" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE 'fast_fail.*exit=[0-9]+' "$TEST_LOG"
}

# ── Print mode and session timeout ────────────────────────────────────

@test "uses -p (print mode) not -- (interactive mode)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must use -p for non-interactive mode (exits after completion)
  grep -q -- '-p ' "$DVB_GRIND_INVOKE_LOG"
  # Must NOT use -- separator (interactive mode waits for user input)
  ! grep -q -- ' -- Run the' "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MAX_SESSION defaults to 3600" {
  grep -q 'DVB_MAX_SESSION:-3600' "$DVB_GRIND"
}

@test "timeout watchdog uses kill-0 polling to detect session exit" {
  grep -q 'kill -0 "$_dvb_pid"' "$DVB_GRIND"
}

@test "timeout watchdog logs session_timeout on kill" {
  grep -q 'session_timeout' "$DVB_GRIND"
}

@test "timeout watchdog is killable via SIGTERM (trap + sleep &; wait)" {
  grep -q "trap 'kill \$! 2>/dev/null; exit 0' TERM" "$DVB_GRIND"
  grep -q 'sleep "$s" &' "$DVB_GRIND"
  grep -q 'wait $!' "$DVB_GRIND"
}

# ── Dry Run ───────────────────────────────────────────────────────────

@test "--dry-run prints config and exits 0" {
  run "$DVB_GRIND" --dry-run 4 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"taskgrind --dry-run"* ]]
  [[ "$output" == *"hours:    4"* ]]
  [[ "$output" == *"skill:    next-task"* ]]
  [[ "$output" == *"Prompt:"* ]]
  [[ "$output" == *"Previous session context"* ]]
  [[ "$output" == *"Commit before timeout"* ]]
}

@test "--dry-run shows custom skill" {
  run "$DVB_GRIND" --dry-run --skill fleet-grind 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill:    fleet-grind"* ]]
}

@test "--dry-run shows repo path" {
  run "$DVB_GRIND" --dry-run "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo:     $TEST_REPO"* ]]
}

@test "--dry-run does not create log file" {
  local dry_log="$TEST_DIR/dry-run.log"
  export DVB_LOG="$dry_log"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$dry_log" ]
}

@test "--dry-run does not launch any devin sessions" {
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "--dry-run shows --prompt focus" {
  run "$DVB_GRIND" --dry-run --prompt "test coverage" 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt:   test coverage"* ]]
  [[ "$output" == *"FOCUS: test coverage"* ]]
}

@test "--dry-run omits prompt line when no --prompt given" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"prompt:"* ]]
  [[ "$output" != *"FOCUS:"* ]]
}

@test "--dry-run shows completion protocol and autonomy guidance" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPLETION PROTOCOL"* ]]
  [[ "$output" == *"remove its entire block"* ]]
  [[ "$output" == *"AUTONOMY:"* ]]
  [[ "$output" == *"browser automation"* ]]
}

# ── Devin binary PATH fallback ────────────────────────────────────────

@test "devin path resolution checks PATH before default" {
  # Structural: lib/constants.sh has command -v devin fallback
  local constants="$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -q 'command -v devin' "$constants"
}

@test "DVB_DEVIN_PATH env override is respected" {
  # Structural: lib/constants.sh checks DVB_DEVIN_PATH first
  local constants="$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -q 'DVB_DEVIN_PATH:-' "$constants" || grep -q 'DVB_DEVIN_PATH' "$constants"
}

# ── Zero-ship session diagnostics ─────────────────────────────────────

@test "zero-ship session captures output tail to log" {
  # Fake devin that prints diagnostic output but doesn't remove tasks
  local diag_devin="$TEST_DIR/diag-devin"
  cat > "$diag_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "Working on hard task..."
echo "STUCK: cannot resolve merge conflict"
SCRIPT
  chmod +x "$diag_devin"
  export DVB_GRIND_CMD="$diag_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Hard task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Log should contain the session output capture
  grep -q 'zero-ship.*last 20 lines' "$TEST_LOG"
  grep -q 'STUCK: cannot resolve merge conflict' "$TEST_LOG"
}

@test "zero-ship diagnostics do not fire when tasks are shipped" {
  # Use sed '1,' (BSD-compatible) to delete the first task each session
  local ship_devin="$TEST_DIR/ship-devin"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
REPO="$TEST_REPO"
if [ -f "\$REPO/TASKS.md" ]; then
  sed -i '' '1,/^- \[ \]/{/^- \[ \]/d;}' "\$REPO/TASKS.md" 2>/dev/null || \
  sed -i '1,/^- \[ \]/{/^- \[ \]/d;}' "\$REPO/TASKS.md" 2>/dev/null || true
fi
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  # Enough tasks that every session ships before the deadline
  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 50); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Every session ships a task, so no zero-ship output captures
  ! grep -q 'zero-ship' "$TEST_LOG"
}

# ── Efficiency summary in grind_done ──────────────────────────────────

@test "grind_done terminal output includes rate and avg session" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rate:"* ]]
  [[ "$output" == *"/h"* ]]
  [[ "$output" == *"Avg session:"* ]]
  [[ "$output" == *"Zero-ship:"* ]]
}

@test "grind_done log line includes rate and sessions_zero_ship" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'grind_done.*rate=.*sessions_zero_ship=' "$TEST_LOG"
}

@test "grind_done log includes avg_session field" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'avg_session=' "$TEST_LOG"
}

@test "zero-ship count in summary matches actual zero-ship sessions" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 15 ))
  export DVB_MAX_ZERO_SHIP=3
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Zero-ship: 3"* ]]
  grep -q 'sessions_zero_ship=3' "$TEST_LOG"
}

# ── Devin binary validation ────────────────────────────────────────────

@test "missing devin binary exits immediately with clear error" {
  # Use production path (no DVB_GRIND_CMD) with nonexistent binary.
  # Set DVB_DEVIN_PATH to a nonexistent path and strip real devin from PATH.
  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="/nonexistent/devin"
  export HOME="/nonexistent/home"
  # Remove devin from PATH so command -v devin fails
  export PATH="/usr/bin:/bin"
  # Skip caffeinate and self-copy by pre-setting the guards
  export DVB_CAFFEINATED=1
  export _DVB_SELF_COPY="/dev/null"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"binary not found"* ]]
}

@test "backend sanity probe blocks silent stub binaries before session 1" {
  local silent_stub="$TEST_DIR/silent-stub-devin"
  create_fake_devin "$silent_stub" <<'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  exit 0
fi
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT

  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="$silent_stub"
  export DVB_CAFFEINATED=1
  export _DVB_SELF_COPY="/dev/null"
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"backend binary may be a stub or broken"* ]]
  grep -q 'backend_probe_failed exit=0 duration=0s backend=devin' "$TEST_LOG"
  ! [ -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "backend sanity probe allows versioned binaries to reach session 1" {
  local versioned_devin="$TEST_DIR/versioned-devin"
  create_fake_devin "$versioned_devin" <<'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  echo "Devin CLI 2026.4.9"
  exit 0
fi
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT

  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="$versioned_devin"
  export DVB_CAFFEINATED=1
  export _DVB_SELF_COPY="/dev/null"
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))
  export DVB_MAX_ZERO_SHIP=1

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -Eq 'backend_probe_ok exit=0 duration=[0-9]+s backend=devin' "$TEST_LOG"
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
  grep -q 'Run the next-task skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "devin binary validation uses -x check (executable)" {
  grep -q '\-x "$_backend_binary"' "$DVB_GRIND"
}

@test "test backend normalizes simple injected commands like /bin/true" {
  export DVB_GRIND_CMD="/bin/true"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  ! grep -q 'No such file or directory' "$TEST_LOG"
}

@test "invalid test backend command exits with actionable error" {
  local missing_backend="$TEST_DIR/missing-backend"
  export DVB_GRIND_CMD="$missing_backend"

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Test backend command is not executable"* ]]
  [[ "$output" == *"$missing_backend"* ]]
}
