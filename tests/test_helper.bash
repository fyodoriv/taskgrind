# Shared test helpers for bats tests.
# Loaded via: load test_helper

# Create isolated temp environment for each test
setup() {
  TEST_DIR="$(mktemp -d)"
  TEST_HOME="$TEST_DIR/home"
  TEST_DOTFILES="$TEST_DIR/dotfiles"

  mkdir -p "$TEST_HOME"
  mkdir -p "$TEST_DOTFILES"

  # Override HOME and TASKGRIND_DIR for isolated testing
  export HOME="$TEST_HOME"
  export TASKGRIND_DIR="$TEST_DOTFILES"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper: create a file with content
create_file() {
  local path="$1" content="${2:-}"
  mkdir -p "$(dirname "$path")"
  echo "$content" > "$path"
}

# Helper: assert file is a symlink pointing to expected target
assert_symlink() {
  local path="$1" expected_target="$2"
  [ -L "$path" ] || { echo "Expected $path to be a symlink"; return 1; }
  local actual
  actual="$(readlink "$path")"
  [ "$actual" = "$expected_target" ] || { echo "Expected symlink to $expected_target, got $actual"; return 1; }
}

# Helper: assert file exists and is a regular file
assert_file() {
  local path="$1"
  [ -f "$path" ] || { echo "Expected $path to exist as a regular file"; return 1; }
}

# Helper: assert file does not exist
assert_no_file() {
  local path="$1"
  [ ! -e "$path" ] || { echo "Expected $path to not exist"; return 1; }
}
