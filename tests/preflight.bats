#!/usr/bin/env bats
# Tests for taskgrind — preflight health checks
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

_install_fake_skill() {
  local skill_name="$1"
  local root="${2:-$TEST_HOME/.agents/skills}"
  mkdir -p "$root/$skill_name"
  printf '# %s\n' "$skill_name" > "$root/$skill_name/SKILL.md"
}

_install_fake_backend_binary() {
  local binary_name="$1"
  local script_path="$TEST_DIR/$binary_name"

  cat > "$script_path" <<'SCRIPT'
#!/bin/bash
# Record every invocation (argv as-is) so callers can assert ordering and the
# ratio of probe vs. model-validation calls.
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
# When taskgrind's startup probe runs `<backend> --version`, it requires a
# non-empty stdout payload from a fast (<1s) zero-exit invocation; otherwise
# run_backend_probe rejects the binary as "stub or broken". Emit a stable
# pseudo-version string so the probe accepts the fixture and the rest of the
# preflight + model-validation flow can run.
if [[ "$*" == *"--version"* ]]; then
  echo "fake-backend 0.0.1"
  exit 0
fi
if [[ "$*" == *"--help"* ]] && [[ "$*" == *"--model invalid-model"* ]]; then
  echo "backend said invalid model: invalid-model" >&2
  exit 1
fi
exit 0
SCRIPT
  chmod +x "$script_path"
  export PATH="$TEST_DIR:$PATH"
  _install_fake_skill "next-task"
}

_install_fake_df() {
  local free_kb="$1"
  local script_path="$TEST_DIR/df"

  cat > "$script_path" <<SCRIPT
#!/bin/bash
cat <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk1 2097152 1000000 ${free_kb} 50% /tmp
EOF
SCRIPT
  chmod +x "$script_path"
  export PATH="$TEST_DIR:$PATH"
}

_install_fake_network_watchdog() {
  local script_path="$TEST_DIR/network-watchdog"

  cat > "$script_path" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
  chmod +x "$script_path"
  export PATH="$TEST_DIR:$PATH"
}

# ── Preflight health checks ───────────────────────────────────────────

@test "--preflight runs health checks and exits 0 on healthy repo" {
  _preflight_git_init
  _install_fake_skill "next-task"
  # Drop the fake DVB_GRIND_CMD and install a fake 'devin' on PATH so the
  # real binary-resolution + model-validation paths run, but against a
  # deterministic fixture instead of the operator's installed devin CLI
  # (which fails model validation under HOME=$TEST_HOME because the
  # versioned install cannot be located).
  unset DVB_GRIND_CMD
  _install_fake_backend_binary "devin"
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

@test "--preflight fails when selected backend cannot see fleet-grind skill" {
  _preflight_git_init
  unset DVB_GRIND_CMD
  _install_fake_backend_binary "devin"
  _install_fake_network_watchdog

  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Requested skill 'fleet-grind' is not visible to backend 'devin'"* ]]
  [[ "$output" == *"$TEST_HOME/.config/devin/skills/fleet-grind/SKILL.md"* ]]
  [[ "$output" == *"Preflight FAILED"* ]]
  [[ "$output" != *"Bosun server unreachable"* ]]
}

@test "--preflight accepts repo-local devin skill when skill validation is enabled in test mode" {
  _preflight_git_init
  mkdir -p "$TEST_REPO/.devin/skills/fleet-grind"
  printf '# fleet-grind\n' > "$TEST_REPO/.devin/skills/fleet-grind/SKILL.md"
  export DVB_VALIDATE_SKILL=1

  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skill visible to devin: fleet-grind ($TEST_REPO/.devin/skills/fleet-grind/SKILL.md)"* ]]
}

@test "--preflight checks skill visibility against the selected backend" {
  _preflight_git_init
  mkdir -p "$TEST_HOME/.config/devin/skills/fleet-grind"
  printf '# fleet-grind\n' > "$TEST_HOME/.config/devin/skills/fleet-grind/SKILL.md"
  export DVB_VALIDATE_SKILL=1

  run "$DVB_GRIND" --preflight --backend codex --skill fleet-grind "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Requested skill 'fleet-grind' is not visible to backend 'codex'"* ]]
  [[ "$output" == *"$TEST_HOME/.codex/skills/fleet-grind/SKILL.md"* ]]
  [[ "$output" != *"$TEST_HOME/.config/devin/skills/fleet-grind/SKILL.md"* ]]
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

# ── Stale stash hygiene ──────────────────────────────────────────────

# Helper: create N stashes in TEST_REPO. Each stash mutates a tracked
# file then `git stash push`. The repo must be initialized first.
_make_stashes() {
  local count="$1"
  local i
  for ((i=1; i<=count; i++)); do
    echo "wip $i" > "$TEST_REPO/wip.txt"
    git -C "$TEST_REPO" add wip.txt
    git -C "$TEST_REPO" commit -q -m "tracked-$i"
    echo "wip $i.$(date +%N)" > "$TEST_REPO/wip.txt"
    git -C "$TEST_REPO" stash push -q -m "wip-$i" >/dev/null
  done
}

@test "preflight warns when stash count exceeds TG_STASH_WARN_THRESHOLD" {
  _preflight_git_init
  _make_stashes 6
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale stash count: 6"* ]]
  [[ "$output" == *"git -C $TEST_REPO stash list"* ]]
}

@test "preflight does not warn when stash count is at or below threshold" {
  _preflight_git_init
  _make_stashes 5
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Stale stash count"* ]]
}

@test "preflight does not warn for repos with no stashes" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Stale stash count"* ]]
}

@test "TG_STASH_WARN_THRESHOLD overrides the default threshold" {
  _preflight_git_init
  _make_stashes 3
  export TG_STASH_WARN_THRESHOLD=2
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale stash count: 3"* ]]
}

@test "TG_STASH_WARN_THRESHOLD=0 disables the stash warning" {
  _preflight_git_init
  _make_stashes 8
  export TG_STASH_WARN_THRESHOLD=0
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Stale stash count"* ]]
}

@test "DVB_STASH_WARN_THRESHOLD legacy alias still works" {
  _preflight_git_init
  _make_stashes 4
  export DVB_STASH_WARN_THRESHOLD=3
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale stash count: 4"* ]]
}

@test "TG_STASH_WARN_THRESHOLD takes precedence over DVB_STASH_WARN_THRESHOLD" {
  _preflight_git_init
  _make_stashes 4
  export DVB_STASH_WARN_THRESHOLD=10
  export TG_STASH_WARN_THRESHOLD=2
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The TG_ value (2) wins over the DVB_ value (10), so 4 trips the warning.
  [[ "$output" == *"Stale stash count: 4"* ]]
}

@test "preflight warns when TASKS.md is missing" {
  _preflight_git_init
  # Remove TASKS.md from repo (setup creates one by default)
  rm -f "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASKS.md not found"* ]]
}

@test "preflight fails when TASKS.md is a directory" {
  _preflight_git_init
  rm -f "$TEST_REPO/TASKS.md"
  mkdir "$TEST_REPO/TASKS.md"

  run "$DVB_GRIND" --preflight "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"TASKS.md exists at $TEST_REPO/TASKS.md but is not a regular file (is_dir=yes, is_link=no)"* ]]
  [[ "$output" == *"case-insensitive filesystems"* ]]
  [[ "$output" == *"--from-prompt"* ]]
  [[ "$output" == *"Preflight FAILED"* ]]
}

@test "preflight fails when TASKS.md is a symlink to a directory" {
  _preflight_git_init
  rm -f "$TEST_REPO/TASKS.md"
  mkdir "$TEST_DIR/tasks-dir"
  ln -s "$TEST_DIR/tasks-dir" "$TEST_REPO/TASKS.md"

  run "$DVB_GRIND" --preflight "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"TASKS.md exists at $TEST_REPO/TASKS.md but is not a regular file (is_dir=yes, is_link=yes)"* ]]
}

@test "main loop preflight fails before launching when TASKS.md is a directory" {
  _preflight_git_init
  rm -f "$TEST_REPO/TASKS.md"
  mkdir "$TEST_REPO/TASKS.md"

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"TASKS.md exists at $TEST_REPO/TASKS.md but is not a regular file"* ]]
  [[ "$output" == *"Preflight FAILED"* ]]
  [ ! -f "$DVB_GRIND_INVOKE_LOG" ]
}

@test "workspace target preflight fails when target TASKS.md is a directory" {
  _preflight_git_init
  local target_repo="$TEST_DIR/target-repo"
  mkdir -p "$target_repo"
  git -C "$target_repo" init -q -b main
  git -C "$target_repo" config user.email "test@test.com"
  git -C "$target_repo" config user.name "Test"
  git -C "$target_repo" commit --allow-empty -m "init" --quiet
  mkdir "$target_repo/TASKS.md"

  run "$DVB_GRIND" --preflight --target-repo "$target_repo" "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Target repo preflight: $target_repo"* ]]
  [[ "$output" == *"TASKS.md exists at $target_repo/TASKS.md but is not a regular file (is_dir=yes, is_link=no)"* ]]
  [[ "$output" == *"Target preflight FAILED"* ]]
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

# Regression for preflight-remote-watchdog-bash32-bug: the previous shell
# watchdog used `wait` on a sibling pid, which works on bash 4+ but
# returns 127 immediately on macOS /bin/bash 3.2 — firing the
# "Git remote unreachable" warning unconditionally on every macOS run
# even when `git ls-remote` would succeed. These two tests pin the fix
# (use git's GIT_HTTP_LOW_SPEED_TIME for the timeout, no shell-level
# watchdog) and ensure neither half regresses.
@test "preflight reports remote reachable for a working local origin (no false alarm on bash 3.2)" {
  # Set up a local bare repo as origin so `git ls-remote` succeeds without
  # depending on network or auth. This is the path that was always
  # firing the warning before the fix on macOS bash 3.2.
  _preflight_git_init
  local bare="$TEST_DIR/origin.git"
  git init --quiet --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push --quiet origin main 2>/dev/null

  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git remote reachable"* ]]
  # The pre-fix bug presented as the "unreachable" warning firing
  # alongside everything else passing — this assertion catches the
  # regression directly.
  [[ "$output" != *"Git remote unreachable"* ]]
}

@test "preflight still warns when origin URL is bogus (timeout path is not silently disabled)" {
  # Negative case: the fix replaces the buggy watchdog with git's own
  # timeout knobs. We need to confirm the timeout still fires — i.e.
  # the warning DOES appear when the remote is genuinely unreachable.
  # Use a non-existent local path as origin so `git ls-remote` fails
  # fast (no real network call needed).
  _preflight_git_init
  git -C "$TEST_REPO" remote add origin "$TEST_DIR/does-not-exist.git"

  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git remote unreachable"* ]]
}

@test "preflight runs before main loop and blocks on failure" {
  # Structural: preflight_check is called before the while loop
  grep -q 'preflight_check' "$DVB_GRIND"
  grep -q 'preflight_failed' "$DVB_GRIND"
}

@test "preflight has all 10 checks" {
  # Structural: verify all 10 check categories exist. Check #10 (bosun-health)
  # was added 2026-04-29 — only fires for skills that need bosun pipelines
  # (fleet-grind, pipeline-ops, …), but the source code path is always
  # present so structural grep passes.
  grep -q 'Backend binary' "$DVB_GRIND"
  grep -q 'Model accepted by' "$DVB_GRIND"
  grep -q 'Skill visible to' "$DVB_GRIND"
  grep -q 'Network connectivity' "$DVB_GRIND"
  grep -q 'Git state clean' "$DVB_GRIND"
  grep -q 'Git remote reachable' "$DVB_GRIND"
  grep -q 'Disk space' "$DVB_GRIND"
  grep -q 'TASKS.md' "$DVB_GRIND"
  grep -q 'network-watchdog' "$DVB_GRIND"
  grep -q 'Bosun server reachable' "$DVB_GRIND"
}

@test "preflight check passes in test mode with DVB_GRIND_CMD" {
  _preflight_git_init
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test mode"* ]]
}

@test "preflight uses TG_NET_CHECK_URL for curl fallback" {
  local fake_bin="$TEST_DIR/fake-bin"
  local fake_curl_log="$TEST_DIR/fake-curl.log"
  mkdir -p "$fake_bin"

  create_fake_devin "$fake_bin/devin" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT

  cat > "$fake_bin/curl" <<SCRIPT
#!/bin/bash
echo "\$*" > "$fake_curl_log"
exit 0
SCRIPT
  chmod +x "$fake_bin/curl"

  _preflight_git_init
  _install_fake_skill "next-task"
  unset DVB_GRIND_CMD
  export PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export TG_NET_CHECK_URL="https://example.invalid/healthz"

  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using curl fallback"* ]]
  grep -q -- 'https://example.invalid/healthz' "$fake_curl_log"
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

@test "preflight validates models through claude-code backend resolution" {
  _enable_preflight_checks
  unset DVB_GRIND_CMD
  _install_fake_backend_binary "claude"
  _preflight_git_init

  run "$DVB_GRIND" --backend claude-code --model invalid-model 1 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"backend said invalid model: invalid-model"* ]]
  [[ "$output" == *"Model rejected by claude-code before starting"* ]]
  [[ "$output" == *"Claude Code install and account"* ]]
  [[ "$output" != *"Devin"* ]]

  # With backend_probe guarding startup, the binary is invoked twice before
  # preflight bails: once for '--version' (probe) and once for
  # '--model invalid-model --help' (model validation). The validation call
  # is the one that must fire; the probe is legitimate startup hygiene.
  local invoke_count
  invoke_count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ' )
  [ "$invoke_count" -eq 2 ]
  grep -q -- '--version' "$DVB_GRIND_INVOKE_LOG"
  grep -q -- '--model invalid-model --help' "$DVB_GRIND_INVOKE_LOG"
}

@test "preflight disk space check runs" {
  _preflight_git_init
  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disk space"* ]]
}

@test "preflight warns when free disk space is below 1GB" {
  _preflight_git_init
  _install_fake_df 800000

  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disk space low: 781MB free (< 1GB)"* ]]
}

@test "preflight fails when free disk space is below 512MB" {
  _preflight_git_init
  _install_fake_df 500000

  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Disk space critical: 488MB free"* ]]
  [[ "$output" == *"Preflight FAILED"* ]]
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

@test "startup probe aborts before session 1 when backend exits immediately with no output" {
  local stub_devin="$TEST_DIR/stub-devin"
  unset DVB_VALIDATE_MODEL
  unset DVB_DEVIN_PATH
  cat > "$stub_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT
  chmod +x "$stub_devin"
  export DVB_GRIND_CMD="$stub_devin"
  export DVB_VALIDATE_BACKEND_STARTUP=1
  # 5s is too tight under TEST_JOBS=2 parallel load: the deadline can fire
  # before the probe runs, so the script exits with 0
  # (deadline_expired_before_session_loop) instead of 1
  # (backend_probe_failed). 30s is plenty — the probe still fails
  # immediately in the common case so the test stays fast.
  export DVB_DEADLINE_OFFSET=30

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"backend binary may be a stub or broken"* ]]
  [[ "$output" == *"reinstall or roll back"* ]]
  # Duration may be 0s, 1s, 2s, ... depending on parallel-test CPU
  # pressure; the probe detection no longer depends on it (output
  # emptiness is the authoritative stub signal). Assert everything else
  # about the log line literally but let the duration float.
  grep -qE 'backend_probe_failed exit=0 duration=[0-9]+s backend=devin' "$TEST_LOG"

  local invoke_count
  invoke_count=$(wc -l < "$DVB_GRIND_INVOKE_LOG" | tr -d ' ')
  [ "$invoke_count" -eq 1 ]
  grep -q -- '--version' "$DVB_GRIND_INVOKE_LOG"
}

@test "startup probe allows normal sessions when backend returns version output" {
  local versioned_devin="$TEST_DIR/versioned-devin"
  unset DVB_VALIDATE_MODEL
  unset DVB_DEVIN_PATH
  cat > "$versioned_devin" <<'SCRIPT'
#!/bin/bash
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
if [[ "${1:-}" == "--version" ]]; then
  echo "Devin CLI 2026.4.9"
fi
exit 0
SCRIPT
  chmod +x "$versioned_devin"
  export DVB_GRIND_CMD="$versioned_devin"
  export DVB_VALIDATE_BACKEND_STARTUP=1
  # 5s would be too tight under TEST_JOBS=2 — session 1 needs to actually
  # run to completion here (we assert `session=1 ended`). 30s is plenty;
  # the fake backend exits immediately so the test stays fast.
  export DVB_DEADLINE_OFFSET=30

  run "$DVB_GRIND" 1 "$TEST_REPO"

  [ "$status" -eq 0 ]
  ! grep -q 'backend_probe_failed' "$TEST_LOG"
  grep -q -- '--version' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'session=1 ended' "$TEST_LOG"
}

# ── Skill pattern validation tests ──────────────────────────────────────────────

@test "_skill_needs_bosun should not match user skills with 'pipeline' in name" {
  # Skills like 'user-ci-pipeline-helper' should not require Bosun validation
  # Only actual Bosun-orchestrated skills should match the pattern

  # Test that user skills containing "pipeline" don't match
  DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"
  source <(grep -A 15 '^_skill_needs_bosun()' "$DVB_GRIND")

  # These should NOT need bosun (return 1)
  skill="user-pipeline-helper"; run _skill_needs_bosun
  [ "$status" -eq 1 ]

  skill="ci-pipeline-debug"; run _skill_needs_bosun
  [ "$status" -eq 1 ]

  skill="my-deployment-pipeline"; run _skill_needs_bosun
  [ "$status" -eq 1 ]

  # These should need bosun (return 0)
  skill="fleet-grind"; run _skill_needs_bosun
  [ "$status" -eq 0 ]

  skill="pipeline-ops"; run _skill_needs_bosun
  [ "$status" -eq 0 ]

  skill="bosun"; run _skill_needs_bosun
  [ "$status" -eq 0 ]
}
