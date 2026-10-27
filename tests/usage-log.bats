#!/usr/bin/env bats
# Tests for the local, content-free usage log (TG_USAGE_LOG) that feeds the
# README Proof section through scripts/proof.sh.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

@test "usage log: a finished grind appends one content-free JSON line" {
  export DVB_USAGE_LOG="$TEST_DIR/usage.jsonl"
  run_tiny_workload
  [ -f "$DVB_USAGE_LOG" ]
  [ "$(wc -l < "$DVB_USAGE_LOG" | tr -d ' ')" -eq 1 ]
  run python3 - "$DVB_USAGE_LOG" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).read())
want = {"v", "ts", "event", "ok", "reason", "backend", "sessions", "shipped",
        "zero_ship", "tasks_added", "remaining", "elapsed_s", "sweeps"}
assert set(row) == want, sorted(set(row) ^ want)
assert row["event"] == "grind" and row["ok"] is True
assert row["sessions"] >= 1 and row["shipped"] >= 1
PY
  [ "$status" -eq 0 ]
}

@test "usage log: holds no repo name, path, or task text" {
  export DVB_USAGE_LOG="$TEST_DIR/usage.jsonl"
  run_tiny_workload
  run cat "$DVB_USAGE_LOG"
  [[ "$output" != *"$(basename "$TEST_REPO")"* ]]
  [[ "$output" != *"/"* ]]
  [[ "$output" != *"Tiny workload"* ]]
}

@test "usage log: DO_NOT_TRACK=1 writes nothing" {
  export DVB_USAGE_LOG="$TEST_DIR/usage.jsonl"
  export DO_NOT_TRACK=1
  run_tiny_workload
  [ ! -e "$DVB_USAGE_LOG" ]
}

@test "usage log: TG_USAGE_LOG=off writes nothing" {
  export TG_USAGE_LOG=off
  run_tiny_workload
  [ ! -e "$HOME/.local/state/taskgrind/usage.jsonl" ]
  unset TG_USAGE_LOG
}

@test "usage log: fake-backend runs write no default log" {
  unset DVB_USAGE_LOG TG_USAGE_LOG
  run_tiny_workload
  [ ! -e "$HOME/.local/state/taskgrind/usage.jsonl" ]
}

@test "usage log: preflight appends one content-free line with the failed check count" {
  export DVB_USAGE_LOG="$TEST_DIR/usage.jsonl"
  # A missing backend binary fails the backend check.
  export DVB_GRIND_CMD="$TEST_DIR/no-such-backend"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 1 ]
  fails=$(printf '%s\n' "$output" | sed -n 's/.*Results: .* \([0-9][0-9]*\) failed.*/\1/p')
  [ "$(wc -l < "$DVB_USAGE_LOG" | tr -d ' ')" -eq 1 ]
  run python3 - "$DVB_USAGE_LOG" "$fails" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).read())
assert set(row) == {"v", "ts", "event", "ok", "failed_checks"}, sorted(row)
assert row["event"] == "preflight" and row["ok"] is False
assert row["failed_checks"] == int(sys.argv[2]) and row["failed_checks"] >= 1
PY
  [ "$status" -eq 0 ]
  run cat "$DVB_USAGE_LOG"
  [[ "$output" != *"/"* ]]
}

@test "usage log: fake-backend preflight writes no default log" {
  unset DVB_USAGE_LOG TG_USAGE_LOG
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ ! -e "$HOME/.local/state/taskgrind/usage.jsonl" ]
}
