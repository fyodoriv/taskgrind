#!/usr/bin/env bats

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

wait_for_resume_session() {
  local state_file="$1"
  local expected_session="$2"
  local attempts=0
  while [[ "$attempts" -lt 50 ]]; do
    if [[ -f "$state_file" ]] && grep -q "^session=$expected_session\$" "$state_file"; then
      return 0
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

@test "writes resumable runtime state for an interrupted run" {
  local state_file="$TEST_DIR/resume-state"
  local slow_devin="$TEST_DIR/slow-devin"
  create_fake_devin "$slow_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG}"
sleep 5
SCRIPT
  export DVB_GRIND_CMD="$slow_devin"
  export DVB_STATE_FILE="$state_file"
  export DVB_DEADLINE_OFFSET=30

  "$DVB_GRIND" 1 "$TEST_REPO" >"$TEST_DIR/stdout.log" 2>"$TEST_DIR/stderr.log" &
  local grind_pid=$!

  wait_for_resume_session "$state_file" 1
  grep -q "^status=running$" "$state_file"
  grep -q "^backend=devin$" "$state_file"
  grep -q "^skill=next-task$" "$state_file"
  grep -q "^model=gpt-5-5-xhigh-priority$" "$state_file"
  grep -q "^startup_prompt=$" "$state_file"

  kill -9 "$grind_pid"
  wait "$grind_pid" 2>/dev/null || true
}

@test "--resume restores counters and clears state after clean completion" {
  local state_file="$TEST_DIR/resume-state"
  local counter_file="$TEST_DIR/resume-counter"
  local resumable_devin="$TEST_DIR/resumable-devin"
  echo "0" > "$counter_file"
  create_fake_devin "$resumable_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "${DVB_GRIND_INVOKE_LOG}"
count=\$(cat "$counter_file")
count=\$((count + 1))
echo "\$count" > "$counter_file"
if [[ "\$count" -eq 1 ]]; then
  sleep 5
else
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
fi
SCRIPT
  export DVB_GRIND_CMD="$resumable_devin"
  export DVB_STATE_FILE="$state_file"
  export DVB_DEADLINE_OFFSET=30

  "$DVB_GRIND" 1 "$TEST_REPO" >"$TEST_DIR/stdout.log" 2>"$TEST_DIR/stderr.log" &
  local grind_pid=$!
  wait_for_resume_session "$state_file" 1
  kill -9 "$grind_pid"
  wait "$grind_pid" 2>/dev/null || true

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -q 'Session 2' "$DVB_GRIND_INVOKE_LOG"
  [ ! -f "$state_file" ]
}

@test "--resume rejects incompatible saved state" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"
  cat > "$state_file" <<EOF
version=999
repo=$TEST_REPO
status=running
deadline=123
session=1
tasks_shipped=0
sessions_zero_ship=0
consecutive_zero_ship=0
backend=devin
skill=next-task
model=gpt-5-5-xhigh-priority
startup_model=gpt-5-5-xhigh-priority
EOF

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: version mismatch"* ]]
}

@test "--resume rejects expired saved state" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"
  cat > "$state_file" <<EOF
version=1
repo=$TEST_REPO
status=running
deadline=$(( $(date +%s) - 60 ))
session=1
tasks_shipped=0
sessions_zero_ship=0
consecutive_zero_ship=0
backend=devin
skill=next-task
model=gpt-5-5-xhigh-priority
startup_model=gpt-5-5-xhigh-priority
EOF

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: deadline expired"* ]]
  [[ "$output" == *"start a fresh grind"* ]]
}

@test "--resume rejects non-running saved states" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO" \
    "status=done"

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: state is not resumable (status=done)"* ]]
}

@test "--resume rejects malformed numeric fields" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO" \
    "deadline=not-a-number"

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: state file is malformed"* ]]
}

@test "--resume rejects saved state from another repo" {
  local state_file="$TEST_DIR/resume-state"
  local other_repo="$TEST_DIR/other-repo"
  export DVB_STATE_FILE="$state_file"

  mkdir -p "$other_repo"
  write_resume_state_file "$state_file" \
    "repo=$other_repo"

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: repo mismatch"* ]]
}

@test "--resume rejects backend override mismatches" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO"

  run "$DVB_GRIND" --resume "$TEST_REPO" --backend claude-code

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: backend override does not match saved state"* ]]
}

@test "--resume accepts matching claude-code backend state" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"
  prepare_tiny_workload

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO" \
    "session=1" \
    "backend=claude-code"

  run "$DVB_GRIND" --resume "$TEST_REPO" --backend claude-code

  [ "$status" -eq 0 ]
  [[ "$output" == *"Resuming: session=1"* ]]
  grep -q -- '--dangerously-skip-permissions' "$DVB_GRIND_INVOKE_LOG"
  [ ! -f "$state_file" ]
}

@test "--resume rejects claude-code state when backend override asks for devin" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO" \
    "backend=claude-code"

  run "$DVB_GRIND" --resume "$TEST_REPO" --backend devin

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: backend override does not match saved state"* ]]
}

@test "--resume rejects model override mismatches" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO"

  run "$DVB_GRIND" --resume "$TEST_REPO" --model claude-opus-4-6

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: model override does not match saved state"* ]]
}

@test "--resume rejects skill override mismatches" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO"

  run "$DVB_GRIND" --resume "$TEST_REPO" --skill standing-audit-gap-loop

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: skill does not match saved state"* ]]
}

@test "--resume restores the saved startup prompt and keeps live prompt overlays" {
  local state_file="$TEST_DIR/resume-state"
  local counter_file="$TEST_DIR/resume-counter"
  local resumable_devin="$TEST_DIR/resumable-devin"
  echo "0" > "$counter_file"
  create_fake_devin "$resumable_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "${DVB_GRIND_INVOKE_LOG}"
count=\$(cat "$counter_file")
count=\$((count + 1))
echo "\$count" > "$counter_file"
if [[ "\$count" -eq 1 ]]; then
  sleep 5
else
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
fi
SCRIPT
  export DVB_GRIND_CMD="$resumable_devin"
  export DVB_STATE_FILE="$state_file"
  export DVB_DEADLINE_OFFSET=30

  "$DVB_GRIND" --prompt "focus on backend docs" 1 "$TEST_REPO" >"$TEST_DIR/stdout.log" 2>"$TEST_DIR/stderr.log" &
  local grind_pid=$!
  wait_for_resume_session "$state_file" 1
  grep -q "^startup_prompt=focus on backend docs$" "$state_file"
  printf 'prefer fast loops' > "$TEST_REPO/.taskgrind-prompt"
  kill -9 "$grind_pid"
  wait "$grind_pid" 2>/dev/null || true

  run "$DVB_GRIND" --resume "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$(cat "$DVB_GRIND_INVOKE_LOG")" == *"FOCUS: focus on backend docs LIVE_PROMPT: prefer fast loops"* ]]
}

@test "--resume rejects prompt override mismatches" {
  local state_file="$TEST_DIR/resume-state"
  export DVB_STATE_FILE="$state_file"

  write_resume_state_file "$state_file" \
    "repo=$TEST_REPO" \
    "startup_prompt=focus on backend docs"

  run "$DVB_GRIND" --resume "$TEST_REPO" --prompt "focus on tests"

  [ "$status" -eq 1 ]
  [[ "$output" == *"saved state is incompatible: prompt override does not match saved state"* ]]
}
