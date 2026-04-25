# Tasks

<!-- policy: keep runtime files /bin/bash 3.2 compatible (guarded by tests/bash-compat.bats) -->
<!-- policy: run `make check` before claiming a task complete; remove the task block in the same commit that ships the fix -->

## P2

- [ ] Direct unit coverage for `resolve_script_path()` locks the symlink-resolution contract for `make install`
  - **ID**: resolve-script-path-direct-coverage
  - **Tags**: test, install, symlink
  - **Details**: `resolve_script_path()` at `bin/taskgrind:67-82` runs before
    any constants are sourced, walks symlink chains to resolve the real script
    path, and is what lets `make install` symlink `/usr/local/bin/taskgrind` →
    `bin/taskgrind` while still letting the executable resolve
    `$TASKGRIND_DIR/lib/constants.sh` correctly. A regression here breaks
    `make install`, brew packaging, and every caller that runs taskgrind via a
    wrapper symlink — but there is no direct unit-style coverage today. Add a
    bats suite that extracts the function via the awk pattern already used for
    `extract_first_task_context` and `format_conflict_paths_for_log`, sources
    it in a subshell, and asserts the resolver handles: plain file (no
    symlink), single-hop relative symlink, single-hop absolute symlink, nested
    symlink chains two and three hops deep, a symlink whose target is in a
    parent directory (`../bin/taskgrind`), and a symlink whose target is in a
    sibling directory. Use `mktemp -d` per test and clean up in `teardown()`.
    The goal is to pin behavior so a future edit to the `while [[ -L ]]` loop
    can't silently break packaging.
  - **Files**: `tests/install.bats` (or a new focused
    `tests/resolve-script-path.bats`), `bin/taskgrind`
  - **Acceptance**: New `@test` cases exercise `resolve_script_path` directly
    without spawning a grind; each supported topology above has at least one
    assertion on the resolved absolute path; `make test TESTS=tests/<file>.bats`
    plus `make check` both pass.

- [ ] Document the exported `TG_INSTANCE_ID` contract for child sessions and wrapper scripts
  - **ID**: document-tg-instance-id
  - **Tags**: docs, multi-instance, env-var
  - **Details**: `bin/taskgrind:1404` does
    `export TG_INSTANCE_ID="$_dvb_slot"` so any AI session, skill, or
    supervisor that inspects its own environment can tell which slot claimed
    the lock (slot 0 owns git sync; higher slots should defer). There is a
    structural test guarding the export in
    `tests/multi-instance.bats:227-236`, but no user-facing doc mentions the
    variable at all — `README.md` shows only `TG_MAX_INSTANCES`, the Env table
    stops at `TG_SESSION_GRACE`, and `taskgrind --help` / `man taskgrind`
    never name it. That makes the contract agent-only tribal knowledge,
    exactly the kind of doc drift the repo policy flags. Add a short
    subsection (or one row in the env var table) that states: (a) `TG_INSTANCE_ID`
    is taskgrind-set, not user-set; (b) its value equals the claimed slot
    (`0` owns between-session git sync, `1+` skip it); (c) skills and wrapper
    scripts can read it to coordinate. Mirror the same wording in `man/taskgrind.1`
    under the multi-instance section and in `README.md` under "Concurrent
    instances on one repo". Do **not** promise it as a user-settable input —
    only as a read-only export.
  - **Files**: `README.md`, `man/taskgrind.1`, `docs/architecture.md`
  - **Acceptance**: `README.md` and the man page both mention `TG_INSTANCE_ID`
    with the read-only / slot-tied contract wording; a new `tests/basics.bats`
    assertion (or extension to `tests/multi-instance.bats`) greps for the
    string in both docs so future edits can't silently drop it; `make check`
    passes.

- [ ] Document the log-file retention policy alongside the cleanup routine
  - **ID**: document-log-retention-policy
  - **Tags**: docs, logs, ops
  - **Details**: The temp-file cleanup block at
    `bin/taskgrind:871-881` purges orphaned `taskgrind-exec.*`,
    `taskgrind-lock-*`, `taskgrind-ses-*`, `taskgrind-gsy-*`,
    `taskgrind-att-*`, `taskgrind-*.session.out`, `taskgrind-*.git-sync`, and
    `taskgrind-*.task-attempts*` files older than one day, but deliberately
    leaves the primary `taskgrind-<date>-<repo>-<pid>.log` files so the
    `grind-log-analyze` skill can run post-mortems. On macOS `TMPDIR` is
    usually swept by the OS, but on Linux and in long-lived CI containers
    those log files accumulate — and today `$TMPDIR/taskgrind-*.log` already
    shows nine logs on this host dating back a day. The policy is intentional
    but undocumented, so operators reading
    `README.md#Monitoring` or `SECURITY.md` can't tell whether to add their
    own logrotate, a cron sweep, or just trust the OS. Add a short
    "Log file retention" note under `README.md#Monitoring` that (a) names the
    filename pattern, (b) says cleanup explicitly skips `.log` files, (c)
    recommends a user-owned rotation on Linux / long-lived hosts, and (d)
    reminds that the `grind-log-analyze` skill consumes these files. Mirror
    the retention bullet in `SECURITY.md` near the existing `600` permissions
    note.
  - **Files**: `README.md`, `SECURITY.md`, `bin/taskgrind` (comment near the
    cleanup block so the rationale doesn't drift)
  - **Acceptance**: README and SECURITY.md each contain a paragraph or bullet
    explicitly naming the retention policy and the reason (post-mortem
    analysis); a new doc-drift test (pattern like
    `tests/basics.bats` "README documents …") greps for the policy wording so
    future edits can't silently drop it; `make check` passes.

## P3

- [ ] CI test cache key invalidates when `tests/verify-bash32-compat.sh` changes
  - **ID**: ci-cache-include-bash32-helper
  - **Tags**: ci, cache, correctness
  - **Details**: `.github/workflows/check.yml:51` computes the test cache key
    from `Makefile`, `bin/taskgrind`, `lib/*.sh`, `tests/*.bats`, and
    `tests/test_helper.bash`, but **not** `tests/verify-bash32-compat.sh` —
    even though `tests/bash-compat.bats` is the guard that actually sources /
    runs that helper to enforce the Bash 3.2 contract documented in
    `AGENTS.md` and `README.md`. An edit to `verify-bash32-compat.sh`
    therefore leaves the cached green status in place, so a regression in the
    compatibility guard can be missed by CI. Extend the `hashFiles(...)`
    tuple in `check.yml` to include `tests/verify-bash32-compat.sh` (and,
    while there, `install.sh` which `make lint` also shellchecks). Keep the
    key single-line / copy-pasteable — this is purely a correctness fix, not
    a refactor.
  - **Files**: `.github/workflows/check.yml`
  - **Acceptance**: The `hashFiles(...)` call in the `test` job includes
    `tests/verify-bash32-compat.sh` and `install.sh`; a grep-style test in
    `tests/basics.bats` (or a new `tests/ci-cache.bats`) asserts both paths
    appear in the cache key so future edits can't silently drop them;
    `make check` passes.


