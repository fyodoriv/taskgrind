#!/usr/bin/env bats

load test_helper

INSTALL_SCRIPT="$BATS_TEST_DIRNAME/../install.sh"

@test "install.sh quotes the update command when install dir already exists" {
  local install_dir="$TEST_DIR/Applications With Spaces/taskgrind copy"
  mkdir -p "$install_dir"

  TASKGRIND_INSTALL_DIR="$install_dir" run sh "$INSTALL_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"To update: cd \"$install_dir\" && git pull"* ]]
}

@test "install.sh quotes the make command when install dir contains spaces" {
  local install_root="$TEST_DIR/Applications With Spaces"
  local install_dir="$install_root/taskgrind copy"
  local fake_bin="$TEST_DIR/fake-bin"
  local git_log="$TEST_DIR/git.log"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$GIT_LOG"
if [ "$1" = "clone" ]; then
  target_dir=$3
  mkdir -p "$target_dir/bin"
  : > "$target_dir/bin/taskgrind"
  chmod +x "$target_dir/bin/taskgrind"
  exit 0
fi
exit 1
SCRIPT
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" GIT_LOG="$git_log" TASKGRIND_INSTALL_DIR="$install_dir" run sh "$INSTALL_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"make -C \"$install_dir\" install"* ]]
}
