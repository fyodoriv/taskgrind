#!/usr/bin/env bats
# Direct unit-style coverage for json_escape() in bin/taskgrind.
#
# json_escape() powers every string field in the JSON payload written by
# write_status_file() — repo, log_file, backend, skill, model,
# current_phase, terminal_reason, and last_session.{result,completed_at}. Today it is
# covered only through integration-level status-file assertions in
# tests/logging.bats, so a subtle regression in backslash/quote/newline/
# tab escaping (for example, a repo path containing a literal \", a CR,
# or a stray tab) would show up as a downstream JSON parse failure in a
# supervisor rather than as a focused helper failure.
#
# These tests extract the function body with awk (matching the established
# pattern for extract_first_task_context and format_conflict_paths_for_log),
# source it in a clean subshell, and assert on exact outputs. They do not
# require DVB_GRIND_CMD or a full session stub.

load test_helper

_extract_json_escape() {
  awk '/^json_escape\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_json_escape() {
  local value="$1"
  local fn
  fn=$(_extract_json_escape)
  run bash -c "$fn"$'\n'"json_escape \"\$1\"" _ "$value"
}

@test "json_escape: empty input yields empty output" {
  _run_json_escape ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "json_escape: plain ASCII passthrough leaves content unchanged" {
  _run_json_escape "hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == "hello world" ]]
}

@test "json_escape: embedded double quote becomes backslash-quote" {
  _run_json_escape 'say "hi"'
  [ "$status" -eq 0 ]
  [[ "$output" == 'say \"hi\"' ]]
}

@test "json_escape: literal backslash becomes double-backslash" {
  _run_json_escape 'path\\to\\file'
  [ "$status" -eq 0 ]
  [[ "$output" == 'path\\\\to\\\\file' ]]
}

@test "json_escape: embedded newline becomes \\n escape" {
  _run_json_escape $'line1\nline2'
  [ "$status" -eq 0 ]
  [[ "$output" == 'line1\nline2' ]]
}

@test "json_escape: embedded carriage return becomes \\r escape" {
  _run_json_escape $'line1\rline2'
  [ "$status" -eq 0 ]
  [[ "$output" == 'line1\rline2' ]]
}

@test "json_escape: embedded tab becomes \\t escape" {
  _run_json_escape $'col1\tcol2'
  [ "$status" -eq 0 ]
  [[ "$output" == 'col1\tcol2' ]]
}

@test "json_escape: backslash is escaped before quote so \\\" is not mis-parsed" {
  # Ordering matters: the function must escape backslashes first, otherwise
  # an input of \" would become \\\" (three chars escaped twice) instead of
  # the correct \\\" sequence that JSON parsers can round-trip.
  _run_json_escape '\"'
  [ "$status" -eq 0 ]
  # Input: one backslash + one double quote
  # Expected JSON-escaped: two backslashes + backslash + double quote
  [[ "$output" == '\\\"' ]]
}

@test "json_escape: combined repo path with quote and newline escapes both" {
  local payload
  payload=$'/tmp/repo with "quote"\nand newline'
  _run_json_escape "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == '/tmp/repo with \"quote\"\nand newline' ]]
}

@test "json_escape: result round-trips through python json.loads for every escape kind" {
  # Integration-style check: wrap the escaped value in a JSON string literal
  # and make sure python's standard json parser returns the original bytes.
  # This pins the contract write_status_file() actually depends on.
  local payload
  payload=$'tab\there "quoted" back\\slash\nnewline\rcarriage'
  _run_json_escape "$payload"
  [ "$status" -eq 0 ]
  local escaped="$output"

  local decoded
  decoded=$(ESCAPED="$escaped" python3 -c '
import json, os
print(json.loads("\"" + os.environ["ESCAPED"] + "\""), end="")
')
  [[ "$decoded" == "$payload" ]]
}
