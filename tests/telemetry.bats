#!/usr/bin/env bats
# Tests for bin/taskgrind-telemetry: opt-in usage counts to PostHog EU.
# No test sends anything real: a fake curl records the request instead.

load test_helper

# This file defines its own setup(): it needs no fixture repo.

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
  export TG_USAGE_LOG="$TEST_DIR/usage.jsonl"
  export TASKGRIND_TELEMETRY_STATE="$TEST_DIR/telemetry.json"
  export TASKGRIND_TELEMETRY_URL="http://127.0.0.1:9/fake"
  export TASKGRIND_POSTHOG_KEY="phc_test_fake_key"
  unset DO_NOT_TRACK
  FAKE="$TEST_DIR/fake-curl"
  cat >"$FAKE" <<'SH'
#!/bin/bash
cat >>"${FAKE_LOG:?}"
echo >>"$FAKE_LOG"
printf '%s' "${FAKE_CODE:-200}"
SH
  chmod +x "$FAKE"
  export TASKGRIND_TELEMETRY_CURL="$FAKE" FAKE_LOG="$TEST_DIR/requests.log"
  TEL="$BATS_TEST_DIRNAME/../bin/taskgrind-telemetry"
  printf '%s\n' \
    '{"v":1,"ts":"2026-10-26T10:00:00Z","event":"grind","ok":true,"reason":"deadline","backend":"claude-code","sessions":3,"shipped":2}' \
    '{"v":1,"ts":"2026-10-26T11:00:00Z","event":"grind","ok":false,"reason":"canary text here","backend":"codex","sessions":1,"shipped":0,"repo":"secret-canary","path":"canary-dir/secret.txt"}' \
    >"$TG_USAGE_LOG"
}

@test "send --dry-run prints only allowlisted fields and hides the key" {
  run bash "$TEL" send --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"api_key": "<posthog_key>"'* ]]
  [[ "$output" == *'"event": "taskgrind.grind"'* ]]
  # shellcheck disable=SC2016 # literal $ in the expected JSON key
  [[ "$output" == *'"$process_person_profile": false'* ]]
  # shellcheck disable=SC2016 # literal $ in the expected JSON key
  [[ "$output" == *'"$geoip_disable": true'* ]]
  [[ "$output" != *canary* ]]
  [[ "$output" != *phc_test* ]]
  [ ! -f "$FAKE_LOG" ]
}

@test "send posts the pending events once, then nothing new" {
  run bash "$TEL" send
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent 2 event(s)"* ]]
  [ "$(jq -s 'length' "$FAKE_LOG")" -eq 1 ]
  [ "$(jq -s '.[0].batch | length' "$FAKE_LOG")" -eq 2 ]
  run grep -q canary "$FAKE_LOG"
  [ "$status" -ne 0 ]
  run bash "$TEL" send
  [[ "$output" == *"nothing new"* ]]
  [ "$(jq -s 'length' "$FAKE_LOG")" -eq 1 ]
}

@test "no key sends nothing" {
  export TASKGRIND_POSTHOG_KEY=""
  run bash "$TEL" send
  [[ "$output" == *"no key"* ]]
  [ ! -f "$FAKE_LOG" ]
}

@test "DO_NOT_TRACK and telemetry off send nothing" {
  DO_NOT_TRACK=1 run bash "$TEL" send
  [[ "$output" == *"DO_NOT_TRACK"* ]]
  bash "$TEL" off
  run bash "$TEL" send
  [[ "$output" == *"turned off"* ]]
  [ ! -f "$FAKE_LOG" ]
  run bash "$TEL" status
  [[ "$output" == *"telemetry: off"* ]]
}

@test "a failed send keeps the cursor and never fails" {
  FAKE_CODE=500 run bash "$TEL" send
  [ "$status" -eq 0 ]
  [[ "$output" == *"send failed"* ]]
  [ "$(jq -r .sent "$TASKGRIND_TELEMETRY_STATE")" = "0" ]
}

@test "daily sends only after the notice, and once a day" {
  bash "$TEL" daily
  [ ! -f "$FAKE_LOG" ]
  run bash "$TEL" notice
  [[ "$output" == *"anonymous usage counts"* ]]
  run bash "$TEL" notice
  [ -z "$output" ]
  bash "$TEL" daily
  [ "$(jq -s 'length' "$FAKE_LOG")" -eq 1 ]
  echo '{"v":1,"ts":"2026-10-26T12:00:00Z","event":"grind","ok":true,"sessions":1}' >>"$TG_USAGE_LOG"
  bash "$TEL" daily
  [ "$(jq -s 'length' "$FAKE_LOG")" -eq 1 ]
}

@test "the state file is private" {
  bash "$TEL" status >/dev/null
  [ "$(stat -c %a "$TASKGRIND_TELEMETRY_STATE" 2>/dev/null || stat -f %Lp "$TASKGRIND_TELEMETRY_STATE")" = "600" ]
}

@test "taskgrind telemetry dispatches to the adapter" {
  run bash "$BATS_TEST_DIRNAME/../bin/taskgrind" telemetry send --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"api_key": "<posthog_key>"'* ]]
}
