#!/usr/bin/env bats
# Tests for --rotate-backends mid-flight backend rotation.
#
# Background: when taskgrind runs against a backend that hits a rate-limit,
# the run loses ~30 minutes of throughput per session in the rate-limit
# window because every session keeps re-trying the same exhausted backend.
# The --rotate-backends flag scans each session's output for rate-limit /
# quota / throttle patterns and advances to the next backend in the list
# on match, so a multi-hour grind keeps shipping by hopping to a backend
# on a different account.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

setup_fake_rotation_backends() {
  ROTATION_FAKE_BIN="$TEST_DIR/fake-bin"
  mkdir -p "$ROTATION_FAKE_BIN"

  cat > "$ROTATION_FAKE_BIN/backend-shim" <<'SCRIPT'
#!/bin/bash
binary_name="${0##*/}"
case "$binary_name" in
  claude) backend_name="claude-code" ;;
  *) backend_name="$binary_name" ;;
esac

if [[ "${1:-}" == "--version" ]]; then
  echo "$backend_name 0.0.1"
  exit 0
fi

echo "$backend_name $*" >> "${DVB_GRIND_INVOKE_LOG:?}"

if [[ ! -f "${ROTATION_SESSION_COUNTER:?}" ]]; then
  echo "0" > "$ROTATION_SESSION_COUNTER"
fi
session_number=$(cat "$ROTATION_SESSION_COUNTER")
session_number=$((session_number + 1))
echo "$session_number" > "$ROTATION_SESSION_COUNTER"

case "${ROTATION_SCENARIO:-}" in
  rate-limit-then-ship)
    if [[ "$backend_name" == "devin" && "$session_number" -eq 1 ]]; then
      echo "429 too many requests: rate limit hit"
      exit 0
    fi
    ;;
  self-investigate-then-ship)
    if [[ "$backend_name" == "claude-code" ]]; then
      echo "Still investigating; no task removed yet."
      exit 0
    fi
    ;;
  missing-next)
    if [[ "$backend_name" == "devin" && "$session_number" -eq 1 ]]; then
      echo "429 too many requests: rate limit hit"
      exit 0
    fi
    ;;
esac

cat > "${TEST_REPO:?}/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS

if [[ "${ROTATION_COMMIT_SHIP:-0}" == "1" ]]; then
  git -C "$TEST_REPO" add TASKS.md
  git -C "$TEST_REPO" commit -m "test: ship task" >/dev/null 2>&1 || true
fi
SCRIPT
  chmod +x "$ROTATION_FAKE_BIN/backend-shim"
  ln -sf "$ROTATION_FAKE_BIN/backend-shim" "$ROTATION_FAKE_BIN/devin"
  ln -sf "$ROTATION_FAKE_BIN/backend-shim" "$ROTATION_FAKE_BIN/claude"

  export ROTATION_FAKE_BIN
  export ROTATION_SESSION_COUNTER="$TEST_DIR/rotation-session-count"
  echo "0" > "$ROTATION_SESSION_COUNTER"

  export PATH="$ROTATION_FAKE_BIN:$PATH"
  export DVB_DEVIN_PATH="$ROTATION_FAKE_BIN/devin"
  export DVB_CAFFEINATED=1
  export DVB_SKIP_PREFLIGHT=1
  export DVB_SKIP_SWEEP_ON_EMPTY=1
  export DVB_SYNC_INTERVAL=999
  export DVB_COOL=0
  export DVB_MIN_SESSION=0
  export DVB_BACKOFF_BASE=0
  export DVB_EMPTY_QUEUE_WAIT=0
  export DVB_NOTIFY=0
  export TEST_REPO DVB_GRIND_INVOKE_LOG
  unset DVB_GRIND_CMD
}

# ── Static checks ────────────────────────────────────────────────────

@test "taskgrind has --rotate-backends flag with comma-separated value" {
  grep -q -- '--rotate-backends=' "$DVB_GRIND"
  grep -q -- '--rotate-backends)' "$DVB_GRIND"
}

@test "taskgrind respects DVB_ROTATE_BACKENDS env var" {
  grep -q 'DVB_ROTATE_BACKENDS' "$DVB_GRIND"
}

@test "taskgrind exposes TG_ROTATE_BACKENDS prefix-resolved env var" {
  grep -q 'ROTATE_BACKENDS' "$DVB_GRIND"
  grep -q 'TG_${_tg_var}' "$DVB_GRIND"
}

@test "taskgrind has _maybe_rotate_backend helper function" {
  grep -q '^_maybe_rotate_backend()' "$DVB_GRIND"
}

@test "taskgrind rotation patterns include common rate-limit keywords" {
  # Patterns must mirror bosun's BackendHealthService RATE_LIMIT_PATTERNS.
  grep -q 'rate.?limit' "$DVB_GRIND"
  grep -q '429' "$DVB_GRIND"
  grep -q 'too many requests' "$DVB_GRIND"
  grep -q 'hit your limit' "$DVB_GRIND"
  grep -q 'quota.?exceed' "$DVB_GRIND"
  grep -q 'throttl' "$DVB_GRIND"
}

@test "taskgrind rotation calls _maybe_rotate_backend after each session" {
  # Must be invoked AFTER session_end log but BEFORE session_output truncation,
  # otherwise the rate-limit detection has nothing to scan.
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
i_call = text.find('_maybe_rotate_backend "$session_output"')
i_truncate = text.find(': > "$session_output"')
assert i_call != -1, "rotation call missing from session loop"
assert i_truncate != -1, "session_output truncation missing"
assert i_call < i_truncate, "rotation must run BEFORE truncation, otherwise no input to scan"
PY
}

@test "backend rotation skip is non-fatal at call sites" {
  grep -q '_maybe_rotate_backend "$session_output" "rate_limit" || true' "$DVB_GRIND"
  grep -q '_maybe_rotate_backend "" "zero_ship_streak" || true' "$DVB_GRIND"
}

@test "taskgrind rotation help block documents --rotate-backends" {
  grep -q -- '--rotate-backends' "$DVB_GRIND" | head -1
  grep -q 'rotate-backends devin,claude-code,codex' "$DVB_GRIND"
}

# ── Integration ─────────────────────────────────────────────────────

@test "rotation: --rotate-backends flag is parsed without error" {
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" --rotate-backends devin,claude-code 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "rotation: --rotate-backends accepts =value syntax" {
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" --rotate-backends=devin,codex 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "rotation: --rotate-backends without value exits with clear error" {
  run "$DVB_GRIND" --rotate-backends 1 "$TEST_REPO"
  # When --rotate-backends consumes "1" as its value, the bare hours arg is
  # never seen — but the script should still report the missing comma-list
  # error path. The simpler expectation: the value "1" is accepted (it's a
  # one-element rotation list), then "$TEST_REPO" is a positional, no error.
  # Force the missing-value error by passing it as the LAST arg:
  run bash -c "'$DVB_GRIND' --rotate-backends"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires"* || "$output" == *"--rotate-backends"* ]]
}

@test "rotation: TG_ROTATE_BACKENDS env var seeds DVB_ROTATE_BACKENDS" {
  export TG_ROTATE_BACKENDS="claude-code,codex,devin"
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "rotation: empty rotation list (single element) is a no-op" {
  # A 1-element rotation list has no "next" to advance to; should not loop.
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" --rotate-backends devin 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "rotation: devin rate-limit rotates into claude-code and preserves session state" {
  setup_fake_rotation_backends
  init_test_repo
  git init --bare "$TEST_DIR/origin.git" >/dev/null
  git -C "$TEST_REPO" remote add origin "$TEST_DIR/origin.git"
  git -C "$TEST_REPO" push -u origin main --quiet

  echo "LIVE_ROTATION_PROMPT" > "$TEST_REPO/.taskgrind-prompt"
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  export DVB_STATUS_FILE="$TEST_DIR/status.json"
  export DVB_DEADLINE_OFFSET=12
  export ROTATION_SCENARIO="rate-limit-then-ship"
  export ROTATION_COMMIT_SHIP=1

  run "$DVB_GRIND" --no-push --backend devin --rotate-backends devin,claude-code \
    --prompt "CLI_ROTATION_PROMPT" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -q 'backend_rotated from=devin to=claude-code reason=rate_limit' "$TEST_LOG"
  grep -qE 'session_start session=1 .*backend=devin' "$TEST_LOG"
  grep -qE 'session_end session=1 .*shipped=0 .*backend=devin' "$TEST_LOG"
  grep -qE 'session_start session=2 .*backend=claude-code' "$TEST_LOG"
  grep -qE 'session_end session=2 .*shipped=1 .*backend=claude-code' "$TEST_LOG"
  grep -q 'final_sync would_push commits=1' "$TEST_LOG"
  grep -q 'grind_done sessions=2 shipped=1' "$TEST_LOG"

  grep -q -- 'devin --model claude-sonnet-4.6 --permission-mode dangerous' "$DVB_GRIND_INVOKE_LOG"
  grep -q -- 'claude-code --model claude-sonnet-4.6 --dangerously-skip-permissions' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'CLI_ROTATION_PROMPT' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'LIVE_ROTATION_PROMPT' "$DVB_GRIND_INVOKE_LOG"
  grep -q '"backend": "claude-code"' "$DVB_STATUS_FILE"
  grep -q '"current_phase": "complete"' "$DVB_STATUS_FILE"
  grep -q '"number": 2' "$DVB_STATUS_FILE"
  grep -q '"shipped": 1' "$DVB_STATUS_FILE"
  [ "$(grep -c '^[[:space:]]*- \[ \]' "$TEST_REPO/TASKS.md")" -eq 0 ]
}

@test "rotation: claude-code zero-ship self-investigation rotates back to devin" {
  setup_fake_rotation_backends
  export DVB_STATUS_FILE="$TEST_DIR/status.json"
  export DVB_DEADLINE_OFFSET=12
  export DVB_SELF_INVESTIGATE_ZERO_SHIP_STREAK=2
  export DVB_MAX_ZERO_SHIP=5
  export ROTATION_SCENARIO="self-investigate-then-ship"

  run "$DVB_GRIND" --backend claude-code --rotate-backends claude-code,devin \
    --prompt "SELF_INVESTIGATE_PROMPT" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -q 'self_investigate anomaly=zero_ship_streak streak=2 threshold=2 backend=claude-code' "$TEST_LOG"
  grep -q 'backend_rotated from=claude-code to=devin reason=zero_ship_streak' "$TEST_LOG"
  grep -qE 'session_start session=1 .*backend=claude-code' "$TEST_LOG"
  grep -qE 'session_start session=2 .*backend=claude-code' "$TEST_LOG"
  grep -qE 'session_start session=3 .*backend=devin' "$TEST_LOG"
  grep -qE 'session_end session=3 .*shipped=1 .*backend=devin' "$TEST_LOG"
  grep -q 'grind_done sessions=3 shipped=1' "$TEST_LOG"
  grep -q 'sessions_zero_ship=2' "$TEST_LOG"

  [ "$(grep -c '^claude-code ' "$DVB_GRIND_INVOKE_LOG")" -eq 2 ]
  [ "$(grep -c '^devin ' "$DVB_GRIND_INVOKE_LOG")" -eq 1 ]
  grep -q 'SELF_INVESTIGATE_PROMPT' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'WARNING: Previous 2 sessions shipped nothing' "$DVB_GRIND_INVOKE_LOG"
  grep -q '"backend": "devin"' "$DVB_STATUS_FILE"
  grep -q '"number": 3' "$DVB_STATUS_FILE"
  grep -q '"shipped": 1' "$DVB_STATUS_FILE"
}

@test "rotation: missing next backend binary skips safely and keeps current backend" {
  setup_fake_rotation_backends
  rm -f "$ROTATION_FAKE_BIN/claude"
  export PATH="$ROTATION_FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export DVB_STATUS_FILE="$TEST_DIR/status.json"
  export DVB_DEADLINE_OFFSET=12
  export ROTATION_SCENARIO="missing-next"

  run "$DVB_GRIND" --backend devin --rotate-backends devin,claude-code 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -q 'backend_rotation_skipped from=devin to=claude-code reason=binary_missing' "$TEST_LOG"
  grep -qE 'session_start session=1 .*backend=devin' "$TEST_LOG"
  grep -qE 'session_start session=2 .*backend=devin' "$TEST_LOG"
  grep -qE 'session_end session=2 .*shipped=1 .*backend=devin' "$TEST_LOG"
  ! grep -q '^claude-code ' "$DVB_GRIND_INVOKE_LOG"
  grep -q '"backend": "devin"' "$DVB_STATUS_FILE"
}

# ── Self-investigation hook ────────────────────────────────────────────

@test "self-investigate: _maybe_self_investigate function exists" {
  grep -q '^_maybe_self_investigate()' "$DVB_GRIND"
}

@test "self-investigate: zero_ship_streak threshold env var" {
  grep -q 'TG_SELF_INVESTIGATE_ZERO_SHIP_STREAK' "$DVB_GRIND"
  grep -q 'DVB_SELF_INVESTIGATE_ZERO_SHIP_STREAK' "$DVB_GRIND"
}

@test "self-investigate: hook runs after _maybe_rotate_backend in session loop" {
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
i_rotate = text.find('_maybe_rotate_backend "$session_output" "rate_limit"')
i_invest = text.find('_maybe_self_investigate')
assert i_rotate != -1, "_maybe_rotate_backend call missing"
assert i_invest != -1, "_maybe_self_investigate call missing"
# self-investigate may appear in the function definition AND in the call site;
# the call site must come AFTER the rotate call in the session loop.
i_invest_call = text.find('_maybe_self_investigate', i_rotate)
assert i_invest_call != -1, "_maybe_self_investigate call after rotate missing"
PY
}

@test "self-investigate: rotate-backends fires on zero_ship_streak (structural trigger)" {
  # When trigger_reason is not 'rate_limit', the rate-limit pattern check is skipped
  # — the rotation fires on accumulated state alone.
  grep -q 'zero_ship_streak' "$DVB_GRIND"
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
# The conditional guard inside _maybe_rotate_backend must skip pattern check
# when reason is not 'rate_limit'.
assert 'if [[ "$trigger_reason" == "rate_limit" ]]' in text, \
  "structural-trigger guard missing — pattern check would block zero_ship_streak rotation"
PY
}

@test "self-investigate: emits self_investigate log line for external observers" {
  grep -q 'self_investigate anomaly=' "$DVB_GRIND"
}
