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
#   - Anomaly detection hard-stops when tasks_shipped > 0 AND delta == 0
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

@test "_ensure_bosun_grind_session helper defined" {
  grep -q '^_ensure_bosun_grind_session()' "$DVB_GRIND"
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

@test "_verify_pipeline_completion_rate hard-stops on anomaly" {
  awk '/^_verify_pipeline_completion_rate\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q 'return 1'
}

@test "EXIT trap exits nonzero when pipeline verification failed" {
  awk '/^handle_exit_trap\(\) \{/,/^}/' "$DVB_GRIND" \
    | grep -q '_pipeline_verify_failed'
  awk '/^handle_exit_trap\(\) \{/,/^}/' "$DVB_GRIND" \
    | grep -q 'exit 1'
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

@test "_pipeline_count_via_api counts completed and waiting-for-merge pipelines only" {
  local harness="$TEST_DIR/count-status-harness.sh"
  local bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<'SCRIPT'
#!/bin/bash
cat <<'JSON'
{"pipelines":[
  {"id":"p1","status":"COMPLETED"},
  {"id":"p2","status":"WAITING_FOR_MERGE"},
  {"id":"p3","status":"FAILED"},
  {"id":"p4","status":"EXECUTING"}
]}
JSON
SCRIPT
  chmod +x "$bin_dir/curl"

  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -euo pipefail
HARNESS
  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_baseline_file=' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^_capture_pipeline_baseline()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"
  echo "_pipeline_count_via_api" >> "$harness"

  run env PATH="$bin_dir:$PATH" /bin/bash "$harness"
  [ "$status" -eq 0 ]
  [[ "$output" == "2" ]]
}

@test "_pipeline_count_via_api uses --max-time 5 (test-friendly timeout)" {
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q -- '--max-time 5'
}

@test "_pipeline_count_via_api sends Authorization header from BOSUN_TOKEN" {
  local harness="$TEST_DIR/auth-harness.sh"
  local bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" > "$TG_CURL_ARGS"
printf '{"pipelines":[{"id":"p1","status":"COMPLETED"},{"id":"p2","status":"WAITING_FOR_MERGE"}]}'
SCRIPT
  chmod +x "$bin_dir/curl"

  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -euo pipefail
HARNESS
  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_baseline_file=' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^_capture_pipeline_baseline()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"
  echo "_pipeline_count_via_api" >> "$harness"

  run env PATH="$bin_dir:$PATH" BOSUN_TOKEN="test-token" TG_CURL_ARGS="$TEST_DIR/curl.args" bash "$harness"
  [ "$status" -eq 0 ]
  [[ "$output" == "2" ]]
  grep -q -- '-H Authorization: Bearer test-token' "$TEST_DIR/curl.args"
}

@test "_pipeline_count_via_api sends Authorization header from auth-token file" {
  local harness="$TEST_DIR/auth-file-harness.sh"
  local bin_dir="$TEST_DIR/bin"
  local home_dir="$TEST_DIR/home"
  mkdir -p "$bin_dir" "$home_dir/.orchestrator"
  printf 'file-token\n' > "$home_dir/.orchestrator/auth-token"
  cat > "$bin_dir/curl" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" > "$TG_CURL_ARGS"
printf '{"pipelines":[{"id":"p1","status":"COMPLETED"}]}'
SCRIPT
  chmod +x "$bin_dir/curl"

  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -euo pipefail
HARNESS
  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_baseline_file=' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^_capture_pipeline_baseline()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"
  echo "_pipeline_count_via_api" >> "$harness"

  run env PATH="$bin_dir:$PATH" HOME="$home_dir" TG_CURL_ARGS="$TEST_DIR/curl-file.args" bash "$harness"
  [ "$status" -eq 0 ]
  [[ "$output" == "1" ]]
  grep -q -- '-H Authorization: Bearer file-token' "$TEST_DIR/curl-file.args"
}

@test "_resolve_bosun_api_auth_args only checks auth-token file when HOME is set" {
  awk '/^_resolve_bosun_api_auth_args\(\) \{/,/^\}/' "$DVB_GRIND" \
    | grep -q '\[\[ -n "${HOME:-}" && -f "$HOME/.orchestrator/auth-token" \]\]'
}

@test "_capture_pipeline_baseline survives curl failure with one numeric fallback" {
  local harness="$TEST_DIR/fallback-harness.sh"
  local bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<'SCRIPT'
#!/bin/bash
exit 22
SCRIPT
  chmod +x "$bin_dir/curl"

  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -euo pipefail
_dvb_tmp="$TG_TEST_TMP"
_lock_hash="fallback"
log_file="$TG_TEST_TMP/fallback.log"
log_write() { echo "$1" >> "$log_file"; }
HARNESS
  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_baseline_file=' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^slot_lock_file()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"
  echo "_capture_pipeline_baseline" >> "$harness"
  echo 'cat "$_pipeline_baseline_file"' >> "$harness"

  run env PATH="$bin_dir:$PATH" TG_TEST_TMP="$TEST_DIR" bash "$harness"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"startCount":0'* ]]
}

@test "_capture_pipeline_baseline tolerates preflight-only before log_write exists" {
  local harness="$TEST_DIR/no-log-harness.sh"
  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -euo pipefail
_dvb_tmp="$TG_TEST_TMP"
_lock_hash="nolog"
HARNESS
  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_baseline_file=' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^slot_lock_file()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"
  cat >> "$harness" <<'HARNESS'
_pipeline_count_via_api() { echo 7; }
_capture_pipeline_baseline
cat "$_pipeline_baseline_file"
HARNESS

  run env TG_TEST_TMP="$TEST_DIR" bash "$harness"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"startCount":7'* ]]
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
  run env \
    TG_TEST_TMP="$TEST_DIR" \
    TG_TEST_REPO="$TEST_DIR" \
    TG_TASKS_SHIPPED=2 \
    TG_API_COUNT=5 \
    bash "$harness"

  [ "$status" -eq 1 ]
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

@test "direct non-markdown commit without Bosun provenance fails even when pipeline delta exists" {
  local repo="$TEST_DIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "Taskgrind Test"
  git -C "$repo" config user.email "taskgrind@example.com"
  printf '# Tasks\n\n## P0\n' > "$repo/TASKS.md"
  git -C "$repo" add TASKS.md
  git -C "$repo" commit --quiet -m "chore: initial"

  local harness="$TEST_DIR/direct-bypass-harness.sh"
  cat > "$harness" <<'HARNESS'
#!/bin/bash
set -uo pipefail
_dvb_tmp="$TG_TEST_TMP"
_lock_hash="direct-bypass"
start_epoch=$(date +%s)
session=1
skill="fleet-grind"
repo="$TG_TEST_REPO"
log_file="$TG_TEST_TMP/direct-bypass.log"
tasks_shipped=1
log_write() { echo "$1" >> "$log_file"; }
_skill_needs_bosun() { return 0; }
HARNESS

  local helpers_start helpers_end
  helpers_start=$(grep -n '^_pipeline_baseline_file=' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$(grep -n '^slot_lock_file()' "$DVB_GRIND" | head -1 | cut -d: -f1)
  helpers_end=$((helpers_end - 1))
  sed -n "${helpers_start},${helpers_end}p" "$DVB_GRIND" >> "$harness"

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
    echo 6
  fi
}
_capture_pipeline_baseline
future=$((start_epoch + 2))
printf 'console.log("direct");\n' > "$repo/direct.js"
git -C "$repo" add direct.js
GIT_AUTHOR_DATE="@$future" GIT_COMMITTER_DATE="@$future" git -C "$repo" commit --quiet -m "fix: direct code"
_verify_pipeline_completion_rate
HARNESS

  run env TG_TEST_TMP="$TEST_DIR" TG_TEST_REPO="$repo" bash "$harness"
  [ "$status" -eq 1 ]
  grep -q 'pipeline_verify DIRECT_CODE_BYPASS' "$TEST_DIR/direct-bypass.log"
  grep -q 'direct.js' "$TEST_DIR/direct-bypass.log"
  ! grep -q 'pipeline_verify ANOMALY tasks_shipped=1 pipeline_delta=0' "$TEST_DIR/direct-bypass.log"
}

# ── Auth failure detection tests ─────────────────────────────────────────────────

@test "_pipeline_count_via_api has auth failure detection code" {
  # Verify that the auth failure detection logic exists in the function
  # This is a structural test to ensure the robustness enhancement is present

  # Check that the function contains auth failure detection logic
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" | grep -q 'AUTH_FAILURE'
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" | grep -q 'Authentication\|Unauthorized\|401'
  awk '/^_pipeline_count_via_api\(\) \{/,/^\}/' "$DVB_GRIND" | grep -q 'curl_exit_code'
}
