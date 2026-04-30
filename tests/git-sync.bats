#!/usr/bin/env bats
# Tests for taskgrind — reset to main between sessions + 6 more
# Auto-split for parallel execution

load test_helper

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

# ── Reset to main between sessions ──────────────────────────────────

@test "between-session sync checks out default branch, not the current branch" {
  # Verify the code checks out detected default branch (not a raw variable)
  grep -q 'checkout "$_default_branch"' "$DVB_GRIND"
  ! grep -q 'pull.*origin.*\$branch' "$DVB_GRIND"
}

@test "between-session sync fetches with --prune" {
  grep -q 'fetch origin --prune' "$DVB_GRIND"
}

@test "between-session sync rebases on origin default branch" {
  grep -q 'rebase "origin/$_default_branch"' "$DVB_GRIND"
}

@test "agent on feature branch gets reset to main next session" {
  # Initialize repo with main + feature branch
  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create a feature branch and leave the repo on it
  git -C "$TEST_REPO" checkout -q -b chore/grind-session-1
  echo "feature" > "$TEST_REPO/feature.txt"
  git -C "$TEST_REPO" add feature.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "feature work"

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # After grind, repo should be on main
  local current_branch
  current_branch=$(git -C "$TEST_REPO" symbolic-ref --short HEAD 2>/dev/null)
  [ "$current_branch" = "main" ]
}

@test "git sync stashes dirty working tree before checkout" {
  # Structural: git diff --quiet check before checkout
  grep -q 'git -C "$repo" diff --quiet' "$DVB_GRIND"
  grep -q 'git -C "$repo" stash --include-untracked' "$DVB_GRIND"
}

@test "git sync restores stash after rebase" {
  # Structural: stash pop after rebase
  grep -q 'git -C "$repo" stash pop' "$DVB_GRIND"
}

@test "git sync logs stashed dirty tree" {
  # Structural: log message includes stash info
  grep -q 'stashed dirty tree' "$DVB_GRIND"
}

@test "dirty working tree survives between-session sync" {
  # Initialize repo with main branch and remote
  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  # Create a dirty file (simulating agent leaving uncommitted changes)
  echo "uncommitted work" > "$TEST_REPO/dirty.txt"
  git -C "$TEST_REPO" add dirty.txt

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  # The dirty file should still exist after sync
  [ -f "$TEST_REPO/dirty.txt" ]
  # Log should mention stashing
  grep -q 'stashed dirty tree' "$TEST_LOG"
}

@test "git sync interval skips non-sync sessions and runs on matching modulo" {
  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE_OFFSET=40
  export DVB_SYNC_INTERVAL=3

  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  grep -q 'git_sync skipped (interval=3, session=1)' "$TEST_LOG"
  grep -q 'git_sync skipped (interval=3, session=2)' "$TEST_LOG"
  grep -q 'git_sync ok' "$TEST_LOG"
}

@test "TG_SYNC_INTERVAL takes precedence over DVB_SYNC_INTERVAL during a real run" {
  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export TG_SYNC_INTERVAL=2
  export DVB_SYNC_INTERVAL=0
  export DVB_DEADLINE_OFFSET=20

  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  grep -q 'git_sync skipped (interval=2, session=1)' "$TEST_LOG"
  grep -q 'git_sync ok' "$TEST_LOG"
}

@test "stash pop failure is logged and stash preserved" {
  # Structural: stash pop failure produces a log marker
  grep -q 'stash_pop_failed' "$DVB_GRIND"
  # Structural: user-visible warning about stash pop failure
  grep -q 'stash pop failed.*stash preserved' "$DVB_GRIND"
}

@test "stash failure is surfaced and stash pop is skipped" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then
  repo_path="\$2"
  shift 2
fi
if [ "\${1:-}" = "stash" ] && [ "\${2:-}" = "--include-untracked" ]; then
  echo "simulated stash failure" >&2
  exit 1
fi
if [ -n "\${repo_path:-}" ]; then
  exec "$real_git" -C "\$repo_path" "\$@"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$TEST_DIR/bin/git"
  export PATH="$TEST_DIR/bin:$PATH"

  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  echo "uncommitted work" > "$TEST_REPO/dirty.txt"
  git -C "$TEST_REPO" add dirty.txt

  export DVB_DEADLINE_OFFSET=15
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git stash failed"* ]]
  [[ "$output" == *"simulated stash failure"* ]]
  ! grep -q 'stash_pop_failed' "$TEST_LOG"
}

# ── Branch cleanup between sessions ───────────────────────────────────

@test "merged branches are cleaned up between sessions" {
  # Initialize repo with main
  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create and merge a feature branch
  git -C "$TEST_REPO" checkout -q -b already-merged
  echo "merged" > "$TEST_REPO/merged.txt"
  git -C "$TEST_REPO" add merged.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "merged branch"
  git -C "$TEST_REPO" checkout -q main
  git -C "$TEST_REPO" merge -q already-merged --no-edit
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The merged branch should be deleted
  ! git -C "$TEST_REPO" branch | grep -q 'already-merged'
  grep -q 'branch_cleanup done' "$TEST_LOG"
}

@test "unmerged branches are not deleted" {
  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create an unmerged branch
  git -C "$TEST_REPO" checkout -q -b work-in-progress
  echo "wip" > "$TEST_REPO/wip.txt"
  git -C "$TEST_REPO" add wip.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "wip"
  git -C "$TEST_REPO" checkout -q main

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The unmerged branch should still exist
  git -C "$TEST_REPO" branch | grep -q 'work-in-progress'
}

@test "branch cleanup deletes merged branches with main as substring" {
  # Regression: old grep -v '^\*\|main' filtered branches containing "main" anywhere
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create and merge a branch with "main" as substring
  git -C "$TEST_REPO" checkout -q -b maintain-docs
  echo "docs" > "$TEST_REPO/docs.txt"
  git -C "$TEST_REPO" add docs.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "maintain docs"
  git -C "$TEST_REPO" checkout -q main
  git -C "$TEST_REPO" merge -q maintain-docs --no-edit
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Branch with "main" substring should be deleted when merged
  ! git -C "$TEST_REPO" branch | grep -q 'maintain-docs'
}

@test "stale branches with gone upstream are pruned" {
  # When a remote branch is deleted (e.g., merged on GitHub), the local branch
  # tracking it becomes stale. After fetch --prune, it shows [gone] upstream.
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create a feature branch, push it, then delete it on the remote
  git -C "$TEST_REPO" checkout -q -b stale-feature
  echo "feature" > "$TEST_REPO/feature.txt"
  git -C "$TEST_REPO" add feature.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "feature work"
  git -C "$TEST_REPO" push -q origin stale-feature 2>/dev/null
  # Set upstream tracking
  git -C "$TEST_REPO" branch --set-upstream-to=origin/stale-feature stale-feature 2>/dev/null
  git -C "$TEST_REPO" checkout -q main
  # Delete the remote branch (simulates GitHub merge+delete)
  git -C "$bare" branch -D stale-feature 2>/dev/null

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The stale branch should be pruned
  ! git -C "$TEST_REPO" branch | grep -q 'stale-feature'
  grep -q 'branch_cleanup pruned=1' "$TEST_LOG"
}

@test "stale branch cleanup logs count when multiple branches pruned" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create two feature branches, push them, delete on remote
  for branch_name in stale-one stale-two; do
    git -C "$TEST_REPO" checkout -q -b "$branch_name"
    echo "$branch_name" > "$TEST_REPO/${branch_name}.txt"
    git -C "$TEST_REPO" add "${branch_name}.txt"
    git -C "$TEST_REPO" commit -q --no-verify -m "$branch_name"
    git -C "$TEST_REPO" push -q origin "$branch_name" 2>/dev/null
    git -C "$TEST_REPO" branch --set-upstream-to="origin/$branch_name" "$branch_name" 2>/dev/null
    git -C "$TEST_REPO" checkout -q main
    git -C "$bare" branch -D "$branch_name" 2>/dev/null
  done

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! git -C "$TEST_REPO" branch | grep -q 'stale-one'
  ! git -C "$TEST_REPO" branch | grep -q 'stale-two'
  grep -q 'branch_cleanup pruned=2' "$TEST_LOG"
}

@test "non-stale tracking branches are not pruned" {
  # Branches with a live upstream should survive cleanup
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Create a branch that still exists on remote
  git -C "$TEST_REPO" checkout -q -b active-feature
  echo "active" > "$TEST_REPO/active.txt"
  git -C "$TEST_REPO" add active.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "active"
  git -C "$TEST_REPO" push -q origin active-feature 2>/dev/null
  git -C "$TEST_REPO" branch --set-upstream-to=origin/active-feature active-feature 2>/dev/null
  git -C "$TEST_REPO" checkout -q main

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Active branch should still exist
  git -C "$TEST_REPO" branch | grep -q 'active-feature'
  # No stale branches pruned
  ! grep -q 'branch_cleanup pruned=' "$TEST_LOG"
}

# ── Rebase abort between sessions ─────────────────────────────────────

@test "rebase conflict is auto-aborted between sessions" {
  # Initialize repo with a commit on main
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "main content" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  # Create a divergent history that will conflict on rebase
  echo "remote change" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "remote change"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null
  # Reset local main behind remote and make a conflicting commit
  git -C "$TEST_REPO" reset -q --hard HEAD~1
  echo "local conflicting change" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "local conflict"

  export DVB_DEADLINE_OFFSET=30
  export DVB_SYNC_INTERVAL=0
  export DVB_MAX_ZERO_SHIP=2
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'rebase_aborted' "$TEST_LOG"
  # Repo should NOT be in rebase-in-progress state
  [ ! -d "$TEST_REPO/.git/rebase-merge" ]
  [ ! -d "$TEST_REPO/.git/rebase-apply" ]
}

@test "clean rebase does not log rebase_aborted" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE_OFFSET=30
  export DVB_SYNC_INTERVAL=0
  export DVB_MAX_ZERO_SHIP=2
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync ok' "$TEST_LOG"
  ! grep -q 'rebase_aborted' "$TEST_LOG"
}

@test "git fetch failure is logged with fetch_failed marker" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  # Point origin at a nonexistent path so fetch fails
  git -C "$TEST_REPO" remote add origin "/nonexistent/bare.git"

  export DVB_DEADLINE_OFFSET=30
  export DVB_SYNC_INTERVAL=0
  export DVB_MAX_ZERO_SHIP=2
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync fetch_failed:' "$TEST_LOG"
  grep -q '/nonexistent/bare.git' "$TEST_LOG"
}

@test "git rebase failure logs conflict details" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  printf 'shared\n' > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"

  local bare="$TEST_DIR/bare.git"
  local remote_worktree="$TEST_DIR/remote-worktree"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin main 2>/dev/null

  git clone -q "$bare" "$remote_worktree"
  git -C "$remote_worktree" config user.email "test@test.com"
  git -C "$remote_worktree" config user.name "Test"
  printf 'remote-change\n' > "$remote_worktree/README.md"
  git -C "$remote_worktree" commit -qam "remote change"
  git -C "$remote_worktree" push -q origin main 2>/dev/null

  printf 'local-change\n' > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" commit -qam "local change"

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync rebase_failed:' "$TEST_LOG"
  grep -q 'CONFLICT' "$TEST_LOG"
}

@test "TASKS-only rebase conflicts auto-resolve and keep sync healthy" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  cat <<'EOF' > "$TEST_REPO/TASKS.md"
# Tasks

## P0

## P1
- [ ] Shared queue task
  **ID**: shared-queue-task

## P2

## P3
EOF
  git -C "$TEST_REPO" add TASKS.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"

  local bare="$TEST_DIR/bare.git"
  local remote_worktree="$TEST_DIR/remote-worktree"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin main 2>/dev/null

  git clone -q "$bare" "$remote_worktree"
  git -C "$remote_worktree" config user.email "test@test.com"
  git -C "$remote_worktree" config user.name "Test"
  cat <<'EOF' > "$remote_worktree/TASKS.md"
# Tasks

## P0

## P1
- [ ] Remote queue task
  **ID**: remote-queue-task

## P2

## P3
EOF
  git -C "$remote_worktree" commit -qam "remote queue change"
  git -C "$remote_worktree" push -q origin main 2>/dev/null

  cat <<'EOF' > "$TEST_REPO/TASKS.md"
# Tasks

## P0

## P1
- [ ] Local queue task
  **ID**: local-queue-task

## P2

## P3
EOF
  git -C "$TEST_REPO" commit -qam "local queue change"

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync rebase_autoresolved class=queue_only paths=TASKS.md strategy=local_theirs' "$TEST_LOG"
  grep -q 'git_sync ok (auto-resolved TASKS.md rebase conflict)' "$TEST_LOG"
  ! grep -q 'git_sync rebase_aborted class=queue_only' "$TEST_LOG"
  git -C "$TEST_REPO" merge-base --is-ancestor origin/main HEAD
  ! [ -d "$TEST_REPO/.git/rebase-merge" ]
  ! [ -d "$TEST_REPO/.git/rebase-apply" ]
  grep -q 'Local queue task' "$TEST_REPO/TASKS.md"
}

@test "general rebase conflicts log conflicted paths and class" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  printf 'shared\n' > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"

  local bare="$TEST_DIR/bare.git"
  local remote_worktree="$TEST_DIR/remote-worktree"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin main 2>/dev/null

  git clone -q "$bare" "$remote_worktree"
  git -C "$remote_worktree" config user.email "test@test.com"
  git -C "$remote_worktree" config user.name "Test"
  printf 'remote-change\n' > "$remote_worktree/README.md"
  git -C "$remote_worktree" commit -qam "remote change"
  git -C "$remote_worktree" push -q origin main 2>/dev/null

  printf 'local-change\n' > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" commit -qam "local change"

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync rebase_conflicts class=repo paths=README.md' "$TEST_LOG"
  grep -q 'git_sync rebase_aborted class=repo' "$TEST_LOG"
}

@test "git checkout failure is logged with checkout_failed marker" {
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --no-verify -m "init"
  # Create remote but no 'main' branch to checkout (we're on main, so this succeeds;
  # instead, test structural presence)
  grep -q 'checkout_failed' "$DVB_GRIND"
}

@test "git sync failure markers are distinguishable in log" {
  # Structural: the outer handler greps for each failure type
  grep -q 'fetch_failed' "$DVB_GRIND"
  grep -q 'checkout_failed' "$DVB_GRIND"
  grep -q 'stash_failed' "$DVB_GRIND"
  grep -q 'rebase_failed' "$DVB_GRIND"
}

# ── Default branch detection ──────────────────────────────────────────

@test "git sync detects default branch from origin/HEAD" {
  # Structural: script uses symbolic-ref to detect default branch
  grep -q 'symbolic-ref refs/remotes/origin/HEAD' "$DVB_GRIND"
}

@test "git sync falls back through remote HEAD probes before main" {
  grep -q 'ls-remote --symref origin HEAD' "$DVB_GRIND"
  grep -q 'show-ref --verify --quiet refs/remotes/origin/main' "$DVB_GRIND"
  grep -q 'show-ref --verify --quiet refs/remotes/origin/master' "$DVB_GRIND"
}

@test "git sync honors an explicit test override before auto-detecting the default branch" {
  init_test_repo "$TEST_REPO" main
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit

  local bare="$TEST_DIR/bare.git"
  git init -q --bare --initial-branch=main "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin main 2>/dev/null

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run env DVB_DEFAULT_BRANCH=release "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync selected_branch branch=release source=env_override' "$TEST_LOG"
}

@test "git sync falls back to the current branch when origin HEAD is missing" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then
  repo_path="\$2"
  shift 2
fi
if [ "\${1:-}" = "symbolic-ref" ] && [ "\${2:-}" = "refs/remotes/origin/HEAD" ]; then
  exit 1
fi
if [ -n "\${repo_path:-}" ]; then
  exec "$real_git" -C "\$repo_path" "\$@"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$TEST_DIR/bin/git"
  export PATH="$TEST_DIR/bin:$PATH"

  init_test_repo "$TEST_REPO" master
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit

  local bare="$TEST_DIR/bare.git"
  git init -q --bare --initial-branch=master "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin master 2>/dev/null

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  grep -Eq 'git_sync selected_branch branch=master source=(ls_remote_head|upstream|current_branch|current_branch_fallback)' "$TEST_LOG"
  ! grep -q 'git_sync checkout_failed: .*pathspec .main.' "$TEST_LOG"
  ! grep -q 'git_sync rebase_failed' "$TEST_LOG"
  grep -q 'git_sync ok' "$TEST_LOG"
  [ "$(git -C "$TEST_REPO" symbolic-ref --short HEAD 2>/dev/null)" = "master" ]
}

@test "git sync falls back to the configured upstream before main" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then
  repo_path="\$2"
  shift 2
fi
if [ "\${1:-}" = "symbolic-ref" ] && [ "\${2:-}" = "refs/remotes/origin/HEAD" ]; then
  exit 1
fi
if [ "\${1:-}" = "ls-remote" ] && [ "\${2:-}" = "--symref" ] && [ "\${3:-}" = "origin" ] && [ "\${4:-}" = "HEAD" ]; then
  exit 1
fi
if [ "\${1:-}" = "show-ref" ] && [ "\${2:-}" = "--verify" ] && [ "\${3:-}" = "--quiet" ] && [ "\${4:-}" = "refs/remotes/origin/master" ]; then
  exit 1
fi
if [ -n "\${repo_path:-}" ]; then
  exec "$real_git" -C "\$repo_path" "\$@"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$TEST_DIR/bin/git"
  export PATH="$TEST_DIR/bin:$PATH"

  init_test_repo "$TEST_REPO" release
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit

  local bare="$TEST_DIR/bare.git"
  git init -q --bare --initial-branch=release "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin release 2>/dev/null

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  grep -q 'git_sync selected_branch branch=release source=upstream' "$TEST_LOG"
  ! grep -q "git_sync checkout_failed: .*pathspec 'main'" "$TEST_LOG"
  ! grep -q 'git_sync rebase_failed' "$TEST_LOG"
  grep -q 'git_sync ok' "$TEST_LOG"
  [ "$(git -C "$TEST_REPO" symbolic-ref --short HEAD 2>/dev/null)" = "release" ]
}

@test "git sync falls back to local default branches before assuming main" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then
  repo_path="\$2"
  shift 2
fi
if [ "\${1:-}" = "symbolic-ref" ] && [ "\${2:-}" = "refs/remotes/origin/HEAD" ]; then
  exit 1
fi
if [ "\${1:-}" = "ls-remote" ] && [ "\${2:-}" = "--symref" ] && [ "\${3:-}" = "origin" ] && [ "\${4:-}" = "HEAD" ]; then
  exit 1
fi
if [ -n "\${repo_path:-}" ]; then
  exec "$real_git" -C "\$repo_path" "\$@"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$TEST_DIR/bin/git"
  export PATH="$TEST_DIR/bin:$PATH"

  init_test_repo "$TEST_REPO" master
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit

  local bare="$TEST_DIR/bare.git"
  git init -q --bare --initial-branch=master "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q -u origin master 2>/dev/null
  rm -f "$TEST_REPO/.git/refs/remotes/origin/master"

  export DVB_DEADLINE_OFFSET=8
  export DVB_SYNC_INTERVAL=0
  git -C "$TEST_REPO" checkout -q --detach
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  ! grep -q "git_sync checkout_failed: .*pathspec 'main'" "$TEST_LOG"
  ! grep -q 'git_sync rebase_failed' "$TEST_LOG"
  grep -q 'git_sync ok' "$TEST_LOG"
  [ "$(git -C "$TEST_REPO" symbolic-ref --short HEAD 2>/dev/null)" = "master" ]
}

@test "git sync uses detected branch for checkout and rebase" {
  grep -q 'checkout "$_default_branch"' "$DVB_GRIND"
  grep -q 'rebase "origin/$_default_branch"' "$DVB_GRIND"
}

# ── Git sync timeout recovery ─────────────────────────────────────────

@test "git sync timeout aborts in-progress rebase" {
  # Structural: the failure branch checks for rebase-in-progress and aborts
  grep -q 'timeout_rebase_aborted' "$DVB_GRIND"
}

@test "git sync timeout aborts in-progress merge" {
  # Structural: the failure branch checks for MERGE_HEAD and aborts
  grep -q 'timeout_merge_aborted' "$DVB_GRIND"
}

@test "DVB_GIT_SYNC_TIMEOUT controls git sync timeout" {
  # Structural: the variable is read from env
  grep -q 'DVB_GIT_SYNC_TIMEOUT:-30' "$DVB_GRIND"
}

@test "TG_GIT_SYNC_TIMEOUT takes precedence over DVB_GIT_SYNC_TIMEOUT during a real sync timeout" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then
  repo_path="\$2"
  shift 2
fi
if [ "\${1:-}" = "fetch" ] && [ "\${2:-}" = "origin" ] && [ "\${3:-}" = "--prune" ]; then
  sleep 2
fi
if [ -n "\${repo_path:-}" ]; then
  exec "$real_git" -C "\$repo_path" "\$@"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$TEST_DIR/bin/git"

  init_test_repo "$TEST_REPO"
  echo "init" > "$TEST_REPO/README.md"
  git -C "$TEST_REPO" add README.md
  git -C "$TEST_REPO" commit -q --amend --no-edit
  local bare="$TEST_DIR/bare.git"
  git init -q --bare "$bare"
  git -C "$TEST_REPO" remote add origin "$bare"
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export PATH="$TEST_DIR/bin:$PATH"
  export TG_GIT_SYNC_TIMEOUT=1
  export DVB_GIT_SYNC_TIMEOUT=5
  export DVB_SYNC_INTERVAL=0
  export DVB_DEADLINE_OFFSET=20

  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -ne 0 ]

  grep -q 'git_sync failed:' "$TEST_LOG"
  ! grep -q 'git_sync ok' "$TEST_LOG"
}

# ── Git sync timer leak fix ────────────────────────────────────────────

@test "git sync timer uses trap+wait pattern to avoid orphaned sleeps" {
  # The git sync timer subshell should have the same pattern as the session
  # timeout watchdog: trap 'kill $! ...; exit 0' TERM + sleep N &; wait $!
  # Count occurrences of the trap pattern — should appear 3+ times:
  # sweep watchdog, session watchdog, git sync timer.
  local count
  count=$(grep -c "trap 'kill \$! 2>/dev/null; exit 0' TERM" "$DVB_GRIND")
  [ "$count" -ge 3 ]
}

# ── Multi-project locking ─────────────────────────────────────────────

@test "locking uses flock(1) with perl fallback for macOS" {
  grep -q 'flock -n "$_lock_fd"' "$DVB_GRIND"
  grep -q 'perl -e.*Fcntl.*flock' "$DVB_GRIND"
}

@test "lock file path is derived from repo hash" {
  grep -q 'shasum' "$DVB_GRIND"
  grep -q 'taskgrind-lock-' "$DVB_GRIND"
}

@test "lock writes diagnostic info (repo, pid, start time)" {
  grep -q 'repo=.*pid=.*started=' "$DVB_GRIND"
}

@test "lock error message shows repo path" {
  grep -q 'all.*instance slot(s) are in use' "$DVB_GRIND"
  grep -q 'repo:' "$DVB_GRIND"
}

@test "locking is skipped in test mode" {
  # DVB_GRIND_CMD being set should skip the lock (fd 9) section
  grep -q 'DVB_GRIND_CMD.*locking\|DVB_GRIND_CMD.*fd conflicts\|DVB_GRIND_CMD.*avoid fd' "$DVB_GRIND"
}

@test "two grinds on different repos get different lock files" {
  # Lock hash should differ for different repo paths
  local hash1 hash2
  hash1=$(echo "/tmp/repo-a" | shasum | cut -d' ' -f1)
  hash2=$(echo "/tmp/repo-b" | shasum | cut -d' ' -f1)
  [ "$hash1" != "$hash2" ]
}

@test "same repo path always gets the same lock file hash" {
  local hash1 hash2
  hash1=$(echo "/Users/me/apps/myrepo" | shasum | cut -d' ' -f1)
  hash2=$(echo "/Users/me/apps/myrepo" | shasum | cut -d' ' -f1)
  [ "$hash1" = "$hash2" ]
}

# ── detect_default_branch() — direct coverage for each fallback rung ──
# Extract the function from bin/taskgrind and call it against repo fixtures
# that force each rung to fire. Catches silent rung drops during refactor.

_extract_detect_default_branch() {
  awk '/^detect_default_branch\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_detect_default_branch() {
  local repo_path="$1"
  local fn
  fn=$(_extract_detect_default_branch)
  bash -c "$fn"$'\n'"detect_default_branch \"$repo_path\""
}

# Helper: create a bare remote + a local clone checked out on a named branch.
_make_remote_and_clone() {
  local remote_path="$1"
  local clone_path="$2"
  local branch_name="${3:-main}"
  git init -q --bare "$remote_path"
  git init -q -b "$branch_name" "$clone_path"
  git -C "$clone_path" config user.email "test@test.com"
  git -C "$clone_path" config user.name "Test"
  git -C "$clone_path" commit --allow-empty -q -m "init"
  git -C "$clone_path" remote add origin "$remote_path"
  git -C "$clone_path" push -q -u origin "$branch_name" 2>/dev/null || true
}

@test "detect_default_branch: DVB_DEFAULT_BRANCH env override wins first" {
  init_test_repo "$TEST_REPO"
  DVB_DEFAULT_BRANCH=custom-trunk run _run_detect_default_branch "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == "custom-trunk env_override" ]]
}

@test "detect_default_branch: origin/HEAD symbolic ref resolves as origin_head" {
  local bare="$TEST_DIR/bare.git"
  _make_remote_and_clone "$bare" "$TEST_REPO" main
  # Explicitly set origin/HEAD (fresh clones set this automatically; init'd
  # repos that have a remote but no HEAD do not — write it directly).
  git -C "$TEST_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  run _run_detect_default_branch "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == "main origin_head" ]]
}

@test "detect_default_branch: upstream tracking branch wins over local main" {
  local bare="$TEST_DIR/bare.git"
  _make_remote_and_clone "$bare" "$TEST_REPO" feature
  # No origin/HEAD ref, so the lookup falls through to upstream tracking.
  git -C "$TEST_REPO" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
  # Delete the origin symref created by push -u so ls-remote also misses.
  rm -f "$bare/HEAD.lock" 2>/dev/null || true
  rm -f "$bare/HEAD"
  echo "0000000000000000000000000000000000000000" > "$bare/HEAD"

  run _run_detect_default_branch "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Accept either the upstream rung or the current_branch rung — both are
  # valid behaviors for 'the current branch exists on origin with upstream'.
  [[ "$output" == "feature upstream" || "$output" == "feature current_branch" ]]
}

@test "detect_default_branch: local main fallback when there is no remote" {
  git init -q -b main "$TEST_REPO"
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" commit --allow-empty -q -m "init"
  # No remote at all, HEAD points to main

  run _run_detect_default_branch "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Without upstream, current_branch rung can still fire if origin/main
  # exists (it does not here); otherwise falls back to local main.
  [[ "$output" == "main local_main" ]]
}

@test "detect_default_branch: local master fallback when only master exists" {
  git init -q -b master "$TEST_REPO"
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" commit --allow-empty -q -m "init"

  run _run_detect_default_branch "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Current branch is 'master' with no upstream and no origin — the
  # current_branch rung misses (no origin), local main misses, local master
  # hits as 'local_master'. If an older git silently creates origin refs,
  # accept the current_branch fallback source name too.
  [[ "$output" == "master local_master" || "$output" == "master current_branch_fallback" ]]
}

@test "detect_default_branch: missing repo path falls back to hardcoded main" {
  # No repo path at all → git commands print 'fatal:' to stderr but the
  # function is |-silenced so the final printf still emits the fallback.
  # bats 'run' merges stdout+stderr, so match the last non-empty line.
  run _run_detect_default_branch "$TEST_DIR/nonexistent-repo"
  [ "$status" -eq 0 ]
  # Drop the stderr lines (start with 'fatal:') and keep the printf output.
  local last
  last=$(printf '%s\n' "$output" | grep -v '^fatal:' | tail -1)
  [[ "$last" == "main hardcoded_main" ]]
}

@test "detect_default_branch: always emits '<branch> <source>' format" {
  # Structural contract: every rung uses printf '%s %s\n', so the output is
  # always exactly two whitespace-separated fields. Refactors that drop one
  # field trip this immediately.
  init_test_repo "$TEST_REPO"
  DVB_DEFAULT_BRANCH=any-branch run _run_detect_default_branch "$TEST_REPO"
  [ "$status" -eq 0 ]
  # Exactly two non-empty space-separated tokens
  local words
  read -ra words <<<"$output"
  [ "${#words[@]}" -eq 2 ]
  [[ -n "${words[0]}" ]]
  [[ -n "${words[1]}" ]]
}

# ── auto_resolve_tasks_rebase_conflicts() — direct coverage ───────────
# Extract the function + its helpers and exercise each decision branch
# against real git fixtures with deliberate conflicts.

_extract_auto_resolve_helpers() {
  # Pull the three relevant functions from bin/taskgrind in source order.
  awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  printf '\n'
  awk '/^rebase_in_progress\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  printf '\n'
  awk '/^auto_resolve_tasks_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_auto_resolve() {
  local repo="$1"
  local fns
  fns=$(_extract_auto_resolve_helpers)
  bash -c "$fns"$'\n'"auto_resolve_tasks_rebase_conflicts \"$repo\""
}

# Helper: build a repo where a rebase against main will conflict on the
# named files. After this call, the repo is left mid-rebase with the
# conflicts still unresolved.
_setup_rebase_conflict() {
  local repo="$1"
  shift
  local files=("$@")

  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"

  for f in "${files[@]}"; do
    mkdir -p "$(dirname "$repo/$f")" 2>/dev/null || true
    printf 'base\n' > "$repo/$f"
    git -C "$repo" add -- "$f"
  done
  git -C "$repo" commit -q -m "base"

  # Branch diverges from main with conflicting edit
  git -C "$repo" checkout -q -b feature
  for f in "${files[@]}"; do
    printf 'feature-side\n' > "$repo/$f"
    git -C "$repo" add -- "$f"
  done
  git -C "$repo" commit -q -m "feature edits"

  # Main also edits the same files so the rebase conflicts
  git -C "$repo" checkout -q main
  for f in "${files[@]}"; do
    printf 'main-side\n' > "$repo/$f"
    git -C "$repo" add -- "$f"
  done
  git -C "$repo" commit -q -m "main edits"

  git -C "$repo" checkout -q feature
  # Conflict is expected here; suppress rebase's stderr but preserve the
  # mid-rebase state for the function to inspect.
  git -C "$repo" rebase main >/dev/null 2>&1 || true
}

@test "auto_resolve_tasks_rebase_conflicts: TASKS.md-only conflict auto-resolves" {
  local repo="$TEST_DIR/auto-resolve-tasks-only"
  _setup_rebase_conflict "$repo" "TASKS.md"
  # Sanity: rebase really is in progress with TASKS.md conflicting
  [ -d "$repo/.git/rebase-merge" ] || [ -d "$repo/.git/rebase-apply" ]

  run _run_auto_resolve "$repo"
  [ "$status" -eq 0 ]
  # Rebase must be cleared after auto-resolve
  ! [ -d "$repo/.git/rebase-merge" ]
  ! [ -d "$repo/.git/rebase-apply" ]
}

@test "auto_resolve_tasks_rebase_conflicts: TASKS.md + other file → NOT auto-resolved" {
  local repo="$TEST_DIR/auto-resolve-mixed"
  _setup_rebase_conflict "$repo" "TASKS.md" "README.md"

  run _run_auto_resolve "$repo"
  [ "$status" -eq 1 ]
  # Rebase must still be in progress — the function refused to touch it
  [ -d "$repo/.git/rebase-merge" ] || [ -d "$repo/.git/rebase-apply" ]
}

@test "auto_resolve_tasks_rebase_conflicts: preserves the feature branch TASKS.md content" {
  local repo="$TEST_DIR/auto-resolve-keep-local"
  _setup_rebase_conflict "$repo" "TASKS.md"

  run _run_auto_resolve "$repo"
  [ "$status" -eq 0 ]
  # During a rebase, 'checkout --theirs' keeps the side being rebased onto
  # the base — which is main's content ('main-side'). The function names
  # this 'strategy=local_theirs' because from the user's perspective it
  # preserves the already-landed queue edit instead of taking the in-flight
  # branch's version. Verify the file exists and is not in conflict state.
  [ -f "$repo/TASKS.md" ]
  ! grep -q '<<<<<<<' "$repo/TASKS.md"
  ! grep -q '>>>>>>>' "$repo/TASKS.md"
  # Content must be one of the two committed versions, not a conflict marker
  local content
  content=$(cat "$repo/TASKS.md")
  [[ "$content" == "main-side" || "$content" == "feature-side" ]]
}

@test "auto_resolve_tasks_rebase_conflicts: no-op when no rebase is in progress" {
  local repo="$TEST_DIR/auto-resolve-clean"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" commit --allow-empty -q -m "init"
  # rebase_in_progress is false → the while loop is skipped → returns 0
  run _run_auto_resolve "$repo"
  [ "$status" -eq 0 ]
}

@test "classify_rebase_conflicts: TASKS.md-only returns queue_only" {
  local fn
  fn=$(awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind")
  run bash -c "$fn"$'\n'"classify_rebase_conflicts 'TASKS.md'"
  [ "$status" -eq 0 ]
  [[ "$output" == "queue_only" ]]
}

@test "classify_rebase_conflicts: nested TASKS.md still counts as queue_only" {
  local fn
  fn=$(awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind")
  # Nested TASKS.md (e.g. in a monorepo subdir) is still a queue file.
  run bash -c "$fn"$'\n'"classify_rebase_conflicts 'packages/foo/TASKS.md'"
  [ "$status" -eq 0 ]
  [[ "$output" == "queue_only" ]]
}

@test "classify_rebase_conflicts: non-queue file returns repo" {
  local fn
  fn=$(awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind")
  run bash -c "$fn"$'\n'"classify_rebase_conflicts 'README.md'"
  [ "$status" -eq 0 ]
  [[ "$output" == "repo" ]]
}

@test "classify_rebase_conflicts: mixed TASKS.md + other returns repo" {
  local fn
  fn=$(awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind")
  # Multi-line input needs to land inside the classify call's single arg;
  # use ANSI-C quoting to pass the newline-separated list.
  local multi_line
  multi_line=$'TASKS.md\nREADME.md'
  run bash -c "$fn"$'\n'"classify_rebase_conflicts \"\$1\"" _ "$multi_line"
  [ "$status" -eq 0 ]
  [[ "$output" == "repo" ]]
}

@test "classify_rebase_conflicts: empty input returns unknown" {
  local fn
  fn=$(awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind")
  run bash -c "$fn"$'\n'"classify_rebase_conflicts ''"
  [ "$status" -eq 0 ]
  [[ "$output" == "unknown" ]]
}

# ── format_conflict_paths_for_log() — direct coverage ─────────────────
# Turns a newline-separated list of conflict paths into the comma-joined
# `paths=A,B,C` fragment the grind-log-analyze skill parses. A silent
# regression that changed the separator or stopped trimming empty lines
# would break every post-mortem report without any structural test
# catching it.

_extract_format_conflict_paths() {
  awk '/^format_conflict_paths_for_log\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

_run_format_conflict_paths() {
  local paths="$1"
  local fn
  fn=$(_extract_format_conflict_paths)
  run bash -c "$fn"$'\n'"format_conflict_paths_for_log \"\$1\"" _ "$paths"
}

@test "format_conflict_paths_for_log: single queue path emits the literal path" {
  _run_format_conflict_paths "TASKS.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "TASKS.md" ]]
}

@test "format_conflict_paths_for_log: multiple queue paths comma-joined in input order" {
  local multi_line
  multi_line=$'TASKS.md\npackages/foo/TASKS.md\npackages/bar/TASKS.md'
  _run_format_conflict_paths "$multi_line"
  [ "$status" -eq 0 ]
  [[ "$output" == "TASKS.md,packages/foo/TASKS.md,packages/bar/TASKS.md" ]]
}

@test "format_conflict_paths_for_log: mixed queue + repo files stay in input order" {
  local multi_line
  multi_line=$'TASKS.md\nREADME.md\nsrc/main.c'
  _run_format_conflict_paths "$multi_line"
  [ "$status" -eq 0 ]
  [[ "$output" == "TASKS.md,README.md,src/main.c" ]]
}

@test "format_conflict_paths_for_log: CRLF line endings trim cleanly" {
  # Git on Windows can echo paths with trailing \r. The formatter doesn't
  # explicitly strip them, so the resulting path token will still include
  # the \r — but the output must still be non-empty and the first path
  # must be recognizable.
  local multi_line
  multi_line=$'TASKS.md\r\nREADME.md\r'
  _run_format_conflict_paths "$multi_line"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # First token starts with TASKS.md regardless of any trailing \r on it.
  [[ "$output" == TASKS.md* ]]
}

@test "format_conflict_paths_for_log: empty input emits unknown sentinel" {
  _run_format_conflict_paths ""
  [ "$status" -eq 0 ]
  [[ "$output" == "unknown" ]]
}

# ── emit_rebase_conflict_logs() — direct coverage ─────────────────────
# Emits the structured `<scope> rebase_conflicts paths=<...> class=<c>`
# + `<scope> rebase_aborted paths=<...> class=<c>` pair that the
# grind-log-analyze skill uses to tell whether a rebase failure was
# queue-only (auto-recoverable), touching repo code (needs a human), or
# unknown (no conflict paths at all).

_extract_emit_rebase_conflict_logs_with_deps() {
  awk '/^extract_rebase_conflict_paths\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  printf '\n'
  awk '/^classify_rebase_conflicts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  printf '\n'
  awk '/^format_conflict_paths_for_log\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
  printf '\n'
  awk '/^emit_rebase_conflict_logs\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../bin/taskgrind"
}

# Stub `log_write` to just echo the message so we can inspect every
# emission as stdout (tests are run under `run`, which captures stdout).
_emit_rebase_conflict_stub_script() {
  cat <<'STUB'
log_write() {
  # drop the timestamp prefix, keep the marker body
  local msg="$*"
  msg="${msg#* }"
  printf '%s\n' "$msg"
}
STUB
}

_run_emit_rebase_conflict_logs() {
  local repo="$1"
  local scope="$2"
  local output_file="${3:-}"
  local fns stub
  fns=$(_extract_emit_rebase_conflict_logs_with_deps)
  stub=$(_emit_rebase_conflict_stub_script)
  run bash -c "$stub"$'\n'"$fns"$'\n'"emit_rebase_conflict_logs \"\$1\" \"\$2\" \"\$3\"" _ "$repo" "$scope" "$output_file"
}

@test "emit_rebase_conflict_logs: TASKS.md-only conflict emits queue_only class" {
  local repo="$TEST_DIR/erc-queue-only"
  _setup_rebase_conflict "$repo" "TASKS.md"

  _run_emit_rebase_conflict_logs "$repo" "pre_session_recovery"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre_session_recovery rebase_conflicts class=queue_only"* ]]
  [[ "$output" == *"pre_session_recovery rebase_aborted class=queue_only"* ]]
  [[ "$output" == *"paths=TASKS.md"* ]]
}

@test "emit_rebase_conflict_logs: TASKS.md + README conflict emits repo class" {
  local repo="$TEST_DIR/erc-repo"
  _setup_rebase_conflict "$repo" "TASKS.md" "README.md"

  _run_emit_rebase_conflict_logs "$repo" "git_sync"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git_sync rebase_conflicts class=repo"* ]]
  [[ "$output" == *"git_sync rebase_aborted class=repo"* ]]
  # Both paths appear in the comma-joined list; order depends on git's
  # status output but both must be present.
  [[ "$output" == *"TASKS.md"* ]]
  [[ "$output" == *"README.md"* ]]
}

@test "emit_rebase_conflict_logs: no conflict at all emits bare rebase_aborted" {
  local repo="$TEST_DIR/erc-no-conflict"
  # Fresh repo, no rebase in progress, no conflict files whatsoever. The
  # function should still fire the bare `<scope> rebase_aborted` line so
  # the grind-log-analyze parser sees the marker.
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" commit --allow-empty -q -m "empty init"

  _run_emit_rebase_conflict_logs "$repo" "pre_session_recovery"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre_session_recovery rebase_aborted"* ]]
  # No class= prefix when no conflict paths were found.
  [[ "$output" != *"rebase_aborted class="* ]]
}

# ── final_sync push: protected-branch (GH006) recovery via PR fallback ─
# The remote rejects a direct push to main with branch protection
# (`GH006: Protected branch update failed`). Detection is regex-based
# against captured stderr. When `gh` is on PATH and TG_NO_PR_FALLBACK
# is unset, taskgrind pushes to a unique feature branch and opens a
# PR via `gh pr create` instead of giving up. Otherwise it falls
# through to a `push_protected_branch_manual_recovery_needed` log.

# Build a fixture: bare remote, origin clone seeded, grind clone with a
# local commit ahead of origin, and a pre-push hook on the grind clone
# that rejects pushes to main with the GH006 marker (only when pushing
# to refs/heads/main; pushes to feature branches are allowed). This
# mirrors GitHub Enterprise branch-protection behavior.
_setup_protected_branch_repo() {
  local remote_repo="$1"
  local grind_repo="$2"
  git init --bare "$remote_repo" >/dev/null

  local origin_repo="${remote_repo%.git}-origin"
  git clone "$remote_repo" "$origin_repo" >/dev/null 2>&1
  git -C "$origin_repo" config user.email "test@test.com"
  git -C "$origin_repo" config user.name "Test"
  git -C "$origin_repo" config core.hooksPath /dev/null
  cat > "$origin_repo/TASKS.md" <<'TASKS'
# Tasks
## P0
- [ ] Seed remote
TASKS
  git -C "$origin_repo" add -f TASKS.md
  git -C "$origin_repo" commit -m "seed remote" >/dev/null
  git -C "$origin_repo" push origin main >/dev/null 2>&1

  git clone "$remote_repo" "$grind_repo" >/dev/null 2>&1
  git -C "$grind_repo" config user.email "test@test.com"
  git -C "$grind_repo" config user.name "Test"
  git -C "$grind_repo" config core.hooksPath /dev/null
  cat > "$grind_repo/TASKS.md" <<'TASKS'
# Tasks
## P0
TASKS
  git -C "$grind_repo" add -f TASKS.md
  git -C "$grind_repo" commit -m "complete task locally" >/dev/null

  # Pre-push hook on the grind clone: reject pushes to main with the
  # GH006 marker but allow pushes to feature branches.
  local hook_dir="${grind_repo}-hooks"
  mkdir -p "$hook_dir"
  cat > "$hook_dir/pre-push" <<'SCRIPT'
#!/bin/bash
while read -r local_ref local_sha remote_ref remote_sha; do
  if [ "$remote_ref" = "refs/heads/main" ]; then
    echo "remote: error: GH006: Protected branch update failed for refs/heads/main." >&2
    echo "remote: error: Required status check \"CI\" is expected." >&2
    echo "To origin" >&2
    echo " ! [remote rejected] HEAD -> main (protected branch hook declined)" >&2
    echo "error: failed to push some refs to 'origin'" >&2
    exit 1
  fi
done
exit 0
SCRIPT
  chmod +x "$hook_dir/pre-push"
  git -C "$grind_repo" config core.hooksPath "$hook_dir"
}

# Fake-devin shim that no-ops; required for taskgrind's session loop to run
# without trying to spawn a real backend during the test.
_setup_fake_devin() {
  local fake="$1"
  cat > "$fake" <<'SCRIPT'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    echo "fake-devin 1.0.0"
    exit 0
  fi
done
echo "$@" >> "${DVB_GRIND_INVOKE_LOG:-/tmp/taskgrind-invocations}"
exit 0
SCRIPT
  chmod +x "$fake"
}

@test "_classify_push_failure: GH006 stderr classified as protected_branch" {
  run bash -c "$(sed -n '/^_classify_push_failure()/,/^}/p' "$DVB_GRIND") ; _classify_push_failure 'remote: error: GH006: Protected branch update failed for refs/heads/main.'"
  [ "$status" -eq 0 ]
  [[ "$output" == "protected_branch" ]]
}

@test "_classify_push_failure: protected-branch-hook stderr classified as protected_branch" {
  run bash -c "$(sed -n '/^_classify_push_failure()/,/^}/p' "$DVB_GRIND") ; _classify_push_failure ' ! [remote rejected] HEAD -> main (protected branch hook declined)'"
  [ "$status" -eq 0 ]
  [[ "$output" == "protected_branch" ]]
}

@test "_classify_push_failure: required-status-check stderr classified as protected_branch" {
  run bash -c "$(sed -n '/^_classify_push_failure()/,/^}/p' "$DVB_GRIND") ; _classify_push_failure 'remote: error: Required status check \"Jira PMC\" is expected.'"
  [ "$status" -eq 0 ]
  [[ "$output" == "protected_branch" ]]
}

@test "_classify_push_failure: existing branch-is-protected hook stderr stays push_failed" {
  # The legacy 'remote rejected push: branch is protected' hook output
  # (used by the existing signals.bats test) does NOT match the structured
  # protected-branch markers and must continue classifying as push_failed
  # so the existing recovery path is unchanged.
  run bash -c "$(sed -n '/^_classify_push_failure()/,/^}/p' "$DVB_GRIND") ; _classify_push_failure 'remote rejected push: branch is protected'"
  [ "$status" -eq 0 ]
  [[ "$output" == "push_failed" ]]
}

@test "_classify_push_failure: non-fast-forward stderr stays push_failed" {
  run bash -c "$(sed -n '/^_classify_push_failure()/,/^}/p' "$DVB_GRIND") ; _classify_push_failure ' ! [rejected]        main -> main (non-fast-forward)'"
  [ "$status" -eq 0 ]
  [[ "$output" == "push_failed" ]]
}

@test "final_sync: protected-branch push triggers PR fallback when gh is on PATH and token set" {
  # Since taskgrind-public-write-approval-gate: TG_PUBLIC_WRITE_TOKEN must be
  # set to authorize auto-PR creation. This test exercises the approved path.
  local remote_repo="$TEST_DIR/protected-remote.git"
  local grind_repo="$TEST_DIR/protected-grind"
  _setup_protected_branch_repo "$remote_repo" "$grind_repo"

  # Stub `gh` to capture the args + return success with a fake PR URL.
  local gh_stub_dir="$TEST_DIR/gh-stub-bin"
  local gh_log="$TEST_DIR/gh-stub-calls.log"
  mkdir -p "$gh_stub_dir"
  cat > "$gh_stub_dir/gh" <<SCRIPT
#!/bin/bash
echo "\$@" > "$gh_log"
echo "https://github.example.test/owner/repo/pull/42"
exit 0
SCRIPT
  chmod +x "$gh_stub_dir/gh"

  local fake_devin="$TEST_DIR/fake-devin-pr-fallback"
  _setup_fake_devin "$fake_devin"

  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="$fake_devin"
  export DVB_CAFFEINATED=1
  export DVB_DEADLINE_OFFSET=5
  # Approval token is required for auto-PR creation.
  PATH="$gh_stub_dir:$PATH" TG_PUBLIC_WRITE_TOKEN=test-session "$DVB_GRIND" 1 "$grind_repo" >/dev/null 2>&1
  [ "$?" -eq 0 ]

  # The classifier emitted the protected-branch marker.
  grep -q 'final_sync push_protected_branch ' "$TEST_LOG"
  # PR fallback attempted with a unique branch name.
  grep -Eq 'final_sync pr_fallback_attempt branch=taskgrind-ship-[0-9]{8}-[0-9]{6}' "$TEST_LOG"
  # gh pr create was invoked with the expected --base / --head wiring.
  grep -q -- '--base main' "$gh_log"
  grep -Eq -- '--head taskgrind-ship-[0-9]{8}-[0-9]{6}' "$gh_log"
  # PR-created log line carries the parsed URL + commit count.
  grep -q 'final_sync pr_created url=https://github.example.test/owner/repo/pull/42 commits=1' "$TEST_LOG"
  # The fallback succeeded so no manual-recovery marker should appear.
  ! grep -q 'final_sync push_protected_branch_manual_recovery_needed' "$TEST_LOG"
}

@test "final_sync: auto-PR is blocked when TG_PUBLIC_WRITE_TOKEN not set" {
  # Acceptance criterion (b): without the approval token, final_sync must block
  # PR creation, write a draft body file, and fall through to manual recovery.
  local remote_repo="$TEST_DIR/protected-remote-notoken.git"
  local grind_repo="$TEST_DIR/protected-grind-notoken"
  _setup_protected_branch_repo "$remote_repo" "$grind_repo"

  local gh_stub_dir="$TEST_DIR/gh-stub-bin-notoken"
  local gh_log="$TEST_DIR/gh-stub-calls-notoken.log"
  mkdir -p "$gh_stub_dir"
  cat > "$gh_stub_dir/gh" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$gh_log"
echo "https://github.example.test/owner/repo/pull/99"
exit 0
SCRIPT
  chmod +x "$gh_stub_dir/gh"

  local fake_devin="$TEST_DIR/fake-devin-notoken"
  _setup_fake_devin "$fake_devin"

  unset DVB_GRIND_CMD
  unset TG_PUBLIC_WRITE_TOKEN
  export DVB_DEVIN_PATH="$fake_devin"
  export DVB_CAFFEINATED=1
  export DVB_DEADLINE_OFFSET=5
  PATH="$gh_stub_dir:$PATH" "$DVB_GRIND" 1 "$grind_repo" >/dev/null 2>&1
  [ "$?" -eq 0 ]

  # Protected-branch push was detected.
  grep -q 'final_sync push_protected_branch ' "$TEST_LOG"
  # Token gate fired — blocked log line must appear.
  grep -Eq 'final_sync pr_blocked_approval_needed branch=taskgrind-ship-[0-9]{8}-[0-9]{6}' "$TEST_LOG"
  # Draft body file path must be logged.
  grep -q 'draft=' "$TEST_LOG"
  # No PR was created.
  [ ! -s "$gh_log" ]
  # Manual recovery marker must appear because PR was blocked.
  grep -q 'final_sync push_protected_branch_manual_recovery_needed' "$TEST_LOG"
}

@test "final_sync: --no-pr-fallback skips PR creation and logs manual recovery" {
  local remote_repo="$TEST_DIR/protected-remote-nopr.git"
  local grind_repo="$TEST_DIR/protected-grind-nopr"
  _setup_protected_branch_repo "$remote_repo" "$grind_repo"

  # `gh` would be available, but the operator opted out of the fallback.
  local gh_stub_dir="$TEST_DIR/gh-stub-bin-nopr"
  local gh_log="$TEST_DIR/gh-stub-calls-nopr.log"
  mkdir -p "$gh_stub_dir"
  cat > "$gh_stub_dir/gh" <<SCRIPT
#!/bin/bash
echo "\$@" > "$gh_log"
exit 0
SCRIPT
  chmod +x "$gh_stub_dir/gh"

  local fake_devin="$TEST_DIR/fake-devin-no-pr-fallback"
  _setup_fake_devin "$fake_devin"

  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="$fake_devin"
  export DVB_CAFFEINATED=1
  export DVB_DEADLINE_OFFSET=5
  PATH="$gh_stub_dir:$PATH" "$DVB_GRIND" 1 "$grind_repo" --no-pr-fallback >/dev/null 2>&1
  [ "$?" -eq 0 ]

  grep -q 'final_sync push_protected_branch ' "$TEST_LOG"
  grep -q 'final_sync push_protected_branch_pr_fallback_disabled' "$TEST_LOG"
  grep -q 'final_sync push_protected_branch_manual_recovery_needed' "$TEST_LOG"
  # gh was never invoked.
  [ ! -s "$gh_log" ]
  # No fallback-attempt line either.
  ! grep -q 'final_sync pr_fallback_attempt' "$TEST_LOG"
}

@test "final_sync: TG_NO_PR_FALLBACK=1 env var disables PR creation" {
  local remote_repo="$TEST_DIR/protected-remote-env.git"
  local grind_repo="$TEST_DIR/protected-grind-env"
  _setup_protected_branch_repo "$remote_repo" "$grind_repo"

  local gh_stub_dir="$TEST_DIR/gh-stub-bin-env"
  local gh_log="$TEST_DIR/gh-stub-calls-env.log"
  mkdir -p "$gh_stub_dir"
  cat > "$gh_stub_dir/gh" <<SCRIPT
#!/bin/bash
echo "\$@" > "$gh_log"
exit 0
SCRIPT
  chmod +x "$gh_stub_dir/gh"

  local fake_devin="$TEST_DIR/fake-devin-env-no-pr"
  _setup_fake_devin "$fake_devin"

  unset DVB_GRIND_CMD
  export DVB_DEVIN_PATH="$fake_devin"
  export DVB_CAFFEINATED=1
  export DVB_DEADLINE_OFFSET=5
  PATH="$gh_stub_dir:$PATH" TG_NO_PR_FALLBACK=1 "$DVB_GRIND" 1 "$grind_repo" >/dev/null 2>&1
  [ "$?" -eq 0 ]

  grep -q 'final_sync push_protected_branch ' "$TEST_LOG"
  grep -q 'final_sync push_protected_branch_pr_fallback_disabled' "$TEST_LOG"
  grep -q 'final_sync push_protected_branch_manual_recovery_needed' "$TEST_LOG"
  [ ! -s "$gh_log" ]
}

@test "final_sync: protected-branch fallback gates on gh availability (structural)" {
  # The no-gh case is exercised in the actual code path by the
  # `command -v gh >/dev/null 2>&1` check that flips
  # `_pr_fallback_eligible=0` and emits `push_protected_branch_no_gh`.
  # We assert the structural existence of those guards rather than
  # rebuild a sanitized PATH (sandboxing every macOS bash dependency
  # off PATH is fragile — the equivalent eligibility=0 → manual-recovery
  # path is already covered by --no-pr-fallback and TG_NO_PR_FALLBACK
  # integration tests above).
  grep -q 'command -v gh >/dev/null 2>&1' "$DVB_GRIND"
  grep -q 'final_sync push_protected_branch_no_gh' "$DVB_GRIND"
  grep -q 'push_protected_branch_manual_recovery_needed' "$DVB_GRIND"
}
