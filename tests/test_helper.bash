# Shared test helpers for bats tests.
# Loaded via: load test_helper
#
# Provides setup()/teardown() used by all split test files.
# Each test gets an isolated tmpdir with fake devin, repo, and lib copies.

remove_with_retries() {
  local target_dir="$1"
  local attempts=0

  while :; do
    rm -rf "$target_dir" && return 0

    attempts=$((attempts + 1))
    if [ "$attempts" -ge 5 ] || [ ! -e "$target_dir" ]; then
      return 1
    fi

    sleep 0.1
  done
}

taskgrind_test_setup() {
  TEST_DIR="$(mktemp -d)"
  TEST_HOME="$TEST_DIR/home"
  TEST_DOTFILES="$TEST_DIR/dotfiles"
  TEST_REPO="$TEST_DIR/repo"
  TEST_LOG="$TEST_DIR/grind.log"

  mkdir -p "$TEST_HOME" "$TEST_DOTFILES/lib" "$TEST_REPO"
  mkdir -p "$TEST_HOME/.agents/skills/next-task"
  printf '# next-task\n' > "$TEST_HOME/.agents/skills/next-task/SKILL.md"
  # Copy shared libraries so the self-copied script can source them.
  # Use APFS clonefile (`cp -c`) when available — on macOS each clone is O(1)
  # and shares blocks until modified, turning a 5ms cp into <1ms across 800
  # test runs. Falls back to plain cp on Linux / non-APFS where -c is rejected.
  cp -c "$BATS_TEST_DIRNAME/../lib/constants.sh" "$TEST_DOTFILES/lib/" 2>/dev/null \
    || cp "$BATS_TEST_DIRNAME/../lib/constants.sh" "$TEST_DOTFILES/lib/"
  cp -c "$BATS_TEST_DIRNAME/../lib/fullpower.sh" "$TEST_DOTFILES/lib/" 2>/dev/null \
    || cp "$BATS_TEST_DIRNAME/../lib/fullpower.sh" "$TEST_DOTFILES/lib/"
  # Default TASKS.md with one task so sessions launch (tests override as needed)
  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Default test task
TASKS
  export HOME="$TEST_HOME"
  export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
  export GIT_AUTHOR_NAME="Taskgrind Tests"
  export GIT_AUTHOR_EMAIL="taskgrind-tests@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export TASKGRIND_DIR="$TEST_DOTFILES"
  export DVB_LOG="$TEST_LOG"
  export DVB_COOL=0
  # Belt-and-suspenders against macOS Notification Center spam during
  # `make check`: bin/taskgrind already skips notifications when
  # DVB_GRIND_CMD is set, but this also covers callers that source the
  # helper without going through the bats runner.
  export DVB_NOTIFY=0
  # Test-mode timing defaults — production defaults are tuned for real
  # multi-hour grinds (15s backoff base, 30s network poll), which add
  # minutes to every fast-failure test that just wants to verify a log
  # marker. Tests that explicitly exercise backoff or polling timing
  # override these in their own setup.
  #
  # `DVB_BACKOFF_BASE=0` zeroes the per-fast-failure sleep so a test that
  # does N fast sessions does not pay 15s × consecutive_fast on each one
  # (one slow run measured ~277s on a single check_network test because
  # of cumulative 45+60+75+90s backoffs).
  #
  # `DVB_NET_WAIT=0` makes wait_for_network's polling loop tight so a
  # test with a 1s `DVB_NET_MAX_WAIT` does not have to sit through one
  # full default 30s poll before the timeout fires.
  #
  # `DVB_EMPTY_QUEUE_WAIT=0` skips the post-sweep "wait for external
  # task injection" pause for any test that hits an empty queue
  # without specifying its own value. Many session.bats tests only check
  # that "Queue empty" output appears or that `sweep_done` was logged;
  # they do not exercise the wait duration and were costing ~15s each
  # because the wait clamped to the auto-extended 15s deadline.
  : "${DVB_BACKOFF_BASE:=0}"
  : "${DVB_NET_WAIT:=0}"
  : "${DVB_EMPTY_QUEUE_WAIT:=0}"
  export DVB_BACKOFF_BASE DVB_NET_WAIT DVB_EMPTY_QUEUE_WAIT

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

setup() {
  taskgrind_test_setup "$@"
}

_taskgrind_original_setup() {
  taskgrind_test_setup "$@"
}

teardown() {
  remove_with_retries "$TEST_DIR"
}

# Helper: force model validation paths to run during tests that exercise
# the preflight validator instead of the normal "test mode skips it" branch.
_enable_preflight_checks() {
  export DVB_VALIDATE_MODEL=1
}

# Helper: initialize a git repo in TEST_REPO for preflight tests
_preflight_git_init() {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" commit --allow-empty -m "init" --quiet
}

# Helper: create an executable fake backend script from stdin.
create_fake_backend() {
  local fake_backend_path="$1"
  cat > "$fake_backend_path"
  chmod +x "$fake_backend_path"
}

# Helper: create an executable fake devin script from stdin.
create_fake_devin() {
  create_fake_backend "$1"
}

# Helper: create an executable fake git-style binary from stdin.
create_fake_git() {
  local fake_git_path="$1"
  cat > "$fake_git_path"
  chmod +x "$fake_git_path"
}

# Helper: initialize a test git repo with a default branch and initial commit.
init_test_repo() {
  local repo_path="${1:-$TEST_REPO}"
  local branch_name="${2:-main}"
  git -C "$repo_path" init -q -b "$branch_name"
  git -C "$repo_path" config user.email "test@test.com"
  git -C "$repo_path" config user.name "Test"
  git -C "$repo_path" commit --allow-empty -m "init" --quiet
}

# Helper: configure the network sentinel path, optionally creating it.
setup_network_sentinel() {
  local sentinel_path="${1:-$TEST_DIR/net-up}"
  local sentinel_state="${2:-up}"
  export DVB_NET_FILE="$sentinel_path"
  if [ "$sentinel_state" = "up" ]; then
    touch "$sentinel_path"
  else
    rm -f "$sentinel_path"
  fi
}

# Assert that at least one session-end log line reports the expected shipped count.
# This avoids matching unrelated log lines like grind_done totals or timeout notices.
assert_session_log_has_shipped() {
  local expected_shipped="$1"
  grep -Eq "session=[0-9]+ ended .*shipped=${expected_shipped}([[:space:]]|\$)" "$TEST_LOG"
}

# Helper: write a resume-state file with sane defaults plus key=value overrides.
write_resume_state_file() {
  local state_file="$1"
  shift
  local deadline="${TEST_RESUME_DEADLINE:-$(( $(date +%s) + 300 ))}"

  cat > "$state_file" <<EOF
version=1
repo=$TEST_REPO
status=running
deadline=$deadline
session=1
tasks_shipped=0
sessions_zero_ship=0
consecutive_zero_ship=0
backend=devin
skill=next-task
model=claude-opus-4-7-max
startup_model=claude-opus-4-7-max
startup_prompt=
EOF

  # Apply each key=value override via awk in place of a per-call `python3` fork.
  # Python startup on macOS is 50-100ms per invocation and tests call this
  # helper dozens of times; one awk pass per key runs in well under 5ms and
  # handles both replace-in-place and append-if-missing in a single program.
  # Awk is POSIX so no portability shim is needed across macOS / Linux runners.
  local entry key value tmp
  for entry in "$@"; do
    key="${entry%%=*}"
    value="${entry#*=}"
    tmp="${state_file}.tmp.$$"
    awk -v k="$key" -v v="$value" -F= '
      BEGIN { matched = 0 }
      $1 == k { print k "=" v; matched = 1; next }
      { print }
      END { if (!matched) print k "=" v }
    ' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  done
}

prepare_tiny_workload() {
  if ! grep -q '^[[:space:]]*- \[ \]' "$TEST_REPO/TASKS.md" 2>/dev/null; then
    cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Tiny workload task
TASKS
  fi

  local tiny_devin="$TEST_DIR/tiny-devin"
  cat > "$tiny_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
SCRIPT
  chmod +x "$tiny_devin"
  export DVB_GRIND_CMD="$tiny_devin"

  DVB_COOL=0
  DVB_EMPTY_QUEUE_WAIT=0
  DVB_BACKOFF_BASE=0
  DVB_MAX_ZERO_SHIP=1
  DVB_SYNC_INTERVAL=999
  TG_COOL=0
  TG_EMPTY_QUEUE_WAIT=0
  TG_BACKOFF_BASE=0
  TG_MAX_ZERO_SHIP=1
  TG_SYNC_INTERVAL=999
  DVB_SKIP_SWEEP_ON_EMPTY=1
  if [ -z "${DVB_DEADLINE:-}" ]; then
    : "${DVB_DEADLINE_OFFSET:=5}"
  fi
  export DVB_COOL DVB_EMPTY_QUEUE_WAIT DVB_BACKOFF_BASE DVB_MAX_ZERO_SHIP
  export DVB_SYNC_INTERVAL DVB_SKIP_SWEEP_ON_EMPTY DVB_DEADLINE_OFFSET
  export TG_COOL TG_EMPTY_QUEUE_WAIT TG_BACKOFF_BASE TG_MAX_ZERO_SHIP TG_SYNC_INTERVAL
}

run_tiny_workload() {
  prepare_tiny_workload
  if [ "$#" -eq 0 ]; then
    run "$DVB_GRIND" 1 "$TEST_REPO"
  else
    run "$DVB_GRIND" "$@"
  fi
}
