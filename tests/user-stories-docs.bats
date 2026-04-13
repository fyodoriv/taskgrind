#!/usr/bin/env bats

@test "user stories remind higher-slot discovery lanes to rebase before committing" {
  run grep -nF 'Slot `1` still needs `git pull --rebase` right before each commit because slot `0` remains the only between-session sync owner' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
}
