#!/usr/bin/env bats

load test_helper

@test "test cache key handles multi-file TESTS selections" {
  run grep -nF 'space := $(empty) $(empty)' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]

  run grep -nF '$(subst $(space),_,' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]

  run grep -nF '> "$(TEST_CACHE)"' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]
}

@test "remove_with_retries retries transient directory-not-empty cleanup failures" {
  local target_dir="$TEST_DIR/stubborn"
  local fake_bin="$TEST_DIR/fake-bin"
  local original_path="$PATH"
  mkdir -p "$target_dir" "$fake_bin"

  cat > "$fake_bin/rm" <<'SCRIPT'
#!/bin/bash
log_file="${TASKGRIND_RM_LOG:?}"
count_file="${TASKGRIND_RM_COUNT:?}"
target="${@: -1}"
count=0
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf 'attempt=%s target=%s\n' "$count" "$target" >> "$log_file"
if [ "$count" -eq 1 ] && [ "$target" = "$TASKGRIND_EXPECTED_TARGET" ]; then
  echo "rm: $target/parallel_output: Directory not empty" >&2
  exit 1
fi
exec /bin/rm "$@"
SCRIPT
  chmod +x "$fake_bin/rm"

  export PATH="$fake_bin:$PATH"
  export TASKGRIND_RM_LOG="$TEST_DIR/rm.log"
  export TASKGRIND_RM_COUNT="$TEST_DIR/rm.count"
  export TASKGRIND_EXPECTED_TARGET="$target_dir"

  run bash -c 'source "$1"; remove_with_retries "$2"' bash "$BATS_TEST_DIRNAME/test_helper.bash" "$target_dir"

  [ "$status" -eq 0 ]
  [ ! -e "$target_dir" ]
  grep -q 'attempt=2' "$TASKGRIND_RM_LOG"
  export PATH="$original_path"
}
