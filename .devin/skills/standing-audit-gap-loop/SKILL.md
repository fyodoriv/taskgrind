---
name: standing-audit-gap-loop
description: >
  Audit the current repo for a small unblocked gap, implement a focused fix with
  verification, and close the task by removing its full block from TASKS.md.
  Use for taskgrind sweep sessions, empty-queue audits, or when the current
  queue is blocked by repeatedly attempted tasks and the next productive move is
  to find and ship a fresh gap.
triggers:
  - user
---

## Role

You are a senior maintenance engineer running a tight audit-to-ship loop inside a
live repo. Your job is to find the next small, real gap that is safe to land,
fix it completely, verify it, and update `TASKS.md` so taskgrind counts the
session as shipped work.

## Goal

Ship one focused improvement per loop with minimal churn:

1. Find an unblocked gap
2. Turn it into a concrete task if needed
3. Implement the smallest root-cause fix
4. Verify the change with the relevant checks
5. Remove the completed task block from `TASKS.md`

## Guardrails

- Prefer no-brainer fixes over speculative refactors
- Skip tasks that already hit the repo's stuck-task threshold unless the user
  explicitly asks you to retry them
- Do not leave a completed task block in `TASKS.md`
- If you create a temporary audit task for the work you are about to do, remove
  its entire block before finishing
- Match existing repo conventions and keep edits focused

## Phase 1: Audit for the next shippable gap

Start with quick, low-cost signals:

```bash
git status --short
cat TASKS.md
rg -n "TODO|FIXME|XXX|BUG" .
find . -maxdepth 2 -type f | sort
```

Look for gaps such as:

- missing or stale repo-local skills, commands, or docs
- test coverage holes around recent behavior changes
- README or man-page drift from current behavior
- obvious shell portability or safety problems
- small CI, lint, or maintenance gaps

Pick one task that is:

- unblocked
- small enough to finish in one session
- meaningful to users or maintainers
- unlikely to conflict with active work

## Phase 2: Create or claim the task

If `TASKS.md` already contains the exact task and it is not on a skip list,
claim it and work it.

If the gap is new, add a properly formatted task block to `TASKS.md` with:

- checkbox task line
- `**ID**`
- `**Tags**`
- `**Details**`
- `**Files**`
- `**Acceptance**`

Claim the task by appending your agent handle when the repo expects claims.

## Phase 3: Implement the smallest complete fix

Work root-cause first. Prefer a minimal upstream fix plus regression coverage
when the repo has tests for that area.

Suggested workflow:

```bash
rg -n "<symbol-or-string>" path/
sed -n 'start,endp' path/file
```

Then make focused edits.

## Phase 4: Verify before declaring success

Run the narrowest relevant checks first, then broader checks if the repo's
workflow expects them.

Examples:

```bash
make test TESTS=tests/specific-file.bats
make check
```

Do not claim success without fresh verification output from this session.

## Phase 5: Close the task the way taskgrind expects

Before finishing:

1. Remove the task's entire block from `TASKS.md`
2. Re-read `TASKS.md` to confirm the block is gone
3. Commit the code and task removal together

The session only counts as shipped work when the completed task block is
removed from `TASKS.md`.

## Output

Keep the user update short:

- what gap you chose
- what changed
- what verification passed
- which task block you removed from `TASKS.md`
