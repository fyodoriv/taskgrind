#!/usr/bin/env bats
# Tests for _capture_pipeline_baseline + _verify_pipeline_completion_rate
# (the taskgrind ↔ bosun pipeline-rate cross-check).
#
# What this catches: agents that ship tasks (remove from TASKS.md) without
# going through bosun pipelines — the Apr 28-29 incident shape. Bosun PRs
# #1554/#1555 close the bypass at commit/push time inside the bosun repo;
# this check is taskgrind's independent observability layer.
#
# Tests cover:
#   - Helper functions exist + are wired correctly
#   - Baseline-file format matches the expected JSON shape
#   - Verification skips cleanly when skill doesn't need bosun
#   - Verification skips cleanly when no baseline exists
#   - Anomaly detection fires when tasks_shipped > 0 AND delta == 0
#   - Anomaly task gets written to TASKS.md with marker
#   - Marker prevents duplicate task entries (idempotency)

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Helper-existence tests (structural) ──────────────────────────────────────

@test "_pipeline_count_via_api helper defined" {
  grep -q '^_pipeline_count_via_api()' "$DVB_GRIND"
}

@test "_capture_pipeline_baseline helper defined" {
  grep -q '^_capture_pipeline_baseline()' "$DVB_GRIND"
}

@test "_verify_pipeline_completion_rate helper defined" {
  grep -q '^_verify_pipeline_completion_rate()' "$DVB_GRIND"
}

@test "_record_pipeline_anomaly_task helper defined" {
  grep -q '^_record_pipeline_anomaly_task()' "$DVB_GRIND"
}

# ── Wiring tests ─────────────────────────────────────────────────────────────

@test "_capture_pipeline_baseline wired into preflight (after bosun health)" {
  # The capture call must follow the successful-bosun-health branch in
  # preflight_check, otherwise we'd capture a baseline against a server
  # that's not ready and emit confusing logs.
  awk '/preflight_pass "Bosun server ready/,/^\}$/' "$DVB_GRIND" \
    | grep -q '_capture_pipeline_baseline'
}

@test "_verify_pipeline_completion_rate wired into cleanup" {
  # The verification runs at session end (cleanup function) so tasks_shipped
  # has its final value when we compute the delta.
  awk '/^cleanup\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q '_verify_pipeline_completion_rate'
}

# ── Baseline-format tests ────────────────────────────────────────────────────

@test "_capture_pipeline_baseline writes startCount + startTime JSON" {
  # The format is documented and the verification function depends on
  # parsing 'startCount':<digits> via grep. If someone changes the format
  # to YAML, msgpack, or a different shape, this test catches it.
  grep -A 8 '^_capture_pipeline_baseline()' "$DVB_GRIND" \
    | grep -q '"startCount":%d'
  grep -A 8 '^_capture_pipeline_baseline()' "$DVB_GRIND" \
    | grep -q '"startTime":%d'
}

@test "_capture_pipeline_baseline scopes file by lock_hash" {
  # File scoped per lock_hash so concurrent grinds in different repos don't
  # clobber each other's baseline.
  grep -A 8 '^_capture_pipeline_baseline()' "$DVB_GRIND" \
    | grep -q 'taskgrind-baseline-\${_lock_hash}'
}

# ── Verification-logic tests ─────────────────────────────────────────────────

@test "_verify_pipeline_completion_rate gates on _skill_needs_bosun" {
  # Skills that don't need bosun (next-task, refactor, etc.) shouldn't
  # have their commits cross-checked against bosun pipelines.
  awk '/^_verify_pipeline_completion_rate\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q '_skill_needs_bosun'
}

@test "_verify_pipeline_completion_rate gates on baseline file existence" {
  awk '/^_verify_pipeline_completion_rate\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'no_baseline'
}

@test "_verify_pipeline_completion_rate flags tasks_shipped>0 + delta=0 anomaly" {
  awk '/^_verify_pipeline_completion_rate\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'tasks_shipped" -gt 0 && "\$delta" -eq 0'
}

@test "_verify_pipeline_completion_rate emits ANOMALY log line" {
  awk '/^_verify_pipeline_completion_rate\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'pipeline_verify ANOMALY'
}

# ── TASKS.md anomaly task test ───────────────────────────────────────────────

@test "_record_pipeline_anomaly_task uses idempotent marker" {
  # The marker keys by start_epoch so a second run of cleanup (e.g. via
  # graceful shutdown + EXIT trap firing) doesn't double-file.
  awk '/^_record_pipeline_anomaly_task\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'taskgrind-pipeline-anomaly-\${start_epoch}'
}

@test "_record_pipeline_anomaly_task auto-files with auto-filed tag" {
  awk '/^_record_pipeline_anomaly_task\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'auto-filed'
}

@test "_record_pipeline_anomaly_task short-circuits if marker already present" {
  awk '/^_record_pipeline_anomaly_task\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'grep -qF "$marker_id"'
}

# ── Curl-API contract tests ──────────────────────────────────────────────────

@test "_pipeline_count_via_api uses BOSUN_API_BASE with /api/v1/pipelines" {
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q '/api/v1/pipelines'
}

@test "_pipeline_count_via_api falls back to grep when jq missing" {
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q "command -v jq"
}

@test "_pipeline_count_via_api uses --max-time 5 (test-friendly timeout)" {
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q -- '--max-time 5'
}

# ── Integration-style: end-to-end with stubbed curl ──────────────────────────

@test "anomaly path: curl returns same count → tasks_shipped → ANOMALY logged" {
  # Stub curl to always return a 1-pipeline response. Capture baseline
  # then verify; with tasks_shipped > 0 and delta = 0, anomaly should
  # be logged. We exercise the helpers directly by sourcing the relevant
  # block from bin/taskgrind into a transient bash and overriding the
  # surrounding env.

  # Build a minimal harness script that defines just the dependencies the
  # helpers need (log_write stub, _skill_needs_bosun stub, etc.) and then
  # extracts and sources the helper definitions from bin/taskgrind.

  local harness="$TEST_DIR/harness.sh"
  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -uo pipefail
_dvb_tmp="$TG_TEST_TMP"
_lock_hash="harness"
start_epoch=$(date +%s)
session=1
skill="fleet-grind"
repo="$TG_TEST_REPO"
log_file="$TG_TEST_TMP/test.log"
tasks_shipped="${TG_TASKS_SHIPPED:-0}"
log_write() { echo "$1" >> "$log_file"; }
_skill_needs_bosun() { return 0; }
HARNESS

  # Extract the four helpers from bin/taskgrind by line range.
  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_count_via_api()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^slot_lock_file()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"

  # Override _pipeline_count_via_api to return a controllable number via env.
  cat >> "$harness" <<'HARNESS'
_pipeline_count_via_api() { echo "${TG_API_COUNT:-0}"; }
HARNESS

  echo "_capture_pipeline_baseline" >> "$harness"
  echo "_verify_pipeline_completion_rate" >> "$harness"

  # Run with fixed counts: API returns 5 at baseline, 5 at end → delta=0 →
  # combined with tasks_shipped=2, should log ANOMALY.
  TG_TEST_TMP="$TEST_DIR" \
    TG_TEST_REPO="$TEST_DIR" \
    TG_TASKS_SHIPPED=2 \
    TG_API_COUNT=5 \
    bash "$harness" 2>&1 || true

  cat "$TEST_DIR/test.log"
  grep -q 'pipeline_verify ANOMALY' "$TEST_DIR/test.log"
  grep -q 'tasks_shipped=2' "$TEST_DIR/test.log"
  grep -q 'pipeline_delta=0' "$TEST_DIR/test.log"
}

@test "no anomaly when tasks_shipped is zero" {
  local harness="$TEST_DIR/harness.sh"
  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -uo pipefail
_dvb_tmp="$TG_TEST_TMP"
_lock_hash="harness2"
start_epoch=$(date +%s)
session=1
skill="fleet-grind"
repo="$TG_TEST_REPO"
log_file="$TG_TEST_TMP/test2.log"
tasks_shipped="${TG_TASKS_SHIPPED:-0}"
log_write() { echo "$1" >> "$log_file"; }
_skill_needs_bosun() { return 0; }
HARNESS

  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_count_via_api()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^slot_lock_file()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"

  cat >> "$harness" <<'HARNESS'
_pipeline_count_via_api() { echo "${TG_API_COUNT:-0}"; }
HARNESS

  echo "_capture_pipeline_baseline" >> "$harness"
  echo "_verify_pipeline_completion_rate" >> "$harness"

  TG_TEST_TMP="$TEST_DIR" \
    TG_TEST_REPO="$TEST_DIR" \
    TG_TASKS_SHIPPED=0 \
    TG_API_COUNT=5 \
    bash "$harness" 2>&1 || true

  ! grep -q 'pipeline_verify ANOMALY' "$TEST_DIR/test2.log"
}

@test "no anomaly when delta > 0 (real pipelines completed)" {
  local harness="$TEST_DIR/harness.sh"
  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -uo pipefail
_dvb_tmp="$TG_TEST_TMP"
_lock_hash="harness3"
start_epoch=$(date +%s)
session=1
skill="fleet-grind"
repo="$TG_TEST_REPO"
log_file="$TG_TEST_TMP/test3.log"
tasks_shipped="${TG_TASKS_SHIPPED:-0}"
log_write() { echo "$1" >> "$log_file"; }
_skill_needs_bosun() { return 0; }
HARNESS

  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_count_via_api()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^slot_lock_file()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"

  # Two-step API: capture returns 5, verify returns 8. The function runs
  # in a subshell each invocation (because callers use `$(...)`), so a
  # plain shell variable counter would reset. Use a temp file as a
  # cross-subshell counter.
  cat >> "$harness" <<'HARNESS'
_pipeline_count_via_api() {
  local counter_file="$_dvb_tmp/_pipeline_count_calls"
  local n
  if [[ -f "$counter_file" ]]; then
    n=$(<"$counter_file")
  else
    n=0
  fi
  n=$((n + 1))
  echo "$n" > "$counter_file"
  if [[ "$n" -eq 1 ]]; then
    echo 5
  else
    echo 8  # 3 pipelines completed during the session
  fi
}
HARNESS

  echo "_capture_pipeline_baseline" >> "$harness"
  echo "_verify_pipeline_completion_rate" >> "$harness"

  TG_TEST_TMP="$TEST_DIR" \
    TG_TEST_REPO="$TEST_DIR" \
    TG_TASKS_SHIPPED=2 \
    bash "$harness" 2>&1 || true

  ! grep -q 'pipeline_verify ANOMALY' "$TEST_DIR/test3.log"
  # But we should still log the delta normally:
  grep -q 'delta=3' "$TEST_DIR/test3.log"
}
