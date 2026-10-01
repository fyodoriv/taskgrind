#!/usr/bin/env bats
# Tests for Bosun 410 EXIT_NOW handling.
#
# Source: bosun-410-honor-exit-now task. After Bosun PR #1581 the
# heartbeat endpoint returns HTTP 410 aggressively whenever the session
# is no longer in active/paused. Taskgrind's CLI prints `EXIT_NOW` to
# stderr on 410 and exits 1. Before this fix the heartbeat loop just
# logged the failure and kept spawning sessions, which is the exact
# leak path the bypass investigation tracked.

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# Build a fake `bosun` CLI whose first `grind heartbeat` call prints
# `EXIT_NOW` on stderr and exits 1 — matching the real CLI's behavior
# when the API returns HTTP 410. `grind register` returns a stable
# session ID; `grind done` records the call and succeeds so the
# deregister path can be asserted.
_make_fake_bosun_410_on_first_heartbeat() {
  local invocations="$1"
  local bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/bosun" <<SCRIPT
#!/bin/bash
printf '%s\n' "\$*" >> "$invocations"
case "\$1\$2" in
  grindregister)
    sid="fake-410-session"
    mkdir -p "\$HOME/.orchestrator"
    cat > "\$HOME/.orchestrator/grind-session-\$sid.env" <<ENV
export BOSUN_GRIND_SESSION_ID="\$sid"
export BOSUN_GRIND_PROJECT_ID="$TEST_REPO"
export BOSUN_API_BASE="http://localhost:9746"
export BOSUN_URL="http://localhost:9746"
ENV
    echo "\$sid"
    exit 0
    ;;
  grindheartbeat)
    # Mirror the real CLI: write EXIT_NOW to stderr and exit 1
    echo "EXIT_NOW" >&2
    exit 1
    ;;
  grinddone)
    exit 0
    ;;
esac
exit 0
SCRIPT
  chmod +x "$bin_dir/bosun"
  echo "$bin_dir/bosun"
}

@test "bosun 410: EXIT_NOW terminates the grind within TG_BOSUN_410_GRACE" {
  local invocations="$TEST_DIR/bosun-invocations.log"
  : > "$invocations"
  local bosun_bin
  bosun_bin=$(_make_fake_bosun_410_on_first_heartbeat "$invocations")

  # Cooperative fake devin — sleeps long enough for a heartbeat to
  # fire, responds to SIGINT cleanly. The test bounds elapsed time at
  # cap+grace+jitter, so a slow backend here would still succeed if
  # SIGINT works; the non-cooperative case lives in a separate test.
  local fake_devin="$TEST_DIR/fake-devin-slow"
  cat > "$fake_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
trap 'exit 0' INT
sleep 30
SCRIPT
  chmod +x "$fake_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] 410 EXIT_NOW termination test
TASKS

  export DVB_GRIND_CMD="$fake_devin"
  export DVB_GRIND_INVOKE_LOG="$TEST_DIR/invocations.log"
  export DVB_BOSUN_HEARTBEAT_TEST=1
  export DVB_REGISTER_REAL_BOSUN_GRIND=1
  export TG_BOSUN_HEARTBEAT_INTERVAL=1
  export TG_BOSUN_410_GRACE=2
  export BOSUN_BIN="$bosun_bin"
  export DVB_DEADLINE_OFFSET=60
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=1
  export DVB_SYNC_INTERVAL=999
  export DVB_EMPTY_QUEUE_WAIT=0
  export DVB_SKIP_SWEEP_ON_EMPTY=1

  local start_epoch end_epoch elapsed
  start_epoch=$(date +%s)
  run "$DVB_GRIND" --skill fleet-grind 1 "$TEST_REPO"
  end_epoch=$(date +%s)
  elapsed=$(( end_epoch - start_epoch ))

  # Grind exited via SIGTERM (143) because the heartbeat loop forwarded
  # it to the parent after detecting EXIT_NOW.
  [ "$status" -eq 143 ]

  # The grind must finish within TG_BOSUN_410_GRACE + jitter, not within
  # the 60s deadline. Allow 20s of scheduling/teardown slack.
  [ "$elapsed" -le 20 ]

  # New log markers fire on the 410 path.
  grep -q 'bosun_heartbeat_410' "$TEST_LOG"
  grep -q 'graceful_shutdown trigger=bosun-410-exit-now' "$TEST_LOG"
}

@test "bosun 410: grind_done records terminal_reason=bosun-410-exit-now" {
  local invocations="$TEST_DIR/bosun-invocations.log"
  : > "$invocations"
  local bosun_bin
  bosun_bin=$(_make_fake_bosun_410_on_first_heartbeat "$invocations")

  local fake_devin="$TEST_DIR/fake-devin-cooperative"
  cat > "$fake_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
trap 'exit 0' INT
sleep 30
SCRIPT
  chmod +x "$fake_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] terminal_reason assertion
TASKS

  export DVB_GRIND_CMD="$fake_devin"
  export DVB_GRIND_INVOKE_LOG="$TEST_DIR/invocations.log"
  export DVB_BOSUN_HEARTBEAT_TEST=1
  export DVB_REGISTER_REAL_BOSUN_GRIND=1
  export TG_BOSUN_HEARTBEAT_INTERVAL=1
  export TG_BOSUN_410_GRACE=2
  export BOSUN_BIN="$bosun_bin"
  export DVB_DEADLINE_OFFSET=60
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=1
  export DVB_SYNC_INTERVAL=999
  export DVB_EMPTY_QUEUE_WAIT=0
  export DVB_SKIP_SWEEP_ON_EMPTY=1

  run "$DVB_GRIND" --skill fleet-grind 1 "$TEST_REPO"
  [ "$status" -eq 143 ]

  # grind_done line must carry terminal_reason=bosun-410-exit-now so
  # post-mortems and dashboards can filter by cause.
  grep -qE 'grind_done .*terminal_reason=bosun-410-exit-now' "$TEST_LOG"
}

@test "bosun 410: no new session is spawned after EXIT_NOW (session count stable)" {
  local invocations="$TEST_DIR/bosun-invocations.log"
  : > "$invocations"
  local bosun_bin
  bosun_bin=$(_make_fake_bosun_410_on_first_heartbeat "$invocations")

  local fake_devin="$TEST_DIR/fake-devin-stub"
  cat > "$fake_devin" <<SCRIPT
#!/bin/bash
# Count invocations so we can assert the second session never runs.
echo "\$@" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
# Cooperative — exits on SIGINT quickly so the 410 grace window is
# not dominated by a slow backend.
trap 'exit 0' INT
sleep 30
SCRIPT
  chmod +x "$fake_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] no-spawn-after-410 test
- [ ] second task should NOT be picked up
TASKS

  export DVB_GRIND_CMD="$fake_devin"
  export DVB_GRIND_INVOKE_LOG="$TEST_DIR/invocations.log"
  export DVB_BOSUN_HEARTBEAT_TEST=1
  export DVB_REGISTER_REAL_BOSUN_GRIND=1
  export TG_BOSUN_HEARTBEAT_INTERVAL=1
  export TG_BOSUN_410_GRACE=2
  export BOSUN_BIN="$bosun_bin"
  export DVB_DEADLINE_OFFSET=60
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=10
  export DVB_SYNC_INTERVAL=999
  export DVB_EMPTY_QUEUE_WAIT=0
  export DVB_SKIP_SWEEP_ON_EMPTY=1

  run "$DVB_GRIND" --skill fleet-grind 1 "$TEST_REPO"

  # Exactly one backend invocation — the second session never runs.
  local invocation_count=0
  if [ -f "$TEST_DIR/invocations.log" ]; then
    invocation_count=$(wc -l < "$TEST_DIR/invocations.log" | tr -d ' ')
  fi
  [ "$invocation_count" -eq 1 ]

  # Log confirms no session=2 ever started
  ! grep -q 'session=2' "$TEST_LOG"
}

@test "bosun 410: TG_BOSUN_410_GRACE default is 30 seconds" {
  # Structural test — the constant drives the default. No full-grind
  # run needed; asserting the default keeps the escape-hatch visible
  # in lib/constants.sh so the contract is hard to break silently.
  local constants_file
  constants_file="$BATS_TEST_DIRNAME/../lib/constants.sh"
  grep -Fq 'DVB_DEFAULT_BOSUN_410_GRACE="30"' "$constants_file"
}

@test "bosun 410: heartbeat_410 log line names the exit grace" {
  # Regression for log-mining: the bosun_heartbeat_410 marker needs the
  # grace window in its kv pairs so a post-mortem can tell whether
  # TG_BOSUN_410_GRACE was overridden or using the default.
  local invocations="$TEST_DIR/bosun-invocations.log"
  : > "$invocations"
  local bosun_bin
  bosun_bin=$(_make_fake_bosun_410_on_first_heartbeat "$invocations")

  local fake_devin="$TEST_DIR/fake-devin-cooperative"
  cat > "$fake_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
trap 'exit 0' INT
sleep 30
SCRIPT
  chmod +x "$fake_devin"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] log-marker test
TASKS

  export DVB_GRIND_CMD="$fake_devin"
  export DVB_GRIND_INVOKE_LOG="$TEST_DIR/invocations.log"
  export DVB_BOSUN_HEARTBEAT_TEST=1
  export DVB_REGISTER_REAL_BOSUN_GRIND=1
  export TG_BOSUN_HEARTBEAT_INTERVAL=1
  export TG_BOSUN_410_GRACE=7
  export BOSUN_BIN="$bosun_bin"
  export DVB_DEADLINE_OFFSET=30
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=1
  export DVB_SYNC_INTERVAL=999
  export DVB_EMPTY_QUEUE_WAIT=0
  export DVB_SKIP_SWEEP_ON_EMPTY=1

  run "$DVB_GRIND" --skill fleet-grind 1 "$TEST_REPO"
  [ "$status" -eq 143 ]

  grep -qE 'bosun_heartbeat_410 session=.* action=exit_requested grace=7s' "$TEST_LOG"
}

@test "bosun: non-410 heartbeat failures still don't terminate the grind" {
  # Regression: the 410 detection must not swallow unrelated failure
  # output. The existing session.bats coverage of 5xx-style failures
  # runs the full grind through — this narrower test just asserts the
  # heartbeat subshell does not write the 410 flag file when the
  # error is not EXIT_NOW, so the new logic doesn't accidentally
  # convert transient failures into mandatory exits.
  local invocations="$TEST_DIR/bosun-invocations.log"
  : > "$invocations"
  local bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/bosun" <<SCRIPT
#!/bin/bash
printf '%s\n' "\$*" >> "$invocations"
case "\$1\$2" in
  grindregister)
    sid="transient-fail-session"
    mkdir -p "\$HOME/.orchestrator"
    cat > "\$HOME/.orchestrator/grind-session-\$sid.env" <<ENV
export BOSUN_GRIND_SESSION_ID="\$sid"
export BOSUN_GRIND_PROJECT_ID="$TEST_REPO"
export BOSUN_API_BASE="http://localhost:9746"
export BOSUN_URL="http://localhost:9746"
ENV
    echo "\$sid"
    exit 0
    ;;
  grindheartbeat)
    # 5xx-style failure — plain error text, no EXIT_NOW marker
    echo "API error 503: backend temporarily unavailable" >&2
    exit 1
    ;;
  grinddone)
    exit 0
    ;;
esac
exit 0
SCRIPT
  chmod +x "$bin_dir/bosun"

  cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] transient-fail test
TASKS

  local fake_devin="$TEST_DIR/fake-devin-quick"
  cat > "$fake_devin" <<SCRIPT
#!/bin/bash
echo "\$@" >> "\${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
sleep 2
cat > "$TEST_REPO/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
SCRIPT
  chmod +x "$fake_devin"

  export DVB_GRIND_CMD="$fake_devin"
  export DVB_GRIND_INVOKE_LOG="$TEST_DIR/invocations.log"
  export DVB_BOSUN_HEARTBEAT_TEST=1
  export DVB_REGISTER_REAL_BOSUN_GRIND=1
  export TG_BOSUN_HEARTBEAT_INTERVAL=1
  export TG_BOSUN_410_GRACE=2
  export BOSUN_BIN="$bin_dir/bosun"
  export DVB_DEADLINE_OFFSET=8
  export DVB_COOL=0
  export DVB_MAX_ZERO_SHIP=1
  export DVB_SYNC_INTERVAL=999
  export DVB_EMPTY_QUEUE_WAIT=0
  export DVB_SKIP_SWEEP_ON_EMPTY=1

  run "$DVB_GRIND" --skill fleet-grind 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  # Transient failures still show up in the log…
  grep -q 'bosun_heartbeat_failed' "$TEST_LOG"

  # …but none of the 410-specific markers fire.
  ! grep -q 'bosun_heartbeat_410' "$TEST_LOG"
  ! grep -q 'graceful_shutdown trigger=bosun-410-exit-now' "$TEST_LOG"
}
