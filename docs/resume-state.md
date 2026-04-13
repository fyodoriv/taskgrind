# Resumable Grind State

This document describes the resume contract that `bin/taskgrind` implements
today. The goal is to keep the on-disk format small, human-readable, and easy
to validate in tests.

## Goals

- Preserve enough state to continue the same grind after an interruption.
- Reject stale or ambiguous state instead of silently mixing two different runs.
- Keep the file inspectable with plain shell tools.

## State file location and format

By default taskgrind writes resume state to:

- `<repo>/.taskgrind-state`

Tests can override the path with `DVB_STATE_FILE`.

The file is a flat `key=value` document, not JSON. Taskgrind rewrites the whole
file via a temporary file plus `mv`, so readers should treat it as a complete
snapshot rather than an append-only log.

Current keys:

- `version` — schema version, currently `1`
- `repo` — absolute repo path that owns the state
- `status` — resumability marker; `--resume` currently accepts only `running`
- `deadline` — absolute deadline epoch seconds
- `session` — completed session counter at the time of the write
- `tasks_shipped` — total shipped tasks so far
- `sessions_zero_ship` — total zero-ship sessions so far
- `consecutive_zero_ship` — current live zero-ship streak
- `backend` — saved backend name
- `skill` — saved skill name
- `model` — active model to resume with
- `startup_model` — original startup model baseline shown to the operator
- `startup_prompt` — original `--prompt` / `TG_PROMPT` baseline for resumed focus

Example:

```text
version=1
repo=/Users/alice/apps/myrepo
status=running
deadline=1760000000
session=3
tasks_shipped=2
sessions_zero_ship=1
consecutive_zero_ship=0
backend=devin
skill=next-task
model=gpt-5.4
startup_model=gpt-5.4
startup_prompt=focus on reliability
```

## What `--resume` restores

When validation succeeds, taskgrind restores:

- the saved deadline
- the session counter
- shipped-task counters
- zero-ship counters
- backend
- skill
- model
- startup model baseline
- startup focus prompt baseline

Resume does not restore every startup flag. In particular, taskgrind does not
persist git-sync cadence or retry maps in the state file. Repo-local
`.taskgrind-prompt` edits also remain live-only: taskgrind restores the saved
startup prompt baseline, then re-reads `.taskgrind-prompt` before each resumed
session so operators can keep steering the run without mutating the original
focus context.

## Validation rules

`taskgrind --resume <repo>` rejects the file unless all of these checks pass:

- the state file exists
- `version` matches the supported schema version
- `repo` matches the current absolute repo path
- `status=running`
- `deadline`, `session`, `tasks_shipped`, `sessions_zero_ship`, and
  `consecutive_zero_ship` are all present and numeric
- the saved deadline is still in the future
- any explicit `--backend` override matches the saved backend
- any explicit `--model` override matches the saved model
- any explicit `--prompt` / `TG_PROMPT` override matches the saved startup
  prompt
- the requested skill matches the saved skill

Current rejection reasons surfaced to the operator:

- `version mismatch`
- `repo mismatch`
- `state is not resumable (status=<value>)`
- `state file is malformed`
- `deadline expired`
- `backend override does not match saved state`
- `model override does not match saved state`
- `prompt override does not match saved state`
- `skill does not match saved state`

When the deadline is expired, taskgrind also suggests starting a fresh grind.

## When taskgrind writes or clears state

Taskgrind writes the state file:

- before the first session starts
- after each completed session updates the counters
- after network recovery extends the deadline

Taskgrind removes the file on clean completion, including:

- empty-queue completion
- deadline completion

The file is intentionally left behind for interrupted runs so `--resume` can
continue them.

Separately from the resume file itself, taskgrind also repairs interrupted git
state before the next session starts. If a prior run died during a rebase or
merge, the next loop aborts that in-progress operation first; normal
between-session sync also auto-resolves `TASKS.md`-only rebase conflicts so
routine queue churn does not strand the repo in recovery mode.

## Operator flow

Fresh run:

1. `taskgrind ~/apps/myrepo 8`
2. Taskgrind creates or refreshes `~/apps/myrepo/.taskgrind-state` while the
   grind is active.
3. If the grind completes cleanly, taskgrind deletes the file.

Resumed run:

1. `taskgrind --resume ~/apps/myrepo`
2. Taskgrind loads the saved `key=value` state, validates it, and restores the
   saved counters and runtime choices.
3. If validation fails, taskgrind exits with a clear incompatibility reason.

## Testing implications

The executable contract is covered in `tests/resume.bats`. At minimum, resume
behavior should keep covering:

- state-file creation for interrupted runs
- restoring counters on a resumed run
- rejecting incompatible schema versions
- rejecting expired deadlines
