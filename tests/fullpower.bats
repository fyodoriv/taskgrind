#!/usr/bin/env bats

load test_helper

FULLPOWER_LIB="$BATS_TEST_DIRNAME/../lib/fullpower.sh"

@test "boost_priority invokes taskpolicy with explicit pid" {
  local fake_bin="$TEST_DIR/fake-bin"
  local taskpolicy_log="$TEST_DIR/taskpolicy.log"
  mkdir -p "$fake_bin"

  create_fake_git "$fake_bin/taskpolicy" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$TASKPOLICY_LOG"
SCRIPT

  run env \
    PATH="$fake_bin:/usr/bin:/bin" \
    FULLPOWER_LIB="$FULLPOWER_LIB" \
    TASKPOLICY_LOG="$taskpolicy_log" \
    bash -c 'source "$FULLPOWER_LIB"; boost_priority 4242'

  [ "$status" -eq 0 ]
  grep -q -- '^-B -t 0 -l 0 -p 4242$' "$taskpolicy_log"
}

@test "boost_priority defaults to the current shell pid" {
  local fake_bin="$TEST_DIR/fake-bin"
  local taskpolicy_log="$TEST_DIR/taskpolicy.log"
  mkdir -p "$fake_bin"

  create_fake_git "$fake_bin/taskpolicy" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$TASKPOLICY_LOG"
SCRIPT

  run env \
    PATH="$fake_bin:/usr/bin:/bin" \
    FULLPOWER_LIB="$FULLPOWER_LIB" \
    TASKPOLICY_LOG="$taskpolicy_log" \
    bash -c '
      source "$FULLPOWER_LIB"
      expected_pid="$$"
      boost_priority
      grep -q -- "^-B -t 0 -l 0 -p $expected_pid\$" "$TASKPOLICY_LOG"
    '

  [ "$status" -eq 0 ]
}

@test "boost_priority skips cleanly when taskpolicy is unavailable" {
  local taskpolicy_log="$TEST_DIR/taskpolicy.log"

  run env \
    PATH="/usr/bin:/bin" \
    FULLPOWER_LIB="$FULLPOWER_LIB" \
    TASKPOLICY_LOG="$taskpolicy_log" \
    bash -c 'source "$FULLPOWER_LIB"; boost_priority 4242'

  [ "$status" -eq 0 ]
  [ ! -e "$taskpolicy_log" ]
}
