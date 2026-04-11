#!/usr/bin/env bats
# Tests for taskgrind — multi-backend support + 9 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

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

@test "--dry-run log path includes repo basename" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  local repo_name
  repo_name=$(basename "$TEST_REPO")
  [[ "$output" == *"$repo_name"* ]]
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

@test "codex backend warns when model contains claude" {
  export DVB_MODEL=claude-opus-4-6-thinking
  run "$DVB_GRIND" --dry-run --backend codex 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning"*"Anthropic model"*"codex"* ]]
}

@test "codex backend no warning when model is overridden" {
  export DVB_MODEL=o3
  run "$DVB_GRIND" --dry-run --backend codex 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Warning"*"Anthropic model"* ]]
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

# ── --model CLI flag ─────────────────────────────────────────────────

@test "--model flag sets model" {
  run "$DVB_GRIND" --dry-run --model gpt-5-4 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5-4"* ]]
}

@test "--model=gpt-5-4 equals syntax works" {
  run "$DVB_GRIND" --dry-run --model=gpt-5-4 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5-4"* ]]
}

@test "--model flag overrides TG_MODEL env" {
  export TG_MODEL=env-model
  run "$DVB_GRIND" --dry-run --model cli-model 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    cli-model"* ]]
}

@test "--model flag overrides DVB_MODEL env" {
  export DVB_MODEL=env-model
  run "$DVB_GRIND" --dry-run --model cli-model 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    cli-model"* ]]
}

@test "--model without value exits with clear error" {
  run "$DVB_GRIND" --model
  [ "$status" -ne 0 ]
  [[ "$output" == *"--model requires a name"* ]]
}

@test "--model= empty value exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" "--model="
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a non-empty name"* ]]
}

@test "--model two-arg with empty string exits with clear error" {
  run "$DVB_GRIND" 1 "$TEST_REPO" --model ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a non-empty name"* ]]
}

@test "--model passes through to backend invocation" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --model gpt-5-4 1 "$TEST_REPO"
  grep -q -- '--model gpt-5-4' "$DVB_GRIND_INVOKE_LOG"
}

@test "--model works with --backend and --skill" {
  run "$DVB_GRIND" --dry-run --model gpt-5-4 --backend codex --skill fleet-grind 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5-4"* ]]
  [[ "$output" == *"backend:  codex"* ]]
  [[ "$output" == *"skill:    fleet-grind"* ]]
}

@test "--model shows in startup banner" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --model custom-model 1 "$TEST_REPO"
  [[ "$output" == *"model=custom-model"* ]]
}

@test "--model shows in log file header" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --model custom-model 1 "$TEST_REPO"
  grep -q 'model=custom-model' "$TEST_LOG"
}

@test "--model suppresses codex-claude warning when overriding" {
  run "$DVB_GRIND" --dry-run --backend codex --model o3 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"Warning"* ]]
}

@test "--help shows --model in usage" {
  run "$DVB_GRIND" --help
  [[ "$output" == *"--model"* ]]
}

# ── Dynamic prompt file (prompt injection between sessions) ──────────

@test "reads prompt file between sessions" {
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "focus on testing" > "$_prompt_file"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'focus on testing' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt file updates are picked up between sessions" {
  # Second session should see updated prompt file content
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "focus on testing" > "$_prompt_file"
  # Multiple sessions — fake devin runs fast, so both sessions will see the prompt
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'focus on testing' "$DVB_GRIND_INVOKE_LOG"
}

@test "missing prompt file is fine (no error)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  rm -f "$TEST_REPO/.taskgrind-prompt"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "--prompt and prompt file combine" {
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "also do this" > "$_prompt_file"
  run "$DVB_GRIND" --prompt "do that" 1 "$TEST_REPO"
  # Both should appear in the invocation
  grep -q 'do that' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'also do this' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt file shown in startup banner when present" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "file-based focus" > "$_prompt_file"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"file-based focus"* ]]
}

@test "--dry-run shows prompt file content" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "file-based focus" > "$_prompt_file"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"file-based focus"* ]]
}

# ── Stability: prompt file size guard ─────────────────────────────────

@test "oversized prompt file is skipped with warning" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  # Create a file larger than 10KB limit
  dd if=/dev/zero bs=1024 count=11 2>/dev/null | tr '\0' 'x' > "$_prompt_file"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The oversized content should NOT appear in the prompt
  ! [[ "$output" == *"xxxx"* ]]
}

@test "prompt file within size limit is read normally" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "small focus" > "$_prompt_file"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"small focus"* ]]
}

@test "prompt file with trailing whitespace is trimmed" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  printf "clean prompt\n\n\n" > "$_prompt_file"
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # The prompt should end with "clean prompt" not trailing whitespace
  grep -q 'clean prompt' "$DVB_GRIND_INVOKE_LOG"
}

# ── Dynamic model file (live model switching between sessions) ────────

@test "model file overrides startup model" {
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  echo "gpt-5-4" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q -- '--model gpt-5-4' "$DVB_GRIND_INVOKE_LOG"
}

@test "missing model file uses startup model (no error)" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  rm -f "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "oversized model file is skipped with warning" {
  # Create a file larger than 1KB limit
  dd if=/dev/zero bs=1024 count=2 2>/dev/null | tr '\0' 'x' > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The oversized content should NOT appear as the model
  ! grep -q 'xxxx' "$DVB_GRIND_INVOKE_LOG" 2>/dev/null || true
}

@test "deleting model file reverts to startup model" {
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  # Create a fake devin that removes the model file on first run
  FAKE_DEVIN_V2="$TEST_DIR/fake-devin-v2"
  cat > "$FAKE_DEVIN_V2" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
# Remove the model file after first invocation so second session reverts
rm -f "$DVB_MODEL_FILE_PATH"
exit 0
SCRIPT
  chmod +x "$FAKE_DEVIN_V2"
  export DVB_GRIND_CMD="$FAKE_DEVIN_V2"
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  export DVB_MODEL_FILE_PATH="$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" --model opus 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # First session should use the file model
  head -1 "$DVB_GRIND_INVOKE_LOG" | grep -q -- '--model sonnet'
}

@test "model file with trailing whitespace is trimmed" {
  printf "gpt-5-4\n\n\n" > "$TEST_REPO/.taskgrind-model"
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model gpt-5-4' "$DVB_GRIND_INVOKE_LOG"
}

@test "model file shown in startup banner when active" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Live model:"* ]]
  [[ "$output" == *"sonnet"* ]]
}

@test "--dry-run shows model from model file" {
  echo "gpt-5-4" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:"* ]]
  [[ "$output" == *"gpt-5-4"* ]]
}

@test "model file overrides --model flag" {
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  echo "gpt-5-4" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" --model opus 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q -- '--model gpt-5-4' "$DVB_GRIND_INVOKE_LOG"
}

# ── Stability: mktemp failure message ─────────────────────────────────

@test "structural: mktemp failures produce clear error messages" {
  grep -q 'Error: cannot create temp file' "$DVB_GRIND"
}

# ── Stability: pre-session git state recovery ─────────────────────────

@test "structural: pre-session git state recovery checks for rebase" {
  grep -q 'pre_session_recovery rebase_aborted' "$DVB_GRIND"
}

@test "structural: pre-session git state recovery checks for merge" {
  grep -q 'pre_session_recovery merge_aborted' "$DVB_GRIND"
}

# ── Stability: final_sync detached HEAD guard ─────────────────────────

@test "structural: final_sync skips push on detached HEAD" {
  grep -q 'final_sync skipped.*detached HEAD' "$DVB_GRIND"
}

# ── Stability: process substitution tee flush ─────────────────────────

@test "structural: production mode pauses for tee flush after session" {
  # Both sweep and regular session paths should have the tee flush pause
  local count
  count=$(grep -c 'let tee flush' "$DVB_GRIND" 2>/dev/null) || true
  [[ "$count" -ge 2 ]]
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

