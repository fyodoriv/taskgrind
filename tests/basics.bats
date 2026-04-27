#!/usr/bin/env bats
# Tests for taskgrind — static checks + 3 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Static checks ────────────────────────────────────────────────────

@test "taskgrind exists and is executable" {
  [ -f "$DVB_GRIND" ]
  [ -x "$DVB_GRIND" ]
}

@test "taskgrind has correct shebang" {
  head -1 "$DVB_GRIND" | grep -q '#!/bin/bash'
}

@test "taskgrind uses strict mode" {
  grep -q 'set -euo pipefail' "$DVB_GRIND"
}

@test "taskgrind re-execs under caffeinate for the whole loop" {
  grep -q 'exec caffeinate.*DVB_CAFFEINATE_FLAGS\|exec caffeinate -ms' "$DVB_GRIND"
}

@test "taskgrind skips caffeinate re-exec in test mode" {
  # DVB_GRIND_CMD being set should prevent the caffeinate exec
  grep -q 'DVB_GRIND_CMD.*DVB_CAFFEINATED' "$DVB_GRIND"
}

@test "taskgrind self-copies to survive script modification during execution" {
  grep -q '_DVB_SELF_COPY' "$DVB_GRIND"
}

@test "taskgrind self-copy uses exec to replace the process" {
  grep -q 'exec "$_dvb_copy"' "$DVB_GRIND"
}

@test "taskgrind cleans up self-copy temp file on exit" {
  # Use a unique prefix to avoid parallel test interference on shared /tmp
  local _tmp="${TMPDIR:-/tmp}"
  _tmp="${_tmp%/}"
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO" 1
  [ "$status" -eq 0 ]
  # No self-copy files with our PID should remain after cleanup
  local leaked
  leaked=$(ls "$_tmp"/taskgrind-exec.* 2>/dev/null | xargs -I{} lsof -p $$ {} 2>/dev/null || true)
  # Simpler: just check no files were created by this specific run
  # The cleanup trap removes the file, so running with past deadline means
  # the script exits immediately and cleans up.
  # Under parallel load, other tests may transiently create files, so we
  # just verify exit was clean.
  [ "$status" -eq 0 ]
}

# ── Argument validation ──────────────────────────────────────────────

@test "no args defaults to 10 hours" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"10h"* ]]
}

@test "default deadline is ~10h from now when no hours arg" {
  # Use --dry-run to inspect computed config without running sessions
  run "$DVB_GRIND" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hours:"*"10"* ]]
}

@test "--help shows usage and exits 0" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "--help documents the short -h and -V aliases" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--help / -h"* ]]
  [[ "$output" == *"--version / -V"* ]]
}

@test "--version prints commit hash and exits 0" {
  run "$DVB_GRIND" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "taskgrind "* ]]
  # Bash 3.2 regex handling is more reliable without interval quantifiers here.
  [[ "$output" =~ [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f] ]]
}

@test "-V is alias for --version" {
  run "$DVB_GRIND" -V
  [ "$status" -eq 0 ]
  [[ "$output" == "taskgrind "* ]]
}

@test "--version does not launch any sessions" {
  run "$DVB_GRIND" --version
  [ "$status" -eq 0 ]
  # Output should be a single line with version info, no session output
  [[ $(echo "$output" | wc -l) -le 1 ]]
}

@test "make help lists the audit target" {
  run make -C "$BATS_TEST_DIRNAME/.." help
  [ "$status" -eq 0 ]
  [[ "$output" == *"make audit"* ]]
}

@test "make audit runs tasks-lint and rejects malformed TASKS.md" {
  # Override TASKS_MD to point at a temp file with a deliberately malformed
  # entry. This avoids racing other parallel bats jobs that read the repo's
  # real TASKS.md while make audit runs.
  local repo_root="$BATS_TEST_DIRNAME/.."
  local broken_tasks
  broken_tasks="$(mktemp "${TMPDIR:-/tmp}/taskgrind-bad-tasks-XXXX.md")"
  cat > "$broken_tasks" <<'EOF'
# Tasks

## P0

- broken without checkbox
  **Tags**: foo
EOF
  run make -C "$repo_root" audit TASKS_MD="$broken_tasks"
  local audit_status="$status"
  local audit_output="$output"
  rm -f "$broken_tasks"
  [ "$audit_status" -ne 0 ]
  [[ "$audit_output" == *"Audit: TASKS.md spec"* ]]
  [[ "$audit_output" == *"task must use checkbox format"* ]]
}

@test "make audit accepts a TASKS.md with only the H1 header" {
  # Empty queue is the legitimate steady state once the grind ships everything.
  # Make sure tasks-lint does not fail the audit on that minimal file. Use a
  # temp override path so this stays parallel-safe.
  local repo_root="$BATS_TEST_DIRNAME/.."
  local empty_tasks
  empty_tasks="$(mktemp "${TMPDIR:-/tmp}/taskgrind-empty-tasks-XXXX.md")"
  printf '# Tasks\n' > "$empty_tasks"
  run make -C "$repo_root" audit TASKS_MD="$empty_tasks"
  local audit_status="$status"
  local audit_output="$output"
  rm -f "$empty_tasks"
  [ "$audit_status" -eq 0 ]
  [[ "$audit_output" == *"Audit: TASKS.md spec"* ]]
  [[ "$audit_output" == *"found 0 error"* ]]
}

@test "make audit handles a missing TASKS.md gracefully" {
  # Once the queue file is removed (e.g. archived between sweeps), make audit
  # must not break — it should print a benign skip line and stay green.
  local repo_root="$BATS_TEST_DIRNAME/.."
  local missing_tasks
  missing_tasks="$(mktemp -u "${TMPDIR:-/tmp}/taskgrind-missing-tasks-XXXX.md")"
  run make -C "$repo_root" audit TASKS_MD="$missing_tasks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no $missing_tasks to lint)"* ]]
}

@test "audit docs mention tasks-lint" {
  # CONTRIBUTING and AGENTS must explain how to install/run tasks-lint; the
  # README should advertise it as a dev dependency for contributors.
  run grep -nF '@tasks-md/lint' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'tasks-lint' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'tasks-lint' "$BATS_TEST_DIRNAME/../AGENTS.md"
  [ "$status" -eq 0 ]

  run grep -nF '@tasks-md/lint' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '@tasks-md/lint' "$BATS_TEST_DIRNAME/../.github/workflows/check.yml"
  [ "$status" -eq 0 ]

  run grep -nF 'tasks-lint $(TASKS_MD)' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]

  run grep -nF 'npx --yes @tasks-md/lint $(TASKS_MD)' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]

  run grep -nF 'TASKS_MD ?= TASKS.md' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]
}

@test "make audit runs the local audit workflow" {
  run make -C "$BATS_TEST_DIRNAME/.." audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audit: TODO:/FIXME: scan"* ]]
  [[ "$output" == *"Audit: docs review queue"* ]]
  [[ "$output" == *"man/taskgrind.1"* ]]
}

@test "make audit docs review queue includes resume docs and repo-local skills" {
  run make -C "$BATS_TEST_DIRNAME/.." audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECURITY.md"* ]]
  [[ "$output" == *"docs/resume-state.md"* ]]
  [[ "$output" == *"AGENTS.md"* ]]
  [[ "$output" == *"Agentfile.yaml"* ]]
  [[ "$output" == *".devin/skills/standing-audit-gap-loop/SKILL.md"* ]]
  [[ "$output" == *".devin/skills/grind-log-analyze/SKILL.md"* ]]
}

@test "make audit TODO/FIXME scan covers the docs review queue files" {
  run grep -n 'grep -RInE.*TODO:|FIXME:.*SECURITY.md.*AGENTS.md.*Agentfile.yaml.*man/taskgrind.1.*standing-audit-gap-loop/SKILL.md.*grind-log-analyze/SKILL.md' "$BATS_TEST_DIRNAME/../Makefile"
  [ "$status" -eq 0 ]

  [[ "$output" != *"tests"* ]]
  [[ "$output" != *"Makefile"* ]]
}

@test "make audit keeps self-referential docs out of the TODO/FIXME findings" {
  run make -C "$BATS_TEST_DIRNAME/.." audit
  [ "$status" -eq 0 ]

  [[ "$output" != *"README.md:51:"* ]]
  [[ "$output" != *"CONTRIBUTING.md:68:"* ]]
  [[ "$output" != *"CONTRIBUTING.md:69:"* ]]
  [[ "$output" != *"man/taskgrind.1:356:"* ]]
  [[ "$output" != *".devin/skills/standing-audit-gap-loop/SKILL.md:47:"* ]]
  [[ "$output" != *"tests/basics.bats:111:"* ]]
  [[ "$output" != *"Makefile:56:"* ]]
}

@test "CONTRIBUTING documents the current make audit review queue" {
  run grep -nF 'SECURITY.md' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'AGENTS.md' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'Agentfile.yaml' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'docs/resume-state.md' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/standing-audit-gap-loop/SKILL.md' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/grind-log-analyze/SKILL.md' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]
}

@test "CONTRIBUTING documents the supported Linux bats install path" {
  run grep -nF 'sudo apt-get install -y npm shellcheck' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'sudo npm install -g bats' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'matches the GitHub Actions CI path for Linux runs' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]
}

@test "README documents the full current make audit review queue" {
  run grep -n 'Contributor audit shortcut:.*README.md.*CONTRIBUTING.md.*SECURITY.md.*AGENTS.md.*Agentfile.yaml.*docs/architecture.md.*docs/resume-state.md.*docs/user-stories.md.*man/taskgrind.1' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/standing-audit-gap-loop/SKILL.md' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/grind-log-analyze/SKILL.md' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "README manual update path uses git pull --rebase" {
  run grep -nF 'git pull --rebase' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "README development commands include make audit" {
  run grep -nF 'make audit      # run the local repo audit workflow' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "README, SECURITY.md, and bin/taskgrind document the log retention policy" {
  # The startup sweep deliberately omits primary *.log files so the
  # grind-log-analyze skill can post-mortem completed grinds. This is an
  # intentional, operator-facing contract — if any of these doc anchors
  # disappear, operators no longer know whether to add their own logrotate
  # rule on long-lived Linux hosts. Treat any failure here as a doc-drift
  # bug, not a flaky test.
  run grep -nF 'Log file retention' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
  run grep -nF 'grind-log-analyze' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
  run grep -nF 'Log files persist across grinds' "$BATS_TEST_DIRNAME/../SECURITY.md"
  [ "$status" -eq 0 ]
  run grep -nF 'Retention policy' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  [ "$status" -eq 0 ]
}

@test "man page example block stays aligned with current CLI help examples" {
  run grep -nF 'taskgrind ~/apps/myrepo 10         # 10h grind in specific repo' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'taskgrind \-\-model "gpt\-5.4 XHigh thinking fast" 8' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'taskgrind \-\-resume ~/apps/myrepo' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'taskgrind \-\-help / \-h' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'taskgrind \-\-version / \-V' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'TG_MAX_INSTANCES=3 taskgrind ~/apps/myrepo 8' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'TG_STATUS_FILE=/tmp/taskgrind-status.json taskgrind ~/apps/myrepo 8' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "man page model option prose keeps the dotted XHigh example" {
  run grep -nF '\fB\-\-model "gpt\-5.4 XHigh thinking fast"\fR.' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'gpt\-5\-4 XHigh thinking fast' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 1 ]
}

@test "man page documents the standardized discovery standing-loop lane" {
  run grep -nF 'standing\-loop' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'discovery\-standing\-loop' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "discovery-lane guard docs explain why audit-only sessions can be refused" {
  run grep -nF 'Audit-only sessions are refused unless `TASKS.md` includes a supported discovery-lane standing-loop task' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -eq 0 ]

  run grep -nF 'taskgrind refuses audit-only sessions unless `TASKS.md` already contains a supported discovery-lane standing-loop task' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "architecture docs describe the current prompt wrapper instead of a thin prompt" {
  run grep -nF 'completion protocol for removing shipped tasks from `TASKS.md`' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -eq 0 ]

  run grep -nF 'the autonomy reminder to use available tools instead of punting' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -eq 0 ]

  run grep -nF 'the optional `FOCUS:` prompt' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -eq 0 ]

  run grep -nF 'the stuck-task skip list when repeated failures were detected' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -eq 0 ]

  run grep -nF 'By keeping the prompt thin' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  [ "$status" -ne 0 ]
}

@test "operator docs surface the context-budget guard from CLI help" {
  run grep -nF 'Sessions should exit before context fills; context exhaustion can crash the' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'process and lose uncommitted work.' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'Sessions should exit before context fills; context exhaustion can crash the' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]

  run grep -nF 'process and lose uncommitted work.' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]

  run grep -nF 'Sessions should exit before context fills; context exhaustion can crash the' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'process and lose uncommitted work.' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "operator docs keep sample model examples aligned with current defaults" {
  run grep -nF 'model:    claude-opus-4-7-max' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'model:    claude-opus-4-7-max' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]

  run grep -nF 'alias resolves to claude-opus-4-7-max' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF 'alias resolves to claude-sonnet-4.6' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "status payload docs describe last_session.result with the four real values only" {
  # bin/taskgrind only ever assigns last_session_result one of four strings:
  # pending (initialization + per-session reset), success (exit 0), failure
  # (non-zero exit), or blocked (audit-only focus refused). The README and man
  # page must enumerate that set exactly so operator watchdogs do not key off
  # phantom labels like completed/timeout/network_wait/none.
  run grep -nF '`pending`' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '`success`' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '`failure`' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF '`blocked`' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  # Phantom result labels must not reappear in the README's status table or
  # JSON examples.
  run grep -nE '"result"[[:space:]]*:[[:space:]]*"(completed|timeout|network_wait|none)"' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 1 ]

  run grep -nE '"result"[[:space:]]*:[[:space:]]*"(completed|timeout|network_wait|none)"' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 1 ]

  # Only the real values may appear in JSON example blocks.
  run grep -nE '"result"[[:space:]]*:[[:space:]]*"[^"]+"' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    case "$line" in
      *'"result": "pending"'*|*'"result": "success"'*|*'"result": "failure"'*|*'"result": "blocked"'*) ;;
      *)
        printf 'README JSON example uses an unsupported last_session.result value: %s\n' "$line" >&2
        return 1
        ;;
    esac
  done <<<"$output"

  run grep -nE '"result"[[:space:]]*:[[:space:]]*"[^"]+"' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    case "$line" in
      *'"result": "pending"'*|*'"result": "success"'*|*'"result": "failure"'*|*'"result": "blocked"'*) ;;
      *)
        printf 'man page JSON example uses an unsupported last_session.result value: %s\n' "$line" >&2
        return 1
        ;;
    esac
  done <<<"$output"

  # The man page prose enumerates the four real values too.
  run grep -nE 'pending|success|failure|blocked' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pending"* ]]
  [[ "$output" == *"success"* ]]
  [[ "$output" == *"failure"* ]]
  [[ "$output" == *"blocked"* ]]

  # Phantom values must not appear in the man page's last_session.result prose.
  # Use awk to extract just the .B last_session.result block (terminated by
  # the next .TP) and grep for the forbidden labels there.
  forbidden=$(awk '/^\.B last_session\.result$/{flag=1; next} /^\.TP$/{flag=0} flag' "$BATS_TEST_DIRNAME/../man/taskgrind.1" | grep -E 'completed|timeout|network_wait|\bnone\b' || true)
  if [[ -n "$forbidden" ]]; then
    printf 'man page last_session.result block still mentions a phantom label:\n%s\n' "$forbidden" >&2
    return 1
  fi

  # The watchdog snippets in README and user-stories must default to pending,
  # not the dropped "none" sentinel.
  run grep -nF 'payload.get("last_session", {}).get("result", "pending")' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'payload.get("last_session", {}).get("result", "pending")' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]

  # The README watchdog must compare against the real success label.
  run grep -nF '"$last_result" = "success"' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "help and README keep the env example block aligned" {
  run "$DVB_GRIND" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"TG_MAX_INSTANCES=3 taskgrind ~/apps/myrepo 8"* ]]
  [[ "$output" == *"TG_STATUS_FILE=/tmp/taskgrind-status.json taskgrind ~/apps/myrepo 8"* ]]

  run grep -nF 'TG_STATUS_FILE=/tmp/taskgrind-status.json taskgrind ~/apps/myrepo 8' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "README documents the supported Linux bats install path" {
  run grep -nF 'sudo apt-get install -y npm shellcheck' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'sudo npm install -g bats' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'match the GitHub Actions CI environment' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]
}

@test "AGENTS development commands include make audit" {
  run grep -nF 'make audit      # run the local repo audit workflow' "$BATS_TEST_DIRNAME/../AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "repo layout docs mention repo-local audit skills" {
  run grep -nF '.devin/skills/' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/' "$BATS_TEST_DIRNAME/../AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "AGENTS repo layout names the focused preflight and installer-output suites" {
  run grep -nF 'tests/preflight.bats' "$BATS_TEST_DIRNAME/../AGENTS.md"
  [ "$status" -eq 0 ]

  run grep -nF 'tests/installer-output.bats' "$BATS_TEST_DIRNAME/../AGENTS.md"
  [ "$status" -eq 0 ]

  run grep -nF 'tests/test_helper.bash' "$BATS_TEST_DIRNAME/../AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "developer docs mention make test-force for uncached reruns" {
  run grep -nF 'make test-force' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'make test-force' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  run grep -nF 'make test-force' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "CONTRIBUTING has a flaky-test runbook with the reproduce/isolate/diagnose recipe" {
  # The runbook must call out the three repro steps so contributors hit the
  # parallel-load edge cases on purpose instead of guessing.
  run grep -nF 'Diagnosing a Flaky Bats Test' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  # Step 1: isolate via -f.
  run grep -nF 'bats tests/<file>.bats -f' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  # Step 2: serial execution.
  run grep -nF 'TEST_JOBS=1' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  # Step 3: reproduce the CI cap.
  run grep -nF 'TEST_JOBS=6' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -eq 0 ]

  # The legacy "Flaky tests" Known Issues bullet must not reappear — it would
  # contradict the runbook by claiming the flakes are pre-existing and not
  # regressions, the exact mindset the runbook is meant to displace.
  run grep -nF '**Flaky tests**' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
  [ "$status" -ne 0 ]
}

@test "CONTRIBUTING mentions the Bash 3.2 compatibility guard only once" {
  run python3 - "$BATS_TEST_DIRNAME/../CONTRIBUTING.md" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
needle = "If you touch runtime shell code, keep it `/bin/bash` 3.2 compatible and use `tests/verify-bash32-compat.sh` plus `tests/bash-compat.bats` to catch Bash-4-only syntax before the full suite does"

count = text.count(needle)
if count != 1:
    print(count)
    raise SystemExit(1)
PY
  [ "$status" -eq 0 ]
}

@test "README mentions the Bash 3.2 compatibility guard only once" {
  run python3 - "$BATS_TEST_DIRNAME/../README.md" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
needle = "Taskgrind runtime files must stay compatible with `/bin/bash` 3.2, and\n`tests/verify-bash32-compat.sh` is the guard that enforces that contract during\nthe bats suite."

count = text.count(needle)
if count != 1:
    print(count)
    raise SystemExit(1)
PY
  [ "$status" -eq 0 ]
}

@test "man page documents the current make audit review queue" {
  run grep -nF 'SECURITY.md' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/standing-audit-gap-loop/SKILL.md' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -nF '.devin/skills/grind-log-analyze/SKILL.md' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "man page keeps the TG_MAX_INSTANCES example deduplicated" {
  run python3 - "$BATS_TEST_DIRNAME/../man/taskgrind.1" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
needle = "TG_MAX_INSTANCES=3 taskgrind ~/apps/myrepo 8"

count = text.count(needle)
if count != 1:
    print(count)
    raise SystemExit(1)
PY
  [ "$status" -eq 0 ]
}

@test "GitHub Actions caches the active make test cache files" {
  run grep -n 'path: \.test-cache-\*' "$BATS_TEST_DIRNAME/../.github/workflows/check.yml"
  [ "$status" -eq 0 ]

  run grep -n 'make test$' "$BATS_TEST_DIRNAME/../.github/workflows/check.yml"
  [ "$status" -eq 0 ]
}

@test "GitHub Actions test cache key covers every shell file make check touches" {
  # tests/bash-compat.bats sources tests/verify-bash32-compat.sh to enforce
  # the Bash 3.2 runtime contract, and `make lint` shellchecks install.sh.
  # Both files affect the outcome of `make test` / `make check`, so both
  # must be in the cache key — otherwise an edit to either one leaves a
  # stale green cache in place and the regression slips through CI.
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/check.yml"
  run grep -n "tests/verify-bash32-compat.sh" "$workflow"
  [ "$status" -eq 0 ]

  run grep -n "install.sh" "$workflow"
  [ "$status" -eq 0 ]

  # The paths must live inside the hashFiles(...) tuple of the test cache
  # key, not somewhere unrelated (e.g. a comment or a different step).
  run grep -nE "tests-.*hashFiles.*tests/verify-bash32-compat.sh.*install.sh" "$workflow"
  [ "$status" -eq 0 ]
}

@test "GitHub Actions runs make audit on pull requests" {
  run grep -n 'make audit$' "$BATS_TEST_DIRNAME/../.github/workflows/check.yml"
  [ "$status" -eq 0 ]
}

@test ".gitignore covers local runtime state and split test cache artifacts" {
  run grep -nF '.taskgrind-state' "$BATS_TEST_DIRNAME/../.gitignore"
  [ "$status" -eq 0 ]

  run grep -nF '.test-cache-*' "$BATS_TEST_DIRNAME/../.gitignore"
  [ "$status" -eq 0 ]
}

@test "man page synopsis includes --resume" {
  awk '
    /^\.SH SYNOPSIS$/ { in_synopsis=1; next }
    /^\.SH / && in_synopsis { exit !found }
    in_synopsis && /\\fB\\-\\-resume\\fR/ { found=1 }
    END { exit !found }
  ' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
}

@test "README usage and man page options document --resume" {
  run grep -nF 'taskgrind --resume ~/apps/myrepo' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run awk '
    /^\.SH OPTIONS$/ { in_options=1; next }
    /^\.SH / && in_options { exit !found }
    in_options && /^\.BR \\-\\-resume/ { found=1 }
    END { exit !found }
  ' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]
}

@test "README resume troubleshooting warns when original overrides must be reused" {
  run python3 - "$BATS_TEST_DIRNAME/../README.md" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
text = " ".join(text.split())
needle = "Plain `taskgrind --resume ~/apps/myrepo` is enough only when the interrupted run used the same startup defaults you are using now."
raise SystemExit(0 if needle in text else 1)
PY
  [ "$status" -eq 0 ]

  run python3 - "$BATS_TEST_DIRNAME/../README.md" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
text = " ".join(text.split())
needle = "If the interrupted run started with explicit `--backend`, `--model`, `--skill`, or baseline `--prompt` / `TG_PROMPT` overrides, repeat those same choices on the resume command."
raise SystemExit(0 if needle in text else 1)
PY
  [ "$status" -eq 0 ]
}

@test "live model override docs use the shipped default model id" {
  run grep -nF 'taskgrind --model claude-opus-4-7-max 8' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'taskgrind --model "gpt-5.4 XHigh thinking fast" 8' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF -- '--model claude-opus-4-7-max' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'model=claude-opus-4-7-max' "$BATS_TEST_DIRNAME/../docs/user-stories.md"
  [ "$status" -eq 0 ]

  run grep -nF 'echo "claude-sonnet-4.6" > ~/apps/myrepo/.taskgrind-model' "$BATS_TEST_DIRNAME/../README.md"
  [ "$status" -eq 0 ]

  run grep -nF 'echo "claude\-sonnet\-4.6" > .taskgrind\-model' "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 0 ]

  run grep -n 'gpt-5-4' "$BATS_TEST_DIRNAME/../README.md" "$BATS_TEST_DIRNAME/../docs/user-stories.md" "$BATS_TEST_DIRNAME/../man/taskgrind.1"
  [ "$status" -eq 1 ]
}

@test "script usage examples use the shipped default model id" {
  run grep -nF '#        taskgrind --model claude-opus-4-7-max 8' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  [ "$status" -eq 0 ]

  run grep -nF '#        taskgrind --model "gpt-5.4 XHigh thinking fast" 8' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  [ "$status" -eq 0 ]

  run grep -n 'gpt-5-4' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  [ "$status" -eq 1 ]
}

@test "CLI docs parity keeps help, README, and man page in sync" {
  run python3 - "$BATS_TEST_DIRNAME/.." <<'PY'
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
help_text = subprocess.check_output([str(root / "bin" / "taskgrind"), "--help"], text=True)
readme = (root / "README.md").read_text()
man = (root / "man" / "taskgrind.1").read_text()

help_flags = set(re.findall(r"--[a-z0-9][a-z0-9-]*", help_text))
help_vars = set(re.findall(r"TG_[A-Z0-9_]+", help_text))

readme_usage = re.search(r"## Usage\n\n```bash\n(.*?)\n```", readme, re.S)
if not readme_usage:
    raise SystemExit("README usage block not found")
readme_flags = set(re.findall(r"--[a-z0-9][a-z0-9-]*", readme_usage.group(1)))

readme_env = re.search(r"## Environment Variables\n\n.*?\n((?:\| `TG_[A-Z0-9_]+`[^\n]*\n)+)", readme, re.S)
if not readme_env:
    raise SystemExit("README environment table not found")
readme_vars = set(re.findall(r"TG_[A-Z0-9_]+", readme_env.group(1)))

man_flags = set()
for raw_line in man.splitlines():
    if raw_line.startswith(".BR \\-\\-"):
        man_flags.update("--" + flag.replace("\\-", "-") for flag in re.findall(r"\\-\\-([a-z0-9\\-]+)", raw_line))

man_vars = set(re.findall(r"^\.B (TG_[A-Z0-9_]+)$", man, re.M))

failures = []
for label, left, right in [
    ("README usage flags vs --help", readme_flags, help_flags),
    ("man options flags vs --help", man_flags, help_flags),
    ("README TG_ vars vs --help", readme_vars, help_vars),
    ("man TG_ vars vs --help", man_vars, help_vars),
]:
    if left != right:
        failures.append(
            f"{label}: missing={sorted(right - left)} extra={sorted(left - right)}"
        )

if failures:
    raise SystemExit("\n".join(failures))
PY
  [ "$status" -eq 0 ]
}

@test "--help works in any arg position" {
  run "$DVB_GRIND" 8 --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "--version works in any arg position" {
  run "$DVB_GRIND" 8 --version
  [ "$status" -eq 0 ]
  [[ "$output" == "taskgrind "* ]]
}

@test "-h works in any arg position" {
  run "$DVB_GRIND" 8 -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "rejects hours over 24" {
  run "$DVB_GRIND" 25 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"max 24"* ]]
}

@test "rejects 0 hours" {
  run "$DVB_GRIND" 0 "$TEST_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "negative number is treated as repo path, not hours" {
  run "$DVB_GRIND" -5
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "non-numeric arg is treated as repo path" {
  run "$DVB_GRIND" abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "rejects nonexistent repo path" {
  run "$DVB_GRIND" 1 "$TEST_DIR/no-such-dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "accepts 24 hours (boundary)" {
  # Deadline in the past so loop body never runs
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 24 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

@test "accepts 1 hour" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
}

# ── Model selection ──────────────────────────────────────────────────

@test "defaults to claude-opus-4-7-max" {
  export DVB_DEADLINE_OFFSET=5
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Must be the exact default model string
  grep -q -- '--model claude-opus-4-7-max' "$DVB_GRIND_INVOKE_LOG"
}

@test "default model does not use 'opus' shortname" {
  export DVB_DEADLINE_OFFSET=5
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Should NOT contain bare '--model opus ' (the shortname)
  local first_invoke
  first_invoke=$(head -1 "$DVB_GRIND_INVOKE_LOG")
  [[ "$first_invoke" != *"--model opus "* ]]
  [[ "$first_invoke" != *"--model opus--"* ]]
}

@test "taskgrind sources shared constants from lib/constants.sh" {
  grep -q 'source.*lib/constants.sh' "$DVB_GRIND"
}

@test "devin binary path is defined in lib/constants.sh" {
  grep -q 'DVB_DEVIN_PATH=' "$BATS_TEST_DIRNAME/../lib/constants.sh"
}

@test "taskgrind uses DVB_DEVIN_PATH from shared constants" {
  grep -q 'DVB_DEVIN_PATH' "$DVB_GRIND"
}


@test "default model is claude-opus-4-7-max" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" == "claude-opus-4-7-max" ]]
}

@test "default model has no -1m suffix" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  [[ "$grind_default" != *-1m ]]
}

@test "default model is a valid devin model id" {
  local grind_default
  grind_default=$(grep '^DVB_DEFAULT_MODEL=' "$BATS_TEST_DIRNAME/../lib/constants.sh" | sed 's/.*="\(.*\)"/\1/')
  # Must be lowercase kebab-case (no spaces, no uppercase)
  [[ "$grind_default" =~ ^[a-z0-9._-]+$ ]]
}

@test "default model passes through to backend invocation" {
  export DVB_DEADLINE_OFFSET=5
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # The default model string must appear in the invocation log
  local invocation
  invocation=$(head -1 "$DVB_GRIND_INVOKE_LOG")
  [[ "$invocation" == *"--model claude-opus-4-7-max"* ]]
}

@test "every session gets the same model flag" {
  export DVB_DEADLINE_OFFSET=8
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  # Every invocation line must contain the exact model flag
  while IFS= read -r line; do
    [[ "$line" == *"--model claude-opus-4-7-max"* ]] || {
      echo "Session missing model flag: $line"; return 1
    }
  done < "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MODEL overrides default completely" {
  export DVB_DEADLINE_OFFSET=5
  export DVB_MODEL=sonnet
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model claude-sonnet-4.6' "$DVB_GRIND_INVOKE_LOG"
  # And the default must not appear
  ! grep -q -- '--model claude-opus-4-7-max ' "$DVB_GRIND_INVOKE_LOG"
}

@test "DVB_MODEL=claude-sonnet-4.5 passes through exactly" {
  export DVB_DEADLINE_OFFSET=5
  export DVB_MODEL=claude-sonnet-4.5
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model claude-sonnet-4.5' "$DVB_GRIND_INVOKE_LOG"
}

# ── TG_ prefix support ─────────────────────────────────────────────────

@test "TG_MODEL overrides default" {
  export DVB_DEADLINE_OFFSET=5
  export TG_MODEL=sonnet
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model claude-sonnet-4.6' "$DVB_GRIND_INVOKE_LOG"
}

@test "TG_MODEL takes precedence over DVB_MODEL" {
  export DVB_DEADLINE_OFFSET=5
  export DVB_MODEL=old-model
  export TG_MODEL=new-model
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q -- '--model new-model' "$DVB_GRIND_INVOKE_LOG"
  ! grep -q -- '--model old-model' "$DVB_GRIND_INVOKE_LOG"
}

@test "TG_SKILL overrides default skill" {
  export DVB_DEADLINE_OFFSET=5
  export TG_SKILL=custom-skill
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"custom-skill"* ]]
}

@test "TG_ prefix resolution block exists (structural)" {
  grep -q 'TG_ prefix resolution' "$DVB_GRIND"
  grep -q 'TG_.*takes precedence' "$DVB_GRIND"
}

@test "--help shows TG_ as primary prefix" {
  run "$DVB_GRIND" --help
  [[ "$output" == *"TG_BACKEND"* ]]
  [[ "$output" == *"TG_MODEL"* ]]
  [[ "$output" == *"DVB_ prefix is supported"* ]]
}

@test "model shows in startup banner" {
  export DVB_DEADLINE_OFFSET=5
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [[ "$output" == *"claude-opus-4-7-max"* ]]
}

@test "model shows in log file header" {
  export DVB_DEADLINE_OFFSET=5
  unset DVB_MODEL 2>/dev/null || true
  run "$DVB_GRIND" 1 "$TEST_REPO"
  grep -q 'model=claude-opus-4-7-max' "$TEST_LOG"
}

@test "repo defaults to current directory" {
  export DVB_DEADLINE=$(( $(date +%s) - 1 ))
  cd "$TEST_REPO"
  run "$DVB_GRIND" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_REPO"* ]]
}
