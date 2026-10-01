#!/usr/bin/env bats
# Tests for taskgrind — Iron Rule 7 pre-commit enforcement preflight check
#
# Guards against the May 2026 readiness-inspection shape where the target
# repo's core.hooksPath was /dev/null (or pointed at a sibling dir without
# Bosun's hook), silently disabling the pipeline-only commit gate that
# Bosun-dependent skills (fleet-grind, pipeline-ops) rely on.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# Build a Bosun-shaped fixture inside TEST_REPO: hooks/pre-commit that
# carries the BOSUN_GRIND_SESSION_ID Iron Rule 7 marker. The test mutates
# core.hooksPath to exercise each failure shape.
_install_bosun_shaped_hook() {
  mkdir -p "$TEST_REPO/hooks"
  cat > "$TEST_REPO/hooks/pre-commit" <<'HOOK'
#!/bin/sh
# Bosun-shaped fixture pre-commit. The real hook checks BOSUN_GRIND_SESSION_ID
# to enforce Iron Rule 7; we only need the marker to be detectable by
# taskgrind's preflight scan.
if [ -n "${BOSUN_GRIND_SESSION_ID:-}" ] && [ "${BOSUN_PIPELINE:-}" != "1" ]; then
  exit 0
fi
exit 0
HOOK
  chmod +x "$TEST_REPO/hooks/pre-commit"
}

_install_fleet_grind_skill() {
  mkdir -p "$TEST_HOME/.config/devin/skills/fleet-grind"
  printf '# fleet-grind\n' > "$TEST_HOME/.config/devin/skills/fleet-grind/SKILL.md"
}

@test "preflight passes when target repo has Iron Rule 7 hook + correct hooksPath" {
  _preflight_git_init
  _install_bosun_shaped_hook
  _install_fleet_grind_skill
  git -C "$TEST_REPO" config core.hooksPath hooks

  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Iron Rule 7 pre-commit hook active"* ]]
}

@test "preflight fails when target repo has core.hooksPath = /dev/null" {
  _preflight_git_init
  _install_bosun_shaped_hook
  _install_fleet_grind_skill
  git -C "$TEST_REPO" config core.hooksPath /dev/null

  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Iron Rule 7 pre-commit hook NOT enforced"* ]]
  [[ "$output" == *"resolves to /dev/null"* ]]
  [[ "$output" == *"git -C \"$TEST_REPO\" config core.hooksPath hooks"* ]]
}

@test "preflight fails when target repo's core.hooksPath points at a sibling dir without the hook" {
  _preflight_git_init
  _install_bosun_shaped_hook
  _install_fleet_grind_skill
  # Create a sibling hooks dir with a benign pre-commit that does NOT contain
  # Bosun's Iron Rule 7 marker.
  mkdir -p "$TEST_DIR/sibling-hooks"
  cat > "$TEST_DIR/sibling-hooks/pre-commit" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
  chmod +x "$TEST_DIR/sibling-hooks/pre-commit"
  git -C "$TEST_REPO" config core.hooksPath "$TEST_DIR/sibling-hooks"

  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Iron Rule 7 pre-commit hook NOT enforced"* ]]
  [[ "$output" == *"does not invoke Bosun's hooks/pre-commit"* ]]
}

@test "preflight check is skipped when target repo does not ship Iron Rule 7" {
  # No Bosun hook installed in TEST_REPO. The check must not fire — taskgrind
  # has no hook to verify, so it should not block the run.
  _preflight_git_init
  _install_fleet_grind_skill

  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Iron Rule 7 pre-commit hook NOT enforced"* ]]
  [[ "$output" != *"Iron Rule 7 pre-commit hook active"* ]]
}

@test "preflight check is skipped when skill does not depend on Bosun" {
  # A non-Bosun skill (the default 'next-task') must never trigger the check,
  # even when a Bosun-shaped hook is installed in the target.
  _preflight_git_init
  _install_bosun_shaped_hook
  git -C "$TEST_REPO" config core.hooksPath /dev/null

  run "$DVB_GRIND" --preflight "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Iron Rule 7 pre-commit hook NOT enforced"* ]]
  [[ "$output" != *"Iron Rule 7 pre-commit hook active"* ]]
}

@test "preflight check structural — function and call wired into bin/taskgrind" {
  # Structural — guards against accidental removal of the helper or its
  # invocation in preflight_check during refactors. The integration tests
  # above exercise behaviour; this one catches the rename/delete shape.
  grep -q '_check_bosun_pipeline_only_enforcement()' "$DVB_GRIND"
  grep -q 'Iron Rule 7 pre-commit hook active' "$DVB_GRIND"
  grep -q 'Iron Rule 7 pre-commit hook NOT enforced' "$DVB_GRIND"
}
