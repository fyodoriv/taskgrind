#!/usr/bin/env bats
# Tests for the 2026-04-29 sane-default refresh (post pipelines-only era).
#
# After bosun PR #1548 enforces "code commits via pipelines only" inside
# fleet-grind sessions, the agent's role shifts from coder to orchestrator
# (launch pipelines, monitor, merge, repeat). Pipelines take 20-45 min each
# so the old 60-min session was budgeted for ~1 cycle. 90-min lets the
# agent batch 2-3 pipeline cycles per session.
#
# Tests cover:
#   - TG_MAX_SESSION default bumped 3600 → 5400
#   - DVB_MAX_SESSION env override still works
#   - Bosun-health preflight check #9 added
#   - _skill_needs_bosun helper present + recognizes known skills
#   - Help/man docs reflect the new default

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Default session length ────────────────────────────────────────────

@test "TG_MAX_SESSION default is 5400 (90 min, post 2026-04-29)" {
  grep -Fq 'DVB_DEFAULT_MAX_SESSION="5400"' "$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -Fq 'max_session="${DVB_MAX_SESSION:-$DVB_DEFAULT_MAX_SESSION}"' "$DVB_GRIND"
}

@test "TG_MAX_SESSION still respects DVB_MAX_SESSION env override" {
  # Sanity: override should still work through the resolution chain.
  grep -Fq 'DVB_MAX_SESSION:-$DVB_DEFAULT_MAX_SESSION' "$DVB_GRIND"
}

@test "TG_MAX_SESSION old default (3600) is no longer the fallback" {
  ! grep -q 'max_session="${DVB_MAX_SESSION:-3600}"' "$DVB_GRIND"
}

@test "audited runtime defaults live in lib/constants.sh with rationale comments" {
  python3 - "$BATS_TEST_DIRNAME/../lib/constants.sh" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
expected = {
    "COOL": "5",
    "MAX_FAST": "20",
    "MAX_SESSION": "5400",
    "SWEEP_MAX": "1800",
    "MAX_ZERO_SHIP": "6",
    "SYNC_INTERVAL": "5",
    "MAX_INSTANCES": "2",
    "MIN_SESSION": "30",
    "NET_WAIT": "30",
    "NET_MAX_WAIT": "3600",
    "NET_RETRIES": "3",
    "NET_RETRY_DELAY": "2",
    "BACKOFF_BASE": "15",
    "BACKOFF_MAX": "120",
    "GIT_SYNC_TIMEOUT": "30",
    "EMPTY_QUEUE_WAIT": "600",
    "SHUTDOWN_GRACE": "120",
    "SESSION_GRACE": "15",
    "SELF_INVESTIGATE_ZERO_SHIP_STREAK": "3",
}
for name, value in expected.items():
    constant = f"DVB_DEFAULT_{name}"
    assert re.search(rf"^# TG_{name}={re.escape(value)}: .+", text, re.M), f"missing rationale for TG_{name}"
    assert re.search(rf"^{constant}=\"{re.escape(value)}\"$", text, re.M), f"missing {constant}={value}"
PY
}

@test "tuned defaults are documented with benchmark rationale" {
  doc="$BATS_TEST_DIRNAME/../docs/defaults-rationale.md"
  [ -f "$doc" ]
  grep -Fq '| `TG_MAX_ZERO_SHIP` | 50 sessions | 6 sessions |' "$doc"
  grep -Fq '| `TG_NET_MAX_WAIT` | 14400s | 3600s |' "$doc"
}

@test "header comment documents the bump rationale" {
  grep -q '20-45 min each' "$DVB_GRIND"
  grep -q 'orchestrator role' "$DVB_GRIND"
}

# ── Bosun-server preflight ────────────────────────────────────────────

@test "_skill_needs_bosun helper exists" {
  grep -q '^_skill_needs_bosun()' "$DVB_GRIND"
}

@test "_skill_needs_bosun recognizes fleet-grind" {
  grep -q 'fleet-grind|full-sweep|bosun' "$DVB_GRIND"
}

@test "_skill_needs_bosun recognizes pipeline-* skills via wildcard" {
  grep -q '\*pipeline\*' "$DVB_GRIND"
}

@test "_check_bosun_health helper exists" {
  grep -q '^_check_bosun_health()' "$DVB_GRIND"
}

@test "_ensure_bosun_grind_session helper exists" {
  grep -q '^_ensure_bosun_grind_session()' "$DVB_GRIND"
}

@test "_check_bosun_health probes /api/v1/ready (no auth required)" {
  grep -q '/api/v1/ready' "$DVB_GRIND"
}

@test "_check_bosun_health respects BOSUN_API_BASE override" {
  grep -q 'BOSUN_API_BASE' "$DVB_GRIND"
  grep -q 'BOSUN_API_BASE:-http://localhost:9746' "$DVB_GRIND"
}

@test "preflight_check has a bosun-health check (#9)" {
  grep -q '9. Bosun server reachable' "$DVB_GRIND"
}

@test "preflight bosun check is conditional on _skill_needs_bosun" {
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
i_check_intro = text.find('9. Bosun server reachable')
assert i_check_intro != -1, "preflight #9 marker missing"
# The next 200 chars should contain a `_skill_needs_bosun` guard.
window = text[i_check_intro:i_check_intro + 600]
assert '_skill_needs_bosun' in window, \
  "bosun preflight should be gated on _skill_needs_bosun, not run unconditionally"
PY
}

@test "preflight bosun check is skipped in test mode (DVB_GRIND_CMD set)" {
  # Bats suite runs with DVB_GRIND_CMD set; the preflight should not require
  # a real bosun server during tests, otherwise CI would need a live bosun.
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
i_check = text.find('9. Bosun server reachable')
window = text[i_check:i_check + 800]
assert 'DVB_GRIND_CMD' in window, "test-mode skip missing"
assert 'preflight_pass "Bosun server check skipped' in window or \
       'Bosun server check skipped (test mode)' in window, \
  "test-mode pass-message missing"
PY
}

@test "preflight ensures a grind session for bosun-dependent skills" {
  python3 - "$DVB_GRIND" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
i_check = text.find('9. Bosun server reachable')
window = text[i_check:i_check + 1400]
assert '_ensure_bosun_grind_session' in window, "grind-session ensure missing from bosun preflight"
assert 'Bosun grind session active' in window, "preflight should report active grind session"
PY
}

# ── Integration: bats run with --preflight should not fail in test mode ─────

@test "preflight runs cleanly when skill is fleet-grind in test mode" {
  # Even with skill=fleet-grind (which needs bosun), test mode should pass
  # because DVB_GRIND_CMD is set.
  run "$DVB_GRIND" --preflight --skill fleet-grind "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bosun server check skipped"* ]]
  [[ "$output" == *"Bosun grind session active"* ]]
}

@test "fleet-grind child sessions inherit BOSUN_GRIND_SESSION_ID in test mode" {
  create_fake_devin "$TEST_DIR/fake-devin-env" <<'SCRIPT'
#!/bin/bash
env | grep '^BOSUN_GRIND_SESSION_ID=' >> "$TG_ENV_LOG"
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT

  export DVB_GRIND_CMD="$TEST_DIR/fake-devin-env"
  export TG_ENV_LOG="$TEST_DIR/env.log"
  export DVB_DEADLINE_OFFSET=5
  export DVB_MIN_SESSION=0
  export DVB_MAX_ZERO_SHIP=1

  run "$DVB_GRIND" --skill fleet-grind "$TEST_REPO" 1

  [ -f "$TG_ENV_LOG" ]
  grep -q '^BOSUN_GRIND_SESSION_ID=taskgrind-test-' "$TG_ENV_LOG"
}

@test "preflight runs cleanly with non-bosun skill (no bosun check at all)" {
  run "$DVB_GRIND" --preflight --skill audit-error-handling "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Bosun check should not appear because the skill doesn't need bosun.
  [[ "$output" != *"Bosun server check"* ]]
}

# ── Backend auto-detection ────────────────────────────────────────────

@test "autodetect: scans PATH for devin / claude-code / codex when --rotate-backends not set" {
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
# The autodetect block must be present and run BEFORE the rotation parsing.
i_autodetect = text.find('Auto-detected backends')
i_rotation_parse = text.find('IFS=\',\' read -ra _rotation_backends <<< "$_rotation_raw"')
assert i_autodetect != -1, "autodetect block missing"
assert i_rotation_parse != -1, "rotation parser missing"
assert i_autodetect < i_rotation_parse, \
  "autodetect must populate _rotation_raw BEFORE the parser reads it"
PY
}

@test "autodetect: only fires when --rotate-backends NOT set" {
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
# The autodetect must be guarded on `_rotation_raw` being empty AND test mode off.
assert 'if [[ -z "$_rotation_raw" && -z "${DVB_GRIND_CMD:-}" ]]' in text, \
  "autodetect guard missing — should only fire when rotation list empty + not in test mode"
PY
}

@test "autodetect: 1-element rotation does not emit (rotation needs >=2)" {
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
assert 'if [[ ${#_autodetected[@]} -ge 2 ]]' in text, \
  "autodetect must require >=2 backends to enable rotation"
PY
}

@test "autodetect: skipped in test mode (DVB_GRIND_CMD set) so bats stays portable" {
  # Run in test mode (DVB_GRIND_CMD already set by test_helper). The autodetect
  # branch should NOT fire — the setup runner doesn't have devin/claude/codex
  # on PATH, and we don't want bats to depend on them.
  export DVB_DEADLINE_OFFSET=2
  run "$DVB_GRIND" --preflight --skill audit-error-handling "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The "Auto-detected" message should NOT appear in test mode.
  [[ "$output" != *"Auto-detected backends"* ]]
}

@test "autodetect: explicit --rotate-backends overrides autodetect" {
  python3 - "$DVB_GRIND" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
# When _rotation_raw is set (from --rotate-backends or TG_ROTATE_BACKENDS),
# autodetect must NOT fire — the user's explicit choice wins.
i_guard = text.find('if [[ -z "$_rotation_raw" && -z "${DVB_GRIND_CMD:-}" ]]')
assert i_guard != -1, "autodetect guard missing"
# Verify the explicit --rotate-backends path runs unconditionally below.
i_parser = text.find('IFS=\',\' read -ra _rotation_backends', i_guard)
assert i_parser != -1, "rotation parser missing after autodetect"
PY
}
