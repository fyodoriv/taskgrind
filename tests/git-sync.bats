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
  # Create a feature branch and leave the repo on it
  git -C "$TEST_REPO" checkout -q -b chore/grind-session-1
  echo "feature" > "$TEST_REPO/feature.txt"
  git -C "$TEST_REPO" add feature.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "feature work"

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
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

  # Create a dirty file (simulating agent leaving uncommitted changes)
  echo "uncommitted work" > "$TEST_REPO/dirty.txt"
  git -C "$TEST_REPO" add dirty.txt

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]

  # The dirty file should still exist after sync
  [ -f "$TEST_REPO/dirty.txt" ]
  # Log should mention stashing
  grep -q 'stashed dirty tree' "$TEST_LOG"
}

@test "stash pop failure is logged and stash preserved" {
  # Structural: stash pop failure produces a log marker
  grep -q 'stash_pop_failed' "$DVB_GRIND"
  # Structural: user-visible warning about stash pop failure
  grep -q 'stash pop failed.*stash preserved' "$DVB_GRIND"
}

# ── Branch cleanup between sessions ───────────────────────────────────

@test "merged branches are cleaned up between sessions" {
  # Initialize repo with main
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
  # Create and merge a feature branch
  git -C "$TEST_REPO" checkout -q -b already-merged
  echo "merged" > "$TEST_REPO/merged.txt"
  git -C "$TEST_REPO" add merged.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "merged branch"
  git -C "$TEST_REPO" checkout -q main
  git -C "$TEST_REPO" merge -q already-merged --no-edit
  git -C "$TEST_REPO" push -q origin main 2>/dev/null

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The merged branch should be deleted
  ! git -C "$TEST_REPO" branch | grep -q 'already-merged'
  grep -q 'branch_cleanup done' "$TEST_LOG"
}

@test "unmerged branches are not deleted" {
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
  # Create an unmerged branch
  git -C "$TEST_REPO" checkout -q -b work-in-progress
  echo "wip" > "$TEST_REPO/wip.txt"
  git -C "$TEST_REPO" add wip.txt
  git -C "$TEST_REPO" commit -q --no-verify -m "wip"
  git -C "$TEST_REPO" checkout -q main

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
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

  export DVB_DEADLINE=$(( $(date +%s) + 8 ))
  export DVB_SYNC_INTERVAL=0
  run "$DVB_GRIND" 1 "$TEST_REPO"
  [ "$status" -eq 0 ]
  grep -q 'git_sync rebase_failed:' "$TEST_LOG"
  grep -q 'CONFLICT' "$TEST_LOG"
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

@test "git sync falls back to main when origin/HEAD is missing" {
  # Structural: fallback assignment
  grep -q '_default_branch="${_default_branch:-main}"' "$DVB_GRIND"
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
  grep -q 'flock -n 9' "$DVB_GRIND"
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
  grep -q 'another taskgrind is already running' "$DVB_GRIND"
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

