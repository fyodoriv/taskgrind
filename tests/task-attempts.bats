#!/usr/bin/env bats

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

extract_attempt_functions() {
  local function_file="$1"

  python3 - <<'PY' "$DVB_GRIND" "$function_file"
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
source = source_path.read_text()
start = source.index("extract_task_ids() {")
end = source.index("# Print the first remaining task context as shell-safe assignments.")
target_path.write_text(source[start:end])
PY
}

@test "attempt write failures are logged and later sessions still reach skip threshold" {
  local real_mv shim_dir state_file

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent test task
  **ID**: persistent-test-task
TASKS

  real_mv="$(command -v mv)"
  shim_dir="$TEST_DIR/shims"
  state_file="$TEST_DIR/mv-state"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/mv" <<SCRIPT
#!/bin/bash
if [[ "\$1" == *taskgrind-att-*.new && "\$2" == *taskgrind-att-* && ! -f "$state_file" ]]; then
  : > "$state_file"
  echo "simulated mv failure" >&2
  exit 1
fi
exec "$real_mv" "\$@"
SCRIPT
  chmod +x "$shim_dir/mv"

  export PATH="$shim_dir:$PATH"
  export DVB_DEADLINE=$(( $(date +%s) + 40 ))
  export DVB_MAX_SESSION=1

  run "$DVB_GRIND" 4 "$TEST_REPO"
  [ "$status" -eq 0 ]

  grep -q 'attempt_write_failed:' "$TEST_LOG"
  grep -q 'task_skip_threshold ids=' "$TEST_LOG"
}

@test "prune_task_attempts_file drops removed task IDs but keeps live ones" {
  local function_file="$TEST_DIR/prune-functions.sh"
  local attempts_file="$TEST_DIR/task-attempts"
  local tasks_file="$TEST_DIR/TASKS.md"

  extract_attempt_functions "$function_file"

  cat > "$attempts_file" <<'ATTEMPTS'
stale-task 4
live-task 3
ATTEMPTS

  cat > "$tasks_file" <<'TASKS'
# Tasks
## P0
- [ ] Live task
  **ID**: live-task
TASKS

  run bash -lc "source '$function_file'; prune_task_attempts_file '$attempts_file' '$tasks_file'; cat '$attempts_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == "live-task 3" ]]
}

@test "shipping a stuck task clears its attempt debt before the ID returns" {
  local function_file="$TEST_DIR/prune-functions.sh"
  local attempts_file="$TEST_DIR/task-attempts"
  local shipped_tasks_file="$TEST_DIR/shipped-tasks.md"
  local returned_tasks_file="$TEST_DIR/returned-tasks.md"

  extract_attempt_functions "$function_file"

  cat > "$attempts_file" <<'ATTEMPTS'
stubborn-task 3
steady-task 1
ATTEMPTS

  cat > "$shipped_tasks_file" <<'TASKS'
# Tasks
## P0
- [ ] Replacement task
  **ID**: replacement-task
- [ ] Steady task
  **ID**: steady-task
TASKS

  cat > "$returned_tasks_file" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task returns
  **ID**: stubborn-task
- [ ] Steady task
  **ID**: steady-task
TASKS

  run bash -lc "source '$function_file'; prune_task_attempts_file '$attempts_file' '$shipped_tasks_file'; prune_task_attempts_file '$attempts_file' '$returned_tasks_file'; cat '$attempts_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == "steady-task 1" ]]
}

@test "successor task churn does not inherit retry counts from shipped work" {
  local function_file="$TEST_DIR/prune-functions.sh"
  local attempts_file="$TEST_DIR/task-attempts"
  local tasks_file="$TEST_DIR/TASKS.md"

  extract_attempt_functions "$function_file"

  cat > "$attempts_file" <<'ATTEMPTS'
original-task 4
shared-task 2
ATTEMPTS

  cat > "$tasks_file" <<'TASKS'
# Tasks
## P0
- [ ] Successor task
  **ID**: successor-task
- [ ] Shared task
  **ID**: shared-task
TASKS

  run bash -lc "source '$function_file'; prune_task_attempts_file '$attempts_file' '$tasks_file'; cat '$attempts_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == "shared-task 2" ]]
}

@test "skip-list prompt only mentions still-live IDs that crossed the threshold" {
  local function_file="$TEST_DIR/prune-functions.sh"
  local attempts_file="$TEST_DIR/task-attempts"
  local tasks_file="$TEST_DIR/TASKS.md"

  extract_attempt_functions "$function_file"

  cat > "$attempts_file" <<'ATTEMPTS'
stale-task 4
live-task 3
warm-task 2
ATTEMPTS

  cat > "$tasks_file" <<'TASKS'
# Tasks
## P0
- [ ] Live task
  **ID**: live-task
- [ ] Warm task
  **ID**: warm-task
TASKS

  run bash -lc "source '$function_file'; prune_task_attempts_file '$attempts_file' '$tasks_file'; awk '\$2 >= 3 { printf \"%s \", \$1 }' '$attempts_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == "live-task " ]]
}

# ── extract_first_task_context() — direct unit-style coverage ─────────
# Extract the function from bin/taskgrind via awk (matches the established
# pattern for all_tasks_blocked / detect_default_branch) and call it in a
# clean subshell against fixture TASKS.md files. The function powers the
# `audit_focus_blocked` and `blocked_wait` operator signals, so a parsing
# regression silently degrades that channel without any integration-level
# failure surface.

_extract_first_task_context() {
  awk '/^extract_first_task_context\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_first_task_context() {
  local tasks_file="$1"
  local fn
  fn=$(_extract_first_task_context)
  # shellcheck disable=SC2016  # $fn contains the literal function definition
  bash -c "$fn"$'\n'"extract_first_task_context \"$tasks_file\""
}

@test "extract_first_task_context: missing file prints nothing and returns 0" {
  run _run_first_task_context "$TEST_REPO/no-such-file.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_first_task_context: empty TASKS.md prints nothing" {
  printf '# Tasks\n' > "$TEST_REPO/TASKS.md"
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_first_task_context: single open task with ID only emits task_id" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Ship the feature
  **ID**: ship-feature
  **Tags**: docs
TASKS
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_id=ship-feature"* ]]
  [[ "$output" != *"blocker="* ]]
}

@test "extract_first_task_context: blocked task emits both task_id and blocker" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Wait for upstream
  **ID**: wait-upstream
  **Blocked by**: external-team
TASKS
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_id=wait-upstream"* ]]
  [[ "$output" == *"blocker=external-team"* ]]
}

@test "extract_first_task_context: only the first open task is reported" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] First task
  **ID**: first-task
  **Blocked by**: blocker-a
- [ ] Second task
  **ID**: second-task
  **Blocked by**: blocker-b
TASKS
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_id=first-task"* ]]
  [[ "$output" == *"blocker=blocker-a"* ]]
  [[ "$output" != *"task_id=second-task"* ]]
  [[ "$output" != *"blocker=blocker-b"* ]]
}

@test "extract_first_task_context: completed [x] tasks are ignored" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [x] Already done
  **ID**: already-done
  **Blocked by**: ghost-blocker
- [ ] Real first open task
  **ID**: real-task
TASKS
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_id=real-task"* ]]
  [[ "$output" != *"task_id=already-done"* ]]
  [[ "$output" != *"blocker=ghost-blocker"* ]]
}

@test "extract_first_task_context: trailing whitespace does not bleed into blocker" {
  # Use printf so each line has a deterministic trailing space; this guards
  # the explicit `sub(/[[:space:]]+$/, "", blocker)` rstrip in the awk body.
  printf '%s\n' \
    '# Tasks' \
    '## P0' \
    '- [ ] Trailing whitespace task' \
    '  **ID**: trail-task' \
    '  **Blocked by**: real-blocker     ' > "$TEST_REPO/TASKS.md"
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_id=trail-task"* ]]
  [[ "$output" == *"blocker=real-blocker"$'\n' ]] || [[ "$output" == *"blocker=real-blocker"* ]]
  # The blocker value must not retain the trailing spaces.
  [[ "$output" != *"blocker=real-blocker     "* ]]
}

@test "extract_first_task_context: blocker without **ID**: still emits blocker only" {
  # Defensive: the function should not crash when **ID**: is missing. It just
  # emits the blocker (or nothing if neither is present).
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task without ID
  **Blocked by**: idless-blocker
TASKS
  run _run_first_task_context "$TEST_REPO/TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocker=idless-blocker"* ]]
  [[ "$output" != *"task_id="* ]]
}
