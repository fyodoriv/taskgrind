#!/usr/bin/env bats
# The README Proof section must match what scripts/proof.sh writes, and each
# saved metric must carry its value, unit, date, data kind, and command.

REPO_DIR="$BATS_TEST_DIRNAME/.."
PROOF="$REPO_DIR/scripts/proof.sh"

setup() {
  command -v jq >/dev/null || skip "jq not installed"
  SCRATCH="$(mktemp -d "${BATS_TMPDIR:-/tmp}/proof.XXXXXX")"
}

teardown() {
  rm -rf "$SCRATCH"
}

@test "proof: the README section equals the generator output" {
  run "$PROOF" --render
  [ "$status" -eq 0 ]
  expected="$output"
  actual="$(awk '/<!-- proof:start -->/{f=1} f{print} /<!-- proof:end -->/{f=0}' "$REPO_DIR/README.md")"
  if [ "$expected" != "$actual" ]; then
    echo "README Proof section is stale: run scripts/proof.sh" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "proof: the saved metrics pass validation" {
  run "$PROOF" --validate "$REPO_DIR/docs/proof/metrics.json"
  [ "$status" -eq 0 ]
}

@test "proof: validation fails on a metric with no date, kind, or command" {
  printf '%s\n' '{"metrics":{"x":{"value":1,"unit":"ms","date":"","kind":"","command":""}}}' >"$SCRATCH/bad.json"
  run "$PROOF" --validate "$SCRATCH/bad.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"metric x has no date"* ]]
  [[ "$output" == *"metric x has no kind"* ]]
  [[ "$output" == *"metric x has no command"* ]]
}

@test "proof: collect turns usage lines into real-use field metrics" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '{"v":1,"ts":"%s","event":"grind","ok":true,"reason":"queue_empty","backend":"claude-code","sessions":4,"shipped":3,"zero_ship":1,"tasks_added":0,"remaining":0,"elapsed_s":7200,"sweeps":0}\n' "$now"
    printf '{"v":1,"ts":"%s","event":"grind","ok":false,"reason":"failed","backend":"codex","sessions":2,"shipped":0,"zero_ship":2,"tasks_added":0,"remaining":5,"elapsed_s":3600,"sweeps":0}\n' "$now"
  } >"$SCRATCH/usage.jsonl"
  XDG_STATE_HOME="$SCRATCH/state" TG_USAGE_LOG="$SCRATCH/usage.jsonl" run "$PROOF" --collect "$SCRATCH/m.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metrics.tasks_shipped_30d.value' "$SCRATCH/m.json")" = "3" ]
  [ "$(jq -r '.metrics.grinds_ok_pct.value' "$SCRATCH/m.json")" = "50" ]
  [ "$(jq -r '.metrics.tasks_per_hour.value' "$SCRATCH/m.json")" = "1" ]
  [ "$(jq -r '.metrics.zero_ship_session_pct.value' "$SCRATCH/m.json")" = "50" ]
  [ "$(jq -r '.metrics.tasks_shipped_30d.kind' "$SCRATCH/m.json")" = "real use" ]
  # The machine label is a salted hash, never the host name.
  run jq -r '.machines | keys[]' "$SCRATCH/m.json"
  [[ "$output" =~ ^m-[0-9a-f]{10}$ ]]
  [[ "$output" != *"$(hostname)"* ]]
  TG_PROOF_METRICS="$SCRATCH/m.json" run "$PROOF" --render
  [[ "$output" == *"3 tasks"* ]]
  [[ "$output" == *"pie title How grinds stopped"* ]]
}

@test "proof: with no field data, headline rows say not measured yet" {
  XDG_STATE_HOME="$SCRATCH/state" TG_USAGE_LOG="$SCRATCH/none.jsonl" run "$PROOF" --collect "$SCRATCH/m.json"
  # No field metric and no timing: nothing to save, so validation fails loudly.
  [ "$status" -ne 0 ]
  printf '%s\n' '{"metrics":{"dry_run_ms":{"value":5,"unit":"ms","date":"2026-10-27","kind":"local run","command":"scripts/proof.sh","history":[{"date":"2026-10-27","value":5}]}},"charts":{"shipped_by_day":[],"stop_reasons_30d":[]},"recording_since":"2026-10-27","machines":{}}' >"$SCRATCH/m.json"
  TG_PROOF_METRICS="$SCRATCH/m.json" run "$PROOF" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"| tasks shipped, last 30 days | not measured yet (field recording on since 2026-10-27)"* ]]
  [[ "$output" == *'```mermaid'* ]]
}

@test "proof: collect counts preflight runs that caught a failed check" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '{"v":1,"ts":"%s","event":"grind","ok":true,"reason":"queue_empty","backend":"codex","sessions":1,"shipped":1,"zero_ship":0,"tasks_added":0,"remaining":0,"elapsed_s":600,"sweeps":0}\n' "$now"
    printf '{"v":1,"ts":"%s","event":"preflight","ok":false,"failed_checks":2}\n' "$now"
    printf '{"v":1,"ts":"%s","event":"preflight","ok":true,"failed_checks":0}\n' "$now"
    printf '{"v":1,"ts":"%s","event":"preflight","ok":true,"failed_checks":0}\n' "$now"
    printf '{"v":1,"ts":"%s","event":"preflight","ok":true,"failed_checks":0}\n' "$now"
  } >"$SCRATCH/usage.jsonl"
  XDG_STATE_HOME="$SCRATCH/state" TG_USAGE_LOG="$SCRATCH/usage.jsonl" run "$PROOF" --collect "$SCRATCH/m.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metrics.preflight_fail_pct.value' "$SCRATCH/m.json")" = "25" ]
  # Preflight lines never count as grinds.
  [ "$(jq -r '.metrics.grinds_30d.value' "$SCRATCH/m.json")" = "1" ]
  TG_PROOF_METRICS="$SCRATCH/m.json" run "$PROOF" --render
  [[ "$output" == *"| Preflight catches setup errors before a long run |"*"| 25 % (preflight runs that caught at least one failed check, of 4 runs) |"* ]]
}
