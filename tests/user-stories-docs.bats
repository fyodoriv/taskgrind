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

@test "operator docs explain env-based backend and model startup defaults" {
  run grep -nF 'TG_MODEL=sonnet taskgrind 8' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
  run grep -nF 'Use flags when you want a' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
  run grep -nF 'one-off override in your shell history; use `TG_BACKEND` or `TG_MODEL` when' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '## 2a. Reusable backend and model defaults via environment' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
  run grep -nF 'TG_BACKEND=codex TG_MODEL=o3 taskgrind ~/apps/myproject 6' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
  run grep -nF 'This is useful for reusable automation because a restart can inherit the same baseline choices without editing the wrapper command itself' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]
}


@test "contributor docs mention the Bash 3.2 compatibility guard" {
  run grep -nF 'Taskgrind runtime files must stay compatible with `/bin/bash` 3.2' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '`tests/verify-bash32-compat.sh` is the guard that enforces that contract during' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'If you touch runtime shell code, keep it `/bin/bash` 3.2 compatible and use `tests/verify-bash32-compat.sh` plus `tests/bash-compat.bats` to catch Bash-4-only syntax before the full suite does' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]
}

@test "README task format examples use real focused bats files" {
  local readme="$BATS_TEST_DIRNAME/../README.md"

  run grep -nF '**Files**: `bin/taskgrind`, `tests/preflight.bats`' "$readme"
  [ "$status" -eq 0 ]

  run grep -nF '**Files**: `bin/taskgrind`, `tests/network.bats`' "$readme"
  [ "$status" -eq 0 ]

  run grep -nF 'tests/auth.bats' "$readme"
  [ "$status" -eq 1 ]

  run grep -nF 'tests/api.bats' "$readme"
  [ "$status" -eq 1 ]
}
