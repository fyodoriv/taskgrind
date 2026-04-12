#!/usr/bin/env bats

load test_helper

INSTALL_SCRIPT="$BATS_TEST_DIRNAME/../install.sh"

setup() {
  _taskgrind_original_setup

  INSTALL_TEST_BIN="$TEST_DIR/install-bin"
  INSTALL_TARGET="$TEST_DIR/apps/taskgrind-install"
  INSTALL_LOG="$TEST_DIR/install.log"
  export TASKGRIND_INSTALL_DIR="$INSTALL_TARGET"
  export INSTALL_LOG

  mkdir -p "$INSTALL_TEST_BIN"
  export PATH="$INSTALL_TEST_BIN:/usr/bin:/bin"
}

@test "install.sh fails clearly when git is unavailable" {
  run env -i HOME="$HOME" PATH="" TASKGRIND_INSTALL_DIR="$INSTALL_TARGET" /bin/sh "$INSTALL_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git is required but not found"* ]]
}

@test "install.sh short-circuits when the install directory already exists" {
  mkdir -p "$INSTALL_TARGET"
  run sh "$INSTALL_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"taskgrind is already installed at $INSTALL_TARGET"* ]]
  [[ "$output" == *"To update: cd \"$INSTALL_TARGET\" && git pull"* ]]
}

@test "install.sh clones into the requested destination and prints next steps" {
  create_fake_git "$INSTALL_TEST_BIN/git" <<'SCRIPT'
#!/bin/sh
if [ "$1" = "clone" ]; then
  mkdir -p "$3/bin"
  printf '#!/bin/sh\nexit 0\n' > "$3/bin/taskgrind"
  chmod +x "$3/bin/taskgrind"
  printf '%s\n' "$@" > "${INSTALL_LOG}"
  exit 0
fi
echo "unexpected git args: $*" >&2
exit 1
SCRIPT

  run sh "$INSTALL_SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$INSTALL_TARGET/bin" ]
  grep -q "^clone$" "$INSTALL_LOG"
  grep -q "^https://github.com/cbrwizard/taskgrind.git$" "$INSTALL_LOG"
  grep -q "^$INSTALL_TARGET$" "$INSTALL_LOG"
  [[ "$output" == *"taskgrind installed to $INSTALL_TARGET"* ]]
  [[ "$output" == *"export PATH=\"$INSTALL_TARGET/bin:\$PATH\""* ]]
  [[ "$output" == *"make -C \"$INSTALL_TARGET\" install"* ]]
}

@test "install.sh repairs a missing executable bit after clone" {
  create_fake_git "$INSTALL_TEST_BIN/git" <<'SCRIPT'
#!/bin/sh
if [ "$1" = "clone" ]; then
  mkdir -p "$3/bin"
  printf '#!/bin/sh\nexit 0\n' > "$3/bin/taskgrind"
  exit 0
fi
echo "unexpected git args: $*" >&2
exit 1
SCRIPT

  run sh "$INSTALL_SCRIPT"
  [ "$status" -eq 0 ]
  [ -x "$INSTALL_TARGET/bin/taskgrind" ]
  [[ "$output" == *"Warning: $INSTALL_TARGET/bin/taskgrind is not executable"* ]]
}
