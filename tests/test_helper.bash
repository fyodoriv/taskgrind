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

# Helper: create an executable fake devin script from stdin.
create_fake_devin() {
  local fake_devin_path="$1"
  cat > "$fake_devin_path"
  chmod +x "$fake_devin_path"
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
model=gpt-5.4
startup_model=gpt-5.4
startup_prompt=
EOF

  local entry key value
  for entry in "$@"; do
    key="${entry%%=*}"
    value="${entry#*=}"
    python3 - "$state_file" "$key" "$value" <<'PY'
from pathlib import Path
import sys

state_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = state_path.read_text().splitlines()

for index, line in enumerate(lines):
    if line.startswith(f"{key}="):
        lines[index] = f"{key}={value}"
        break
else:
    lines.append(f"{key}={value}")

state_path.write_text("\n".join(lines) + "\n")
PY
  done
}
