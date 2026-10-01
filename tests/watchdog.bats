#!/usr/bin/env bats
# Tests for the SIGINT -> SIGTERM -> SIGKILL escalation watchdog
# (lib/watchdog.sh). Source: `sweep-watchdog-escalate-to-sigkill` task —
# reproduces the 2026-05-01 dotfiles grind log where a sweep ran 26 908 s
# against a 1800 s cap (14.95x overrun) because the previous inlined
# watchdog stopped at SIGTERM and could be silently disarmed by spurious
# signals.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"
WATCHDOG_LIB="$BATS_TEST_DIRNAME/../lib/watchdog.sh"

# ── Unit tests against lib/watchdog.sh directly ──────────────────────
#
# The watchdog escalation logic is a pure function, so we can source the
# library and exercise it without booting the full grind loop. This
# keeps the regression tests fast and free of integration noise.

# Helper: spawn a fake backend that ignores SIGINT and (optionally)
# SIGTERM, then return its PID via $WATCHDOG_FAKE_PID. The backend
# self-terminates after `lifetime` seconds so a misbehaving test cannot
# orphan a process across the bats run.
_spawn_signal_ignoring_backend() {
  local lifetime="${1:-30}"
  local ignore_term="${2:-1}"
  local script="$TEST_DIR/fake-wedged-backend"
  if [ "$ignore_term" = "1" ]; then
    cat > "$script" <<SCRIPT
#!/bin/bash
trap '' INT TERM
sleep $lifetime
SCRIPT
  else
    cat > "$script" <<SCRIPT
#!/bin/bash
trap '' INT
sleep $lifetime
SCRIPT
  fi
  chmod +x "$script"
  "$script" &
  WATCHDOG_FAKE_PID=$!
}

# Helper: source the watchdog library + minimal constants needed by it.
_load_watchdog_lib() {
  # shellcheck disable=SC1090
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  # shellcheck disable=SC1090
  source "$WATCHDOG_LIB"
}

@test "watchdog kills a backend that ignores SIGINT and SIGTERM within cap + grace + kill_grace" {
  _load_watchdog_lib

  # Force tight grace windows so the test runs in seconds, not minutes.
  export DVB_SESSION_GRACE=2
  export DVB_WATCHDOG_KILL_GRACE=2
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  _spawn_signal_ignoring_backend 60 1
  local fake_pid="$WATCHDOG_FAKE_PID"

  local cap=3
  local watch_start watch_end watch_elapsed
  watch_start=$(date +%s)
  ( dvb_watchdog_run "test_session" "$cap" "$fake_pid" ) &
  local watchdog_pid=$!
  wait "$watchdog_pid"
  watch_end=$(date +%s)
  watch_elapsed=$(( watch_end - watch_start ))

  # Backend MUST be dead by the time the watchdog returns. The previous
  # inlined body left the backend alive after SIGTERM, so this assertion
  # is the regression for the 14.95x cap overrun.
  if kill -0 "$fake_pid" 2>/dev/null; then
    kill -KILL "$fake_pid" 2>/dev/null || true
    fail "Backend still alive after watchdog returned — escalation never reached SIGKILL"
  fi

  # Total elapsed must respect the cap-plus-escalation budget. cap=3 +
  # grace=2 + kill_grace=2 = 7s; allow up to 15s for parallel-bats
  # scheduling jitter. The pre-fix behaviour ran indefinitely.
  [ "$watch_elapsed" -le 15 ] || fail "Watchdog took ${watch_elapsed}s — exceeded cap+grace+kill_grace+jitter budget"

  # Escalation marker on the SIGKILL path must be present.
  grep -q 'test_session_watchdog escalation=SIGKILL' "$log_file" \
    || fail "Missing escalation=SIGKILL log marker. Log:\n$(cat "$log_file")"
}

@test "watchdog ignores spurious SIGTERM while backend is still alive (cannot be silently disarmed)" {
  _load_watchdog_lib

  export DVB_SESSION_GRACE=2
  export DVB_WATCHDOG_KILL_GRACE=2
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  _spawn_signal_ignoring_backend 60 1
  local fake_pid="$WATCHDOG_FAKE_PID"

  # Use a longer cap so we can SIGTERM the watchdog mid-phase-1 and
  # confirm it keeps enforcing the cap rather than exiting on the
  # spurious signal. The previous inlined body had `trap 'kill $!
  # 2>/dev/null; exit 0' TERM` which silently disarmed. The new trap
  # checks `kill -0 $target_pid` first — backend alive means ignore.
  local cap=4
  ( dvb_watchdog_run "test_session" "$cap" "$fake_pid" ) &
  local watchdog_pid=$!

  # Send a spurious SIGTERM mid-phase-1 while the backend is still
  # alive. With the disarm bug, the watchdog would `exit 0` here and
  # leave the backend running forever; with the new trap, it sees the
  # backend is alive and ignores the signal.
  sleep 1
  kill -TERM "$watchdog_pid" 2>/dev/null || true

  # Watchdog should still finish within cap + grace + kill_grace +
  # jitter, having killed the backend.
  local watch_start watch_end watch_elapsed
  watch_start=$(date +%s)
  wait "$watchdog_pid" 2>/dev/null || true
  watch_end=$(date +%s)
  watch_elapsed=$(( watch_end - watch_start ))

  if kill -0 "$fake_pid" 2>/dev/null; then
    kill -KILL "$fake_pid" 2>/dev/null || true
    fail "Spurious SIGTERM disarmed the watchdog — backend survived"
  fi

  # cap (4s) + grace (2s) + kill_grace (2s) + buffer = 15s ceiling.
  # The watch_start above is post-SIGTERM, so we just need this remaining
  # window to fit the escalation. Allow generous parallel-bats slack.
  [ "$watch_elapsed" -le 15 ] || fail "Watchdog took ${watch_elapsed}s after spurious SIGTERM — too slow"

  grep -q 'test_session_watchdog escalation=SIGKILL' "$log_file" \
    || fail "Missing escalation=SIGKILL after spurious SIGTERM"
}

@test "watchdog exits cleanly when parent sends SIGTERM after backend already exited" {
  _load_watchdog_lib

  export DVB_SESSION_GRACE=15
  export DVB_WATCHDOG_KILL_GRACE=5
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  # Backend that exits immediately. The watchdog will be in its phase-1
  # sleep when the parent tears it down.
  local script="$TEST_DIR/fake-instant-backend"
  cat > "$script" <<SCRIPT
#!/bin/bash
exit 0
SCRIPT
  chmod +x "$script"
  "$script" &
  local fake_pid=$!
  wait "$fake_pid" 2>/dev/null || true

  # Cap large enough that the polling loop is the bottleneck if the
  # SIGTERM is ignored. Without the parent-teardown branch, the watchdog
  # waits up to 5s for the next poll iteration; with the branch it
  # exits within milliseconds. The rotation test (12s deadline, 3
  # sessions) was the regression that motivated this branch.
  local cap=300
  ( dvb_watchdog_run "test_session" "$cap" "$fake_pid" ) &
  local watchdog_pid=$!

  # Backend is dead; simulate parent tearing down the watchdog.
  local watch_start watch_end watch_elapsed
  watch_start=$(date +%s)
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  watch_end=$(date +%s)
  watch_elapsed=$(( watch_end - watch_start ))

  # Should exit within ~2s, not the full 5s polling interval.
  [ "$watch_elapsed" -le 3 ] || fail "Parent-teardown SIGTERM took ${watch_elapsed}s — should exit immediately when backend already dead"

  # No escalation markers — the watchdog never reached the cap.
  if grep -q 'escalation=' "$log_file"; then
    fail "Watchdog escalated on a clean parent-teardown path. Log:\n$(cat "$log_file")"
  fi
}

@test "watchdog returns immediately when backend exits gracefully (no escalation marker)" {
  _load_watchdog_lib

  export DVB_SESSION_GRACE=15
  export DVB_WATCHDOG_KILL_GRACE=5
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  # Quick-exit fake backend — runs for 1s then exits. The watchdog
  # should detect the dead PID via `kill -0` and return without ever
  # escalating.
  local script="$TEST_DIR/fake-quick-backend"
  cat > "$script" <<SCRIPT
#!/bin/bash
sleep 1
SCRIPT
  chmod +x "$script"
  "$script" &
  local fake_pid=$!

  local cap=30
  local watch_start watch_end watch_elapsed
  watch_start=$(date +%s)
  ( dvb_watchdog_run "test_session" "$cap" "$fake_pid" ) &
  local watchdog_pid=$!
  wait "$watchdog_pid"
  watch_end=$(date +%s)
  watch_elapsed=$(( watch_end - watch_start ))

  # Watchdog should exit within ~5s (one phase-1 poll + 1s sleep + jitter).
  # Critically it must NOT wait the full cap.
  [ "$watch_elapsed" -le 10 ] || fail "Watchdog ran ${watch_elapsed}s for a 1s backend — should exit on graceful backend exit"

  # No escalation markers on the graceful path.
  if grep -q 'escalation=SIGKILL\|escalation=SIGTERM\|escalation=SIGINT' "$log_file"; then
    fail "Watchdog escalated on a graceful exit. Log:\n$(cat "$log_file")"
  fi
}

@test "watchdog does not kill a cooperative backend (SIGINT alone is enough)" {
  _load_watchdog_lib

  export DVB_SESSION_GRACE=10
  export DVB_WATCHDOG_KILL_GRACE=5
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  # Cooperative backend — exits cleanly on SIGINT. Watchdog should
  # send SIGINT and then return without escalating to SIGTERM/SIGKILL.
  local script="$TEST_DIR/fake-cooperative-backend"
  cat > "$script" <<SCRIPT
#!/bin/bash
trap 'exit 0' INT
sleep 60
SCRIPT
  chmod +x "$script"
  "$script" &
  local fake_pid=$!

  local cap=2
  ( dvb_watchdog_run "test_session" "$cap" "$fake_pid" ) &
  local watchdog_pid=$!
  wait "$watchdog_pid"

  if kill -0 "$fake_pid" 2>/dev/null; then
    kill -KILL "$fake_pid" 2>/dev/null || true
    fail "Cooperative backend still alive after watchdog returned"
  fi

  grep -q 'test_session_watchdog escalation=SIGINT' "$log_file" \
    || fail "Missing escalation=SIGINT marker on the graceful-shutdown path"
  if grep -q 'test_session_watchdog escalation=SIGKILL' "$log_file"; then
    fail "Watchdog escalated to SIGKILL on a cooperative backend — should have stopped at SIGINT"
  fi
}

@test "watchdog emits legacy session_timeout marker for the session context" {
  _load_watchdog_lib

  export DVB_SESSION_GRACE=2
  export DVB_WATCHDOG_KILL_GRACE=2
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  _spawn_signal_ignoring_backend 60 1
  local fake_pid="$WATCHDOG_FAKE_PID"

  local cap=2
  ( dvb_watchdog_run "session" "$cap" "$fake_pid" \
      "session_timeout session=42 max=${cap}s" ) &
  local watchdog_pid=$!
  wait "$watchdog_pid"

  if kill -0 "$fake_pid" 2>/dev/null; then
    kill -KILL "$fake_pid" 2>/dev/null || true
  fi

  grep -q 'session_timeout session=42 max=2s' "$log_file" \
    || fail "Missing legacy session_timeout marker. Log:\n$(cat "$log_file")"
}

@test "watchdog SIGKILL marker reports elapsed time" {
  _load_watchdog_lib

  export DVB_SESSION_GRACE=2
  export DVB_WATCHDOG_KILL_GRACE=2
  export log_file="$TEST_DIR/watchdog.log"
  : > "$log_file"

  _spawn_signal_ignoring_backend 60 1
  local fake_pid="$WATCHDOG_FAKE_PID"

  local cap=2
  ( dvb_watchdog_run "sweep" "$cap" "$fake_pid" ) &
  local watchdog_pid=$!
  wait "$watchdog_pid"

  if kill -0 "$fake_pid" 2>/dev/null; then
    kill -KILL "$fake_pid" 2>/dev/null || true
  fi

  # The escalation line must include both pid= and elapsed= so post-
  # mortems can correlate cap overruns with backend instances.
  grep -qE 'sweep_watchdog escalation=SIGKILL pid=[0-9]+ elapsed=[0-9]+s' "$log_file" \
    || fail "SIGKILL marker missing pid/elapsed details. Log:\n$(cat "$log_file")"
}

# ── Structural / contract tests against bin/taskgrind ────────────────

@test "bin/taskgrind sources lib/watchdog.sh" {
  grep -q 'source.*lib/watchdog.sh' "$DVB_GRIND"
}

@test "bin/taskgrind invokes dvb_watchdog_run for session, sweep, and supervisor_repair contexts" {
  grep -q 'dvb_watchdog_run "session"' "$DVB_GRIND"
  grep -q 'dvb_watchdog_run "sweep"' "$DVB_GRIND"
  grep -q 'dvb_watchdog_run "supervisor_repair"' "$DVB_GRIND"
}

@test "bin/taskgrind no longer contains the trap-disarm bug pattern in watchdog blocks" {
  # The pattern `trap 'kill $! 2>/dev/null; exit 0' TERM` was the
  # self-disarm bug. Two non-watchdog spots (git-sync timeouts) still
  # use a similar shape — limit this assertion to the watchdog blocks
  # by checking that no `dvb_watchdog_run` site is preceded by this
  # exact trap line.
  ! awk '
    /trap '\''kill \$! 2>\/dev\/null; exit 0'\'' TERM/ { last = NR }
    /dvb_watchdog_run/ {
      if (last && (NR - last) < 30) {
        print "trap-disarm pattern within 30 lines before dvb_watchdog_run at line " NR
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$DVB_GRIND"
}

@test "DVB_DEFAULT_WATCHDOG_KILL_GRACE defaults to 5" {
  grep -Fq 'DVB_DEFAULT_WATCHDOG_KILL_GRACE="5"' "$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -Fq 'DVB_WATCHDOG_KILL_GRACE:-' "$WATCHDOG_LIB"
}
