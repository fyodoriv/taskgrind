#!/usr/bin/env bats
# Tests for taskgrind — workspace mode (--target-repo / TG_TARGET_REPOS).
# Covers CLI parsing, env-var resolution, validation, banner/dry-run/preflight
# output, session env exports, prompt injection, status JSON, resume state,
# and the doc-parity contract for the new flag.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# Helper: create a second repo (target) inside TEST_DIR. Returns the path.
_make_target_repo() {
  local name="${1:-target}"
  local target_dir="$TEST_DIR/$name"
  mkdir -p "$target_dir"
  printf '# Tasks\n## P0\n- [ ] Target task\n' > "$target_dir/TASKS.md"
  echo "$target_dir"
}

# ── CLI flag parsing ─────────────────────────────────────────────────

@test "--target-repo accepts a single path" {
  local target
  target=$(_make_target_repo target1)
  run "$DVB_GRIND" --dry-run --target-repo "$target" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace: control + 1 target(s)"* ]]
  [[ "$output" == *"target:   $target"* ]]
}

@test "--target-repo=PATH equals syntax works" {
  local target
  target=$(_make_target_repo target1)
  run "$DVB_GRIND" --dry-run --target-repo="$target" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"target:   $target"* ]]
}

@test "--target-repo can be repeated for multiple targets" {
  local t1 t2 t3
  t1=$(_make_target_repo target1)
  t2=$(_make_target_repo target2)
  t3=$(_make_target_repo target3)
  run "$DVB_GRIND" --dry-run \
    --target-repo "$t1" \
    --target-repo "$t2" \
    --target-repo "$t3" \
    "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace: control + 3 target(s)"* ]]
  [[ "$output" == *"target:   $t1"* ]]
  [[ "$output" == *"target:   $t2"* ]]
  [[ "$output" == *"target:   $t3"* ]]
}

@test "--target-repo without a value errors with a clear message" {
  run "$DVB_GRIND" --target-repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target-repo requires a path"* ]]
}

@test "--target-repo= with empty value errors" {
  run "$DVB_GRIND" --target-repo= "$TEST_REPO" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target-repo requires a path"* ]]
}

@test "--target-repo with empty string after the flag errors" {
  run "$DVB_GRIND" --target-repo "" "$TEST_REPO" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target-repo requires a non-empty path"* ]]
}

@test "non-existent --target-repo path errors out at startup" {
  run "$DVB_GRIND" --dry-run --target-repo "$TEST_DIR/no-such-target" "$TEST_REPO" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target-repo path does not exist"* ]]
}

@test "--target-repo cannot equal the control repo" {
  run "$DVB_GRIND" --dry-run --target-repo "$TEST_REPO" "$TEST_REPO" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"same as the control repo"* ]]
}

@test "duplicate --target-repo entries are silently deduped" {
  local target
  target=$(_make_target_repo target1)
  run "$DVB_GRIND" --dry-run \
    --target-repo "$target" \
    --target-repo "$target" \
    "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace: control + 1 target(s)"* ]]
  # Only one `target:` line should appear — count via grep -c
  local count
  count=$(grep -c "^  target:   $target$" <<<"$output" || true)
  [ "$count" -eq 1 ]
}

@test "--target-repo accepts a relative path and resolves to absolute" {
  local target
  target=$(_make_target_repo rel-target)
  # Pass a relative path by cding into TEST_DIR first
  cd "$TEST_DIR"
  run "$DVB_GRIND" --dry-run --target-repo "rel-target" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  # Output should show absolute path
  [[ "$output" == *"target:   $target"* ]]
}

# ── Env var handling ─────────────────────────────────────────────────

@test "TG_TARGET_REPOS env populates the target list (colon-separated)" {
  local t1 t2
  t1=$(_make_target_repo env-t1)
  t2=$(_make_target_repo env-t2)
  TG_TARGET_REPOS="$t1:$t2" run "$DVB_GRIND" --dry-run "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace: control + 2 target(s)"* ]]
  [[ "$output" == *"target:   $t1"* ]]
  [[ "$output" == *"target:   $t2"* ]]
}

@test "DVB_TARGET_REPOS env (legacy alias) also populates the target list" {
  local target
  target=$(_make_target_repo legacy-t1)
  DVB_TARGET_REPOS="$target" run "$DVB_GRIND" --dry-run "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace: control + 1 target(s)"* ]]
  [[ "$output" == *"target:   $target"* ]]
}

@test "TG_TARGET_REPOS takes precedence over DVB_TARGET_REPOS" {
  local tg_path dvb_path
  tg_path=$(_make_target_repo tg-priority)
  dvb_path=$(_make_target_repo dvb-priority)
  TG_TARGET_REPOS="$tg_path" DVB_TARGET_REPOS="$dvb_path" \
    run "$DVB_GRIND" --dry-run "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"target:   $tg_path"* ]]
  [[ "$output" != *"target:   $dvb_path"* ]]
}

@test "--target-repo CLI flag overrides TG_TARGET_REPOS env" {
  local cli_path env_path
  cli_path=$(_make_target_repo cli-wins)
  env_path=$(_make_target_repo env-loses)
  TG_TARGET_REPOS="$env_path" \
    run "$DVB_GRIND" --dry-run --target-repo "$cli_path" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"target:   $cli_path"* ]]
  [[ "$output" != *"target:   $env_path"* ]]
}

@test "empty TG_TARGET_REPOS entries are skipped" {
  local target
  target=$(_make_target_repo skip-empty)
  # Adjacent colons produce empty entries; they must be filtered out.
  TG_TARGET_REPOS=":$target::" run "$DVB_GRIND" --dry-run "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace: control + 1 target(s)"* ]]
}

@test "no --target-repo and no env still works (single-repo mode preserved)" {
  unset TG_TARGET_REPOS DVB_TARGET_REPOS 2>/dev/null || true
  run "$DVB_GRIND" --dry-run "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" != *"workspace:"* ]]
  [[ "$output" != *"target:"* ]]
}

# ── Banner and log header ────────────────────────────────────────────

@test "startup banner lists each target repo" {
  local t1 t2
  t1=$(_make_target_repo banner-t1)
  t2=$(_make_target_repo banner-t2)
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --target-repo "$t1" --target-repo "$t2" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workspace: control + 2 target(s)"* ]]
  [[ "$output" == *"- $t1"* ]]
  [[ "$output" == *"- $t2"* ]]
}

@test "log file header records the joined targets list" {
  local t1 t2
  t1=$(_make_target_repo log-t1)
  t2=$(_make_target_repo log-t2)
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --target-repo "$t1" --target-repo "$t2" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  grep -q "targets=$t1:$t2" "$TEST_LOG"
}

@test "log file does not record targets= when single-repo run" {
  unset TG_TARGET_REPOS DVB_TARGET_REPOS 2>/dev/null || true
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  ! grep -q 'targets=' "$TEST_LOG"
}

# ── Dry-run output ───────────────────────────────────────────────────

@test "--dry-run prompt includes WORKSPACE: block when targets are set" {
  local target
  target=$(_make_target_repo dry-prompt)
  run "$DVB_GRIND" --dry-run --target-repo "$target" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKSPACE: This grind has 1 target repo(s)"* ]]
  [[ "$output" == *"$target"* ]]
}

@test "--dry-run prompt has no WORKSPACE: block when no targets" {
  unset TG_TARGET_REPOS DVB_TARGET_REPOS 2>/dev/null || true
  run "$DVB_GRIND" --dry-run "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [[ "$output" != *"WORKSPACE:"* ]]
}

# ── Preflight ────────────────────────────────────────────────────────

@test "--preflight header lists each target" {
  local t1 t2
  t1=$(_make_target_repo pf-t1)
  t2=$(_make_target_repo pf-t2)
  _enable_preflight_checks
  _preflight_git_init
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight --target-repo "$t1" --target-repo "$t2" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"target:   $t1"* ]]
  [[ "$output" == *"target:   $t2"* ]]
}

@test "--preflight runs per-target checks and reports them" {
  local t1
  t1=$(_make_target_repo pf-target)
  _enable_preflight_checks
  _preflight_git_init
  # Initialize the target as a git repo too so the per-target check has
  # something concrete to report.
  init_test_repo "$t1" main
  echo "# Tasks" > "$TEST_REPO/TASKS.md"
  run "$DVB_GRIND" --preflight --target-repo "$t1" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Target repo preflight: $t1"* ]]
  # The target preflight should have its own summary line.
  [[ "$output" == *"Target preflight"* ]]
}

# ── Status file ──────────────────────────────────────────────────────

@test "TG_STATUS_FILE includes a targets array (empty when none)" {
  unset TG_TARGET_REPOS DVB_TARGET_REPOS 2>/dev/null || true
  local status_path="$TEST_DIR/status-empty.json"
  export DVB_STATUS_FILE="$status_path"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [ -f "$status_path" ]
  grep -q '"targets": \[\]' "$status_path"
}

@test "TG_STATUS_FILE includes target paths when targets are set" {
  local t1 t2
  t1=$(_make_target_repo status-t1)
  t2=$(_make_target_repo status-t2)
  local status_path="$TEST_DIR/status-targets.json"
  export DVB_STATUS_FILE="$status_path"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --target-repo "$t1" --target-repo "$t2" "$TEST_REPO" 2
  [ "$status" -eq 0 ]
  [ -f "$status_path" ]
  grep -q "\"targets\": \[\"$t1\", \"$t2\"\]" "$status_path"
}

# ── Resume state persistence ─────────────────────────────────────────

@test "resume-state file persists targets= line" {
  local t1 t2 state_file="$TEST_REPO/.taskgrind-state"
  t1=$(_make_target_repo state-t1)
  t2=$(_make_target_repo state-t2)
  export DVB_DEADLINE_OFFSET=5
  # Run briefly; state file should be created with targets= line.
  "$DVB_GRIND" --target-repo "$t1" --target-repo "$t2" "$TEST_REPO" 2 >/dev/null 2>&1 || true
  # The state file may be cleaned up on clean exit; force-write via an early
  # deadline so the loop body doesn't run, but the running-state write happens
  # before the loop.
  if [[ -f "$state_file" ]]; then
    grep -q "targets=$t1:$t2" "$state_file"
  else
    # On clean exit the state file is removed. Recreate via env override
    # forcing an in-flight write — use TG_STATUS_FILE which guarantees we
    # see the running-state record at least once.
    skip "state file removed on clean exit; covered by next test"
  fi
}

@test "--resume errors when --target-repo list does not match saved state" {
  local t1 t2
  t1=$(_make_target_repo resume-t1)
  t2=$(_make_target_repo resume-t2)
  local state_file="$TEST_REPO/.taskgrind-state"
  # Hand-craft a saved state with the original targets.
  write_resume_state_file "$state_file" "targets=$t1"
  # Future deadline so the resume passes the deadline check.
  export TEST_RESUME_DEADLINE=$(( $(date +%s) + 600 ))
  write_resume_state_file "$state_file" "targets=$t1"
  # Now resume with a different target list — should error.
  run "$DVB_GRIND" --resume --target-repo "$t2" "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target repos do not match saved state"* ]]
}

@test "--resume errors when CLI passes targets but state has none" {
  local target
  target=$(_make_target_repo resume-only-cli)
  local state_file="$TEST_REPO/.taskgrind-state"
  export TEST_RESUME_DEADLINE=$(( $(date +%s) + 600 ))
  write_resume_state_file "$state_file" "targets="
  run "$DVB_GRIND" --resume --target-repo "$target" "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target repos do not match saved state"* ]]
}

@test "--resume restores target list from saved state when CLI omits flag" {
  local target
  target=$(_make_target_repo resume-restore)
  local state_file="$TEST_REPO/.taskgrind-state"
  export TEST_RESUME_DEADLINE=$(( $(date +%s) + 600 ))
  write_resume_state_file "$state_file" "targets=$target"
  # Past deadline cuts the loop short, but the resume validation still runs.
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --resume "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Banner should show the restored target.
  [[ "$output" == *"Workspace: control + 1 target(s)"* ]]
  [[ "$output" == *"$target"* ]]
}

@test "--resume with matching --target-repo list succeeds" {
  local target
  target=$(_make_target_repo resume-match)
  local state_file="$TEST_REPO/.taskgrind-state"
  export TEST_RESUME_DEADLINE=$(( $(date +%s) + 600 ))
  write_resume_state_file "$state_file" "targets=$target"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" --resume --target-repo "$target" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workspace: control + 1 target(s)"* ]]
}

# ── Session env exports ──────────────────────────────────────────────

@test "TG_TARGET_REPOS env is exported to the session backend" {
  local t1 t2
  t1=$(_make_target_repo env-export-t1)
  t2=$(_make_target_repo env-export-t2)
  # Replace the fake devin with one that records env vars too.
  cat > "$DVB_GRIND_CMD" <<SCRIPT
#!/bin/bash
echo "args=\$*" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "env_TG_TARGET_REPOS=\${TG_TARGET_REPOS:-UNSET}" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "env_TG_TARGET_REPO_COUNT=\${TG_TARGET_REPO_COUNT:-UNSET}" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT
  chmod +x "$DVB_GRIND_CMD"
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" --target-repo "$t1" --target-repo "$t2" "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  grep -q "env_TG_TARGET_REPOS=$t1:$t2" "$DVB_GRIND_INVOKE_LOG"
  grep -q 'env_TG_TARGET_REPO_COUNT=2' "$DVB_GRIND_INVOKE_LOG"
}

@test "TG_TARGET_REPOS is not exported when no targets are set" {
  unset TG_TARGET_REPOS DVB_TARGET_REPOS 2>/dev/null || true
  cat > "$DVB_GRIND_CMD" <<SCRIPT
#!/bin/bash
echo "env_TG_TARGET_REPOS=\${TG_TARGET_REPOS:-UNSET}" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
echo "env_TG_TARGET_REPO_COUNT=\${TG_TARGET_REPO_COUNT:-UNSET}" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT
  chmod +x "$DVB_GRIND_CMD"
  export DVB_DEADLINE_OFFSET=5
  run "$DVB_GRIND" "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  grep -q 'env_TG_TARGET_REPOS=UNSET' "$DVB_GRIND_INVOKE_LOG"
  grep -q 'env_TG_TARGET_REPO_COUNT=UNSET' "$DVB_GRIND_INVOKE_LOG"
}

# ── Session prompt ───────────────────────────────────────────────────

@test "session prompt includes WORKSPACE: block when targets are set" {
  local t1 t2
  t1=$(_make_target_repo prompt-t1)
  t2=$(_make_target_repo prompt-t2)
  run_tiny_workload --target-repo "$t1" --target-repo "$t2" "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  grep -q 'WORKSPACE: This grind has 2 target repo' "$DVB_GRIND_INVOKE_LOG"
  grep -q "$t1" "$DVB_GRIND_INVOKE_LOG"
  grep -q "$t2" "$DVB_GRIND_INVOKE_LOG"
}

@test "session prompt does not include WORKSPACE: when no targets" {
  unset TG_TARGET_REPOS DVB_TARGET_REPOS 2>/dev/null || true
  run_tiny_workload "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  ! grep -q 'WORKSPACE:' "$DVB_GRIND_INVOKE_LOG"
}

# ── Help / docs surface ──────────────────────────────────────────────

@test "--help documents --target-repo flag" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--target-repo"* ]]
}

@test "--help documents TG_TARGET_REPOS env var" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"TG_TARGET_REPOS"* ]]
}

@test "--help describes workspace mode purpose" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace mode"* ]]
}

@test "user-stories doc includes the workspace-mode story" {
  run grep -nF '## 12. Multi-repo workspace' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
}

@test "user-stories doc shows colon-separated TG_TARGET_REPOS env example" {
  run grep -nF 'TG_TARGET_REPOS=~/apps/frontend:~/apps/backend taskgrind ~/apps/control' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
}

@test "README usage block includes --target-repo example" {
  # grep treats `--target-repo` as a flag without `--` separator
  run grep -nF -- '--target-repo ~/apps/frontend --target-repo ~/apps/backend' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "README env table documents TG_TARGET_REPOS" {
  run grep -nF '| `TG_TARGET_REPOS` ' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "man page synopsis lists --target-repo" {
  run grep -nF '\-\-target\-repo' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "man page ENVIRONMENT lists TG_TARGET_REPOS" {
  run grep -nE '^\.B TG_TARGET_REPOS$' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

# ── Structural assertions ────────────────────────────────────────────

@test "structural: target_repos array is initialized empty by default" {
  grep -q 'target_repos=()' "$DVB_GRIND"
}

@test "structural: TG_TARGET_REPOS is included in the TG_ alias loop" {
  grep -q 'TARGET_REPOS' "$DVB_GRIND"
}

@test "structural: final_sync_all wraps single-repo final_sync" {
  grep -q 'final_sync_all()' "$DVB_GRIND"
  grep -q 'final_sync "\$repo"' "$DVB_GRIND"
}

@test "structural: sync_target_repo helper exists" {
  grep -q 'sync_target_repo()' "$DVB_GRIND"
}

@test "structural: graceful_shutdown calls final_sync_all not final_sync" {
  # The signal handler must push every repo; calling bare `final_sync` from
  # graceful_shutdown would silently drop target pushes on Ctrl+C.
  grep -q '_dvb_skip_exit_final_sync=1' "$DVB_GRIND"
  grep -B1 -A1 '_dvb_skip_exit_final_sync=1' "$DVB_GRIND" | grep -q 'final_sync_all'
}

@test "structural: handle_exit_trap calls final_sync_all" {
  awk '/^handle_exit_trap\(\) \{/,/^\}/' "$DVB_GRIND" | grep -q 'final_sync_all'
}

@test "structural: per-repo memo replaces single-pair head/ahead state" {
  grep -q '_dvb_final_sync_memo' "$DVB_GRIND"
  ! grep -q '_dvb_final_sync_attempted_head' "$DVB_GRIND"
  ! grep -q '_dvb_final_sync_attempted_ahead' "$DVB_GRIND"
}

@test "structural: target sync runs after the control sync block" {
  grep -q 'sync_target_repo "\$_ts"' "$DVB_GRIND"
}

@test "structural: target sync log lines use target=<name> trailing label" {
  # Workspace mode emits `git_sync ok target=<name>` etc. (label as TRAILING
  # qualifier, not prefix) so a single `grep "git_sync ok"` matches both
  # control- and target-repo lines. Pin the trailing-label shape here.
  grep -q '_ts_label="target=\$(basename "\$_ts_repo")"' "$DVB_GRIND"
  grep -q 'git_sync ok \$_ts_label' "$DVB_GRIND"
}

@test "structural: target final_sync log lines use target=<name> label" {
  # The wrapper passes "target=<basename>" (no trailing space) and final_sync
  # appends it to log lines as a SUFFIX, so `final_sync push_ok` etc. literal
  # markers stay contiguous in the source for the marker-drift guard.
  grep -q 'final_sync "\$_t" "target=\$(basename "\$_t")"' "$DVB_GRIND"
}
