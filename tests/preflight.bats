#!/usr/bin/env bats
# Tests for taskgrind — preflight health checks
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Preflight health checks ───────────────────────────────────────────

@test "--preflight runs health checks and exits 0 on healthy repo" {
  _preflight_git_init
  # Add TASKS.md
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"taskgrind --preflight"* ]]
  [[ "$output" == *"Preflight checks for:"* ]]
  [[ "$output" == *"Backend binary"* ]]
}

@test "--preflight shows config header" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo:"* ]]
  [[ "$output" == *"skill:    fleet-grind"* ]]
  [[ "$output" == *"model:"* ]]
}

@test "--preflight shows prompt if provided" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight --prompt "test focus" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt:   test focus"* ]]
}

@test "--preflight omits prompt line when no --prompt given" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"prompt:"* ]]
}

@test "--preflight does not create log file" {
  local pf_log="$TEST_DIR/preflight.log"
  export DVB_LOG="$pf_log"
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$pf_log" ]
}

@test "--preflight does not launch any devin sessions" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "--preflight does not create lockfile" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  # No lockfile should exist for the TEST_REPO
  local _tmp="${TMPDIR:-/tmp}"
  _tmp="${_tmp%/}"
  local lock_hash
  lock_hash=$(echo "$TEST_REPO" | shasum | cut -d' ' -f1)
  [ ! -f "$_tmp/taskgrind-lock-${lock_hash}" ]
}

@test "--preflight shows pass/warn/fail counts in summary" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Results:"* ]]
  [[ "$output" == *"passed"* ]]
}

@test "preflight detects mid-rebase git state" {
  _preflight_git_init
  # Simulate mid-rebase state
  mkdir -p "$TEST_REPO/.git/rebase-merge"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  # Should still exit 0 (warn, not fail) because rebase is one factor
  [[ "$output" == *"rebase in progress"* ]]
}

@test "preflight detects mid-merge git state" {
  _preflight_git_init
  # Simulate mid-merge state
  touch "$TEST_REPO/.git/MERGE_HEAD"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [[ "$output" == *"merge in progress"* ]]
}

@test "preflight warns when TASKS.md is missing" {
  _preflight_git_init
  # Remove TASKS.md from repo (setup creates one by default)
  rm -f "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASKS.md not found"* ]]
}

@test "preflight shows task count when TASKS.md exists" {
  _preflight_git_init
  cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] First task
- [ ] Second task
## P1
- [ ] Third task
EOF
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASKS.md found (3 open tasks)"* ]]
}

@test "preflight warns on non-git repo" {
  # TEST_REPO is not a git repo
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not a git repository"* ]]
}

@test "preflight warns when no git remote configured" {
  _preflight_git_init
  # No remote added
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No git remote configured"* ]]
}

@test "preflight runs before main loop and blocks on failure" {
  # Structural: preflight_check is called before the while loop
  grep -q 'preflight_check' "$DVB_GRIND"
  grep -q 'preflight_failed' "$DVB_GRIND"
}

@test "preflight has all 8 checks" {
  # Structural: verify all 8 check categories exist
  grep -q 'Backend binary' "$DVB_GRIND"
  grep -q 'Model accepted by' "$DVB_GRIND"
  grep -q 'Network connectivity' "$DVB_GRIND"
  grep -q 'Git state clean' "$DVB_GRIND"
  grep -q 'Git remote reachable' "$DVB_GRIND"
  grep -q 'Disk space' "$DVB_GRIND"
  grep -q 'TASKS.md' "$DVB_GRIND"
  grep -q 'network-watchdog' "$DVB_GRIND"
}

@test "preflight check passes in test mode with DVB_GRIND_CMD" {
  _preflight_git_init
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test mode"* ]]
}

@test "preflight rejects unknown model before the session loop" {
  local validating_devin="$TEST_DIR/validating-devin"
  cat > "$validating_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
if [[ "$*" == *"--help"* ]] && [[ "$*" == *"--model invalid-model"* ]]; then
  echo "Error: Unknown model: 'invalid-model'" >&2
  exit 1
fi
exit 0
SCRIPT
  chmod +x "$validating_devin"
  export DVB_GRIND_CMD="$validating_devin"
  export DVB_VALIDATE_MODEL=1
  _preflight_git_init

  run "$DVB_GRIND" --model invalid-model 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown model: 'invalid-model'"* ]]
  [[ "$output" == *"before starting"* ]]

  local invoke_count
  invoke_count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$invoke_count" -eq 1 ]
  grep -q -- '--help' "$DVB_GRIND_INVOKE_LOG"
}

@test "preflight disk space check runs" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disk space"* ]]
}

@test "main loop preflight blocks launch on failure" {
  # Force preflight failure by pointing DVB_DEVIN_PATH to nonexistent binary.
  # Must unset DVB_GRIND_CMD so the binary check runs (not skipped in test mode).
  # Can't rely on HOME alone — command -v devin finds the real binary in PATH.
  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="/nonexistent/bin/devin"
  export DVB_CAFFEINATED=1
  export _DVB_SELF_COPY="/dev/null"
  export DVB_DEADLINE=$(($(date +%s) + 60))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Preflight FAILED"* ]] || [[ "$output" == *"not found"* ]]
}

