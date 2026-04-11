# Shared test helpers for bats tests.
# Loaded via: load test_helper
#
# Provides setup()/teardown() used by all split test files.
# Each test gets an isolated tmpdir with fake devin, repo, and lib copies.

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
