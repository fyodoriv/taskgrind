#!/usr/bin/env bats

@test "user stories remind higher-slot discovery lanes to rebase before committing" {
  run grep -nF 'Slot `1` still needs `git pull --rebase` right before each commit because slot `0` remains the only between-session sync owner' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
}

@test "architecture explains why slot 0 is the only between-session sync owner" {
  run grep -nF "Making every slot run its own fetch/rebase loop would create dueling sync cycles" "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -eq 0 ]
}

@test "operator docs keep slot 0 as the sync owner and higher slots rebasing" {
  run grep -nF 'slot 1+` skips that sync, rebases just before committing' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'Slot `1` and above skip that sync and get prompt instructions to avoid overlapping edits, prefer audits/docs/queue work or status-file supervision, and run `git pull --rebase` before committing' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]

  run grep -nF "Higher slots should prefer non\\-overlapping" "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
  run grep -nF "rebase immediately before" "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}
