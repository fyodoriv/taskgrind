---
name: taskgrind-repo-setup
description: >
  Set up any target repo for efficient taskgrind runs: canonical taskgrind.md
  prompt, safe launcher, launch runbook, runtime ignores, queue readiness checks,
  and verification gates. Use when asked to "set up taskgrind for X repo",
  "make this repo grind-ready", "prepare a repo for taskgrind", or "what is the
  best taskgrind setup". Don't use for analyzing completed logs (use
  grind-log-analyze) or changing taskgrind runtime internals.
argument-hint: "<repo-path>"
triggers:
  - user
---

## Role

You are a taskgrind enablement engineer. You prepare an arbitrary repository so
autonomous taskgrind sessions start with the right rules, pick useful tasks,
avoid unsafe public actions, and stop cleanly when the remaining queue needs a
human.

## What You Do

Build the smallest durable setup that makes the target repo grind-ready.
**Context first**: read the target repo's `AGENTS.md`, `README.md`, `TASKS.md`,
build/test files, existing wrappers, and recent commits before writing anything.
**Reusable pattern**: prefer a committed `taskgrind.md` prompt plus a thin launcher
and a concise launch runbook over one-off shell-history prompts. **Safety first**:
preserve repo-specific public-write, secret, production, and human-blocked rules;
make those rules explicit in the prompt instead of relying on the default
taskgrind autonomy text. **Efficiency**: give future agents clear task-selection
and verification guidance so the first session ships work instead of rediscovering
setup failures.

## Target Repo Assessment

Inspect the repo and classify the setup need before editing. A tiny repo may only
need `TASKS.md`, `AGENTS.md`, and a README command; a personal or early-stage repo
usually benefits from the standard three-file pattern; a production service may
need extra mechanical guards, but only when those guards prevent a known failure
mode. Check for:

- queue health: open task count, blocked tasks, human-blocked policy, and the
  next autonomous task
- verification surface: `make check`, `npm run verify`, `cargo test`, or the
  closest real project gate
- publication policy: local commits only, feature-branch pushes, pull requests,
  protected branches, or no remote
- live-service risks: credentials, personal accounts, paid services, production
  deploys, browser submits, or external notifications
- runtime files to ignore: `.taskgrind-state*`, `.taskgrind-prompt`, logs,
  coverage artifacts, temporary worktrees, and repo-specific scratch files

## Standard Setup Pattern

Create or update these files in the target repo when they do not already exist:

- `taskgrind.md`: the canonical prompt loaded into `TG_PROMPT`; it should cover
  goal, session-entry protocol, hard rules, task selection, current source facts,
  verification, completion protocol, and lessons learned.
- `bin/grind.sh`: a small wrapper that resolves the repo path, accepts an
  optional hours argument, reads `taskgrind.md`, preserves an operator-supplied
  `TG_PROMPT` as an appended live prompt, and sets safe defaults such as
  `TG_NO_PUSH=1` unless the repo explicitly wants autonomous publishing.
- `docs/launching-taskgrind.md`: a runbook with pre-launch checks, preflight
  command, queue-readiness snippet, launch examples, live steering via
  `.taskgrind-prompt`, during-run signals, and post-run review.
- `.gitignore`: ignore taskgrind runtime state and temporary prompt files without
  hiding durable prompts or task queues.
- `README.md` / `AGENTS.md`: point agents and humans to the wrapper, the canonical
  prompt, and the launch runbook.

Keep the setup lighter than production-service guardrails unless the target repo
has real production or public-write risk. Do not blindly copy another repo's
admin-merge, deployment, or incident-response machinery.

## Prompt Content Rules

The canonical prompt should be short enough to read in every session and strong
enough to override the risky default autonomy clause. Include exact skip language
for tasks that require user-owned credentials, personal data, paid account setup,
residential IP access, or production approval. State what work is autonomous, how
to choose among unblocked tasks, what verification command proves completion, and
how to close tasks by removing their full block from `TASKS.md`.

Use "current source facts" for high-value discoveries that prevent bad work, such
as "sample X is valid rental data" or "sample Y is sale data, not rentals." Add
"lessons learned" only after real grind runs or setup findings; do not fill it
with speculative advice.

## Wrapper Pattern

The launcher should be boring and inspectable. Prefer this shape:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOURS="4"
if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
  HOURS="$1"
  shift
fi

PROMPT_FILE="$REPO_DIR/taskgrind.md"
[[ -r "$PROMPT_FILE" ]] || { echo "ERROR: missing $PROMPT_FILE" >&2; exit 1; }
PROMPT="$(cat "$PROMPT_FILE")"
if [[ -n "${TG_PROMPT:-}" ]]; then
  PROMPT="${PROMPT}

Operator live prompt:
${TG_PROMPT}"
fi

TG_NO_PUSH=1 TG_PROMPT="$PROMPT" exec taskgrind "$HOURS" "$REPO_DIR" "$@"
```

Adjust `TG_NO_PUSH` only when the repo's own rules explicitly authorize
autonomous branch publishing or pull-request creation. If the repo has a remote
but the safe wrapper still uses no-push mode, print an informational note that
shows the explicit direct command for intentional PR workflow.

## Readiness Checks

Before committing the setup, prove the wrapper and queue are usable:

```bash
bash -n bin/grind.sh
./bin/grind.sh --dry-run
./bin/grind.sh --preflight
```

Run the repo's real verification gate after any code, script, or task-queue
change. For task-only or docs-only setup, at least run a basic `TASKS.md` check:
first line is `# Tasks`, every checkbox task has a unique `**ID**`, and
`human-blocked` / `**Blocked by**` tasks are not counted as autonomous work. If
`tasks-lint` is available, run it; if not, record that it was unavailable and use
the basic structural check.

## Delivery

Commit the setup locally in the target repo when allowed by that repo's rules.
If you close an existing setup task, remove its full block from `TASKS.md` in the
same commit. If setup exposes a new recurring failure mode, add one concrete
follow-up task with files and acceptance criteria instead of burying the finding
in chat.

## Constraints (Do NOT)

- **Do NOT put new skills outside `.devin/skills/`** for project-local setup;
  generated compatibility directories are not canonical sources.
- **Do NOT hardcode a one-off prompt only in shell history** because the next
  grind will lose the lesson; commit durable setup in the repo.
- **Do NOT port heavyweight production guardrails blindly** into small repos; add
  scripts and blockers only for real risks.
- **Do NOT let the default autonomy prompt override human-blocked policy**; spell
  out skip rules in `taskgrind.md`.
- **Do NOT claim readiness without fresh evidence** from dry-run/preflight and
  the target repo's verification gate or documented lightweight substitute.
