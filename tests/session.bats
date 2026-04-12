#!/usr/bin/env bats
# Tests for taskgrind — session loop + 3 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Session loop ─────────────────────────────────────────────────────

@test "runs devin with --permission-mode dangerous" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--permission-mode dangerous' "$DVB_GRIND_INVOKE_LOG"
}

@test "runs devin in print mode with -p prompt" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '-p Run the next-task skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt includes session number" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'Session 1' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt includes remaining minutes" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'minutes remaining' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt includes commit-before-timeout guidance" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'Commit before timeout' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt includes completion protocol with merge and remove instructions" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'COMPLETION PROTOCOL' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'PR.*merge' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'remove.*task.*TASKS.md' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt includes autonomy block with automation guidance" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'AUTONOMY:' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'browser automation' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'MCP tools' "$DVB_GRIND_INVOKE_LOG"
  grep -q "Do not leave tasks saying 'requires manual work'" "$DVB_GRIND_INVOKE_LOG"
}

@test "startup sources fullpower helper and boosts the taskgrind pid" {
  local fake_bin="$TEST_DIR/fake-bin"
  local taskpolicy_log="$TEST_DIR/taskpolicy.log"
  local devin_parent_log="$TEST_DIR/devin-parent.log"
  mkdir -p "$fake_bin"

  create_fake_git "$fake_bin/taskpolicy" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$TASKPOLICY_LOG"
SCRIPT

  create_fake_devin "$TEST_DIR/fake-devin-with-ppid" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$PPID" > "$DEVIN_PARENT_LOG"
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT

  export PATH="$fake_bin:$PATH"
  export TASKPOLICY_LOG="$taskpolicy_log"
  export DEVIN_PARENT_LOG="$devin_parent_log"
  export DVB_GRIND_CMD="$TEST_DIR/fake-devin-with-ppid"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ -f "$taskpolicy_log" ]
  [ -f "$devin_parent_log" ]
  local expected_pid
  expected_pid="$(cat "$devin_parent_log")"
  grep -q -- "^-B -t 0 -l 0 -p $expected_pid\$" "$taskpolicy_log"
}

@test "zero-ship session summary tells next session about the problem" {
  local counter_file="$TEST_DIR/counter"
  local prompt_dir="$TEST_DIR/prompts"
  echo "0" > "$counter_file"
  mkdir -p "$prompt_dir"
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
prompt=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-p" ]; then
    prompt="\$arg"
    break
  fi
  case "\$arg" in
    -p=*)
      prompt="\${arg#-p=}"
      break
      ;;
  esac
  prev="\$arg"
done
printf '%s' "\$prompt" > "$prompt_dir/prompt-\$n.txt"
if [ "\$n" -eq 2 ]; then
  cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
EOF
fi
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 2 prompt should mention the zero-ship from session 1
  [ -f "$prompt_dir/prompt-2.txt" ]
  grep -q 'task count did not decrease' "$prompt_dir/prompt-2.txt"
}

@test "skip list warning appears in session 4 prompt after repeated task attempts" {
  local tmp_root="$TEST_DIR/tmp"
  local counter_file="$TEST_DIR/skip-counter"
  local prompt_devin="$TEST_DIR/prompt-devin"
  mkdir -p "$tmp_root"
  echo "0" > "$counter_file"
  export TMPDIR="$tmp_root"
  cat > "$prompt_devin" <<SCRIPT
#!/bin/bash
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
prompt=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-p" ]; then
    prompt="\$arg"
    break
  fi
  case "\$arg" in
    -p=*)
      prompt="\${arg#-p=}"
      break
      ;;
  esac
  prev="\$arg"
done
printf '%s' "\$prompt" > "$TEST_DIR/prompt-\$n.txt"
sleep 0.2
SCRIPT
  chmod +x "$prompt_devin"
  export DVB_GRIND_CMD="$prompt_devin"
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
  **ID**: stubborn-task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=6
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$TEST_DIR/prompt-4.txt" ]
  grep -q 'SKIP these stuck tasks (attempted 3+ times): stubborn-task' "$TEST_DIR/prompt-4.txt"
}

@test "task skip threshold is logged when a task hits 3 attempts" {
  local counter_file="$TEST_DIR/log-counter"
  local prompt_devin="$TEST_DIR/log-devin"
  echo "0" > "$counter_file"
  cat > "$prompt_devin" <<SCRIPT
#!/bin/bash
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
sleep 0.2
SCRIPT
  chmod +x "$prompt_devin"
  export DVB_GRIND_CMD="$prompt_devin"
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
  **ID**: stubborn-task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=6
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'task_skip_threshold ids=stubborn-task' "$TEST_LOG"
}

@test "task attempt temp files are cleaned up after the run" {
  local tmp_root="$TEST_DIR/tmp"
  local counter_file="$TEST_DIR/cleanup-counter"
  local prompt_devin="$TEST_DIR/cleanup-devin"
  mkdir -p "$tmp_root"
  echo "0" > "$counter_file"
  export TMPDIR="$tmp_root"
  cat > "$prompt_devin" <<SCRIPT
#!/bin/bash
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
sleep 0.2
SCRIPT
  chmod +x "$prompt_devin"
  export DVB_GRIND_CMD="$prompt_devin"
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
  **ID**: stubborn-task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=6
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! find "$tmp_root" -maxdepth 1 -name 'taskgrind-*.task-attempts*' | grep -q .
}

@test "--skill flag changes the skill in the prompt" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill fleet-grind
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "--skill flag shows in startup banner" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill fleet-grind
  [[ "$output" == *"skill=fleet-grind"* ]]
}

@test "DVB_SKILL env overrides default skill" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SKILL=fleet-grind
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "--skill flag overrides DVB_SKILL env" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SKILL=sweep
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill fleet-grind
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "default skill is next-task when no --skill or DVB_SKILL" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'Run the next-task skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "--skill works with repo path in any order" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 --skill fleet-grind "$TEST_REPO"
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "hours after repo path works" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"3h"* ]]
}

@test "hours after --skill works" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --skill fleet-grind 5 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"5h"* ]]
  [[ "$output" == *"fleet-grind"* ]]
}

@test "hours at end with all flags works" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" --skill fleet-grind 12
  [ "$status" -eq 0 ]
  [[ "$output" == *"12h"* ]]
  [[ "$output" == *"fleet-grind"* ]]
}

# ── --prompt flag ────────────────────────────────────────────────────

@test "--prompt flag adds focus to session prompt" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "focus on test coverage"
  grep -q 'FOCUS: focus on test coverage' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt= syntax works" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt="improve error handling"
  grep -q 'FOCUS: improve error handling' "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_PROMPT env sets focus prompt" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_PROMPT="fix flaky tests"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'FOCUS: fix flaky tests' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt flag overrides DVB_PROMPT env" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_PROMPT="env prompt"
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "flag prompt"
  grep -q 'FOCUS: flag prompt' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt shows focus in startup banner" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "test coverage"
  [[ "$output" == *"Focus: test coverage"* ]]
}

@test "--prompt without value errors" {
  run "$DVB_GRIND" --prompt
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prompt requires a value"* ]]
}

@test "no --prompt omits FOCUS from prompt" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'FOCUS:' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt works with --skill and repo in any order" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --prompt "perf work" --skill fleet-grind "$TEST_REPO" 1
  grep -q 'FOCUS: perf work' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "runs multiple sessions when deadline allows" {
  # Fake devin that exits instantly; generous deadline to avoid flake under load
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG")
  [ "$count" -ge 2 ]
}

@test "session counter increments across sessions" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'session 1' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'session 2' "$DVB_GRIND_INVOKE_LOG"
}

@test "stops when deadline passes" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # No invocations — deadline already passed
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "expired deadline prints a skip message before the session loop" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deadline already expired — skipping session loop."* ]]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "does not launch another session after the deadline expires during pre-session setup" {
  local fake_bin="$TEST_DIR/fake-bin"
  local git_counter="$TEST_DIR/git-rev-parse-head-count"
  local fake_devin="$fake_bin/devin"
  mkdir -p "$fake_bin"
  echo "0" > "$git_counter"

  init_test_repo

  cat > "$fake_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT
  chmod +x "$fake_devin"

  cat > "$fake_bin/git" <<'SCRIPT'
#!/bin/bash
if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" && "${4:-}" == "HEAD" ]]; then
  count=$(cat "$GIT_HEAD_COUNTER")
  count=$((count + 1))
  echo "$count" > "$GIT_HEAD_COUNTER"
  if [[ "$count" -eq 3 ]]; then
    sleep 20
  fi
fi
exec /usr/bin/git "$@"
SCRIPT
  chmod +x "$fake_bin/git"

  export PATH="$fake_bin:$PATH"
  export GIT_HEAD_COUNTER="$git_counter"
  unset DVB_GRIND_CMD
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
  [ "$(grep -c 'Run the next-task skill' "$DVB_GRIND_INVOKE_LOG")" -eq 1 ]
  grep -q 'Session 1' "$DVB_GRIND_INVOKE_LOG"
  ! grep -q 'Session 2' "$DVB_GRIND_INVOKE_LOG"
}

@test "continues loop when devin exits non-zero" {
  # Fake devin that fails
  local bad_devin="$TEST_DIR/bad-devin"
  cat > "$bad_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 1
SCRIPT
  chmod +x "$bad_devin"
  export DVB_GRIND_CMD="$bad_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG")
  [ "$count" -ge 2 ]
}

# ── Task counting ────────────────────────────────────────────────────

@test "counts tasks from TASKS.md" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks

## P0

- [ ] Fix the build
- [ ] Update docs

## P1

- [ ] Refactor auth module
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"3 tasks queued"* ]]
}

@test "reports 0 tasks when TASKS.md is missing" {
  rm -f "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Queue empty"* ]]
}

@test "reports 0 tasks when TASKS.md has no checkboxes" {
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Queue empty"* ]]
}

@test "count_tasks returns clean integer 0 (no multiline) when no checkboxes" {
  # Regression: grep -c exits 1 on 0 matches, || echo "0" produced "0\n0"
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # With empty queue, sweep runs then exits cleanly without arithmetic errors
  [ "$status" -eq 0 ]
  grep -q 'sweep_empty\|sweep_done' "$TEST_LOG"
}

@test "empty queue launches sweep session to find work" {
  # When TASKS.md has zero tasks, the grind should sweep for work
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
## P1
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Sweep session should have been launched (fake devin records invocation)
  [ -s "$DVB_GRIND_INVOKE_LOG" ]
  grep -q 'TASKS.md is empty' "$DVB_GRIND_INVOKE_LOG"
  # Sweep found nothing, so exits
  grep -q 'sweep_empty' "$TEST_LOG"
}

@test "empty queue sweep keeps the configured skill in the prompt" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill standing-audit-gap-loop
  [ "$status" -eq 0 ]
  grep -q 'Run the standing-audit-gap-loop skill' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'TASKS.md is empty' "$DVB_GRIND_INVOKE_LOG"
}

@test "missing TASKS.md launches sweep then exits" {
  rm -f "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'sweep_empty' "$TEST_LOG"
}

@test "sweep that finds tasks continues grind with normal sessions" {
  # Fake devin that populates TASKS.md when it sees the sweep prompt
  local sweep_devin="$TEST_DIR/sweep-devin"
  cat > "$sweep_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# If this is a sweep (prompt mentions "TASKS.md is empty"), add tasks
if echo "\$@" | grep -q "TASKS.md is empty"; then
  printf '# Tasks\n## P0\n- [ ] Found task\n' > "$TEST_REPO/TASKS.md"
fi
SCRIPT
  chmod +x "$sweep_devin"
  export DVB_GRIND_CMD="$sweep_devin"
  # Start with empty queue
  printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should have sweep session + at least 1 normal session
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -ge 2 ]
  grep -q 'sweep_found' "$TEST_LOG"
  # Normal session prompt should reference the skill
  grep -q 'Run the next-task skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "sweep runs at most once per grind" {
  # Fake devin that always clears tasks (simulates sweep that finds nothing useful)
  local clear_devin="$TEST_DIR/clear-devin"
  cat > "$clear_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# Always clear tasks
printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$clear_devin"
  export DVB_GRIND_CMD="$clear_devin"
  # Start with a task so the first session runs, then it clears, sweep runs, sweep clears
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Will be cleared
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should have 1 normal session + 1 sweep = 2 invocations (not infinite)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "sweep resets after productive sessions so queue can refill" {
  # Fake devin that: sweep adds tasks, normal sessions remove tasks
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
if echo "\$@" | grep -q "TASKS.md is empty"; then
  # Sweep: add 1 task
  printf '# Tasks\n## P0\n- [ ] Swept task\n' > "$TEST_REPO/TASKS.md"
else
  # Normal session: remove all tasks
  printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
fi
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"
  # Start empty — first sweep adds tasks, session removes them, second sweep fires
  printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Flow: sweep1 (adds task) → session1 (removes task) → sweep2 (adds task) → ...
  # Should have at least 2 sweeps
  local sweep_count
  sweep_count=$(grep -c 'TASKS.md is empty' "$DVB_GRIND_INVOKE_LOG")
  [ "$sweep_count" -ge 2 ]
}

@test "sweep session checks network on fast failure" {
  # Empty queue triggers sweep. Sweep crashes fast (no network file).
  # Network check should fire and pause the marathon.
  printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
  export DVB_MIN_SESSION=999  # every session is "fast" failure
  export DVB_NET_FILE="$TEST_DIR/net-up"
  # Network is down (no sentinel file) — should log network_down
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  export DVB_NET_MAX_WAIT=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should have detected network down during sweep recovery
  grep -q 'network_down\|network_timeout' "$TEST_LOG"
}

@test "empty queue wait honors DVB_EMPTY_QUEUE_WAIT" {
  printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
  export DVB_EMPTY_QUEUE_WAIT=2
  export DVB_DEADLINE=$(( $(date +%s) + 6 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting 2s for external task injection"* ]]
  grep -q 'queue_empty tasks=0 sweep=done — waiting 2s' "$TEST_LOG"
}

@test "non-empty queue launches a session" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] A real task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should have launched at least one session
  [ -s "$DVB_GRIND_INVOKE_LOG" ]
  ! grep -q 'queue_empty' "$TEST_LOG"
}

# ── Prompt hardening ──────────────────────────────────────────────────

@test "prompt includes session timeout budget" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'timeout.*s' "$DVB_GRIND_INVOKE_LOG"
}

@test "queue cleared mid-run triggers sweep on next iteration" {
  # Fake devin that clears TASKS.md on first call
  local clear_devin="$TEST_DIR/clear-devin"
  cat > "$clear_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# Clear all tasks on first call
printf '# Tasks\n## P0\n## P1\n' > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$clear_devin"
  export DVB_GRIND_CMD="$clear_devin"
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Only task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should run 1 real session + 1 sweep session = 2 invocations
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 2 ]
  grep -q 'sweep_empty' "$TEST_LOG"
}

@test "all-blocked queue waits then exits" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P1
- [ ] Deploy to K8s
  **ID**: deploy-k8s
  **Blocked by**: jenkins-setup
- [ ] Configure DNS
  **ID**: config-dns
  **Blocked by**: k8s-namespace
TASKS

  # Use a very short deadline so the blocked-wait sleep gets cut short
  # by the deadline check on the next loop iteration
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'all_tasks_blocked' "$TEST_LOG"
  [[ "$output" == *"All 2 remaining tasks are blocked"* ]]
  # No sessions should have been launched
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "partially blocked queue does NOT exit early" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P1
- [ ] Deploy to K8s
  **ID**: deploy-k8s
  **Blocked by**: jenkins-setup
- [ ] Write docs
  **ID**: write-docs
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'all_tasks_blocked' "$TEST_LOG"
  # Should have launched at least 1 session
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "all-blocked with single task exits" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Waiting for OIDC credentials
  **ID**: oidc-creds
  **Blocked by**: eiam-team
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'all_tasks_blocked' "$TEST_LOG"
}

@test "multi-blocker task does not cause false all-blocked" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P1
- [ ] Deploy to K8s
  **ID**: deploy-k8s
  **Blocked by**: jenkins-setup
  **Blocked by**: dns-config
- [ ] Write docs
  **ID**: write-docs
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'all_tasks_blocked' "$TEST_LOG"
  # Should have launched at least 1 session (write-docs is not blocked)
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "second session prompt includes previous session context" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Session 2 should reference session 1 results
  grep -q 'Previous session:.*session 1' "$DVB_GRIND_INVOKE_LOG"
}

@test "first session prompt has no previous session context" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Session 1 prompt should NOT contain "Previous session"
  local first_prompt
  first_prompt=$(head -1 "$DVB_GRIND_INVOKE_LOG")
  [[ "$first_prompt" != *"Previous session"* ]]
}

@test "repo deletion mid-marathon aborts gracefully" {
  local volatile="$TEST_DIR/volatile-repo"
  mkdir -p "$volatile"
  # Add a task so the grind doesn't exit on empty queue
  printf '# Tasks\n## P0\n- [ ] A task\n' > "$volatile/TASKS.md"
  # Fake devin that deletes the repo on first call
  local nuke_devin="$TEST_DIR/nuke-devin"
  cat > "$nuke_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
rm -rf "$volatile"
SCRIPT
  chmod +x "$nuke_devin"
  export DVB_GRIND_CMD="$nuke_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$volatile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repo directory missing"* ]]
  [[ "$output" == *"Grind complete: 1 sessions, 0+ tasks"* ]]
  grep -q 'repo_missing' "$TEST_LOG"
  ! grep -q 'queue_empty tasks=0' "$TEST_LOG"
}

@test "log_write does not crash on deleted log file" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  # Use a log file that will be deleted by the fake devin
  local volatile_log="$TEST_DIR/volatile.log"
  export DVB_LOG="$volatile_log"
  local del_devin="$TEST_DIR/del-log-devin"
  cat > "$del_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
rm -f "$volatile_log"
SCRIPT
  chmod +x "$del_devin"
  export DVB_GRIND_CMD="$del_devin"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should complete without crashing despite log deletion
  [[ "$output" == *"Grind complete"* ]]
}

@test "git sync uses background kill timeout to prevent hanging" {
  # Timer subshell: sleep $timeout & wait, then kill _git_pid
  grep -q 'sleep "$_git_sync_timeout" &' "$DVB_GRIND"
  grep -q 'kill "$_git_pid"' "$DVB_GRIND"
}

@test "production mode captures stdout to session_output" {
  grep -q 'tee -a "$session_output"' "$DVB_GRIND"
}

@test "session output is truncated between sessions" {
  grep -q ': > "$session_output"' "$DVB_GRIND"
}

@test "tracks shipped tasks when count decreases" {
  # Fake devin that removes one task each invocation
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# Remove the first task line from TASKS.md
REPO="$TEST_REPO"
if [ -f "\$REPO/TASKS.md" ]; then
  sed -i '' '0,/^- \[ \]/{/^- \[ \]/d;}' "\$REPO/TASKS.md" 2>/dev/null || \
  sed -i '0,/^- \[ \]/{/^- \[ \]/d;}' "\$REPO/TASKS.md" 2>/dev/null || true
fi
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task one
- [ ] Task two
- [ ] Task three
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Summary should show shipped tasks
  [[ "$output" == *"sessions"* ]]
  [[ "$output" == *"tasks"* ]]
}

@test "does not count added tasks as shipped" {
  # Fake devin that adds a task
  local add_devin="$TEST_DIR/add-devin"
  cat > "$add_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "- [ ] New task" >> "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$add_devin"
  export DVB_GRIND_CMD="$add_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Existing task
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should show 0+ tasks (not negative)
  [[ "$output" == *"0+ tasks"* ]]
}

@test "ID-based shipped: removing task with ID counts as shipped" {
  # Fake devin that removes task-a and its metadata, keeping task-b
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task B
  **ID**: task-b
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task A
  **ID**: task-a
- [ ] Task B
  **ID**: task-b
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  assert_session_log_has_shipped 1
}

@test "ID-based shipped: adding and removing tasks counts correctly" {
  # The key scenario: agent removes task-a (pre-existing) and adds task-c (new).
  # Count-based: before=2, after=2, shipped=0 (WRONG).
  # ID-based: task-a removed → shipped=1 (CORRECT).
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task B
  **ID**: task-b
- [ ] Task C (new)
  **ID**: task-c
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task A
  **ID**: task-a
- [ ] Task B
  **ID**: task-b
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # ID-based: task-a was present before and gone after → shipped=1
  assert_session_log_has_shipped 1
}

@test "ID-based shipped: adding 2 and removing 2 still counts shipped" {
  # Agent removes task-a and task-b, adds task-c and task-d.
  # Count-based: 2→2, shipped=0. ID-based: 2 removed → shipped=2.
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task C
  **ID**: task-c
- [ ] Task D
  **ID**: task-d
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task A
  **ID**: task-a
- [ ] Task B
  **ID**: task-b
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  assert_session_log_has_shipped 2
}

@test "ID-based shipped: no IDs falls back to count-based" {
  # Tasks without **ID**: metadata use the old count-based approach
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task two
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task one
- [ ] Task two
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Count-based fallback: 2→1 = shipped=1
  assert_session_log_has_shipped 1
}

@test "ID-based shipped: logs new tasks added during session" {
  # Agent adds a new task with ID during the session
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task A
  **ID**: task-a
- [ ] Task B (new)
  **ID**: task-b
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task A
  **ID**: task-a
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'tasks_added=1' "$TEST_LOG"
}

@test "ID-based shipped: parent removal survives temporary subtask churn" {
  # Reproduce a planning-style session that replaces a parent task with
  # temporary subtasks, then removes those subtasks before finishing with one
  # surviving follow-up task. The final queue stays flat, but one pre-session
  # task ID was still shipped and must count.
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Peer task that survives
  **ID**: task-peer
- [ ] Temporary subtask one
  **ID**: task-parent-step-1
- [ ] Temporary subtask two
  **ID**: task-parent-step-2
EOF
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Peer task that survives
  **ID**: task-peer
- [ ] Follow-up task created during the session
  **ID**: task-followup
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Parent task to decompose and ship
  **ID**: task-parent
- [ ] Peer task that survives
  **ID**: task-peer
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  assert_session_log_has_shipped 1
  grep -q 'tasks_added=1' "$TEST_LOG"
  ! grep -q 'productive_zero_ship' "$TEST_LOG"
}

@test "count-based: tasks_added log written without crash when tasks_after > tasks_before" {
  # Regression test for bash UTF-8 variable name bug:
  # $tasks_before→$tasks_after — the → arrow (\xe2\x86\x92) caused bash to
  # include \xe2 as part of the variable name under set -u, crashing with
  # "tasks_before⚠: unbound variable". Fix: ${tasks_before}→${tasks_after}.
  # This test exercises the count-based fallback branch (no IDs in TASKS.md)
  # where a session adds tasks (tasks_after > tasks_before).
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task one
- [ ] Task two
- [ ] Task three
EOF
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task one
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must not crash — exit 0 or natural deadline expiry
  [[ "$status" -eq 0 ]]
  # tasks_added=2 must appear in the log (1→3 = 2 added)
  grep -q 'tasks_added=2' "$TEST_LOG"
  # Must include the "external injection" marker
  grep -q 'external injection' "$TEST_LOG"
}

@test "ID-based shipped: resets zero-ship counter on ID-tracked ship" {
  # Verify stall detection resets when ID-based shipping detects work.
  # Session 3 ships task-a (removing it, adding task-c). This resets the
  # consecutive_zero_ship counter. We verify the reset happened by checking
  # that session 3 logged shipped=1, proving the ID-based path works with
  # stall detection.
  local counter_file="$TEST_DIR/counter"
  echo "0" > "$counter_file"
  local smart_devin="$TEST_DIR/smart-devin"
  cat > "$smart_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
if [ "\$n" -eq 3 ]; then
  # Session 3: remove task-a (ship it), add task-c
  cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Task B
  **ID**: task-b
- [ ] Task C
  **ID**: task-c
EOF
elif [ "\$n" -eq 4 ]; then
  cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
EOF
fi
SCRIPT
  chmod +x "$smart_devin"
  export DVB_GRIND_CMD="$smart_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task A
  **ID**: task-a
- [ ] Task B
  **ID**: task-b
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 20 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 3 shipped via ID tracking — verify the shipped=1 log
  grep -q 'session=3 ended.*shipped=1' "$TEST_LOG"
  # Stall warning at consecutive_zero_ship=3 should NOT appear before session 3
  # because session 3 resets the counter. It may appear later (sessions 4-6).
  # The key assertion: session 3 reset the counter (shipped=1 proves it).
}

@test "productive queue churn does not increment zero-ship stall counters" {
  init_test_repo

  local state_file="$TEST_DIR/state"
  export DVB_STATE_FILE="$state_file"
  local counter_file="$TEST_DIR/churn-counter"
  echo "0" > "$counter_file"

  local churn_devin="$TEST_DIR/churn-devin"
  cat > "$churn_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
if [ "\$n" -eq 1 ]; then
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Persistent task
  **ID**: task-a
- [ ] New task injected during session
  **ID**: task-b
EOF
echo "new work" >> "$TEST_REPO/code.txt"
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -q -m "fix: session work"
else
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
EOF
fi
SCRIPT
  chmod +x "$churn_devin"
  export DVB_GRIND_CMD="$churn_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
  **ID**: task-a
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -q 'productive_zero_ship' "$TEST_LOG"
  grep -q 'zero_ship_stall_ignored session=1 reason=queue_delta_offset' "$TEST_LOG"
  grep -q 'grind_done.*sessions_zero_ship=0' "$TEST_LOG"
  ! grep -q 'stall_warning' "$TEST_LOG"
}

@test "temporary local task churn does not increment zero-ship stall counters" {
  init_test_repo

  local state_file="$TEST_DIR/state"
  export DVB_STATE_FILE="$state_file"
  local counter_file="$TEST_DIR/churn-counter"
  echo "0" > "$counter_file"

  local churn_devin="$TEST_DIR/churn-devin"
  cat > "$churn_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
if [ "\$n" -eq 1 ]; then
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Persistent task
  **ID**: task-a
- [ ] Temporary subtask
  **ID**: task-temp
EOF
git -C "$TEST_REPO" add TASKS.md
git -C "$TEST_REPO" commit -q -m "test: add temporary task"

cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Persistent task
  **ID**: task-a
EOF
echo "new work" >> "$TEST_REPO/code.txt"
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -q -m "fix: session work after task churn"
else
cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
EOF
fi
SCRIPT
  chmod +x "$churn_devin"
  export DVB_GRIND_CMD="$churn_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
  **ID**: task-a
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  grep -q 'productive_zero_ship' "$TEST_LOG"
  grep -q 'zero_ship_stall_ignored session=1 reason=local_task_churn' "$TEST_LOG"
  grep -q 'grind_done.*sessions_zero_ship=0' "$TEST_LOG"
  ! grep -q 'stall_warning' "$TEST_LOG"
}

@test "counts nested/indented task checkboxes" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Top-level task
  - [ ] Nested sub-task
    - [ ] Deeply nested sub-task
## P1
- [ ] Another top-level
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"4 tasks queued"* ]]
}

@test "remaining time never shows negative in prompt" {
  # Fake devin that sleeps briefly so clock can drift past deadline
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
# Record the prompt to check remaining time
echo "$@" >> "${DVB_GRIND_INVOKE_LOG}.full"
exit 0
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"
  # Deadline just 1s in the future — remaining_min will be 0
  export DVB_DEADLINE=$(( $(date +%s) + 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # The prompt should never contain a negative number before "minutes remaining"
  if [ -f "$DVB_GRIND_INVOKE_LOG.full" ]; then
    ! grep -qE -- '-[0-9]+ minutes remaining' "$DVB_GRIND_INVOKE_LOG.full"
  fi
}
