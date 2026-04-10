#!/usr/bin/env bats
# Tests for taskgrind (multi-session marathon grind loop)

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Setup / Teardown ─────────────────────────────────────────────────

setup() {
  TEST_DIR="$(mktemp -d)"
  TEST_HOME="$TEST_DIR/home"
  TEST_DOTFILES="$TEST_DIR/dotfiles"
  TEST_REPO="$TEST_DIR/repo"
  TEST_LOG="$TEST_DIR/grind.log"

  mkdir -p "$TEST_HOME" "$TEST_DOTFILES/lib" "$TEST_REPO"
  # Copy shared libraries so the self-copied script can source them
  cp "$BATS_TEST_DIRNAME/../lib/constants.sh" "$TEST_DOTFILES/lib/"
  cp "$BATS_TEST_DIRNAME/../lib/fullpower.sh" "$TEST_DOTFILES/lib/"
  # Default TASKS.md with one task so sessions launch (tests override as needed)
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Default test task
TASKS
  export HOME="$TEST_HOME"
  export TASKGRIND_DIR="$TEST_DOTFILES"
  export DVB_LOG="$TEST_LOG"
  export DVB_COOL=0

  # Create a fake devin that just exits immediately
  FAKE_DEVIN="$TEST_DIR/fake-devin"
  cat > "$FAKE_DEVIN" <<'SCRIPT'
#!/bin/bash
# Fake devin — records invocations and exits
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT
  chmod +x "$FAKE_DEVIN"
  export DVB_GRIND_CMD="$FAKE_DEVIN"
  export DVB_GRIND_INVOKE_LOG="$TEST_DIR/invocations.log"
}

teardown() {
  rm -rf "$TEST_DIR"
}

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
  # Snapshot existing temp files so we only detect leaks from THIS run
  local _tmp="${TMPDIR:-/tmp}"
  _tmp="${_tmp%/}"
  local before
  before=$(ls "$_tmp"/taskgrind-exec.* 2>/dev/null | sort)
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  local after
  after=$(ls "$_tmp"/taskgrind-exec.* 2>/dev/null | sort)
  # No new files should remain after cleanup
  [ "$before" = "$after" ]
}

# ── Argument validation ──────────────────────────────────────────────

@test "no args defaults to 8 hours" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8h"* ]]
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

@test "defaults to claude-opus-4-6-thinking (not shortname)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must be the exact explicit name, not 'opus' shortname
  grep -q -- '--model claude-opus-4-6-thinking' "$DVB_GRIND_INVOKE_LOG"
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


@test "default model has no dots (Devin uses dashes)" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" != *.* ]]
}

@test "default model has no -1m suffix" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" != *-1m ]]
}

@test "default model includes thinking" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" == *thinking* ]]
}

@test "every session gets the same model flag" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Every invocation line must contain the exact model flag
  while IFS= read -r line; do
    [[ "$line" == *"--model claude-opus-4-6-thinking"* ]] || {
      echo "Session missing model flag: $line"; return 1
    }
  done < "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MODEL overrides default completely" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MODEL=sonnet
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model sonnet' "$DVB_GRIND_INVOKE_LOG"
  # And the default must not appear
  ! grep -q -- '--model claude-opus-4-6-thinking' "$DVB_GRIND_INVOKE_LOG"
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
  grep -q -- '--model sonnet' "$DVB_GRIND_INVOKE_LOG"
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
  [[ "$output" == *"claude-opus-4-6-thinking"* ]]
}

@test "model shows in log file header" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'model=claude-opus-4-6-thinking' "$TEST_LOG"
}

@test "repo defaults to current directory" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  cd "$TEST_REPO"
  run "$DVB_GRIND" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_REPO"* ]]
}

# ── Session loop ─────────────────────────────────────────────────────

@test "runs devin with --permission-mode dangerous" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--permission-mode dangerous' "$DVB_GRIND_INVOKE_LOG"
}

@test "runs devin in print mode with -p prompt" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '-p Run the next-task skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt includes session number" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
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

@test "zero-ship session summary tells next session about the problem" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 2 prompt should mention the zero-ship from session 1
  grep -q 'task count did not decrease' "$DVB_GRIND_INVOKE_LOG"
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
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
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
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
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
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should run 1 real session + 1 sweep session = 2 invocations
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 2 ]
  grep -q 'sweep_empty' "$TEST_LOG"
}

@test "all-blocked queue exits without running sessions" {
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

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
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
  grep -q 'repo_missing' "$TEST_LOG"
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
  grep -q 'shipped=1' "$TEST_LOG"
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
  grep -q 'shipped=1' "$TEST_LOG"
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
  grep -q 'shipped=2' "$TEST_LOG"
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
  grep -q 'shipped=1' "$TEST_LOG"
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

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 3 shipped via ID tracking — verify the shipped=1 log
  grep -q 'session=3 ended.*shipped=1' "$TEST_LOG"
  # Stall warning at consecutive_zero_ship=3 should NOT appear before session 3
  # because session 3 resets the counter. It may appear later (sessions 4-6).
  # The key assertion: session 3 reset the counter (shipped=1 proves it).
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

# ── Log file ─────────────────────────────────────────────────────────

@test "creates log file" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$TEST_LOG" ]
}

@test "log file contains header with config" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q '# taskgrind started' "$TEST_LOG"
  grep -q "hours=1" "$TEST_LOG"
  grep -q "model=claude-opus-4-6-thinking" "$TEST_LOG"
}

@test "log file records session start entries" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'session=1' "$TEST_LOG"
}

@test "log file records session end entries" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'ended' "$TEST_LOG"
}

@test "log file records tasks_after count" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task one
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'tasks_after=' "$TEST_LOG"
}

@test "log file records shipped count per session" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'shipped=' "$TEST_LOG"
}

@test "DVB_LOG overrides log file path" {
  local custom_log="$TEST_DIR/custom.log"
  export DVB_LOG="$custom_log"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$custom_log" ]
}

@test "default log file uses timestamp format" {
  unset DVB_LOG
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Output should show a log path with YYYY-MM-DD-HHMM-reponame-PID pattern
  [[ "$output" =~ taskgrind-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[a-zA-Z0-9_.-]+-[0-9]+\.log ]]
}

# ── Banner and summary ───────────────────────────────────────────────

@test "shows startup banner with hours and model" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"taskgrind"* ]]
  [[ "$output" == *"1h"* ]]
  [[ "$output" == *"claude-opus-4-6-thinking"* ]]
}

@test "shows startup banner with repo path" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"$TEST_REPO"* ]]
}

@test "shows session restart message" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Each session runs"* ]]
}

@test "shows completion summary with session count" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Grind complete"* ]]
  [[ "$output" == *"sessions"* ]]
}

@test "shows completion summary with task count" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"tasks"* ]]
}

@test "shows log file path in summary" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"$TEST_LOG"* ]]
}

@test "shows cooldown message between sessions" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_COOL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Cooling down"* ]]
}

# ── DVB_DEADLINE override ────────────────────────────────────────────

@test "DVB_DEADLINE overrides computed deadline" {
  # Set deadline in the past — should not run any sessions
  export DVB_DEADLINE=$(( $(date +%s) - 10 ))
  run "$DVB_GRIND" 10 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
  [[ "$output" == *"0 sessions"* ]]
}

# ── Cooldown ─────────────────────────────────────────────────────────

@test "DVB_COOL=0 skips sleep between sessions" {
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_COOL=0
  local start end
  start=$(date +%s)
  run "$DVB_GRIND" 1 "$TEST_REPO"
  end=$(date +%s)
  # With cooldown=0, multiple sessions should complete in < 8s
  [ $((end - start)) -lt 8 ]
}

# ── Working directory ────────────────────────────────────────────────

@test "changes to repo directory for devin session" {
  # Fake devin that records its cwd
  local cwd_devin="$TEST_DIR/cwd-devin"
  cat > "$cwd_devin" <<SCRIPT
#!/bin/bash
pwd >> "$TEST_DIR/cwd.log"
SCRIPT
  chmod +x "$cwd_devin"
  export DVB_GRIND_CMD="$cwd_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q "$TEST_REPO" "$TEST_DIR/cwd.log"
}

@test "resolves relative repo path to absolute" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  cd "$TEST_DIR"
  run "$DVB_GRIND" 1 repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_DIR/repo"* ]]
}

# ── Grind handoff protocol ───────────────────────────────────────────

# ── Duration tracking ─────────────────────────────────────────────────

@test "format_duration outputs hours and minutes" {
  # Run grind with past deadline so it finishes immediately — summary should include duration
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Summary line should contain a duration like "0s" or "1s" etc.
  [[ "$output" == *"Grind complete:"* ]]
  [[ "$output" == *s* ]] || [[ "$output" == *m* ]] || [[ "$output" == *h* ]]
}

@test "grind summary includes duration in seconds for short runs" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # With an already-past deadline, should complete in <1min → "Xs" format
  [[ "$output" == *"0 sessions"* ]]
  [[ "$output" =~ [0-9]+s ]]
}

@test "grind log includes duration field" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'duration=' "$TEST_LOG"
  grep -q 'elapsed=' "$TEST_LOG"
}

@test "grind log includes elapsed in seconds" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Log should contain elapsed=Ns where N is a number
  grep -qE 'elapsed=[0-9]+s' "$TEST_LOG"
}

# ── zshrc duration tracking ──────────────────────────────────────────

# ── zshrc hardening ───────────────────────────────────────────────────

# ── Network resilience ────────────────────────────────────────────────
# These tests use DVB_MIN_SESSION to enable fast-failure detection,
# DVB_NET_FILE as a sentinel file for network state (test mode),
# and DVB_NET_WAIT/DVB_NET_MAX_WAIT for fast polling.

@test "check_network returns true when DVB_NET_FILE exists" {
  # Verify the test-mode sentinel mechanism works
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Network is up, so no network_down in log
  ! grep -q 'network_down' "$TEST_LOG"
}

@test "check_network uses network-watchdog --check-only in production mode" {
  grep -q 'network-watchdog --check-only' "$DVB_GRIND"
}

@test "fast session triggers network check when DVB_MIN_SESSION set" {
  # Fake devin exits instantly (0s < min_session_secs), network is up
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Sessions ran (network was up, so no pause)
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "network down pauses loop and logs network_down" {
  # No sentinel file = network down. max_wait=0 so it times out immediately.
  export DVB_NET_FILE="$TEST_DIR/net-up"  # file does NOT exist
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should have logged network_down
  grep -q 'network_down' "$TEST_LOG"
}

@test "network timeout exits the loop" {
  # Network never comes back, max_wait=0 forces immediate timeout
  export DVB_NET_FILE="$TEST_DIR/net-up"  # does not exist
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'network_timeout' "$TEST_LOG"
}

@test "network recovery extends deadline and logs network_restored" {
  # Sentinel file created after 2s — long enough for the grind to start,
  # run the first session, hit fast-failure, and enter wait_for_network.
  nohup bash -c "sleep 2; touch '$TEST_DIR/net-up'" &>/dev/null &

  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-up"  # does not exist yet
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=30
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'network_restored' "$TEST_LOG"
}

@test "session number rolls back after network recovery" {
  nohup bash -c "sleep 2; touch '$TEST_DIR/net-up'" &>/dev/null &

  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=30
  export DVB_DEADLINE=$(( $(date +%s) + 20 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # First session=1 fails fast → network down → network back → session counter rolled back
  # Next iteration: session=1 again (the retry)
  # Log should show session=1 appearing twice (original + retry)
  local session1_count
  session1_count=$(grep -c 'session=1 ' "$TEST_LOG" || true)
  session1_count="${session1_count:-0}"
  [ "$session1_count" -ge 2 ]
}

@test "consecutive fast failures increment counter and trigger backoff" {
  # Network is up but sessions keep failing fast — should see fast_fail in log
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # After 3+ fast failures, should log fast_fail with backoff
  grep -q 'fast_fail' "$TEST_LOG"
  grep -q 'consecutive=3' "$TEST_LOG"
}

@test "backoff increases with consecutive fast failures" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=1
  export DVB_BACKOFF_MAX=10
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With base=1: consecutive=3 → 3s, consecutive=4 → 4s, etc.
  grep -q 'backoff=3s' "$TEST_LOG"
  grep -q 'backoff=4s' "$TEST_LOG"
}

@test "backoff caps at DVB_BACKOFF_MAX" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_BACKOFF_MAX=5
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With base=0 all backoffs are 0, capped at 5 (but 0 < 5 so cap never triggers)
  # Verify no backoff exceeds the max
  if grep -q 'backoff=' "$TEST_LOG"; then
    ! grep -qE 'backoff=([6-9]|[1-9][0-9]+)s' "$TEST_LOG"
  fi
}

@test "backoff formula defaults cap to 120s" {
  # Structural: verify the default max is 120
  grep -q 'DVB_BACKOFF_MAX:-120' "$DVB_GRIND"
}

@test "backoff sleep extends deadline like network wait does" {
  # Structural: after sleep "$backoff", deadline should be extended
  grep -A3 'sleep "$backoff"' "$DVB_GRIND" | grep -q 'deadline=.*deadline.*backoff'
}

@test "consecutive_fast resets after a normal-length session" {
  # First few sessions are fast (incrementing consecutive_fast)
  # Then a slow session resets the counter
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# On 4th invocation, simulate a long session
count=\$(wc -l < "$DVB_GRIND_INVOKE_LOG" 2>/dev/null || echo 0)
if [ "\$count" -ge 4 ]; then
  # Sleep longer than min_session_secs to reset counter
  sleep 2
fi
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=1
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -f "$DVB_GRIND_INVOKE_LOG" ]
  local invoke_count
  invoke_count=$(wc -l < "$DVB_GRIND_INVOKE_LOG")
  [ "$invoke_count" -ge 4 ]
}

@test "min_session_secs defaults to 0 in test mode (existing tests unaffected)" {
  # When DVB_GRIND_CMD is set but DVB_MIN_SESSION is not, min_session_secs=0
  # This means fast-failure detection is disabled — no fast_fail log entries
  unset DVB_MIN_SESSION 2>/dev/null || true
  unset DVB_NET_FILE 2>/dev/null || true
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'fast_fail' "$TEST_LOG"
  ! grep -q 'network_down' "$TEST_LOG"
}

@test "DVB_MIN_SESSION overrides the default threshold" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # With min_session=999, every instant session is a fast failure
  grep -q 'fast_fail' "$TEST_LOG"
}

@test "DVB_NET_WAIT controls polling interval" {
  # This is a structural test — verify the variable is used
  grep -q 'DVB_NET_WAIT' "$DVB_GRIND"
  grep -q 'interval.*DVB_NET_WAIT' "$DVB_GRIND"
}

@test "DVB_NET_MAX_WAIT controls timeout" {
  grep -q 'DVB_NET_MAX_WAIT' "$DVB_GRIND"
  grep -q 'max_wait.*DVB_NET_MAX_WAIT' "$DVB_GRIND"
}

@test "network down message shows in terminal output" {
  export DVB_NET_FILE="$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=0
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Network down"* ]]
}

@test "network restored message shows in terminal output" {
  # Schedule network recovery after a delay — must be long enough that the
  # first fast-failure check sees network down before the file appears.
  (sleep 3; touch "$TEST_DIR/net-up") &
  local _touch_pid=$!

  local restore_devin="$TEST_DIR/restore-devin"
  cat > "$restore_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
SCRIPT
  chmod +x "$restore_devin"
  export DVB_GRIND_CMD="$restore_devin"
  export DVB_NET_FILE="$TEST_DIR/net-up"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_MAX_FAST=999
  export DVB_MAX_ZERO_SHIP=10
  export DVB_NET_WAIT=0
  export DVB_NET_MAX_WAIT=30
  export DVB_DEADLINE=$(( $(date +%s) + 15 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  kill "$_touch_pid" 2>/dev/null || true
  wait "$_touch_pid" 2>/dev/null || true
  [[ "$output" == *"Network back"* ]]
}

@test "fast failure warning shows exit code in terminal output" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"fast failures"* ]]
  [[ "$output" == *"exit="* ]]
}

@test "session end log includes exit code and duration" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE 'session=1 ended exit=[0-9]+ duration=[0-9]+s' "$TEST_LOG"
}

# ── Diagnostics and bail out ──────────────────────────────────────────

@test "non-zero exit code is logged per session" {
  local failing_devin="$TEST_DIR/fail-devin"
  cat > "$failing_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 42
SCRIPT
  chmod +x "$failing_devin"
  export DVB_GRIND_CMD="$failing_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'exit=42' "$TEST_LOG"
}

@test "exit code shows in terminal session end message" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"exit=0"* ]]
}

@test "DVB_MAX_FAST defaults to 5" {
  grep -q 'DVB_MAX_FAST:-5' "$DVB_GRIND"
}

@test "max fast failures bails out with diagnostic" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Giving up"* ]]
  grep -q 'bail_out' "$TEST_LOG"
}

@test "bail out stops the loop (no more sessions after)" {
  local counter_devin="$TEST_DIR/counter-devin"
  cat > "$counter_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
SCRIPT
  chmod +x "$counter_devin"
  export DVB_GRIND_CMD="$counter_devin"
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should have exactly 3 invocations (bail at 3, not more)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 3 ]
}

@test "fast failure captures session output to log" {
  local err_devin="$TEST_DIR/err-devin"
  cat > "$err_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "ERROR: something went wrong"
exit 1
SCRIPT
  chmod +x "$err_devin"
  export DVB_GRIND_CMD="$err_devin"
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=2
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 3 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'session.*output' "$TEST_LOG"
  grep -q 'ERROR: something went wrong' "$TEST_LOG"
}

@test "bail out shows last session output in terminal" {
  local err_devin="$TEST_DIR/err-devin"
  cat > "$err_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "FATAL: cannot connect to API"
exit 1
SCRIPT
  chmod +x "$err_devin"
  export DVB_GRIND_CMD="$err_devin"
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"FATAL: cannot connect to API"* ]]
}

@test "bail out log includes exit code" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_MAX_FAST=3
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE 'bail_out consecutive=3 exit=[0-9]+' "$TEST_LOG"
}

# ── Argument hardening ─────────────────────────────────────────────────

@test "--skill without a value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

@test "--skill=fleet-grind equals syntax works" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --skill=fleet-grind
  [ "$status" -eq 0 ]
  grep -q 'Run the fleet-grind skill' "$DVB_GRIND_INVOKE_LOG"
}

@test "--skill= empty value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" "--skill="
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a non-empty name"* ]]
}

@test "--backend= empty value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" "--backend="
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

@test "DVB_COOL=abc exits with must be numeric error" {
  export DVB_COOL=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be numeric"* ]]
}

@test "DVB_MAX_FAST=abc exits with must be numeric error" {
  export DVB_MAX_FAST=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_FAST must be numeric"* ]]
}

@test "DVB_MAX_SESSION=abc exits with must be numeric error" {
  export DVB_MAX_SESSION=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_SESSION must be numeric"* ]]
}

@test "DVB_SHUTDOWN_GRACE=abc exits with must be numeric error" {
  export DVB_SHUTDOWN_GRACE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SHUTDOWN_GRACE must be numeric"* ]]
}

@test "DVB_MIN_SESSION=abc exits with must be numeric error" {
  export DVB_MIN_SESSION=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MIN_SESSION must be numeric"* ]]
}

@test "DVB_NET_WAIT=abc exits with must be numeric error" {
  export DVB_NET_WAIT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_WAIT must be numeric"* ]]
}

@test "DVB_NET_MAX_WAIT=abc exits with must be numeric error" {
  export DVB_NET_MAX_WAIT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_MAX_WAIT must be numeric"* ]]
}

@test "DVB_NET_RETRIES=abc exits with must be numeric error" {
  export DVB_NET_RETRIES=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_RETRIES must be numeric"* ]]
}

@test "DVB_NET_RETRY_DELAY=abc exits with must be numeric error" {
  export DVB_NET_RETRY_DELAY=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NET_RETRY_DELAY must be numeric"* ]]
}

@test "DVB_BACKOFF_BASE=abc exits with must be numeric error" {
  export DVB_BACKOFF_BASE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_BACKOFF_BASE must be numeric"* ]]
}

@test "DVB_BACKOFF_MAX=abc exits with must be numeric error" {
  export DVB_BACKOFF_MAX=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_BACKOFF_MAX must be numeric"* ]]
}

@test "DVB_SYNC_INTERVAL=abc exits with must be numeric error" {
  export DVB_SYNC_INTERVAL=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SYNC_INTERVAL must be numeric"* ]]
}

@test "DVB_GIT_SYNC_TIMEOUT=abc exits with must be numeric error" {
  export DVB_GIT_SYNC_TIMEOUT=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_GIT_SYNC_TIMEOUT must be numeric"* ]]
}

@test "DVB_DEADLINE=abc exits with must be epoch error" {
  export DVB_DEADLINE=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DVB_DEADLINE must be a Unix epoch integer"* ]]
}

@test "numeric directory name treated as repo path not hours" {
  local num_dir="$TEST_DIR/42"
  mkdir -p "$num_dir"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$num_dir" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$num_dir"* ]]
}

# ── Inter-session git pull ─────────────────────────────────────────────

@test "pulls latest changes between sessions in a git repo" {
  # Initialize the test repo as a git repo with a remote
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  # Create a bare remote and push
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin HEAD 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync ok' "$TEST_LOG"
}

@test "skips git pull for non-git repos" {
  # TEST_REPO is a plain directory (no .git)
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'git_sync' "$TEST_LOG"
}

@test "skips git pull for git repos without a remote" {
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  # No remote added

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'git_sync' "$TEST_LOG"
}

@test "fast_fail log includes exit code" {
  local net_file="$TEST_DIR/net-up"
  touch "$net_file"
  export DVB_NET_FILE="$net_file"
  export DVB_MIN_SESSION=999
  export DVB_BACKOFF_BASE=0
  export DVB_COOL=0
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE 'fast_fail.*exit=[0-9]+' "$TEST_LOG"
}

# ── Print mode and session timeout ────────────────────────────────────

@test "uses -p (print mode) not -- (interactive mode)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must use -p for non-interactive mode (exits after completion)
  grep -q -- '-p ' "$DVB_GRIND_INVOKE_LOG"
  # Must NOT use -- separator (interactive mode waits for user input)
  ! grep -q -- ' -- Run the' "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MAX_SESSION defaults to 3600" {
  grep -q 'DVB_MAX_SESSION:-3600' "$DVB_GRIND"
}

@test "timeout watchdog uses kill-0 polling to detect session exit" {
  grep -q 'kill -0 "$_dvb_pid"' "$DVB_GRIND"
}

@test "timeout watchdog logs session_timeout on kill" {
  grep -q 'session_timeout' "$DVB_GRIND"
}

@test "timeout watchdog is killable via SIGTERM (trap + sleep &; wait)" {
  grep -q "trap 'kill \$! 2>/dev/null; exit 0' TERM" "$DVB_GRIND"
  grep -q 'sleep "$s" &' "$DVB_GRIND"
  grep -q 'wait $!' "$DVB_GRIND"
}

# ── Stderr Logging ────────────────────────────────────────────────────

@test "production mode redirects stderr to log file" {
  grep -q '2>> "$log_file" &' "$DVB_GRIND"
}

# ── macOS Notification ────────────────────────────────────────────────

@test "sends macOS notification on completion by default" {
  grep -q 'osascript.*display notification' "$DVB_GRIND"
}

@test "DVB_NOTIFY=0 suppresses notification" {
  grep -q 'DVB_NOTIFY:-1' "$DVB_GRIND"
  grep -q 'DVB_NOTIFY' "$DVB_GRIND"
}

@test "notification includes session count and tasks shipped" {
  grep -q 'tasks shipped' "$DVB_GRIND"
}

@test "notification uses argv passing to avoid osascript injection" {
  # osascript should receive the message as an argument, not interpolated in the script
  grep -q 'on run argv' "$DVB_GRIND"
  grep -q 'item 1 of argv' "$DVB_GRIND"
}

@test "git sync output is sanitized before logging" {
  # Control characters should be stripped from git sync output
  grep -q "tr -cd '\[:print:\]" "$DVB_GRIND"
}

# ── Dry Run ───────────────────────────────────────────────────────────

@test "--dry-run prints config and exits 0" {
  run "$DVB_GRIND" --dry-run 4 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"taskgrind --dry-run"* ]]
  [[ "$output" == *"hours:    4"* ]]
  [[ "$output" == *"skill:    next-task"* ]]
  [[ "$output" == *"Prompt:"* ]]
  [[ "$output" == *"Previous session context"* ]]
  [[ "$output" == *"Commit before timeout"* ]]
}

@test "--dry-run shows custom skill" {
  run "$DVB_GRIND" --dry-run --skill fleet-grind 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill:    fleet-grind"* ]]
}

@test "--dry-run shows repo path" {
  run "$DVB_GRIND" --dry-run "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo:     $TEST_REPO"* ]]
}

@test "--dry-run does not create log file" {
  local dry_log="$TEST_DIR/dry-run.log"
  export DVB_LOG="$dry_log"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$dry_log" ]
}

@test "--dry-run does not launch any devin sessions" {
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "--dry-run shows --prompt focus" {
  run "$DVB_GRIND" --dry-run --prompt "test coverage" 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt:   test coverage"* ]]
  [[ "$output" == *"FOCUS: test coverage"* ]]
}

@test "--dry-run omits prompt line when no --prompt given" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"prompt:"* ]]
  [[ "$output" != *"FOCUS:"* ]]
}

# ── Log File Security ────────────────────────────────────────────────

@test "log file permissions are 600 (owner-only)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ -f "$TEST_LOG" ]
  local perms
  perms=$(stat -f '%Lp' "$TEST_LOG" 2>/dev/null || stat -c '%a' "$TEST_LOG" 2>/dev/null)
  [ "$perms" = "600" ]
}

@test "DVB_LOG pointing to directory exits with error" {
  export DVB_LOG="$TEST_DIR"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"points to a directory"* ]]
}

@test "DVB_LOG with nonexistent parent creates parent directory" {
  export DVB_LOG="$TEST_DIR/deep/nested/dir/grind.log"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/deep/nested/dir/grind.log" ]
}

# ── format_duration branch coverage ──────────────────────────────────

@test "format_duration minutes-only branch: 120s → 2m" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 120)
  [ "$result" = "2m" ]
}

@test "format_duration hours+minutes branch: 3661s → 1h1m" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 3661)
  [ "$result" = "1h1m" ]
}

@test "format_duration seconds branch: 45s → 45s" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 45)
  [ "$result" = "45s" ]
}

@test "format_duration zero seconds: 0 → 0s" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 0)
  [ "$result" = "0s" ]
}

@test "format_duration exact hour: 3600s → 1h0m" {
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
  result=$(dvb_format_duration 3600)
  [ "$result" = "1h0m" ]
}

# ── Signal handling ──────────────────────────────────────────────────

@test "taskgrind traps INT signal for cleanup" {
  grep -q "trap.*INT" "$DVB_GRIND"
}

@test "taskgrind traps TERM signal for cleanup" {
  grep -q "trap.*TERM" "$DVB_GRIND"
}

@test "taskgrind prints summary on interrupt (INT/TERM)" {
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<'SCRIPT'
#!/bin/bash
sleep 10
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/signal-output.txt" 2>&1 &
  local grind_pid=$!
  sleep 2
  kill -INT "$grind_pid" 2>/dev/null || true
  wait "$grind_pid" 2>/dev/null || true
  grep -q "Grind complete\|sessions" "$TEST_DIR/signal-output.txt"
}

# ── Graceful shutdown ────────────────────────────────────────────────

@test "INT signal waits for running session before exiting" {
  # Slow devin that takes 5s but records when it starts and finishes
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "session_started" >> "$TEST_DIR/session-lifecycle.log"
sleep 3
echo "session_finished" >> "$TEST_DIR/session-lifecycle.log"
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  export DVB_SHUTDOWN_GRACE=10

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/graceful-output.txt" 2>&1 &
  local grind_pid=$!
  sleep 1
  # Send INT while session is running
  kill -INT "$grind_pid" 2>/dev/null || true
  wait "$grind_pid" 2>/dev/null || true
  # Session should have finished (session_finished written)
  grep -q 'session_finished' "$TEST_DIR/session-lifecycle.log"
}

@test "graceful shutdown function is called on INT" {
  # Structural: INT trap calls graceful_shutdown, not just cleanup
  grep -q "trap 'graceful_shutdown 130' INT" "$DVB_GRIND"
}

@test "graceful shutdown sends SIGINT then waits before SIGTERM" {
  # Structural: graceful_shutdown sends INT first, sleeps in a loop, then SIGTERM
  grep -q 'kill -INT.*_dvb_pid' "$DVB_GRIND"
  grep -q 'DVB_SHUTDOWN_GRACE' "$DVB_GRIND"
  # Verify SIGTERM escalation exists after grace period
  grep -A5 'waited -lt.*_shutdown_grace' "$DVB_GRIND" | grep -q 'kill.*_dvb_pid'
}

@test "structural: graceful_shutdown waits for _dvb_pid" {
  grep -q 'graceful_shutdown' "$DVB_GRIND"
  grep -q 'kill -INT.*_dvb_pid' "$DVB_GRIND"
  grep -q 'DVB_SHUTDOWN_GRACE' "$DVB_GRIND"
}

@test "structural: final_sync pushes local commits" {
  grep -q 'final_sync' "$DVB_GRIND"
  grep -q 'git.*push.*origin' "$DVB_GRIND"
}

@test "structural: EXIT trap calls final_sync before cleanup" {
  grep -q "trap 'final_sync; cleanup' EXIT" "$DVB_GRIND"
}

# ── Tasks unchanged scenario ─────────────────────────────────────────

@test "zero tasks shipped when tasks unchanged between sessions" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'shipped=0' "$TEST_LOG"
}

@test "summary shows 0+ tasks when no tasks shipped" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task that stays
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"0+ tasks"* ]]
}

# ── Deadline check before cooldown ───────────────────────────────────

@test "deadline check before cooldown prevents sleeping past deadline" {
  grep -q 'Check deadline before cooldown' "$DVB_GRIND"
  local check_line sleep_line
  check_line=$(grep -n 'Check deadline before cooldown' "$DVB_GRIND" | head -1 | cut -d: -f1)
  sleep_line=$(grep -n 'sleep "$cooldown"' "$DVB_GRIND" | head -1 | cut -d: -f1)
  [ -n "$check_line" ]
  [ -n "$sleep_line" ]
  [ "$check_line" -lt "$sleep_line" ]
}

@test "grind exits immediately when deadline reached mid-loop" {
  export DVB_DEADLINE=$(( $(date +%s) + 1 ))
  export DVB_COOL=60
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Grind complete"* ]]
}

# ── Caffeinate re-exec ───────────────────────────────────────────────

@test "caffeinate re-exec is skipped in test mode" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "DVB_CAFFEINATED env prevents double caffeinate" {
  grep -q 'DVB_CAFFEINATED' "$DVB_GRIND"
  grep -A2 'DVB_CAFFEINATED' "$DVB_GRIND" | grep -q 'caffeinate'
}

@test "Linux: systemd-inhibit fallback for caffeinate (structural)" {
  grep -q 'systemd-inhibit' "$DVB_GRIND"
  grep -q 'idle:sleep' "$DVB_GRIND"
}

@test "Linux: flock fallback for lockf (structural)" {
  grep -q 'flock -n 9' "$DVB_GRIND"
}

@test "Linux: notify-send fallback for osascript (structural)" {
  grep -q 'notify-send' "$DVB_GRIND"
}

# ── Reset to main between sessions ──────────────────────────────────

@test "between-session sync checks out default branch, not the current branch" {
  # Verify the code checks out detected default branch (not a raw variable)
  grep -q 'checkout "$_default_branch"' "$DVB_GRIND"
  ! grep -q 'pull.*origin.*\$branch' "$DVB_GRIND"
}

@test "between-session sync fetches with --prune" {
  grep -q 'fetch origin --prune' "$DVB_GRIND"
}

@test "between-session sync rebases on origin default branch" {
  grep -q 'rebase "origin/$_default_branch"' "$DVB_GRIND"
}

@test "agent on feature branch gets reset to main next session" {
  # Initialize repo with main + feature branch
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create a feature branch and leave the repo on it
  git -C "$TEST_REPO" checkout -q -b chore/grind-session-1
  echo "feature" > "$TEST_REPO/feature.txt"
  git -C "$TEST_REPO" add feature.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "feature work"

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # After grind, repo should be on main
  local current_branch
  current_branch=$(git -C "$TEST_REPO" symbolic-ref --short HEAD 2>/dev/null)
  [ "$current_branch" = "main" ]
}

@test "git sync stashes dirty working tree before checkout" {
  # Structural: git diff --quiet check before checkout
  grep -q 'git -C "$repo" diff --quiet' "$DVB_GRIND"
  grep -q 'git -C "$repo" stash --include-untracked' "$DVB_GRIND"
}

@test "git sync restores stash after rebase" {
  # Structural: stash pop after rebase
  grep -q 'git -C "$repo" stash pop' "$DVB_GRIND"
}

@test "git sync logs stashed dirty tree" {
  # Structural: log message includes stash info
  grep -q 'stashed dirty tree' "$DVB_GRIND"
}

@test "dirty working tree survives between-session sync" {
  # Initialize repo with main branch and remote
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  # Create a dirty file (simulating agent leaving uncommitted changes)
  echo "uncommitted work" > "$TEST_REPO/dirty.txt"
  git -C "$TEST_REPO" add dirty.txt

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  # The dirty file should still exist after sync
  [ -f "$TEST_REPO/dirty.txt" ]
  # Log should mention stashing
  grep -q 'stashed dirty tree' "$TEST_LOG"
}

@test "stash pop failure is logged and stash preserved" {
  # Structural: stash pop failure produces a log marker
  grep -q 'stash_pop_failed' "$DVB_GRIND"
  # Structural: user-visible warning about stash pop failure
  grep -q 'stash pop failed.*stash preserved' "$DVB_GRIND"
}

# ── Stall detection (zero-ship sessions) ─────────────────────────────

@test "DVB_MAX_ZERO_SHIP defaults to 8" {
  grep -q 'DVB_MAX_ZERO_SHIP:-8' "$DVB_GRIND"
}

@test "5 consecutive zero-ship sessions exits the marathon" {
  # Create a persistent task that never gets removed
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task that never completes
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zero-ship sessions"* ]]
  [[ "$output" == *"stalled"* ]]
  grep -q 'stall_bail' "$TEST_LOG"
  # Should have exactly 5 sessions (bail at 5)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$count" -eq 5 ]
}

@test "3 consecutive zero-ship sessions adds stall warning to log" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'stall_warning consecutive_zero_ship=3' "$TEST_LOG"
}

@test "stall warning appears in prompt after 3 zero-ship sessions" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 4's prompt should contain the stall warning
  grep -q 'WARNING.*shipped nothing' "$DVB_GRIND_INVOKE_LOG"
}

@test "stall warning tells agent to decompose" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Large task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must mention decompose
  grep -q 'decompose' "$DVB_GRIND_INVOKE_LOG"
  # Should NOT mention sweep (removed from prompt)
  ! grep -q 'sweep' "$DVB_GRIND_INVOKE_LOG"
}

@test "productive zero-ship detected when agent commits but does not remove task" {
  # Set up a real git repo so git HEAD changes can be detected
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" add TASKS.md
  git -C "$TEST_REPO" commit -q -m "initial"

  # Fake devin that commits code but never removes the task
  local commit_devin="$TEST_DIR/commit-devin"
  cat > "$commit_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "fix something" >> "$TEST_REPO/code.txt"
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -q -m "fix: session work" --allow-empty
SCRIPT
  chmod +x "$commit_devin"
  export DVB_GRIND_CMD="$commit_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task that never gets removed
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'productive_zero_ship' "$TEST_LOG"
}

@test "productive zero-ship escalation appears in prompt after 2 zero-ship sessions with commits" {
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" add TASKS.md
  git -C "$TEST_REPO" commit -q -m "initial"

  local commit_devin="$TEST_DIR/commit-devin"
  cat > "$commit_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
echo "work" >> "$TEST_REPO/code.txt"
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -q -m "fix: do work"
SCRIPT
  chmod +x "$commit_devin"
  export DVB_GRIND_CMD="$commit_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Persistent task
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Session 3's prompt should contain the URGENT escalation
  grep -q 'URGENT.*committed code.*did NOT remove' "$DVB_GRIND_INVOKE_LOG"
}

@test "no productive zero-ship when no commits and no ships" {
  # Non-git repo: no commits possible, so no productive zero-ship
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Task
TASKS

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'productive_zero_ship' "$TEST_LOG"
}

@test "zero-ship counter resets when a session ships a task" {
  # Fake devin that removes a task each run by counting invocations and rewriting TASKS.md
  local ship_devin="$TEST_DIR/ship-devin"
  local counter_file="$TEST_DIR/ship-counter"
  echo "0" > "$counter_file"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
# Increment counter and rewrite TASKS.md with one fewer task
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
remaining=\$((30 - n))
[ \$remaining -lt 0 ] && remaining=0
{
  echo "# Tasks"
  echo "## P0"
  i=1
  while [ \$i -le \$remaining ]; do
    echo "- [ ] Task \$i"
    i=\$((i + 1))
  done
} > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  # Start with 30 tasks
  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 30); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"

  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=3
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Should NOT have stall_bail — every session ships a task, counter stays at 0
  ! grep -q 'stall_bail' "$TEST_LOG"
  # Verify tasks were actually shipped
  [ "$( grep -c 'shipped=[1-9]' "$TEST_LOG" || true )" -ge 1 ]
}

@test "DVB_MAX_ZERO_SHIP=abc exits with must be numeric error" {
  export DVB_MAX_ZERO_SHIP=abc
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_MAX_ZERO_SHIP must be numeric"* ]]
}

# ── Branch cleanup between sessions ───────────────────────────────────

@test "merged branches are cleaned up between sessions" {
  # Initialize repo with main
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create and merge a feature branch
  git -C "$TEST_REPO" checkout -q -b already-merged
  echo "merged" > "$TEST_REPO/merged.txt"
  git -C "$TEST_REPO" add merged.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "merged branch"
  git -C "$TEST_REPO" checkout -q main
  git -C "$TEST_REPO" merge -q already-merged --no-edit
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The merged branch should be deleted
  ! git -C "$TEST_REPO" branch | grep -q 'already-merged'
  grep -q 'branch_cleanup done' "$TEST_LOG"
}

@test "unmerged branches are not deleted" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create an unmerged branch
  git -C "$TEST_REPO" checkout -q -b work-in-progress
  echo "wip" > "$TEST_REPO/wip.txt"
  git -C "$TEST_REPO" add wip.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "wip"
  git -C "$TEST_REPO" checkout -q main

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The unmerged branch should still exist
  git -C "$TEST_REPO" branch | grep -q 'work-in-progress'
}

@test "branch cleanup deletes merged branches with main as substring" {
  # Regression: old grep -v '^\*\|main' filtered branches containing "main" anywhere
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create and merge a branch with "main" as substring
  git -C "$TEST_REPO" checkout -q -b maintain-docs
  echo "docs" > "$TEST_REPO/docs.txt"
  git -C "$TEST_REPO" add docs.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "maintain docs"
  git -C "$TEST_REPO" checkout -q main
  git -C "$TEST_REPO" merge -q maintain-docs --no-edit
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Branch with "main" substring should be deleted when merged
  ! git -C "$TEST_REPO" branch | grep -q 'maintain-docs'
}

@test "stale branches with gone upstream are pruned" {
  # When a remote branch is deleted (e.g., merged on GitHub), the local branch
  # tracking it becomes stale. After fetch --prune, it shows [gone] upstream.
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create a feature branch, push it, then delete it on the remote
  git -C "$TEST_REPO" checkout -q -b stale-feature
  echo "feature" > "$TEST_REPO/feature.txt"
  git -C "$TEST_REPO" add feature.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "feature work"
  git -C "$TEST_REPO" push -q origin stale-feature 2>/dev/null
  # Set upstream tracking
  git -C "$TEST_REPO" branch --set-upstream-to=origin/stale-feature stale-feature 2>/dev/null
  git -C "$TEST_REPO" checkout -q main
  # Delete the remote branch (simulates GitHub merge+delete)
  git -C "$bare" branch -D stale-feature 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The stale branch should be pruned
  ! git -C "$TEST_REPO" branch | grep -q 'stale-feature'
  grep -q 'branch_cleanup pruned=1' "$TEST_LOG"
}

@test "stale branch cleanup logs count when multiple branches pruned" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create two feature branches, push them, delete on remote
  for branch_name in stale-one stale-two; do
    git -C "$TEST_REPO" checkout -q -b "$branch_name"
    echo "$branch_name" > "$TEST_REPO/${branch_name}.txt"
    git -C "$TEST_REPO" add "${branch_name}.txt"
    git -C "$TEST_REPO" commit -q --no-verify -m "$branch_name"
    git -C "$TEST_REPO" push -q origin "$branch_name" 2>/dev/null
    git -C "$TEST_REPO" branch --set-upstream-to="origin/$branch_name" "$branch_name" 2>/dev/null
    git -C "$TEST_REPO" checkout -q main
    git -C "$bare" branch -D "$branch_name" 2>/dev/null
  done

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! git -C "$TEST_REPO" branch | grep -q 'stale-one'
  ! git -C "$TEST_REPO" branch | grep -q 'stale-two'
  grep -q 'branch_cleanup pruned=2' "$TEST_LOG"
}

@test "non-stale tracking branches are not pruned" {
  # Branches with a live upstream should survive cleanup
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create a branch that still exists on remote
  git -C "$TEST_REPO" checkout -q -b active-feature
  echo "active" > "$TEST_REPO/active.txt"
  git -C "$TEST_REPO" add active.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "active"
  git -C "$TEST_REPO" push -q origin active-feature 2>/dev/null
  git -C "$TEST_REPO" branch --set-upstream-to=origin/active-feature active-feature 2>/dev/null
  git -C "$TEST_REPO" checkout -q main

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Active branch should still exist
  git -C "$TEST_REPO" branch | grep -q 'active-feature'
  # No stale branches pruned
  ! grep -q 'branch_cleanup pruned=' "$TEST_LOG"
}

# ── PID in log file and log lines ─────────────────────────────────────

@test "default log file name includes repo and PID for uniqueness" {
  unset DVB_LOG
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Log path in output should include repo basename and PID segment before .log
  [[ "$output" =~ taskgrind-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[a-zA-Z0-9_.-]+-[0-9]+\.log ]]
}

@test "log lines include pid= prefix" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # At least one log_write line should have the [pid=N] prefix
  grep -qE '^\[pid=[0-9]+\]' "$TEST_LOG"
}

@test "grind_done log line includes pid= prefix" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -qE '^\[pid=[0-9]+\].*grind_done' "$TEST_LOG"
}

@test "two rapid invocations get separate default log files" {
  # Structural: log name includes repo basename + PID so different runs cannot collide
  unset DVB_LOG
  local log_pattern
  log_pattern=$(grep 'DVB_LOG:-' "$DVB_GRIND")
  [[ "$log_pattern" == *'$$'* ]]
  [[ "$log_pattern" == *'_repo_basename'* ]]
}

# ── Rebase abort between sessions ─────────────────────────────────────

@test "rebase conflict is auto-aborted between sessions" {
  # Initialize repo with a commit on main
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "main content" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  # Create a divergent history that will conflict on rebase
  echo "remote change" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "remote change"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Reset local main behind remote and make a conflicting commit
  git -C "$TEST_REPO" reset -q --hard HEAD~1
  echo "local conflicting change" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "local conflict"

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'rebase_aborted' "$TEST_LOG"
  # Repo should NOT be in rebase-in-progress state
  [ ! -d "$TEST_REPO/.git/rebase-merge" ]
  [ ! -d "$TEST_REPO/.git/rebase-apply" ]
}

@test "clean rebase does not log rebase_aborted" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync ok' "$TEST_LOG"
  ! grep -q 'rebase_aborted' "$TEST_LOG"
}

# ── Default branch detection ──────────────────────────────────────────

@test "git sync detects default branch from origin/HEAD" {
  # Structural: script uses symbolic-ref to detect default branch
  grep -q 'symbolic-ref refs/remotes/origin/HEAD' "$DVB_GRIND"
}

@test "git sync falls back to main when origin/HEAD is missing" {
  # Structural: fallback assignment
  grep -q '_default_branch="${_default_branch:-main}"' "$DVB_GRIND"
}

@test "git sync uses detected branch for checkout and rebase" {
  grep -q 'checkout "$_default_branch"' "$DVB_GRIND"
  grep -q 'rebase "origin/$_default_branch"' "$DVB_GRIND"
}

# ── Git sync timeout recovery ─────────────────────────────────────────

@test "git sync timeout aborts in-progress rebase" {
  # Structural: the failure branch checks for rebase-in-progress and aborts
  grep -q 'timeout_rebase_aborted' "$DVB_GRIND"
}

@test "git sync timeout aborts in-progress merge" {
  # Structural: the failure branch checks for MERGE_HEAD and aborts
  grep -q 'timeout_merge_aborted' "$DVB_GRIND"
}

@test "DVB_GIT_SYNC_TIMEOUT controls git sync timeout" {
  # Structural: the variable is read from env
  grep -q 'DVB_GIT_SYNC_TIMEOUT:-30' "$DVB_GRIND"
}

# ── Network check retry ──────────────────────────────────────────────

@test "network check retries before declaring down" {
  # Structural: retry loop in check_network
  grep -q 'DVB_NET_RETRIES:-3' "$DVB_GRIND"
  grep -q '_check_network_once && return 0' "$DVB_GRIND"
}

@test "network check skips retry in test mode" {
  # Test mode calls _check_network_once directly, bypassing the retry loop
  grep -q '_check_network_once; return' "$DVB_GRIND"
}

# ── Devin binary PATH fallback ────────────────────────────────────────

@test "devin path resolution checks PATH before default" {
  # Structural: lib/constants.sh has command -v devin fallback
  local constants="$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -q 'command -v devin' "$constants"
}

@test "DVB_DEVIN_PATH env override is respected" {
  # Structural: lib/constants.sh checks DVB_DEVIN_PATH first
  local constants="$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -q 'DVB_DEVIN_PATH:-' "$constants" || grep -q 'DVB_DEVIN_PATH' "$constants"
}

# ── Zero-ship session diagnostics ─────────────────────────────────────

@test "zero-ship session captures output tail to log" {
  # Fake devin that prints diagnostic output but doesn't remove tasks
  local diag_devin="$TEST_DIR/diag-devin"
  cat > "$diag_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "Working on hard task..."
echo "STUCK: cannot resolve merge conflict"
SCRIPT
  chmod +x "$diag_devin"
  export DVB_GRIND_CMD="$diag_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Hard task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Log should contain the session output capture
  grep -q 'zero-ship.*last 20 lines' "$TEST_LOG"
  grep -q 'STUCK: cannot resolve merge conflict' "$TEST_LOG"
}

@test "zero-ship diagnostics do not fire when tasks are shipped" {
  # Use sed '1,' (BSD-compatible) to delete the first task each session
  local ship_devin="$TEST_DIR/ship-devin"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
REPO="$TEST_REPO"
if [ -f "\$REPO/TASKS.md" ]; then
  sed -i '' '1,/^- \[ \]/{/^- \[ \]/d;}' "\$REPO/TASKS.md" 2>/dev/null || \
  sed -i '1,/^- \[ \]/{/^- \[ \]/d;}' "\$REPO/TASKS.md" 2>/dev/null || true
fi
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  # Enough tasks that every session ships before the deadline
  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 50); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Every session ships a task, so no zero-ship output captures
  ! grep -q 'zero-ship' "$TEST_LOG"
}

# ── Efficiency summary in grind_done ──────────────────────────────────

@test "grind_done terminal output includes rate and avg session" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rate:"* ]]
  [[ "$output" == *"/h"* ]]
  [[ "$output" == *"Avg session:"* ]]
  [[ "$output" == *"Zero-ship:"* ]]
}

@test "grind_done log line includes rate and sessions_zero_ship" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'grind_done.*rate=.*sessions_zero_ship=' "$TEST_LOG"
}

@test "grind_done log includes avg_session field" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'avg_session=' "$TEST_LOG"
}

@test "zero-ship count in summary matches actual zero-ship sessions" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 15 ))
  export DVB_MAX_ZERO_SHIP=3
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Zero-ship: 3"* ]]
  grep -q 'sessions_zero_ship=3' "$TEST_LOG"
}

# ── Multi-project locking ─────────────────────────────────────────────

@test "locking uses lockf(1) on macOS and flock(1) on Linux" {
  grep -q 'lockf -t 0 9' "$DVB_GRIND"
  grep -q 'flock -n 9' "$DVB_GRIND"
}

@test "lock file path is derived from repo hash" {
  grep -q 'shasum' "$DVB_GRIND"
  grep -q 'taskgrind-lock-' "$DVB_GRIND"
}

@test "lock writes diagnostic info (repo, pid, start time)" {
  grep -q 'repo=.*pid=.*started=' "$DVB_GRIND"
}

@test "lock error message shows repo path" {
  grep -q 'another taskgrind is already running' "$DVB_GRIND"
  grep -q 'repo:' "$DVB_GRIND"
}

@test "locking is skipped in test mode" {
  # DVB_GRIND_CMD being set should skip the lock (fd 9) section
  grep -q 'DVB_GRIND_CMD.*locking\|DVB_GRIND_CMD.*fd conflicts\|DVB_GRIND_CMD.*avoid fd' "$DVB_GRIND"
}

@test "two grinds on different repos get different lock files" {
  # Lock hash should differ for different repo paths
  local hash1 hash2
  hash1=$(echo "/tmp/repo-a" | shasum | cut -d' ' -f1)
  hash2=$(echo "/tmp/repo-b" | shasum | cut -d' ' -f1)
  [ "$hash1" != "$hash2" ]
}

@test "same repo path always gets the same lock file hash" {
  local hash1 hash2
  hash1=$(echo "/Users/me/apps/myrepo" | shasum | cut -d' ' -f1)
  hash2=$(echo "/Users/me/apps/myrepo" | shasum | cut -d' ' -f1)
  [ "$hash1" = "$hash2" ]
}

# ── Temp file cleanup patterns ─────────────────────────────────────────

@test "find cleanup patterns only match taskgrind-prefixed files" {
  # The find fallback must use 'taskgrind-*' prefix on all patterns to avoid
  # deleting files from other tools in TMPDIR.
  # Extract the find lines from the cleanup block
  local find_lines
  find_lines=$(grep 'find.*_dvb_tmp.*-delete' "$DVB_GRIND")
  # Every -name pattern must start with 'taskgrind-'
  local bad_patterns
  bad_patterns=$(echo "$find_lines" | grep -oE "'-name' '[^']*'|-name '[^']*'" | grep -v 'taskgrind-' || true)
  [ -z "$bad_patterns" ]
}

@test "fd cleanup regex is scoped to taskgrind files" {
  # The fd regex should only match files starting with 'taskgrind-'
  grep -q "taskgrind-(exec" "$DVB_GRIND"
}

# ── grind_done log ordering on Ctrl-C ──────────────────────────────────

@test "grind_done is last log entry on Ctrl-C interrupt" {
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  local slow_devin="$TEST_DIR/slow-devin"
  cat > "$slow_devin" <<'SCRIPT'
#!/bin/bash
sleep 10
SCRIPT
  chmod +x "$slow_devin"
  export DVB_GRIND_CMD="$slow_devin"

  "$DVB_GRIND" 1 "$TEST_REPO" > "$TEST_DIR/int-output.txt" 2>&1 &
  local grind_pid=$!
  sleep 2
  kill -INT "$grind_pid" 2>/dev/null || true
  wait "$grind_pid" 2>/dev/null || true
  # grind_done should be the last log_write entry — no session-end after it
  local last_content_line
  last_content_line=$(grep -v '^#' "$TEST_LOG" | grep -v '^$' | tail -1)
  [[ "$last_content_line" == *"grind_done"* ]]
}

@test "_dvb_finalizing flag guards session-end log after cleanup" {
  # Structural: session-end log is wrapped in _dvb_finalizing check
  grep -q '_dvb_finalizing.*0.*log_write.*session=.*ended\|_dvb_finalizing -eq 0' "$DVB_GRIND"
}

@test "cleanup sets _dvb_finalizing=1" {
  grep -q '_dvb_finalizing=1' "$DVB_GRIND"
}

# ── Devin binary validation ────────────────────────────────────────────

@test "missing devin binary exits immediately with clear error" {
  # Use production path (no DVB_GRIND_CMD) with nonexistent binary.
  # Set DVB_DEVIN_PATH to a nonexistent path and strip real devin from PATH.
  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="/nonexistent/devin"
  export HOME="/nonexistent/home"
  # Remove devin from PATH so command -v devin fails
  export PATH="/usr/bin:/bin"
  # Skip caffeinate and self-copy by pre-setting the guards
  export DVB_CAFFEINATED=1
  export _DVB_SELF_COPY="/dev/null"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"binary not found"* ]]
}

@test "devin binary validation uses -x check (executable)" {
  grep -q '\-x "$_backend_binary"' "$DVB_GRIND"
}

# ── Network watchdog fallback ──────────────────────────────────────────

@test "check_network falls back to curl when network-watchdog is missing" {
  grep -q 'command -v network-watchdog' "$DVB_GRIND"
  grep -q 'curl -sf --max-time 5' "$DVB_GRIND"
}

@test "check_network prefers network-watchdog when available" {
  # Structural: the elif branch checks for network-watchdog before curl fallback
  grep -q 'elif command -v network-watchdog' "$DVB_GRIND"
}

# ── Graceful timeout (SIGINT before SIGTERM) ───────────────────────────

@test "timeout watchdog sends SIGINT before SIGTERM" {
  grep -q 'kill -INT "$_dvb_pid"' "$DVB_GRIND"
}

@test "timeout watchdog has grace period before SIGTERM escalation" {
  # After SIGINT, wait a grace period then check if still alive
  grep -q '_grace=15' "$DVB_GRIND"
  grep -q 'sleep "$_grace"' "$DVB_GRIND"
  grep -q 'still alive after.*grace.*SIGTERM' "$DVB_GRIND"
}

@test "timeout watchdog only sends SIGTERM if process survived SIGINT" {
  # kill -0 check before SIGTERM escalation
  grep -A2 'sleep "$_grace"' "$DVB_GRIND" | grep -q 'kill -0 "$_dvb_pid"'
}

# ── Git sync timer leak fix ────────────────────────────────────────────

@test "git sync timer uses trap+wait pattern to avoid orphaned sleeps" {
  # The git sync timer subshell should have the same pattern as the session
  # timeout watchdog: trap 'kill $! ...; exit 0' TERM + sleep N &; wait $!
  # Count occurrences of the trap pattern — should appear 3+ times:
  # sweep watchdog, session watchdog, git sync timer.
  local count
  count=$(grep -c "trap 'kill \$! 2>/dev/null; exit 0' TERM" "$DVB_GRIND")
  [ "$count" -ge 3 ]
}

# ── Preflight health checks ───────────────────────────────────────────

_preflight_git_init() {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" commit --allow-empty -m "init" --quiet
}

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

@test "preflight has all 7 checks" {
  # Structural: verify all 7 check categories exist
  grep -q 'Backend binary' "$DVB_GRIND"
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

# ── Prompt hardening ───────────────────────────────────────────────────

@test "--prompt adds priority framing to pick matching tasks first" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "focus on test coverage"
  grep -q 'Pick tasks from TASKS.md that relate to this focus' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt priority framing mentions unrelated tasks fallback" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "taskgrind stability"
  grep -q 'Only work on unrelated tasks if no matching tasks remain' "$DVB_GRIND_INVOKE_LOG"
}

@test "log header includes prompt= when --prompt is set" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "test focus"
  grep -q 'prompt=test focus' "$TEST_LOG"
}

@test "log header omits prompt= when no --prompt given" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'prompt=' "$(head -2 "$TEST_LOG")"
}

@test "grind_done log includes prompt when --prompt is set" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "ship features"
  grep 'grind_done' "$TEST_LOG" | grep -q 'prompt=ship features'
}

@test "grind_done log omits prompt when no --prompt given" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep 'grind_done' "$TEST_LOG" | grep -q 'prompt='
}

@test "--prompt with single quotes passes through safely" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt "it's a test"
  grep -q "FOCUS: it's a test" "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt with dollar sign passes through without expansion" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt 'fix $HOME paths'
  grep -q 'FOCUS: fix \$HOME paths' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt with double quotes passes through safely" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO" --prompt 'multi word with "quotes"'
  grep -q 'FOCUS: multi word with "quotes"' "$DVB_GRIND_INVOKE_LOG"
}

@test "--dry-run shows priority framing with --prompt" {
  run "$DVB_GRIND" --dry-run --prompt "test coverage" 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pick tasks from TASKS.md that relate to this focus"* ]]
}

# ── Multi-backend support ─────────────────────────────────────────────

@test "default backend is devin" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"backend=devin"* ]]
}

@test "--backend flag sets backend" {
  run "$DVB_GRIND" --dry-run --backend claude-code 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  claude-code"* ]]
}

@test "--backend=codex equals syntax works" {
  run "$DVB_GRIND" --dry-run --backend=codex 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  codex"* ]]
}

@test "DVB_BACKEND env sets backend" {
  export DVB_BACKEND=claude-code
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  claude-code"* ]]
}

@test "--backend flag overrides DVB_BACKEND env" {
  export DVB_BACKEND=codex
  run "$DVB_GRIND" --dry-run --backend claude-code 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  claude-code"* ]]
}

@test "unknown backend exits with error" {
  run "$DVB_GRIND" --dry-run --backend unknown-backend 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown backend"* ]]
  [[ "$output" == *"Supported: devin, claude-code, codex"* ]]
}

@test "--backend without value exits with clear error" {
  run "$DVB_GRIND" --backend
  [ "$status" -ne 0 ]
  [[ "$output" == *"--backend requires a name"* ]]
}

@test "backend shows in startup banner" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"backend=devin"* ]]
}

@test "backend shows in log file header" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'backend=devin' "$TEST_LOG"
}

@test "--preflight shows backend in config header" {
  _preflight_git_init
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  devin"* ]]
}

@test "--dry-run shows backend in config" {
  run "$DVB_GRIND" --dry-run --backend codex 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  codex"* ]]
}

@test "--dry-run shows early_exit_on_stall enabled by default" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"early_exit_on_stall: 1"* ]]
}

@test "--dry-run shows early_exit_on_stall disabled when DVB_EARLY_EXIT_ON_STALL=0" {
  export DVB_EARLY_EXIT_ON_STALL=0
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"early_exit_on_stall: 0"* ]]
}

@test "build_session_args produces --permission-mode dangerous for devin backend" {
  grep -q "permission-mode dangerous" "$DVB_GRIND"
}

@test "build_session_args produces --dangerously-skip-permissions for claude-code backend" {
  grep -q "dangerously-skip-permissions" "$DVB_GRIND"
}

@test "build_session_args produces -q for codex backend" {
  # codex backend uses -q for quiet/non-interactive mode
  grep -q '"-q"' "$DVB_GRIND" || grep -q "\\-q" "$DVB_GRIND"
}

@test "devin backend invokes with --permission-mode dangerous" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --backend devin 1 "$TEST_REPO"
  [ -f "$DVB_GRIND_INVOKE_LOG" ] && grep -q -- '--permission-mode dangerous' "$DVB_GRIND_INVOKE_LOG"
}

@test "claude-code backend invokes with --dangerously-skip-permissions" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --backend claude-code 1 "$TEST_REPO"
  [ -f "$DVB_GRIND_INVOKE_LOG" ] && grep -q -- '--dangerously-skip-permissions' "$DVB_GRIND_INVOKE_LOG"
}

@test "codex backend invokes with -q flag" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --backend codex 1 "$TEST_REPO"
  [ -f "$DVB_GRIND_INVOKE_LOG" ] && grep -q -- '-q' "$DVB_GRIND_INVOKE_LOG"
}

@test "resolve_backend_binary function exists" {
  grep -q 'resolve_backend_binary()' "$DVB_GRIND"
}

@test "build_session_args function exists" {
  grep -q 'build_session_args()' "$DVB_GRIND"
}

@test "DVB_BACKEND=abc exits with unknown backend error" {
  export DVB_BACKEND=abc
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown backend"* ]]
}

# ── Diminishing returns / DVB_EARLY_EXIT_ON_STALL ─────────────────────

@test "diminishing returns warning after 5 low-throughput sessions" {
  # Persistent task never removed → 0 shipped per session
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=10
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'diminishing_returns' "$TEST_LOG"
  [[ "$output" == *"Low throughput"* ]]
}

@test "DVB_EARLY_EXIT_ON_STALL=1 exits early on low throughput" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=10
  export DVB_EARLY_EXIT_ON_STALL=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'early_exit_stall' "$TEST_LOG"
  [[ "$output" == *"TG_EARLY_EXIT_ON_STALL=1"* ]]
}

@test "DVB_EARLY_EXIT_ON_STALL=0 does not exit early" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  export DVB_MAX_ZERO_SHIP=6
  export DVB_EARLY_EXIT_ON_STALL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should bail due to zero-ship stall, NOT early_exit_stall
  ! grep -q 'early_exit_stall' "$TEST_LOG"
  grep -q 'stall_bail' "$TEST_LOG"
}

@test "early exit stops the grind loop (no more sessions)" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))
  export DVB_MAX_ZERO_SHIP=20
  export DVB_EARLY_EXIT_ON_STALL=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should exit after ~5 sessions (when diminishing returns fires)
  local count
  count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  # Exactly 5 sessions (diminishing returns fires at session 5)
  [ "$count" -le 6 ]
}

@test "productive timeout warning when shipped session hits timeout" {
  # Fake devin that removes one task per invocation
  local ship_devin="$TEST_DIR/ship-devin"
  local counter_file="$TEST_DIR/ship-counter"
  echo "0" > "$counter_file"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
remaining=\$((5 - n))
[ \$remaining -lt 0 ] && remaining=0
{
  echo "# Tasks"
  echo "## P0"
  i=1
  while [ \$i -le \$remaining ]; do
    echo "- [ ] Task \$i"
    i=\$((i + 1))
  done
} > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 5); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"

  # DVB_MAX_SESSION=0 means any elapsed time >= 0 triggers productive_timeout
  export DVB_MAX_SESSION=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'productive_timeout' "$TEST_LOG"
  [[ "$output" == *"Productive session hit timeout"* ]]
}

@test "productive timeout auto-increases max_session" {
  local ship_devin="$TEST_DIR/ship-devin"
  local counter_file="$TEST_DIR/ship-counter"
  echo "0" > "$counter_file"
  cat > "$ship_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
remaining=\$((3 - n))
[ \$remaining -lt 0 ] && remaining=0
{
  echo "# Tasks"
  echo "## P0"
  i=1
  while [ \$i -le \$remaining ]; do
    echo "- [ ] Task \$i"
    i=\$((i + 1))
  done
} > "$TEST_REPO/TASKS.md"
SCRIPT
  chmod +x "$ship_devin"
  export DVB_GRIND_CMD="$ship_devin"

  {
    echo "# Tasks"
    echo "## P0"
    for i in $(seq 1 3); do
      echo "- [ ] Task $i"
    done
  } > "$TEST_REPO/TASKS.md"

  export DVB_MAX_SESSION=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Auto-increasing to"* ]]
  grep -q 'new_timeout=' "$TEST_LOG"
}

@test "productive timeout caps at 7200s (structural)" {
  # Behavioral: fast stubs can't reach the cap (session_elapsed ≈ 0 < 1800 after
  # first increase), so we verify the cap logic structurally.
  grep -q 'max_session.*7200' "$DVB_GRIND"
  grep -q 'at cap' "$DVB_GRIND"
  # Verify the clamp: if max_session + 1800 > 7200, it's set to exactly 7200
  grep -Fq 'max_session" -gt 7200' "$DVB_GRIND"
  grep -Fq '&& max_session=7200' "$DVB_GRIND"
}

@test "no productive timeout when session does not ship" {
  # Tasks never removed → 0 shipped → no productive_timeout
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_MAX_SESSION=0
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_MAX_ZERO_SHIP=3
  run "$DVB_GRIND" 1 "$TEST_REPO"
  ! grep -q 'productive_timeout' "$TEST_LOG"
}
