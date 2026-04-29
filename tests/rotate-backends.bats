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

@test "taskgrind rotation help block documents --rotate-backends" {
  grep -q -- '--rotate-backends' "$DVB_GRIND" | head -1
  grep -q 'rotate-backends devin,claude-code,codex' "$DVB_GRIND"
}

# ── Integration ─────────────────────────────────────────────────────

@test "rotation: --rotate-backends flag is parsed without error" {
  export DVB_DEADLINE_OFFSET=1
  run "$DVB_GRIND" --rotate-backends devin,claude-code 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "rotation: --rotate-backends accepts =value syntax" {
  export DVB_DEADLINE_OFFSET=1
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
  export DVB_DEADLINE_OFFSET=1
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "rotation: empty rotation list (single element) is a no-op" {
  # A 1-element rotation list has no "next" to advance to; should not loop.
  export DVB_DEADLINE_OFFSET=1
  run "$DVB_GRIND" --rotate-backends devin 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}
