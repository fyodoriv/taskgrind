#!/usr/bin/env bats

load test_helper

@test "runtime files stay compatible with /bin/bash 3.2 constraints" {
  run "$BATS_TEST_DIRNAME/verify-bash32-compat.sh"
  [ "$status" -eq 0 ]
}
