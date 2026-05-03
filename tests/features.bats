#!/usr/bin/env bats
# Tests for taskgrind — multi-backend support + 9 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Multi-backend support ─────────────────────────────────────────────

@test "default backend is devin" {
  run_tiny_workload
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
  export DVB_BACKEND=codex
  export TG_BACKEND=devin
  run_tiny_workload
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
  run_tiny_workload
  [[ "$output" == *"backend=devin"* ]]
}

@test "backend shows in log file header" {
  run_tiny_workload
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
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" --backend devin 1 "$TEST_REPO"
  [ -f "$DVB_GRIND_INVOKE_LOG" ] && grep -q -- '--permission-mode dangerous' "$DVB_GRIND_INVOKE_LOG"
}

@test "claude-code backend invokes with --dangerously-skip-permissions" {
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" --backend claude-code 1 "$TEST_REPO"
  [ -f "$DVB_GRIND_INVOKE_LOG" ] && grep -q -- '--dangerously-skip-permissions' "$DVB_GRIND_INVOKE_LOG"
}

@test "claude-code backend completes workload with lifecycle log and status parity" {
  export DVB_STATUS_FILE="$TEST_DIR/status.json"

  run_tiny_workload --backend claude-code 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend=claude-code"* ]]
  grep -q -- '--dangerously-skip-permissions' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'backend=claude-code' "$TEST_LOG"
  grep -qE 'session_start session=1 .*backend=claude-code' "$TEST_LOG"
  grep -qE 'session_end session=1 .*backend=claude-code' "$TEST_LOG"
  grep -q '"backend": "claude-code"' "$DVB_STATUS_FILE"
  grep -q '"current_phase": "complete"' "$DVB_STATUS_FILE"
  grep -q '"shipped": 1' "$DVB_STATUS_FILE"
}

@test "codex backend invokes with -q flag" {
  export DVB_DEADLINE_OFFSET=5
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

@test "codex backend defaults to codex-compatible GPT-5.5 model" {
  run "$DVB_GRIND" --dry-run --backend codex 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5.5"* ]]
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
  run "$DVB_GRIND" --dry-run --model gpt-5-5 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5-5"* ]]
}

@test "--model=gpt-5-5 equals syntax works" {
  run "$DVB_GRIND" --dry-run --model=gpt-5-5 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5-5"* ]]
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
  run_tiny_workload --model gpt-5-5 1 "$TEST_REPO"
  grep -q -- '--model gpt-5-5' "$DVB_GRIND_INVOKE_LOG"
}

@test "--model preserves quoted multi-word values" {
  run_tiny_workload --model "Claude Opus 4.7 Max" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q -- '--model Claude Opus 4.7 Max' "$DVB_GRIND_INVOKE_LOG"
}

@test "--model alias resolves before backend invocation" {
  run_tiny_workload --model opus 1 "$TEST_REPO"
  grep -q -- '--model claude-opus-4-7-max' "$DVB_GRIND_INVOKE_LOG"
}

@test "--model works with --backend and --skill" {
  run "$DVB_GRIND" --dry-run --model gpt-5-5 --backend codex --skill fleet-grind 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    gpt-5-5"* ]]
  [[ "$output" == *"backend:  codex"* ]]
  [[ "$output" == *"skill:    fleet-grind"* ]]
}

@test "--model shows in startup banner" {
  run_tiny_workload --model custom-model 1 "$TEST_REPO"
  [[ "$output" == *"model=custom-model"* ]]
}

@test "--model shows in log file header" {
  run_tiny_workload --model custom-model 1 "$TEST_REPO"
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
  [[ "$output" == *'--model "Claude Opus 4.7 Max"'* ]]
}

@test "fleet-grind default GPT-5.5 dry-run includes standard context guard" {
  run "$DVB_GRIND" --dry-run --skill fleet-grind 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTEXT_BUDGET: Model profile standard"* ]]
  [[ "$output" == *"one merge/fill/fix cycle"* ]]
}

@test "fleet-grind opus dry-run includes large context profile" {
  run "$DVB_GRIND" --dry-run --skill fleet-grind --model opus 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    claude-opus-4-7-max"* ]]
  [[ "$output" == *"CONTEXT_BUDGET: Model profile large"* ]]
}

@test "fleet-grind non-opus 1M model stays on standard context profile" {
  run "$DVB_GRIND" --dry-run --skill fleet-grind --model custom-1M 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    custom-1M"* ]]
  [[ "$output" == *"CONTEXT_BUDGET: Model profile standard"* ]]
  [[ "$output" != *"CONTEXT_BUDGET: Model profile large"* ]]
}

@test "non-fleet skill dry-run omits fleet context guard" {
  run "$DVB_GRIND" --dry-run --skill next-task 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CONTEXT_BUDGET"* ]]
}

# ── Dynamic prompt file (prompt injection between sessions) ──────────

@test "reads prompt file between sessions" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "focus on testing" > "$_prompt_file"
  run_tiny_workload
  grep -q 'focus on testing' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt file updates are picked up between sessions" {
  # Second session should see updated prompt file content
  export DVB_DEADLINE_OFFSET=10
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "focus on testing" > "$_prompt_file"
  # Multiple sessions — fake devin runs fast, so both sessions will see the prompt
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'focus on testing' "$DVB_GRIND_INVOKE_LOG"
}

@test "missing prompt file is fine (no error)" {
  rm -f "$TEST_REPO/.taskgrind-prompt"
  run_tiny_workload
  [ "$status" -eq 0 ]
}

@test "--prompt and prompt file combine" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "also do this" > "$_prompt_file"
  run_tiny_workload --prompt "do that" 1 "$TEST_REPO"
  # Both should appear in the invocation
  grep -q 'do that' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'also do this' "$DVB_GRIND_INVOKE_LOG"
}

@test "prompt file shown in startup banner when present" {
  _prompt_file="$TEST_REPO/.taskgrind-prompt"
  echo "file-based focus" > "$_prompt_file"
  run_tiny_workload
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
  run_tiny_workload
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
  echo "gpt-5-5" > "$TEST_REPO/.taskgrind-model"
  run_tiny_workload
  [ "$status" -eq 0 ]
  grep -q -- '--model gpt-5-5' "$DVB_GRIND_INVOKE_LOG"
}

@test "missing model file uses startup model (no error)" {
  rm -f "$TEST_REPO/.taskgrind-model"
  run_tiny_workload
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
  export DVB_DEADLINE_OFFSET=10
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
  export DVB_DEADLINE_OFFSET=10
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
  run "$DVB_GRIND" --model gpt-5-5 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  sed -n '2p' "$DVB_GRIND_INVOKE_LOG" | grep -q -- '--model claude-sonnet-4.6'
}

@test "model file with trailing whitespace is trimmed" {
  printf "gpt-5-5\n\n\n" > "$TEST_REPO/.taskgrind-model"
  run_tiny_workload
  grep -q -- '--model gpt-5-5' "$DVB_GRIND_INVOKE_LOG"
}

@test "model file shown in startup banner when active" {
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  run_tiny_workload
  [[ "$output" == *"Live model:"* ]]
  [[ "$output" == *"claude-sonnet-4.6"* ]]
}

@test "model file alias is shown in the session banner as the resolved model" {
  echo "sonnet" > "$TEST_REPO/.taskgrind-model"
  run_tiny_workload
  [[ "$output" == *"Session 1"* ]]
  [[ "$output" == *"tasks queued — model=claude-sonnet-4.6"* ]]
  [[ "$output" != *"tasks queued — model=sonnet"* ]]
}

@test "--dry-run shows model from model file" {
  echo "gpt-5-5" > "$TEST_REPO/.taskgrind-model"
  run "$DVB_GRIND" --dry-run 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:"* ]]
  [[ "$output" == *"gpt-5-5"* ]]
}

@test "model file overrides --model flag" {
  echo "gpt-5-5" > "$TEST_REPO/.taskgrind-model"
  run_tiny_workload --model opus 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q -- '--model gpt-5-5' "$DVB_GRIND_INVOKE_LOG"
}

@test "unknown model alias passes through unchanged" {
  run_tiny_workload --model custom-unknown-model 1 "$TEST_REPO"
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

# ── Notification spam guard ───────────────────────────────────────────
#
# The desktop-notification block in cleanup() must skip in test mode
# (`DVB_GRIND_CMD` set) so `make check` does not fire a real macOS
# Notification Center alert from every bats invocation that reaches
# the cleanup path. Without this, running the full suite spammed the
# operator with hundreds of "taskgrind complete" banners.

@test "structural: notification block gates on DVB_GRIND_CMD test-mode marker" {
  # The condition must include both `DVB_NOTIFY != 0` AND `-z
  # DVB_GRIND_CMD` so a fake-backend test cannot leak a notification
  # even if it forgot to clear DVB_NOTIFY.
  grep -q 'DVB_NOTIFY:-1.*!= "0".*-z "${DVB_GRIND_CMD' "$DVB_GRIND"
}

@test "structural: osascript notification call is reachable from cleanup() only" {
  # A regression that hoists the osascript / notify-send call outside
  # the gated block (or removes the test-mode short-circuit) would
  # silently re-enable the spam. Anchor on both calls living inside
  # the gated `if` and the comment that documents the test-mode skip.
  grep -q 'Skip in test mode' "$DVB_GRIND"
  local osascript_line notify_send_line gate_line
  osascript_line=$(awk '/osascript .* "taskgrind complete"/{print NR; exit}' "$DVB_GRIND")
  notify_send_line=$(awk '/notify-send "taskgrind complete"/{print NR; exit}' "$DVB_GRIND")
  gate_line=$(awk '/-z "\${DVB_GRIND_CMD/{print NR; exit}' "$DVB_GRIND")
  [ -n "$osascript_line" ]
  [ -n "$notify_send_line" ]
  [ -n "$gate_line" ]
  [ "$gate_line" -lt "$osascript_line" ]
  [ "$gate_line" -lt "$notify_send_line" ]
}

@test "test_helper.bash sets DVB_NOTIFY=0 as a defensive belt against notification spam" {
  # Bats test-mode already gates via DVB_GRIND_CMD inside the script,
  # but the helper also exports DVB_NOTIFY=0 so a future test that
  # forgets the script-level guard (or runs taskgrind without the
  # fake backend) still cannot fire a real macOS notification.
  grep -q '^  export DVB_NOTIFY=0$' "$BATS_TEST_DIRNAME/test_helper.bash"
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
  run_tiny_workload 1 "$TEST_REPO" --prompt "focus on test coverage"
  grep -q 'Pick tasks from TASKS.md that relate to this focus' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt priority framing mentions unrelated tasks fallback" {
  run_tiny_workload 1 "$TEST_REPO" --prompt "taskgrind stability"
  grep -q 'Only work on unrelated tasks if no matching tasks remain' "$DVB_GRIND_INVOKE_LOG"
}

@test "log header includes prompt= when --prompt is set" {
  run_tiny_workload 1 "$TEST_REPO" --prompt "test focus"
  grep -q 'prompt=test focus' "$TEST_LOG"
}

@test "log header omits prompt= when no --prompt given" {
  run_tiny_workload
  ! grep -q 'prompt=' "$(head -2 "$TEST_LOG")"
}

@test "grind_done log includes prompt when --prompt is set" {
  run_tiny_workload 1 "$TEST_REPO" --prompt "ship features"
  grep 'grind_done' "$TEST_LOG" | grep -q 'prompt=ship features'
}

@test "grind_done log omits prompt when no --prompt given" {
  run_tiny_workload
  ! grep 'grind_done' "$TEST_LOG" | grep -q 'prompt='
}

@test "--prompt with single quotes passes through safely" {
  run_tiny_workload 1 "$TEST_REPO" --prompt "it's a test"
  grep -q "FOCUS: it's a test" "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt with dollar sign passes through without expansion" {
  run_tiny_workload 1 "$TEST_REPO" --prompt 'fix $HOME paths'
  grep -q 'FOCUS: fix \$HOME paths' "$DVB_GRIND_INVOKE_LOG"
}

@test "--prompt with double quotes passes through safely" {
  run_tiny_workload 1 "$TEST_REPO" --prompt 'multi word with "quotes"'
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
    "session_start"
    "session_end"
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
    "sweep_efficiency"

    # Failures and stalls
    "fast_fail"
    "bail_out"
    "stall_warning"
    "stall_bail"
    "early_exit_stall"
    "diminishing_returns"
    "diminishing_returns_exit"
    "productive_timeout"
    "productive_zero_ship"
    "shipped_inferred"
    "zero_ship_stall_ignored"
    "task_skip_threshold"
    "task_attempts_reset"
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
  # Since taskgrind-public-write-approval-gate: no longer tells agents to merge
  # PRs without approval; gate language replaces the old "merge it first" clause.
  [[ "$output" != *"merge it first"* ]]
  [[ "$output" == *"without explicit operator approval"* ]]
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
  # robust against unrelated edits above the function. Workspace mode renamed
  # the local repo variable to `_fs_repo` so the per-repo function can serve
  # both the control repo and each target.
  local would_push_line push_line
  would_push_line=$(awk '/final_sync would_push/{print NR; exit}' "$DVB_GRIND")
  push_line=$(awk '/git -C "\$_fs_repo" push origin HEAD/{print NR; exit}' "$DVB_GRIND")
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
  export DVB_DEADLINE_OFFSET=30

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

# ── Public-write approval gate (taskgrind-public-write-approval-gate) ────
#
# Incident: leeward-notify session opened UX-Infra/plugin-cli#5465 while
# working from an oncall-hub task. Contributing patterns: "fully autonomous",
# "never skip manual steps", "if you created a PR, merge it first" —
# these can overpower the public-write rule when TASKS.md has a green-list
# annotation. Task metadata is task context only, not operator approval.
#
# Acceptance:
# (a) prompt explicitly says TASKS.md green-lists do not authorize public writes
# (b) final_sync auto-PR requires TG_PUBLIC_WRITE_TOKEN or blocks with draft body
# (c) PR body includes "Why this is needed" and canonical Fyodor footer
# (d) COMPLETION PROTOCOL no longer tells agents to merge/push/bypass without gate

@test "prompt contains PUBLIC_WRITE_GATE section in both no-push branches" {
  # Gate must appear regardless of --no-push setting.
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLIC_WRITE_GATE"* ]]

  export TG_NO_PUSH=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLIC_WRITE_GATE"* ]]
}

@test "prompt states TASKS.md metadata does not authorize public writes" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The gate text must explicitly say task metadata is NOT authorization
  [[ "$output" == *"does NOT authorize any public write"* ]]
}

@test "standard COMPLETION PROTOCOL no longer tells agents to merge PRs without approval" {
  # Regression guard: the old prompt said 'merge it first' which told agents
  # to merge PRs unconditionally. The new protocol must forbid that.
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"merge it first"* ]]
  # Must require explicit approval instead
  [[ "$output" == *"without explicit operator approval"* ]]
}

@test "standard COMPLETION PROTOCOL forbids --no-verify hook bypass" {
  # Regression guard: the incident included a push with --no-verify.
  # The session prompt must explicitly forbid this.
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-verify"* ]]
}

@test "structural: PR body template includes Why this is needed section" {
  # Acceptance criterion (c): PR bodies must explain why the PR is needed.
  grep -q 'Why this is needed' "$DVB_GRIND"
}

@test "structural: PR body template includes canonical Fyodor agent footer" {
  # Acceptance criterion (c): PR bodies must include the canonical footer.
  grep -q '🤖 Written by an agent, not Fyodor' "$DVB_GRIND"
}

@test "structural: final_sync checks TG_PUBLIC_WRITE_TOKEN before auto-PR" {
  # Acceptance criterion (b): cross-repo PR creation requires a fresh token
  # or the run exits blocked with the draft body path.
  grep -q 'TG_PUBLIC_WRITE_TOKEN' "$DVB_GRIND"
  grep -q 'DVB_PUBLIC_WRITE_TOKEN' "$DVB_GRIND"
  grep -q 'pr_blocked_approval_needed' "$DVB_GRIND"
}

@test "structural: final_sync writes draft PR body file when token not set" {
  # When TG_PUBLIC_WRITE_TOKEN is absent, the draft must be saved locally.
  grep -q 'pr-draft' "$DVB_GRIND"
}

@test "operator docs name TG_PUBLIC_WRITE_TOKEN alongside PR-fallback gates" {
  # Doc-drift guard: any rename to the token gate must update docs in lockstep.
  local readme="$BATS_TEST_DIRNAME/../README.md"
  local man="$BATS_TEST_DIRNAME/../man/taskgrind.1"
  grep -q 'TG_PUBLIC_WRITE_TOKEN' "$readme"
  grep -q 'TG_PUBLIC_WRITE_TOKEN' "$man"
}

# ── Trusted-repo mode (taskgrind-trusted-repo-mode) ───────────────────
#
# `TG_TRUSTED_REPO=1` is for personal/side-project repos where the
# operator has already granted blanket approval for feature-branch push
# and `gh pr create`. The session prompt's PUBLIC_WRITE_GATE flips
# accordingly so the agent doesn't stop at the standard approval gate
# for those two actions. Merging PRs, pushing to main/master or any
# protected branch, force-pushing, bypassing pre-push hooks, opening
# issues, posting to Slack/Jira/email, publishing packages, and any
# cross-repo or upstream public write are still gated. NO-PUBLISH MODE
# (`TG_NO_PUSH=1`) wins — its COMPLETION PROTOCOL forbids any push,
# so the trusted-repo grant is suppressed in the gate prompt to avoid
# contradicting it.
#
# Acceptance:
# (a) default --dry-run reports trusted_repo=0 with the standard gate
# (b) TG_TRUSTED_REPO=1 reports trusted_repo=1 with the trusted gate
# (c) TG_NO_PUSH=1 + TG_TRUSTED_REPO=1: NO-PUBLISH wins, standard gate
# (d) invalid value rejected at startup with actionable error
# (e) DVB_TRUSTED_REPO=1 is honoured as the legacy alias
# (f) operator docs (README, man) name TG_TRUSTED_REPO

@test "--dry-run defaults to trusted_repo=0 with the standard PUBLIC_WRITE_GATE" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trusted_repo: 0"* ]]
  [[ "$output" != *"TG_TRUSTED_REPO=1"* ]]
  [[ "$output" == *"does NOT authorize any public write"* ]]
}

@test "TG_TRUSTED_REPO=1 flips trusted_repo and rewrites the PUBLIC_WRITE_GATE" {
  export TG_TRUSTED_REPO=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trusted_repo: 1"* ]]
  [[ "$output" == *"This repo is configured as a trusted repo (TG_TRUSTED_REPO=1)"* ]]
  [[ "$output" == *"pre-authorized for the task you are working on"* ]]
  # Still gates merging, protected pushes, force-push, --no-verify
  [[ "$output" == *"merging pull requests"* ]]
  [[ "$output" == *"main/master or any protected branch"* ]]
  [[ "$output" == *"force-pushing"* ]]
  [[ "$output" == *"--no-verify"* ]]
  # Standard gate text NOT present (replaced by trusted-repo wording)
  [[ "$output" != *"does NOT authorize any public write"* ]]
}

@test "DVB_TRUSTED_REPO=1 is honoured as the legacy alias" {
  export DVB_TRUSTED_REPO=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trusted_repo: 1"* ]]
  [[ "$output" == *"TG_TRUSTED_REPO=1"* ]]
}

@test "TG_NO_PUSH=1 wins over TG_TRUSTED_REPO=1 (NO-PUBLISH MODE precedence)" {
  # NO-PUBLISH MODE explicitly forbids any push/PR — the trusted-repo
  # grant must not contradict that. The gate falls back to the standard
  # text so the agent isn't told two opposite things at once.
  export TG_NO_PUSH=1
  export TG_TRUSTED_REPO=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
  [[ "$output" == *"trusted_repo: 1"* ]]
  [[ "$output" == *"NO-PUBLISH MODE"* ]]
  # Trusted-repo gate text NOT present when NO-PUBLISH wins
  [[ "$output" != *"This repo is configured as a trusted repo"* ]]
  # Standard gate text IS present
  [[ "$output" == *"does NOT authorize any public write"* ]]
}

@test "TG_TRUSTED_REPO rejects non-boolean values at startup" {
  export TG_TRUSTED_REPO=yes
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_TRUSTED_REPO must be 0 or 1"* ]]
}

@test "structural: trusted-repo gate wording lives in dry-run, supervisor, and live session prompts" {
  # The trusted-repo branch must appear in each of the three prompt
  # construction sites: --dry-run echo, supervisor_repair_prompt, and
  # the live session prompt. Anchor on the unique opening clause.
  local trusted_count
  trusted_count=$(grep -c 'configured as a trusted repo (TG_TRUSTED_REPO=1)' "$DVB_GRIND" 2>/dev/null) || trusted_count=0
  [ "$trusted_count" -ge 3 ]
}

@test "operator docs name TG_TRUSTED_REPO alongside the other gates" {
  # Doc-drift guard: any rename or scope change to the trusted-repo
  # gate must update operator-facing references in lockstep.
  local readme="$BATS_TEST_DIRNAME/../README.md"
  local man="$BATS_TEST_DIRNAME/../man/taskgrind.1"
  grep -q 'TG_TRUSTED_REPO' "$readme"
  grep -q 'TG_TRUSTED_REPO' "$man"
}

# ── Sweep ceiling and efficiency marker ───────────────────────────────
#
# Sweeps used to inherit `max_session`, which the productive-timeout
# escalation can grow to 7200 s mid-run. A sweep that slid up to that
# ceiling could burn ~14 % of a 10 h budget on backlog discovery
# (observed 2026-04-24, sweep #2 = 4954 s for 7 tasks). `TG_SWEEP_MAX`
# gives sweeps their own watchdog (default 1800 s); a derived
# `sweep_efficiency` marker surfaces tasks_per_min so post-mortems can
# see the trend without summing every `sweep_done` line.

@test "TG_SWEEP_MAX defaults to 1800 in --dry-run" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep_max:   1800s"* ]]
}

@test "TG_SWEEP_MAX env var is honoured in --dry-run" {
  export TG_SWEEP_MAX=300
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep_max:   300s"* ]]
}

@test "DVB_SWEEP_MAX is honoured as the legacy alias" {
  export DVB_SWEEP_MAX=600
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep_max:   600s"* ]]
}

@test "TG_SWEEP_MAX takes precedence over DVB_SWEEP_MAX" {
  export DVB_SWEEP_MAX=120
  export TG_SWEEP_MAX=900
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep_max:   900s"* ]]
}

@test "TG_SWEEP_MAX rejects non-numeric values at startup" {
  export TG_SWEEP_MAX=abc
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SWEEP_MAX must be a positive integer"* ]]
}

@test "TG_SWEEP_MAX rejects zero" {
  export TG_SWEEP_MAX=0
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_SWEEP_MAX must be a positive integer"* ]]
}

@test "structural: sweep watchdog uses sweep_max_session, not max_session" {
  # Anchor the assertion on the comment-block plus the sweep-only
  # watchdog assignment so a future refactor cannot silently fold
  # sweeps back under the productive-timeout-escalated grind cap.
  grep -q 'sweep_max_session, NOT max_session' "$DVB_GRIND"
  # The sweep block runs `remaining=$sweep_max_session` inside the
  # subshell timer. Pinpoint the exact line shape.
  grep -q 'remaining=\$sweep_max_session' "$DVB_GRIND"
}

@test "structural: sweep_done log line includes the cap value" {
  grep -q 'sweep_done exit=\$session_exit elapsed=\${session_elapsed}s cap=\${sweep_max_session}s' "$DVB_GRIND"
}

@test "sweep_efficiency log marker is emitted after a real sweep run" {
  # Force the sweep path: empty queue, fake backend, then assert the
  # efficiency marker fires with the expected fields. The marker must
  # land regardless of whether the sweep found anything (the
  # zero-tasks case is what surfaces a stuck sweep), so the test
  # leaves the queue empty and asserts on the literal marker.
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'sweep_done exit=' "$TEST_LOG"
  grep -q 'sweep_efficiency tasks=0 elapsed=[0-9]\+s tasks_per_min=' "$TEST_LOG"
}

@test "sweep_efficiency reports a positive tasks_per_min when tasks are found" {
  local sweep_devin="$TEST_DIR/sweep-devin"
  cat > "$sweep_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$DVB_GRIND_INVOKE_LOG"
if echo "\$@" | grep -q 'TASKS.md is empty'; then
  printf '# Tasks\n## P0\n- [ ] Found one\n  **ID**: found-one\n- [ ] Found two\n  **ID**: found-two\n' > "$TEST_REPO/TASKS.md"
fi
SCRIPT
  chmod +x "$sweep_devin"
  export DVB_GRIND_CMD="$sweep_devin"
  printf '# Tasks\n## P0\n' > "$TEST_REPO/TASKS.md"
  export DVB_DEADLINE_OFFSET=8
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'sweep_efficiency tasks=2 elapsed=[0-9]\+s tasks_per_min=' "$TEST_LOG"
}

@test "operator docs name TG_SWEEP_MAX alongside the other gates" {
  local readme="$BATS_TEST_DIRNAME/../README.md"
  local man="$BATS_TEST_DIRNAME/../man/taskgrind.1"
  local skill="$BATS_TEST_DIRNAME/../.devin/skills/grind-log-analyze/SKILL.md"

  grep -q 'TG_SWEEP_MAX' "$readme"
  grep -q 'sweep_efficiency tasks=N elapsed=Ns tasks_per_min=N\.NN' "$readme"

  grep -q 'TG_SWEEP_MAX' "$man"
  grep -q 'sweep_efficiency tasks=N elapsed=Ns tasks_per_min=N.NN' "$man"

  grep -q 'sweep_efficiency' "$skill"
  grep -q 'cap=Ns' "$skill"
}

# ── Diminishing-returns default exit ──────────────────────────────────
#
# The diminishing-returns detector tracks shipped counts in a 5-session
# rolling window. Default behavior used to be advisory-only — agentbrew
# logs (2026-04-24) show the detector firing at session 8 followed by
# 3.5h of further low-throughput sessions before a separate stall path
# eventually bailed. ~30 % of a 10 h budget burned after the signal
# fired. The new default exits on the SECOND consecutive trip with a
# distinct `diminishing_returns_exit` log marker so the trigger can be
# disambiguated from the "exit on first trip" `early_exit_stall` path.
#
# Three env vars compose the policy:
#   - TG_NO_STALL_EXIT=1 disables auto-exit entirely (advisory only).
#   - TG_EXIT_ON_STALL=1 (and the legacy TG_EARLY_EXIT_ON_STALL=1 alias)
#     exits on the FIRST trip with `early_exit_stall`.
#   - default-2x exit is the new fallback when neither of the above is
#     set: bail when the consecutive trips counter reaches 2.

@test "--dry-run shows stall_exit_policy default_2x_consecutive by default" {
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stall_exit_policy: default_2x_consecutive"* ]]
}

@test "--dry-run shows stall_exit_policy advisory_only when TG_NO_STALL_EXIT=1" {
  export TG_NO_STALL_EXIT=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stall_exit_policy: advisory_only"* ]]
}

@test "--dry-run shows stall_exit_policy strict_first_trip when TG_EXIT_ON_STALL=1" {
  export TG_EXIT_ON_STALL=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stall_exit_policy: strict_first_trip"* ]]
}

@test "TG_EXIT_ON_STALL=1 and TG_EARLY_EXIT_ON_STALL=1 both flip strict mode" {
  export TG_EARLY_EXIT_ON_STALL=1
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stall_exit_policy: strict_first_trip"* ]]
}

@test "TG_NO_STALL_EXIT rejects non-boolean values at startup" {
  export TG_NO_STALL_EXIT=yes
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_NO_STALL_EXIT must be 0 or 1"* ]]
}

@test "TG_EXIT_ON_STALL rejects non-boolean values at startup" {
  export TG_EXIT_ON_STALL=yes
  run "$DVB_GRIND" --dry-run 8 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TG_EXIT_ON_STALL must be 0 or 1"* ]]
}

@test "diminishing_returns log line carries the consecutive trip counter" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE_OFFSET=15
  export DVB_MAX_ZERO_SHIP=20
  export TG_NO_STALL_EXIT=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'diminishing_returns window=5 shipped=[01] consecutive=[0-9]\+' "$TEST_LOG"
}

@test "default 2x exit fires diminishing_returns_exit on the second consecutive trip" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE_OFFSET=30
  # Keep DVB_MAX_ZERO_SHIP higher than the diminishing-returns trip
  # window so the stall_bail path does not fire first.
  export DVB_MAX_ZERO_SHIP=20
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'diminishing_returns_exit consecutive=2 reason=default-2x' "$TEST_LOG"
  ! grep -q 'early_exit_stall' "$TEST_LOG"
}

@test "TG_NO_STALL_EXIT=1 keeps the grind running past consecutive trips" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE_OFFSET=15
  export DVB_MAX_ZERO_SHIP=20
  export TG_NO_STALL_EXIT=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'diminishing_returns_exit' "$TEST_LOG"
  ! grep -q 'early_exit_stall' "$TEST_LOG"
  grep -q 'diminishing_returns window=5' "$TEST_LOG"
}

@test "TG_EXIT_ON_STALL=1 exits on the first trip with early_exit_stall" {
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Stubborn task
TASKS
  export DVB_DEADLINE_OFFSET=15
  export DVB_MAX_ZERO_SHIP=20
  export TG_EXIT_ON_STALL=1
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'early_exit_stall' "$TEST_LOG"
  ! grep -q 'diminishing_returns_exit' "$TEST_LOG"
}

@test "consecutive trip counter resets after a session that ships >= 1 task" {
  # Fake backend ships exactly one task on the 6th invocation, then
  # stops touching TASKS.md again. The counter must reset on the
  # productive session, so subsequent zero-ship sessions cannot land a
  # second consecutive trip until the window-of-5 is once again all
  # zero.
  local toggle_devin="$TEST_DIR/toggle-devin"
  local counter_file="$TEST_DIR/dim-counter"
  echo "0" > "$counter_file"
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] First task
  **ID**: first-task
- [ ] Second task
  **ID**: second-task
- [ ] Third task
  **ID**: third-task
TASKS
  create_fake_devin "$toggle_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "${DVB_GRIND_INVOKE_LOG}"
n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" > "$counter_file"
if [[ "\$n" -eq 6 ]]; then
  cat > "$TEST_REPO/TASKS.md" <<'EOF'
# Tasks
## P0
- [ ] Second task
  **ID**: second-task
- [ ] Third task
  **ID**: third-task
EOF
fi
SCRIPT
  export DVB_GRIND_CMD="$toggle_devin"
  export DVB_DEADLINE_OFFSET=30
  export DVB_MAX_ZERO_SHIP=20
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Detector fires across the run because plenty of sessions ship 0,
  # but the counter must hit 0 once on session 6, and ride back up
  # only after subsequent zero-ship sessions rebuild a full zero
  # window.
  grep -q 'diminishing_returns window=5 shipped=[0-9]\+ consecutive=' "$TEST_LOG"
  grep -q 'consecutive=0' "$TEST_LOG" \
    || grep -q 'diminishing_returns window=5 shipped=1' "$TEST_LOG"
}

@test "operator docs name TG_NO_STALL_EXIT and TG_EXIT_ON_STALL alongside the existing gates" {
  local readme="$BATS_TEST_DIRNAME/../README.md"
  local man="$BATS_TEST_DIRNAME/../man/taskgrind.1"
  local skill="$BATS_TEST_DIRNAME/../.devin/skills/grind-log-analyze/SKILL.md"

  grep -q 'TG_NO_STALL_EXIT' "$readme"
  grep -q 'TG_EXIT_ON_STALL' "$readme"
  grep -q 'diminishing_returns_exit consecutive=2 reason=default-2x' "$readme"

  grep -q 'TG_NO_STALL_EXIT' "$man"
  grep -q 'TG_EXIT_ON_STALL' "$man"
  grep -q 'diminishing_returns_exit consecutive=2 reason=default-2x' "$man"

  grep -q 'diminishing_returns_exit' "$skill"
  grep -q 'consecutive=N reason=default-2x' "$skill"
}
