#!/usr/bin/env bats
# Repo-local skill contract: scripts/validate-skills.py, run by `make audit`.

REPO_DIR="$BATS_TEST_DIRNAME/.."
VALIDATE="$REPO_DIR/scripts/validate-skills.py"

setup() {
  SCRATCH="$(mktemp -d "${BATS_TMPDIR:-/tmp}/skills.XXXXXX")"
}

teardown() {
  rm -rf "$SCRATCH"
}

_skill() {
  mkdir -p "$SCRATCH/$1"
  cat > "$SCRATCH/$1/SKILL.md"
}

@test "skills: every repo-local skill passes validation" {
  run python3 "$VALIDATE" "$REPO_DIR/.agents/skills"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill(s) OK"* ]]
}

@test "skills: a malformed skill fails with one line per problem" {
  _skill Bad_Name <<'MD'
---
name: other-name
description:
---
Body without a rules section.
MD
  _skill no-frontmatter <<'MD'
# Just a heading
MD
  run python3 "$VALIDATE" "$SCRATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bad_Name/SKILL.md: name 'other-name' does not match directory 'Bad_Name'"* ]]
  [[ "$output" == *"Bad_Name/SKILL.md: directory name is not lowercase-hyphenated"* ]]
  [[ "$output" == *"Bad_Name/SKILL.md: description is empty"* ]]
  [[ "$output" == *"Bad_Name/SKILL.md: no '## Constraints', '## Guardrails', or '## Rules' section"* ]]
  [[ "$output" == *"no-frontmatter/SKILL.md: missing '---' frontmatter delimiters"* ]]
}

@test "skills: make audit runs the skill validator" {
  run grep -nF 'scripts/validate-skills.py' "$REPO_DIR/Makefile"
  [ "$status" -eq 0 ]
}
