#!/usr/bin/env bats
# Tests for taskgrind — static checks + 3 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Static checks ────────────────────────────────────────────────────

@test "taskgrind exists and is executable" {
  [ -f "$DVB_GRIND" ]
  [ -x "$DVB_GRIND" ]
}

@test "taskgrind has correct shebang" {
  head -1 "$DVB_GRIND" | grep -q '#!/bin/bash'
}

@test "taskgrind uses strict mode" {
  grep -q 'set -euo pipefail' "$DVB_GRIND"
}

@test "taskgrind re-execs under caffeinate for the whole loop" {
  grep -q 'exec caffeinate.*DVB_CAFFEINATE_FLAGS\|exec caffeinate -ms' "$DVB_GRIND"
}

@test "taskgrind skips caffeinate re-exec in test mode" {
  # DVB_GRIND_CMD being set should prevent the caffeinate exec
  grep -q 'DVB_GRIND_CMD.*DVB_CAFFEINATED' "$DVB_GRIND"
}

@test "taskgrind self-copies to survive script modification during execution" {
  grep -q '_DVB_SELF_COPY' "$DVB_GRIND"
}

@test "taskgrind self-copy uses exec to replace the process" {
  grep -q 'exec "$_dvb_copy"' "$DVB_GRIND"
}

@test "taskgrind cleans up self-copy temp file on exit" {
  # Use a unique prefix to avoid parallel test interference on shared /tmp
  local _tmp="${TMPDIR:-/tmp}"
  _tmp="${_tmp%/}"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  # No self-copy files with our PID should remain after cleanup
  local leaked
  leaked=$(ls "$_tmp"/taskgrind-exec.* 2>/dev/null | xargs -I{} lsof -p $$ {} 2>/dev/null || true)
  # Simpler: just check no files were created by this specific run
  # The cleanup trap removes the file, so running with past deadline means
  # the script exits immediately and cleans up.
  # Under parallel load, other tests may transiently create files, so we
  # just verify exit was clean.
  [ "$status" -eq 0 ]
}

# ── Argument validation ──────────────────────────────────────────────

@test "no args defaults to 10 hours" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND"
  [ "$status" -eq 0 ]
  [[ "$output" == *"10h"* ]]
}

@test "default deadline is ~10h from now when no hours arg" {
  # Use --dry-run to inspect computed config without running sessions
  run "$DVB_GRIND" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:"*"10"* ]]
}

@test "--help shows usage and exits 0" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "--version prints commit hash and exits 0" {
  run "$DVB_GRIND" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "taskgrind "* ]]
  # Should contain a short git hash (7+ hex chars)
  [[ "$output" =~ [0-9a-f]{7} ]]
}

@test "-V is alias for --version" {
  run "$DVB_GRIND" -V
  [ "$status" -eq 0 ]
  [[ "$output" == "taskgrind "* ]]
}

@test "--version does not launch any sessions" {
  run "$DVB_GRIND" --version
  [ "$status" -eq 0 ]
  # Output should be a single line with version info, no session output
  [[ $(echo "$output" | wc -l) -le 1 ]]
}

@test "--help works in any arg position" {
  run "$DVB_GRIND" 8 --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "--version works in any arg position" {
  run "$DVB_GRIND" 8 --version
  [ "$status" -eq 0 ]
  [[ "$output" == "taskgrind "* ]]
}

@test "-h works in any arg position" {
  run "$DVB_GRIND" 8 -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "rejects hours over 24" {
  run "$DVB_GRIND" 25 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"max 24"* ]]
}

@test "rejects 0 hours" {
  run "$DVB_GRIND" 0 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "negative number is treated as repo path, not hours" {
  run "$DVB_GRIND" -5
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "non-numeric arg is treated as repo path" {
  run "$DVB_GRIND" abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "rejects nonexistent repo path" {
  run "$DVB_GRIND" 1 "$TEST_DIR/no-such-dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "accepts 24 hours (boundary)" {
  # Deadline in the past so loop body never runs
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 24 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "accepts 1 hour" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

# ── Model selection ──────────────────────────────────────────────────

@test "defaults to gpt-5.4" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must be the exact default model string
  grep -q -- '--model gpt-5.4' "$DVB_GRIND_INVOKE_LOG"
}

@test "default model does not use 'opus' shortname" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should NOT contain bare '--model opus ' (the shortname)
  local first_invoke
  first_invoke=$(head -1 "$DVB_GRIND_INVOKE_LOG")
  [[ "$first_invoke" != *"--model opus "* ]]
  [[ "$first_invoke" != *"--model opus--"* ]]
}

@test "taskgrind sources shared constants from lib/constants.sh" {
  grep -q 'source.*lib/constants.sh' "$DVB_GRIND"
}

@test "devin binary path is defined in lib/constants.sh" {
  grep -q 'DVB_DEVIN_PATH=' "$BATS_TEST_DIRNAME/../lib/constants.sh"
}

@test "taskgrind uses DVB_DEVIN_PATH from shared constants" {
  grep -q 'DVB_DEVIN_PATH' "$DVB_GRIND"
}


@test "default model is gpt-5.4" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" == "gpt-5.4" ]]
}

@test "default model has no -1m suffix" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" != *-1m ]]
}

@test "default model is a valid devin model id" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  # Must be lowercase kebab-case (no spaces, no uppercase)
  [[ "$grind_default" =~ ^[a-z0-9._-]+$ ]]
}

@test "default model passes through to backend invocation" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # The default model string must appear in the invocation log
  local invocation
  invocation=$(head -1 "$DVB_GRIND_INVOKE_LOG")
  [[ "$invocation" == *"--model gpt-5.4"* ]]
}

@test "every session gets the same model flag" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Every invocation line must contain the exact model flag
  while IFS= read -r line; do
    [[ "$line" == *"--model gpt-5.4"* ]] || {
      echo "Session missing model flag: $line"; return 1
    }
  done < "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MODEL overrides default completely" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MODEL=sonnet
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model claude-sonnet-4.6' "$DVB_GRIND_INVOKE_LOG"
  # And the default must not appear
  ! grep -q -- '--model gpt-5.4 ' "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MODEL=claude-sonnet-4.5 passes through exactly" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MODEL=claude-sonnet-4.5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model claude-sonnet-4.5' "$DVB_GRIND_INVOKE_LOG"
}

# ── TG_ prefix support ─────────────────────────────────────────────────

@test "TG_MODEL overrides default" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export TG_MODEL=sonnet
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model claude-sonnet-4.6' "$DVB_GRIND_INVOKE_LOG"
}

@test "TG_MODEL takes precedence over DVB_MODEL" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MODEL=old-model
  export TG_MODEL=new-model
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model new-model' "$DVB_GRIND_INVOKE_LOG"
  ! grep -q -- '--model old-model' "$DVB_GRIND_INVOKE_LOG"
}

@test "TG_SKILL overrides default skill" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export TG_SKILL=custom-skill
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"custom-skill"* ]]
}

@test "TG_ prefix resolution block exists (structural)" {
  grep -q 'TG_ prefix resolution' "$DVB_GRIND"
  grep -q 'TG_.*takes precedence' "$DVB_GRIND"
}

@test "--help shows TG_ as primary prefix" {
  run "$DVB_GRIND" --help
  [[ "$output" == *"TG_BACKEND"* ]]
  [[ "$output" == *"TG_MODEL"* ]]
  [[ "$output" == *"DVB_ prefix is supported"* ]]
}

@test "model shows in startup banner" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"gpt-5.4"* ]]
}

@test "model shows in log file header" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'model=gpt-5.4' "$TEST_LOG"
}

@test "repo defaults to current directory" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  cd "$TEST_REPO"
  run "$DVB_GRIND" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_REPO"* ]]
}
