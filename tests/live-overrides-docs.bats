#!/usr/bin/env bats

@test "man page documents live prompt and model override files" {
  local man_page="$BATS_TEST_DIRNAME/../man/taskgrind.1"

  run grep -nF '.SS LIVE OVERRIDE FILES' "$man_page"
  [ "$status" -eq 0 ]

  run grep -n '\.taskgrind\\-prompt' "$man_page"
  [ "$status" -eq 0 ]

  run grep -n 'startup \\-\\-prompt text' "$man_page"
  [ "$status" -eq 0 ]

  run grep -n 'Delete the file to stop injecting those extra' "$man_page"
  [ "$status" -eq 0 ]

  run grep -n '\.taskgrind\\-model' "$man_page"
  [ "$status" -eq 0 ]

  run grep -n 'startup model chosen by \\-\\-model or TG_MODEL' "$man_page"
  [ "$status" -eq 0 ]

  run grep -n 'Delete the file to fall back to the startup' "$man_page"
  [ "$status" -eq 0 ]
}
