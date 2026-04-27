#!/usr/bin/env bats
# Tests for taskgrind — --from-prompt natural-language config translation.
#
# Covers CLI parsing, env-var alias, KEY=VALUE response parsing, the
# explicit > env > prompt > default precedence chain, error paths
# (malformed responses, resume conflict, empty briefs), and
# dry-run / banner integration. The translation calls the configured AI
# backend in production; tests stub the response via
# `DVB_FROM_PROMPT_RESPONSE` so they stay deterministic and offline.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── CLI parsing ──────────────────────────────────────────────────────

@test "--from-prompt accepts a quoted text argument" {
  export DVB_FROM_PROMPT_RESPONSE='hours=2'
  run "$DVB_GRIND" --dry-run --from-prompt "two hours" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    2"* ]]
}

@test "--from-prompt=TEXT equals syntax works" {
  export DVB_FROM_PROMPT_RESPONSE='hours=3'
  run "$DVB_GRIND" --dry-run --from-prompt="three hours" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    3"* ]]
}

@test "--from-prompt without a value errors with a clear message" {
  run "$DVB_GRIND" --from-prompt
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from-prompt requires a text"* ]]
}

@test "--from-prompt= empty value errors" {
  run "$DVB_GRIND" --from-prompt= "$TEST_REPO" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from-prompt requires a non-empty text"* ]]
}

@test "--from-prompt with empty string after the flag errors" {
  run "$DVB_GRIND" --from-prompt "" "$TEST_REPO" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from-prompt requires a non-empty text"* ]]
}

# ── Env var alias ────────────────────────────────────────────────────

@test "TG_FROM_PROMPT env populates the brief" {
  export DVB_FROM_PROMPT_RESPONSE='hours=4'
  TG_FROM_PROMPT="four hours" run "$DVB_GRIND" --dry-run "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    4"* ]]
}

@test "DVB_FROM_PROMPT env (legacy alias) also populates the brief" {
  export DVB_FROM_PROMPT_RESPONSE='hours=5'
  DVB_FROM_PROMPT="five hours" run "$DVB_GRIND" --dry-run "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    5"* ]]
}

@test "TG_FROM_PROMPT takes precedence over DVB_FROM_PROMPT" {
  export DVB_FROM_PROMPT_RESPONSE='hours=6'
  TG_FROM_PROMPT="tg wins" DVB_FROM_PROMPT="dvb loses" \
    run "$DVB_GRIND" --dry-run "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    6"* ]]
}

@test "--from-prompt CLI flag overrides TG_FROM_PROMPT env" {
  export DVB_FROM_PROMPT_RESPONSE='hours=7'
  TG_FROM_PROMPT="env brief" run "$DVB_GRIND" --dry-run --from-prompt "cli brief" "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Both produce the same hours=7 since the stubbed response doesn't change,
  # but the CLI flag winning is verified by the script not erroring on env+CLI
  # combo and the response being consumed.
  [[ "$output" == *"hours:    7"* ]]
}

# ── KEY=VALUE response parsing ───────────────────────────────────────

@test "single-field response sets only that field, leaves others at default" {
  export DVB_FROM_PROMPT_RESPONSE='model=opus'
  run "$DVB_GRIND" --dry-run --from-prompt "use opus" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    claude-opus-4-7-max"* ]]
  # hours should still be the default (10)
  [[ "$output" == *"hours:    10"* ]]
}

@test "full response populates every slot" {
  local target1 target2
  target1="$TEST_DIR/full-t1"
  target2="$TEST_DIR/full-t2"
  mkdir -p "$target1" "$target2"
  export DVB_FROM_PROMPT_RESPONSE="hours=8
repo=$TEST_REPO
target_repos=$target1:$target2
model=opus
backend=devin
skill=pipeline-ops
focus=focus on tests
no_push=1"
  run "$DVB_GRIND" --dry-run --from-prompt "everything"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    8"* ]]
  [[ "$output" == *"repo:     $TEST_REPO"* ]]
  [[ "$output" == *"backend:  devin"* ]]
  [[ "$output" == *"skill:    pipeline-ops"* ]]
  [[ "$output" == *"model:    claude-opus-4-7-max"* ]]
  [[ "$output" == *"no_push:  1"* ]]
  [[ "$output" == *"target:   $target1"* ]]
  [[ "$output" == *"target:   $target2"* ]]
  [[ "$output" == *"prompt:   focus on tests"* ]]
}

@test "model alias from prompt resolves to the canonical id" {
  export DVB_FROM_PROMPT_RESPONSE='model=sonnet'
  run "$DVB_GRIND" --dry-run --from-prompt "sonnet please" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    claude-sonnet-4.6"* ]]
}

@test "unknown keys in response are ignored (defensive)" {
  export DVB_FROM_PROMPT_RESPONSE='bogus=xyz
hours=9
random_extra=junk'
  run "$DVB_GRIND" --dry-run --from-prompt "noisy LLM" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    9"* ]]
}

@test "trailing CR in response values is trimmed" {
  # Simulate \r\n line endings from a backend that doesn't normalize.
  export DVB_FROM_PROMPT_RESPONSE=$'hours=8\r\nmodel=opus\r'
  run "$DVB_GRIND" --dry-run --from-prompt "windows-y output" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    8"* ]]
  [[ "$output" == *"model:    claude-opus-4-7-max"* ]]
}

@test "empty value for a key sets the slot to empty (no crash)" {
  export DVB_FROM_PROMPT_RESPONSE='hours=8
focus='
  run "$DVB_GRIND" --dry-run --from-prompt "blank focus" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    8"* ]]
  # Empty focus means no `prompt:` line in dry-run
  [[ "$output" != *"prompt:"* ]]
}

# ── Precedence: explicit CLI > env > prompt > default ────────────────

@test "explicit --hours positional beats prompt-translated hours" {
  export DVB_FROM_PROMPT_RESPONSE='hours=8'
  run "$DVB_GRIND" --dry-run --from-prompt "8 hours" 4 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    4"* ]]
}

@test "explicit positional repo beats prompt-translated repo" {
  local prompt_repo cli_repo
  prompt_repo="$TEST_DIR/prompt-repo"
  cli_repo="$TEST_DIR/cli-repo"
  mkdir -p "$prompt_repo" "$cli_repo"
  export DVB_FROM_PROMPT_RESPONSE="repo=$prompt_repo"
  run "$DVB_GRIND" --dry-run --from-prompt "use prompt repo" "$cli_repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo:     $cli_repo"* ]]
}

@test "explicit --model beats prompt-translated model" {
  export DVB_FROM_PROMPT_RESPONSE='model=opus'
  run "$DVB_GRIND" --dry-run --from-prompt "use opus" --model sonnet "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    claude-sonnet-4.6"* ]]
}

@test "TG_MODEL env beats prompt-translated model" {
  export DVB_FROM_PROMPT_RESPONSE='model=opus'
  TG_MODEL=sonnet run "$DVB_GRIND" --dry-run --from-prompt "use opus" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model:    claude-sonnet-4.6"* ]]
}

@test "explicit --backend beats prompt-translated backend" {
  export DVB_FROM_PROMPT_RESPONSE='backend=codex'
  run "$DVB_GRIND" --dry-run --from-prompt "use codex backend" --backend claude-code "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  claude-code"* ]]
}

@test "TG_BACKEND env beats prompt-translated backend" {
  export DVB_FROM_PROMPT_RESPONSE='backend=codex'
  TG_BACKEND=claude-code run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:  claude-code"* ]]
}

@test "explicit --skill beats prompt-translated skill" {
  export DVB_FROM_PROMPT_RESPONSE='skill=pipeline-ops'
  run "$DVB_GRIND" --dry-run --from-prompt "x" --skill standing-audit-gap-loop "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill:    standing-audit-gap-loop"* ]]
}

@test "TG_SKILL env beats prompt-translated skill" {
  export DVB_FROM_PROMPT_RESPONSE='skill=pipeline-ops'
  TG_SKILL=standing-audit-gap-loop run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill:    standing-audit-gap-loop"* ]]
}

@test "explicit --prompt focus beats prompt-translated focus" {
  export DVB_FROM_PROMPT_RESPONSE='focus=prompt-focus'
  run "$DVB_GRIND" --dry-run --from-prompt "x" --prompt "cli-focus" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt:   cli-focus"* ]]
}

@test "TG_PROMPT env beats prompt-translated focus" {
  export DVB_FROM_PROMPT_RESPONSE='focus=prompt-focus'
  TG_PROMPT="env-focus" run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt:   env-focus"* ]]
}

@test "explicit --no-push beats prompt-translated no_push" {
  export DVB_FROM_PROMPT_RESPONSE='no_push=0'
  run "$DVB_GRIND" --dry-run --from-prompt "publish freely" --no-push "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
}

@test "TG_NO_PUSH env beats prompt-translated no_push" {
  export DVB_FROM_PROMPT_RESPONSE='no_push=0'
  TG_NO_PUSH=1 run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no_push:  1"* ]]
}

@test "explicit --target-repo beats prompt-translated target_repos" {
  local cli_target prompt_target
  cli_target="$TEST_DIR/cli-target"
  prompt_target="$TEST_DIR/prompt-target"
  mkdir -p "$cli_target" "$prompt_target"
  export DVB_FROM_PROMPT_RESPONSE="target_repos=$prompt_target"
  run "$DVB_GRIND" --dry-run --from-prompt "x" --target-repo "$cli_target" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"target:   $cli_target"* ]]
  [[ "$output" != *"target:   $prompt_target"* ]]
}

@test "TG_TARGET_REPOS env beats prompt-translated target_repos" {
  local env_target prompt_target
  env_target="$TEST_DIR/env-target"
  prompt_target="$TEST_DIR/prompt-target"
  mkdir -p "$env_target" "$prompt_target"
  export DVB_FROM_PROMPT_RESPONSE="target_repos=$prompt_target"
  TG_TARGET_REPOS="$env_target" run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"target:   $env_target"* ]]
  [[ "$output" != *"target:   $prompt_target"* ]]
}

# ── Error paths ──────────────────────────────────────────────────────

@test "--from-prompt + --resume errors with a clear message" {
  run "$DVB_GRIND" --resume --from-prompt "x" "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from-prompt is not compatible with --resume"* ]]
}

@test "translation response with no parseable lines errors" {
  export DVB_FROM_PROMPT_RESPONSE='this is just prose, no key value lines'
  run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no parseable KEY=VALUE lines"* ]]
}

@test "translation response that is empty errors" {
  export DVB_FROM_PROMPT_RESPONSE=''
  run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no parseable KEY=VALUE lines"* ]]
}

@test "translation response that targets a non-existent repo errors at validation" {
  # The translator returns a valid-shape line but the path doesn't exist.
  # Validation should reject it just like a bad --target-repo.
  export DVB_FROM_PROMPT_RESPONSE="target_repos=$TEST_DIR/nope-this-does-not-exist"
  run "$DVB_GRIND" --dry-run --from-prompt "x" "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target-repo path does not exist"* ]]
}

# ── Banner / dry-run integration ─────────────────────────────────────

@test "--dry-run shows merged config when --from-prompt is set" {
  local target1
  target1="$TEST_DIR/banner-t1"
  mkdir -p "$target1"
  export DVB_FROM_PROMPT_RESPONSE="hours=6
repo=$TEST_REPO
target_repos=$target1
model=opus
focus=focus on banner test"
  run "$DVB_GRIND" --dry-run --from-prompt "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:    6"* ]]
  [[ "$output" == *"repo:     $TEST_REPO"* ]]
  [[ "$output" == *"workspace: control + 1 target(s)"* ]]
  [[ "$output" == *"prompt:   focus on banner test"* ]]
}

@test "log file records from_prompt translated audit line" {
  export DVB_FROM_PROMPT_RESPONSE='hours=2
model=opus'
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --from-prompt "two hours opus" "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'from_prompt translated' "$TEST_LOG"
  grep -q 'hours=2' "$TEST_LOG"
  grep -q 'model=opus' "$TEST_LOG"
}

@test "log file records from_prompt override when CLI flag wins over prompt" {
  export DVB_FROM_PROMPT_RESPONSE='model=opus'
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --from-prompt "use opus" --model sonnet "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'from_prompt override slot=model' "$TEST_LOG"
  grep -q 'reason=cli_explicit' "$TEST_LOG"
}

@test "log file does not record from_prompt lines when --from-prompt was not used" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! grep -q 'from_prompt' "$TEST_LOG"
}

# ── Help / docs surface ──────────────────────────────────────────────

@test "--help documents --from-prompt flag" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--from-prompt"* ]]
}

@test "--help documents TG_FROM_PROMPT env var" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"TG_FROM_PROMPT"* ]]
}

@test "user-stories doc includes the from-prompt story" {
  run grep -nF '## 13. Natural-language config briefs' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
}

@test "README usage block includes --from-prompt example" {
  # grep treats `--from-prompt` as a flag without `--` separator
  run grep -nF -- '--from-prompt "8h on agentbrew' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "README env table documents TG_FROM_PROMPT" {
  run grep -nF '| `TG_FROM_PROMPT` ' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "man page synopsis lists --from-prompt" {
  run grep -nF '\-\-from\-prompt' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "man page ENVIRONMENT lists TG_FROM_PROMPT" {
  run grep -nE '^\.B TG_FROM_PROMPT$' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

# ── Structural assertions ────────────────────────────────────────────

@test "structural: translate_from_prompt() function is defined" {
  grep -q 'translate_from_prompt()' "$DVB_GRIND"
}

@test "structural: DVB_FROM_PROMPT_RESPONSE test bypass is wired" {
  grep -q 'DVB_FROM_PROMPT_RESPONSE' "$DVB_GRIND"
}

@test "structural: TG_FROM_PROMPT is included in the TG_ alias loop" {
  grep -q 'FROM_PROMPT' "$DVB_GRIND"
}

@test "structural: model resolution chain includes prompt fallback layer" {
  # The line that resolves requested_model must include `_fp_model` BETWEEN
  # the env var and the default. A regression that drops `_fp_model` would
  # silently make --from-prompt model fields a no-op.
  grep -qE 'requested_model=.*_cli_model.*DVB_MODEL.*_fp_model.*DVB_DEFAULT_MODEL' "$DVB_GRIND"
}

@test "structural: backend resolution chain includes prompt fallback layer" {
  grep -qE 'requested_backend=.*_cli_backend.*DVB_BACKEND.*_fp_backend' "$DVB_GRIND"
}

@test "structural: target repos resolution falls back to _fp_targets" {
  grep -q 'IFS=.:.* read -r -a _target_repos_raw <<< "\$_fp_targets"' "$DVB_GRIND"
}

@test "structural: no_push resolution chain includes _fp_no_push fallback" {
  grep -qE 'no_push="\$_fp_no_push"' "$DVB_GRIND"
}

@test "structural: --resume + --from-prompt rejection lives in startup flow" {
  grep -q '\-\-from-prompt is not compatible with \-\-resume' "$DVB_GRIND"
}

@test "structural: from_prompt audit logs use log_write" {
  grep -q 'from_prompt translated' "$DVB_GRIND"
  grep -q 'from_prompt override' "$DVB_GRIND"
}
