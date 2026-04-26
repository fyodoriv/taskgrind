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

@test "TG_BACKEND takes precedence over DVB_BACKEND during a real run" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  export DVB_BACKEND=codex
  export TG_BACKEND=devin
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend=devin"* ]]
  grep -q -- '--permission-mode dangerous' "$DVB_GRIND_INVOKE_LOG"
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
  _enable_preflight_checks
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

@test "--dry-run shows early_exit_on_stall disabled by default" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"early_exit_on_stall: 0"* ]]
}

@test "--dry-run shows early_exit_on_stall enabled when DVB_EARLY_EXIT_ON_STALL=1" {
  export DVB_EARLY_EXIT_ON_STALL=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"early_exit_on_stall: 1"* ]]
}

@test "--dry-run log path includes repo basename" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  local repo_name
  repo_name=$(basename "$TEST_REPO")
  [[ "$output" == *"$repo_name"* ]]
}

@test "--dry-run log path is fully expanded (no literal \$(date) or \$\$ placeholders)" {
  # The dry-run line is meant to be copy-pasteable into a supervisor config
  # or tail command. Emitting literal $(date '+%Y-%m-%d-%H%M') and $$ tokens
  # forced operators to remember how taskgrind actually names its log file.
  # This test pins the "fully expanded" output so a future edit to the echo
  # line can't silently regress the UX back to literal placeholders.
  #
  # test_helper.bash exports DVB_LOG to a fixed path so the session log is
  # predictable for other tests; unset it here so the dry-run echo falls
  # back to the default taskgrind-YYYY-MM-DD-HHMM-<repo>-<pid>.log template
  # that real users see on first launch.
  unset DVB_LOG
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  local log_line
  log_line=$(printf '%s\n' "$output" | grep '^  log:')
  [ -n "$log_line" ]

  # No unexpanded placeholders
  [[ "$log_line" != *'$(date'* ]]
  [[ "$log_line" != *'$$'* ]]

  # Either the path is concrete (matches the real naming pattern) OR the
  # line carries an explicit "(placeholders expanded at launch)" annotation.
  if [[ "$log_line" == *"placeholders expanded at launch"* ]]; then
    return 0
  fi

  # Concrete pattern: taskgrind-YYYY-MM-DD-HHMM-<repo>-<pid>.log
  local repo_name
  repo_name=$(basename "$TEST_REPO")
  local pattern="taskgrind-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-${repo_name}-[0-9]+\.log"
  printf '%s\n' "$log_line" | grep -Eq "$pattern"
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
  export DVB_MODEL=claude-opus-4-7-max
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

@test "--model preserves quoted multi-word values" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --model "gpt-5-4 XHigh thinking fast" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q -- '--model gpt-5-4 XHigh thinking fast' "$DVB_GRIND_INVOKE_LOG"
}

@test "--model alias resolves before backend invocation" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --model opus 1 "$TEST_REPO"
  grep -q -- '--model claude-opus-4-7-max' "$DVB_GRIND_INVOKE_LOG"
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
  [[ "$output" == *'--model "gpt-5.4 XHigh thinking fast"'* ]]
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

@test "prompt file survives deletion race after size check" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  printf "race-safe prompt" > "$_prompt_file"

  fake_bin="$TEST_DIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/wc" <<EOF
#!/bin/bash
if [ "\$1" = "-c" ]; then
  cat >/dev/null
  rm -f "$_prompt_file"
  printf "16\n"
else
  /usr/bin/wc "\$@"
fi
EOF
  chmod +x "$fake_bin/wc"
  export PATH="$fake_bin:$PATH"

  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"race-safe prompt"* ]]
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
  head -1 "$DVB_GRIND_INVOKE_LOG" | grep -q -- '--model claude-sonnet-4.6'
}

@test "model file alias resolves on live reload" {
  export DVB_DEADLINE=$(( $(date +%s) + 10 ))
  FAKE_DEVIN_V3="$TEST_DIR/fake-devin-v3"
  cat > "$FAKE_DEVIN_V3" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
count_file="${DVB_MODEL_COUNT_FILE:?}"
count=$(cat "$count_file")
count=$((count + 1))
echo "$count" > "$count_file"
if [[ "$count" -eq 1 ]]; then
  printf 'sonnet\n' > "${DVB_MODEL_FILE_PATH:?}"
fi
exit 0
SCRIPT
  chmod +x "$FAKE_DEVIN_V3"
  export DVB_GRIND_CMD="$FAKE_DEVIN_V3"
  export DVB_MODEL_FILE_PATH="$TEST_REPO/.taskgrind-model"
  export DVB_MODEL_COUNT_FILE="$TEST_DIR/model-count"
  echo "0" > "$DVB_MODEL_COUNT_FILE"
  rm -f "$DVB_MODEL_FILE_PATH"
  run "$DVB_GRIND" --model gpt-5-4 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  sed -n '2p' "$DVB_GRIND_INVOKE_LOG" | grep -q -- '--model claude-sonnet-4.6'
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
  [[ "$output" == *"claude-sonnet-4.6"* ]]
}

@test "model file alias is shown in the session banner as the resolved model" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"Session 1"* ]]
  [[ "$output" == *"tasks queued — model=claude-sonnet-4.6"* ]]
  [[ "$output" != *"tasks queued — model=sonnet"* ]]
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

@test "unknown model alias passes through unchanged" {
  export DVB_DEADLINE=$(( $(date +%s) + 5 ))
  run "$DVB_GRIND" --model custom-unknown-model 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q -- '--model custom-unknown-model' "$DVB_GRIND_INVOKE_LOG"
}

# ── Stability: mktemp failure message ─────────────────────────────────

@test "structural: mktemp failures produce clear error messages" {
  grep -q 'Error: cannot create temp file' "$DVB_GRIND"
}

# ── Stability: pre-session git state recovery ─────────────────────────

@test "structural: pre-session git state recovery checks for rebase" {
  # The script now composes the 'pre_session_recovery rebase_aborted' marker
  # via emit_rebase_conflict_logs; keep the structural assertion on the
  # call-site plus the helper's shared format so a refactor cannot drop
  # either half of the contract.
  grep -q 'emit_rebase_conflict_logs .*pre_session_recovery' "$DVB_GRIND"
  grep -q '${scope} rebase_aborted' "$DVB_GRIND"
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

# ── grind-log-analyze skill marker drift guard ────────────────────────

@test "grind-log-analyze skill mentions every log marker bin/taskgrind emits today" {
  # Every event the script writes must be discoverable in the
  # grind-log-analyze skill's parser tables. If the script gains a new
  # marker, the skill must be updated in the same change set or this
  # test fails — preventing silent drift between emitter and parser.
  #
  # The canonical marker list below is the contract. Adding a new
  # marker to bin/taskgrind requires: (1) emit it from the script,
  # (2) document it in `.devin/skills/grind-log-analyze/SKILL.md`,
  # (3) append the token here. All three guarantees are mechanically
  # checked: each marker is grep'd in both files.
  local script="$BATS_TEST_DIRNAME/../bin/taskgrind"
  local skill="$BATS_TEST_DIRNAME/../.devin/skills/grind-log-analyze/SKILL.md"
  [ -f "$script" ]
  [ -f "$skill" ]

  # Static markers emitted directly by `log_write "..."` calls. Most are
  # the bare event token; a few include a leading space-or-suffix to
  # disambiguate (e.g. `final_sync push_failed` vs the wider `final_sync`
  # prefix).
  local -a static_markers=(
    # Session lifecycle
    "session_timeout"
    "remaining="         # session=N remaining=Mm tasks=N model= ...
    " ended exit="       # session=N ended exit=N duration=Ns ...
    "live_model="
    "tasks_added="
    "tasks_appeared"
    "tasks_unblocked"
    "all_tasks_blocked"

    # Sweep / queue
    "queue_empty"
    "sweep_done"
    "sweep_found"
    "sweep_empty"

    # Failures and stalls
    "fast_fail"
    "bail_out"
    "stall_warning"
    "stall_bail"
    "early_exit_stall"
    "diminishing_returns"
    "productive_timeout"
    "productive_zero_ship"
    "shipped_inferred"
    "zero_ship_stall_ignored"
    "task_skip_threshold"
    "attempt_write_failed"
    "audit_focus_without_task"

    # Network
    "network_down"
    "network_restored"
    "network_timeout"

    # Lifecycle bookends
    "preflight_failed"
    "deadline_expired_before_session_loop"
    "deadline_expired_before_session_start"
    "graceful_shutdown waiting"
    "graceful_shutdown timeout"
    "graceful_shutdown session_finished"
    "graceful_shutdown duplicate_signal"

    # Pre-session recovery
    "pre_session_recovery merge_aborted"
    "repo_missing"

    # Final sync
    "final_sync skipped"
    "final_sync nothing_to_push"
    "final_sync skipped_duplicate"
    "final_sync pushing"
    "final_sync push_ok"
    "final_sync push_failed"
    "final_sync push_stderr"
    "final_sync would_push"

    # Git sync
    "git_sync ok"
    "git_sync skipped"
    "git_sync rebase_conflicts"
    "git_sync timeout_rebase_aborted"
    "git_sync timeout_merge_aborted"
    "git_sync stash_pop_failed"
    "git_sync failed"
    "branch_cleanup pruned"
    "branch_cleanup done"

    # Wrap-up
    "grind_done"
  )

  # Dynamic markers emitted via helper variables (e.g. `_backend_probe_summary`,
  # `_git_fail`). Each is constructed in a helper rather than passed as a
  # literal to log_write, so we grep the helper site instead of the log_write
  # call site.
  local -a dynamic_markers=(
    "backend_probe_ok"
    "backend_probe_failed"
    "git_sync selected_branch"
    "git_sync stash_failed"
    "git_sync fetch_failed"
    "git_sync checkout_failed"
    "git_sync rebase_aborted"
    "git_sync rebase_autoresolved"
    "git_sync rebase_failed"
  )

  # Scope-templated markers emitted via `emit_rebase_conflict_logs <repo>
  # <scope>` — the helper writes `${scope} rebase_conflicts ...` and
  # `${scope} rebase_aborted ...`. Verify both that the call site exists
  # (so the marker can fire) and that the skill documents the resulting
  # line.
  local -a scope_markers=(
    "pre_session_recovery rebase_aborted"
    "pre_session_recovery rebase_conflicts"
  )

  local marker missing=()
  for marker in "${static_markers[@]}" "${dynamic_markers[@]}"; do
    if ! grep -qF "$marker" "$script"; then
      missing+=("script: $marker")
    fi
    if ! grep -qF "$marker" "$skill"; then
      missing+=("skill: $marker")
    fi
  done

  # Scope markers — script side: just verify the emit_rebase_conflict_logs
  # call passes the scope; skill side: literal grep.
  for marker in "${scope_markers[@]}"; do
    local scope="${marker%% *}"
    if ! grep -qF "emit_rebase_conflict_logs " "$script" \
      || ! grep -qF "\"${scope}\"" "$script"; then
      missing+=("script: $marker (no emit_rebase_conflict_logs call with scope ${scope})")
    fi
    if ! grep -qF "$marker" "$skill"; then
      missing+=("skill: $marker")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'Marker drift detected:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    return 1
  fi
}

# ── No-publish mode ────────────────────────────────────────────────────
#
# `--no-push` / `TG_NO_PUSH=1` must do two things at once: (1) flip the
# session prompt's COMPLETION PROTOCOL to NO-PUBLISH MODE so the agent
# is told not to run `git push`, `gh pr create`, or `gh pr merge`, and
# (2) short-circuit `final_sync` before its `git push` call, replacing
# `final_sync push_ok` with `final_sync would_push commits=N head=<sha>`
# so the operator can review and push manually.

@test "--dry-run defaults to no_push=0 and the standard COMPLETION PROTOCOL" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  0"* ]]
  [[ "$output" == *"merge it first"* ]]
  [[ "$output" != *"NO-PUBLISH MODE"* ]]
}

@test "--no-push flag flips no_push=1 and rewrites the COMPLETION PROTOCOL" {
  run "$DVB_GRIND" --dry-run --no-push 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
  [[ "$output" == *"NO-PUBLISH MODE"* ]]
  [[ "$output" == *"Do NOT push to any remote"* ]]
  [[ "$output" == *"Do NOT create pull requests"* ]]
  [[ "$output" == *"Do NOT merge pull requests"* ]]
  [[ "$output" != *"merge it first"* ]]
}

@test "TG_NO_PUSH=1 has the same effect as --no-push" {
  export TG_NO_PUSH=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
  [[ "$output" == *"NO-PUBLISH MODE"* ]]
}

@test "DVB_NO_PUSH=1 is honoured as the legacy alias" {
  export DVB_NO_PUSH=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
  [[ "$output" == *"NO-PUBLISH MODE"* ]]
}

@test "--no-push CLI flag overrides TG_NO_PUSH=0 from the environment" {
  export TG_NO_PUSH=0
  run "$DVB_GRIND" --dry-run --no-push 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
}

@test "TG_NO_PUSH rejects non-boolean values at startup" {
  export TG_NO_PUSH=yes
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NO_PUSH must be 0 or 1"* ]]
}

@test "structural: final_sync logs would_push instead of pushing when no_push=1" {
  # The branch must precede the `git push origin HEAD` invocation so
  # the push call is skipped entirely. Anchor the assertion on both
  # the marker emission and the surrounding short-circuit.
  grep -q 'final_sync would_push' "$DVB_GRIND"
  grep -q 'no_push" == "1"' "$DVB_GRIND"
}

@test "structural: would_push branch sits before the git push call" {
  # The two line numbers are recovered with awk so the test stays
  # robust against unrelated edits above the function.
  local would_push_line push_line
  would_push_line=$(awk '/final_sync would_push/{print NR; exit}' "$DVB_GRIND")
  push_line=$(awk '/git -C "\$repo" push origin HEAD/{print NR; exit}' "$DVB_GRIND")
  [ -n "$would_push_line" ]
  [ -n "$push_line" ]
  [ "$would_push_line" -lt "$push_line" ]
}

@test "structural: NO-PUBLISH MODE wording lives in both the dry-run mirror and the live session prompt" {
  local nopublish_count
  nopublish_count=$(grep -c 'NO-PUBLISH MODE' "$DVB_GRIND" 2>/dev/null) || nopublish_count=0
  # One occurrence in the dry-run echo, one in the runtime prompt.
  [ "$nopublish_count" -ge 2 ]
}

@test "no_push value is persisted in resume state and restored on --resume" {
  local state_file="$TEST_DIR/resume-state"
  local slow_devin="$TEST_DIR/slow-devin"
  create_fake_devin "$slow_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG}"
sleep 5
SCRIPT
  export DVB_GRIND_CMD="$slow_devin"
  export DVB_STATE_FILE="$state_file"
  export DVB_DEADLINE=$(( $(date +%s) + 30 ))

  "$DVB_GRIND" --no-push 1 "$TEST_REPO" >"$TEST_DIR/stdout.log" 2>"$TEST_DIR/stderr.log" &
  local grind_pid=$!

  local attempts=0
  while [[ "$attempts" -lt 50 ]]; do
    if [[ -f "$state_file" ]] && grep -q "^session=1$" "$state_file"; then
      break
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done

  grep -q "^no_push=1$" "$state_file"

  kill -9 "$grind_pid"
  wait "$grind_pid" 2>/dev/null || true
}

@test "operator docs name --no-push and TG_NO_PUSH alongside the other gates" {
  # Doc-drift guard: any rename or scope change to the no-push gate must
  # update the operator-facing references in lockstep with the script.
  local readme="$BATS_TEST_DIRNAME/../README.md"
  local man="$BATS_TEST_DIRNAME/../man/taskgrind.1"
  local arch="$BATS_TEST_DIRNAME/../docs/architecture.md"
  local stories="$BATS_TEST_DIRNAME/../docs/user-stories.md"
  local resume="$BATS_TEST_DIRNAME/../docs/resume-state.md"

  grep -q -- '--no-push' "$readme"
  grep -q 'TG_NO_PUSH' "$readme"
  grep -q 'final_sync would_push' "$readme"

  grep -q 'no\\-push' "$man"
  grep -q 'TG_NO_PUSH' "$man"
  grep -q 'final_sync would_push' "$man"

  grep -q -- '--no-push' "$arch"
  grep -q 'no-publish mode is two-sided' "$arch"

  grep -q '7b. Producing work for review without auto-publishing' "$stories"
  grep -q 'TG_NO_PUSH=1 taskgrind' "$stories"

  grep -q '`no_push`' "$resume"
}
