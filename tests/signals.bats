#!/usr/bin/env bats
# Tests for taskgrind — signal handling + 9 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Signal handling ──────────────────────────────────────────────────

@test "taskgrind traps INT signal for cleanup" {
  grep -q "trap.*INT" "$DVB_GRIND"
}

@test "taskgrind traps TERM signal for cleanup" {
  grep -q "trap.*TERM" "$DVB_GRIND"
}

@test "taskgrind prints summary on interrupt (INT/TERM)" {
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<'SCRIPT'
#!/bin/bash
sleep 10
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/signal-output.txt" 2>&1 &
  local grind_pid=$!
  sleep 2
  kill -INT "$grind_pid" 2>/dev/null || true
  wait "$grind_pid" 2>/dev/null || true
  grep -q "Grind complete\|sessions" "$TEST_DIR/signal-output.txt"
}

# ── Graceful shutdown ────────────────────────────────────────────────

@test "INT signal waits for running session before exiting" {
  # Slow devin that takes 5s but records when it starts and finishes
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "session_started" >> "$TEST_DIR/session-lifecycle.log"
sleep 3
echo "session_finished" >> "$TEST_DIR/session-lifecycle.log"
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  export DVB_SHUTDOWN_GRACE=10

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/graceful-output.txt" 2>&1 &
  local grind_pid=$!
  sleep 1
  # Send INT while session is running
  kill -INT "$grind_pid" 2>/dev/null || true
  wait "$grind_pid" 2>/dev/null || true
  # Session should have finished (session_finished written)
  grep -q 'session_finished' "$TEST_DIR/session-lifecycle.log"
}

@test "graceful shutdown function is called on INT" {
  # Structural: INT trap calls graceful_shutdown, not just cleanup
  grep -q "trap 'graceful_shutdown 130' INT" "$DVB_GRIND"
}

@test "graceful shutdown sends SIGINT then waits before SIGTERM" {
  # Structural: graceful_shutdown sends INT first, sleeps in a loop, then SIGTERM
  grep -q 'kill -INT.*_dvb_pid' "$DVB_GRIND"
  grep -q 'DVB_SHUTDOWN_GRACE' "$DVB_GRIND"
  # Verify SIGTERM escalation exists after grace period
  grep -A5 'waited -lt.*_shutdown_grace' "$DVB_GRIND" | grep -q 'kill.*_dvb_pid'
}

@test "structural: graceful_shutdown waits for _dvb_pid" {
  grep -q 'graceful_shutdown' "$DVB_GRIND"
  grep -q 'kill -INT.*_dvb_pid' "$DVB_GRIND"
  grep -q 'DVB_SHUTDOWN_GRACE' "$DVB_GRIND"
}

@test "structural: graceful_shutdown kills orphaned git sync processes" {
  grep -q '_git_pid=0' "$DVB_GRIND"
  grep -q '_git_timer=0' "$DVB_GRIND"
  # graceful_shutdown kills git processes
  grep -A40 'graceful_shutdown()' "$DVB_GRIND" | grep -q '_git_pid'
  # cleanup also kills git processes
  grep -A60 'cleanup()' "$DVB_GRIND" | grep -q '_git_pid'
}

@test "structural: graceful_shutdown kills elapsed timer" {
  # graceful_shutdown should clean up _dvb_timer_pid to prevent orphan output
  grep -A50 'graceful_shutdown()' "$DVB_GRIND" | grep -q '_dvb_timer_pid'
}

@test "structural: _productive_zero_ship initialized before loop" {
  # Must be initialized before the while loop to avoid set -u crash
  grep -q '_productive_zero_ship=0' "$DVB_GRIND"
}

@test "structural: final_sync pushes local commits" {
  grep -q 'final_sync' "$DVB_GRIND"
  grep -q 'git.*push.*origin' "$DVB_GRIND"
}

@test "structural: EXIT trap calls final_sync before cleanup" {
  grep -q "trap 'final_sync; cleanup' EXIT" "$DVB_GRIND"
}

# ── Tasks unchanged scenario ─────────────────────────────────────────

@test "zero tasks shipped when tasks unchanged between sessions" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'shipped=0' "$TEST_LOG"
}

@test "summary shows 0+ tasks when no tasks shipped" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task that stays
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"0+ tasks"* ]]
}

# ── Deadline check before cooldown ───────────────────────────────────

@test "deadline check before cooldown prevents sleeping past deadline" {
  grep -q 'Check deadline before cooldown' "$DVB_GRIND"
  local check_line sleep_line
  check_line=$(grep -n 'Check deadline before cooldown' "$DVB_GRIND" | head -1 | cut -d: -f1)
  sleep_line=$(grep -n 'sleep "$cooldown"' "$DVB_GRIND" | head -1 | cut -d: -f1)
  [ -n "$check_line" ]
  [ -n "$sleep_line" ]
  [ "$check_line" -lt "$sleep_line" ]
}

@test "grind exits immediately when deadline reached mid-loop" {
  export DVB_DEADLINE=$(( $(date +%s) + 1 ))
  export DVB_COOL=60
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Grind complete"* ]]
}

# ── Caffeinate re-exec ───────────────────────────────────────────────

@test "caffeinate re-exec is skipped in test mode" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "DVB_CAFFEINATED env prevents double caffeinate" {
  grep -q 'DVB_CAFFEINATED' "$DVB_GRIND"
  grep -A2 'DVB_CAFFEINATED' "$DVB_GRIND" | grep -q 'caffeinate'
}

@test "Linux: systemd-inhibit fallback for caffeinate (structural)" {
  grep -q 'systemd-inhibit' "$DVB_GRIND"
  grep -q 'idle:sleep' "$DVB_GRIND"
}

@test "Linux: flock preferred, perl fallback when flock unavailable (structural)" {
  grep -q 'flock -n 9' "$DVB_GRIND"
  grep -q 'perl.*Fcntl.*LOCK_EX' "$DVB_GRIND"
}

@test "Linux: notify-send fallback for osascript (structural)" {
  grep -q 'notify-send' "$DVB_GRIND"
}

# ── Stall detection (zero-ship sessions) ─────────────────────────────

@test "DVB_MAX_ZERO_SHIP defaults to 8" {
  grep -q 'DVB_MAX_ZERO_SHIP:-8' "$DVB_GRIND"
}

@test "5 consecutive zero-ship sessions exits the marathon" {
  # Create a persistent task that never gets removed
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task that never completes
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zero-ship sessions"* ]]
  [[ "$output" == *"stalled"* ]]
  grep -q 'stall_bail' "$TEST_LOG"
  # Should have exactly 5 sessions (bail at 5)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 5 ]
}

@test "3 consecutive zero-ship sessions adds stall warning to log" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'stall_warning consecutive_zero_ship=3' "$TEST_LOG"
}

@test "stall warning appears in prompt after 3 zero-ship sessions" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 4's prompt should contain the stall warning
  grep -q 'WARNING.*shipped nothing' "$DVB_GRIND_INVOKE_LOG"
}

@test "stall warning tells agent to decompose" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Large task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must mention decompose
  grep -q 'decompose' "$DVB_GRIND_INVOKE_LOG"
  # Should NOT mention sweep (removed from prompt)
  ! grep -q 'sweep' "$DVB_GRIND_INVOKE_LOG"
}

@test "productive zero-ship detected when agent commits but does not remove task" {
  # Set up a real git repo so git HEAD changes can be detected
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" add TASKS.md
  git -C "$TEST_REPO" commit -q -m "initial"

  # Fake devin that commits code but never removes the task
  local commit_devin="$TEST_DIR/commit-devin"
  cat > "$commit_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "fix something" >> "$TEST_REPO/code.txt"
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -q -m "fix: session work" --allow-empty
SCRIPT
  chmod +x "$commit_devin"
  export DVB_GRIND_CMD="$commit_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task that never gets removed
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'productive_zero_ship' "$TEST_LOG"
}

@test "productive zero-ship escalation appears in prompt after 2 zero-ship sessions with commits" {
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" add TASKS.md
  git -C "$TEST_REPO" commit -q -m "initial"

  local commit_devin="$TEST_DIR/commit-devin"
  cat > "$commit_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "work" >> "$TEST_REPO/code.txt"
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -q -m "fix: do work"
SCRIPT
  chmod +x "$commit_devin"
  export DVB_GRIND_CMD="$commit_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 3's prompt should contain the URGENT escalation
  grep -q 'URGENT.*committed code.*did NOT remove' "$DVB_GRIND_INVOKE_LOG"
}

@test "no productive zero-ship when no commits and no ships" {
  # Non-git repo: no commits possible, so no productive zero-ship
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'productive_zero_ship' "$TEST_LOG"
}

@test "zero-ship counter resets when a session ships a task" {
  # Fake devin that removes a task each run by counting invocations and rewriting TASKS.md
  local ship_devin="$TEST_DIR/ship-devin"
  local counter_file="$TEST_DIR/ship-counter"
  echo "0" > "$counter_file"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# Increment counter and rewrite TASKS.md with one fewer task
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
remaining=\$((30 - n))
[ \$remaining -lt 0 ] && remaining=0
{
  echo "# Tasks"
  echo "## P0"
  i=1
  while [ \$i -le \$remaining ]; do
    echo "- [ ] Task \$i"
    i=\$((i + 1))
  done
} > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  # Start with 30 tasks
  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 30); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=3
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should NOT have stall_bail — every session ships a task, counter stays at 0
  ! grep -q 'stall_bail' "$TEST_LOG"
  # Verify tasks were actually shipped
  [ "$( grep -c 'shipped=[1-9]' "$TEST_LOG" || true )" -ge 1 ]
}

@test "DVB_MAX_ZERO_SHIP=abc exits with must be numeric error" {
  export DVB_MAX_ZERO_SHIP=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_ZERO_SHIP must be numeric"* ]]
}

# ── grind_done log ordering on Ctrl-C ──────────────────────────────────

@test "grind_done is last log entry on Ctrl-C interrupt" {
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<'SCRIPT'
#!/bin/bash
sleep 10
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/int-output.txt" 2>&1 &
  local grind_pid=$!
  sleep 2
  kill -INT "$grind_pid" 2>/dev/null || true
  wait "$grind_pid" 2>/dev/null || true
  # grind_done should be the last log_write entry — no session-end after it
  local last_content_line
  last_content_line=$(grep -v '^#' "$TEST_LOG" | grep -v '^$' | tail -1)
  [[ "$last_content_line" == *"grind_done"* ]]
}

@test "_dvb_finalizing flag guards session-end log after cleanup" {
  # Structural: session-end log is wrapped in _dvb_finalizing check
  grep -q '_dvb_finalizing.*0.*log_write.*session=.*ended\|_dvb_finalizing -eq 0' "$DVB_GRIND"
}

@test "cleanup sets _dvb_finalizing=1" {
  grep -q '_dvb_finalizing=1' "$DVB_GRIND"
}

# ── Temp file cleanup patterns ─────────────────────────────────────────

@test "find cleanup patterns only match taskgrind-prefixed files" {
  # The find fallback must use 'taskgrind-*' prefix on all patterns to avoid
  # deleting files from other tools in TMPDIR.
  # Extract the find lines from the cleanup block
  local find_lines
  find_lines=$(grep 'find.*_dvb_tmp.*-delete' "$DVB_GRIND")
  # Every -name pattern must start with 'taskgrind-'
  local bad_patterns
  bad_patterns=$(echo "$find_lines" | grep -oE "'-name' '[^']*'|-name '[^']*'" | grep -v 'taskgrind-' || true)
  [ -z "$bad_patterns" ]
}

@test "fd cleanup regex is scoped to taskgrind files" {
  # The fd regex should only match files starting with 'taskgrind-'
  grep -q "taskgrind-(exec" "$DVB_GRIND"
}

# ── Graceful timeout (SIGINT before SIGTERM) ───────────────────────────

@test "timeout watchdog sends SIGINT before SIGTERM" {
  grep -q 'kill -INT "$_dvb_pid"' "$DVB_GRIND"
}

@test "timeout watchdog has grace period before SIGTERM escalation" {
  # After SIGINT, wait a grace period then check if still alive
  grep -q '_grace=15' "$DVB_GRIND"
  grep -q 'sleep "$_grace"' "$DVB_GRIND"
  grep -q 'still alive after.*grace.*SIGTERM' "$DVB_GRIND"
}

@test "timeout watchdog only sends SIGTERM if process survived SIGINT" {
  # kill -0 check before SIGTERM escalation
  grep -A2 'sleep "$_grace"' "$DVB_GRIND" | grep -q 'kill -0 "$_dvb_pid"'
}

# ── Diminishing returns / DVB_EARLY_EXIT_ON_STALL ─────────────────────

@test "diminishing returns warning after 5 low-throughput sessions" {
  # Persistent task never removed → 0 shipped per session
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=10
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'diminishing_returns' "$TEST_LOG"
  [[ "$output" == *"Low throughput"* ]]
}

@test "DVB_EARLY_EXIT_ON_STALL=1 exits early on low throughput" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=10
  export DVB_EARLY_EXIT_ON_STALL=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'early_exit_stall' "$TEST_LOG"
  [[ "$output" == *"TG_EARLY_EXIT_ON_STALL=1"* ]]
}

@test "DVB_EARLY_EXIT_ON_STALL=0 does not exit early" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 15 ))
  export DVB_MAX_ZERO_SHIP=6
  export DVB_EARLY_EXIT_ON_STALL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should bail due to zero-ship stall, NOT early_exit_stall
  ! grep -q 'early_exit_stall' "$TEST_LOG"
  grep -q 'stall_bail' "$TEST_LOG"
}

@test "early exit stops the grind loop (no more sessions)" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  export DVB_MAX_ZERO_SHIP=20
  export DVB_EARLY_EXIT_ON_STALL=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should exit after ~5 sessions (when diminishing returns fires)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  # Exactly 5 sessions (diminishing returns fires at session 5)
  [ "$count" -le 6 ]
}

@test "productive timeout warning when shipped session hits timeout" {
  # Fake devin that removes one task per invocation
  local ship_devin="$TEST_DIR/ship-devin"
  local counter_file="$TEST_DIR/ship-counter"
  echo "0" > "$counter_file"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
remaining=\$((5 - n))
[ \$remaining -lt 0 ] && remaining=0
{
  echo "# Tasks"
  echo "## P0"
  i=1
  while [ \$i -le \$remaining ]; do
    echo "- [ ] Task \$i"
    i=\$((i + 1))
  done
} > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 5); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"

  # DVB_MAX_SESSION=0 means any elapsed time >= 0 triggers productive_timeout
  export DVB_MAX_SESSION=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'productive_timeout' "$TEST_LOG"
  [[ "$output" == *"Productive session hit timeout"* ]]
}

@test "productive timeout auto-increases max_session" {
  local ship_devin="$TEST_DIR/ship-devin"
  local counter_file="$TEST_DIR/ship-counter"
  echo "0" > "$counter_file"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
remaining=\$((3 - n))
[ \$remaining -lt 0 ] && remaining=0
{
  echo "# Tasks"
  echo "## P0"
  i=1
  while [ \$i -le \$remaining ]; do
    echo "- [ ] Task \$i"
    i=\$((i + 1))
  done
} > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 3); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"

  export DVB_MAX_SESSION=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Auto-increasing to"* ]]
  grep -q 'new_timeout=' "$TEST_LOG"
}

@test "productive timeout caps at 7200s (structural)" {
  # Behavioral: fast stubs can't reach the cap (session_elapsed ≈ 0 < 1800 after
  # first increase), so we verify the cap logic structurally.
  grep -q 'max_session.*7200' "$DVB_GRIND"
  grep -q 'at cap' "$DVB_GRIND"
  # Verify the clamp: if max_session + 1800 > 7200, it's set to exactly 7200
  grep -Fq 'max_session" -gt 7200' "$DVB_GRIND"
  grep -Fq '&& max_session=7200' "$DVB_GRIND"
}

@test "no productive timeout when session does not ship" {
  # Tasks never removed → 0 shipped → no productive_timeout
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_MAX_SESSION=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=3
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'productive_timeout' "$TEST_LOG"
}

