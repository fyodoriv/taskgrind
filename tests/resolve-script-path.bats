#!/usr/bin/env bats
# Tests for `resolve_script_path()` at the top of `bin/taskgrind` — the
# helper that walks symlink chains so a wrapper symlink (e.g. the one
# `make install` creates at `/usr/local/bin/taskgrind`) can still find
# the real script directory and source `lib/constants.sh`. A regression
# in the `while [[ -L ]]` loop silently breaks `make install`, brew
# packaging, and every wrapper that resolves taskgrind via PATH lookup.
#
# The function runs before any constants are sourced and before any
# argument parsing, so an end-to-end test can't easily exercise its
# behavior without spawning a real grind. Instead this suite extracts
# the function via the same awk pattern used by `extract_first_task_context`
# and `format_conflict_paths_for_log` and runs it in a clean subshell
# against fixture directory trees.

DVB_GRIND="$BATS_TEST_DIRNAME/../bin/taskgrind"

_extract_resolve_script_path() {
  awk '/^resolve_script_path\(\) \{/,/^}$/' "$DVB_GRIND"
}

# Run resolve_script_path against $1 in a clean bash subshell. Echoes
# the function's output to stdout so the caller can compare via
# `[[ "$output" == ... ]]` after `run`.
_run_resolve_script_path() {
  local path="$1"
  local fn
  fn=$(_extract_resolve_script_path)
  # shellcheck disable=SC2016  # $fn contains the literal function definition
  bash -c "$fn"$'\n'"resolve_script_path \"\$1\"" _ "$path"
}

# Canonicalize a directory the same way `resolve_script_path` does
# internally (`cd -P` + `pwd`). Test fixtures live under `mktemp -d`
# which on macOS resolves through `/var/folders → /private/var/folders`,
# so expected values must be canonicalized to match the function's
# output exactly.
_canonical_dir() {
  (cd -P "$1" && pwd)
}

setup() {
  TMP_ROOT="$(mktemp -d)"
}

teardown() {
  if [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  fi
}

@test "resolve_script_path: plain file with no symlink resolves to its own absolute path" {
  local target="$TMP_ROOT/taskgrind"
  echo '#!/bin/bash' > "$target"
  chmod +x "$target"
  local expected
  expected="$(_canonical_dir "$TMP_ROOT")/taskgrind"

  run _run_resolve_script_path "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: single-hop relative symlink resolves through the link" {
  local real_dir="$TMP_ROOT/real"
  mkdir -p "$real_dir"
  echo '#!/bin/bash' > "$real_dir/taskgrind"
  chmod +x "$real_dir/taskgrind"
  ln -s "real/taskgrind" "$TMP_ROOT/wrapper"
  local expected
  expected="$(_canonical_dir "$real_dir")/taskgrind"

  run _run_resolve_script_path "$TMP_ROOT/wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: single-hop absolute symlink resolves through the link" {
  local real_dir="$TMP_ROOT/real"
  mkdir -p "$real_dir"
  echo '#!/bin/bash' > "$real_dir/taskgrind"
  chmod +x "$real_dir/taskgrind"
  ln -s "$real_dir/taskgrind" "$TMP_ROOT/wrapper"
  local expected
  expected="$(_canonical_dir "$real_dir")/taskgrind"

  run _run_resolve_script_path "$TMP_ROOT/wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: two-hop nested symlink chain resolves to the real file" {
  local real_dir="$TMP_ROOT/real"
  mkdir -p "$real_dir"
  echo '#!/bin/bash' > "$real_dir/taskgrind"
  chmod +x "$real_dir/taskgrind"
  ln -s "$real_dir/taskgrind" "$TMP_ROOT/middle"
  ln -s "$TMP_ROOT/middle" "$TMP_ROOT/wrapper"
  local expected
  expected="$(_canonical_dir "$real_dir")/taskgrind"

  run _run_resolve_script_path "$TMP_ROOT/wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: three-hop nested symlink chain resolves to the real file" {
  local real_dir="$TMP_ROOT/real"
  mkdir -p "$real_dir"
  echo '#!/bin/bash' > "$real_dir/taskgrind"
  chmod +x "$real_dir/taskgrind"
  ln -s "$real_dir/taskgrind" "$TMP_ROOT/hop1"
  ln -s "$TMP_ROOT/hop1" "$TMP_ROOT/hop2"
  ln -s "$TMP_ROOT/hop2" "$TMP_ROOT/wrapper"
  local expected
  expected="$(_canonical_dir "$real_dir")/taskgrind"

  run _run_resolve_script_path "$TMP_ROOT/wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: symlink target in parent directory resolves correctly" {
  # Mirrors the brew install layout: a wrapper inside `bin/` points at
  # the real script in `../share/...`. The relative `../bin/taskgrind`
  # form must canonicalize to the absolute path of the real file.
  local install_root="$TMP_ROOT/Cellar/taskgrind/1.0.0"
  local bin_dir="$install_root/bin"
  local share_dir="$install_root/share/taskgrind"
  mkdir -p "$bin_dir" "$share_dir"
  echo '#!/bin/bash' > "$share_dir/taskgrind"
  chmod +x "$share_dir/taskgrind"
  ln -s "../share/taskgrind/taskgrind" "$bin_dir/taskgrind"
  local expected
  expected="$(_canonical_dir "$share_dir")/taskgrind"

  run _run_resolve_script_path "$bin_dir/taskgrind"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: symlink target in sibling directory resolves correctly" {
  local sibling_a="$TMP_ROOT/a"
  local sibling_b="$TMP_ROOT/b"
  mkdir -p "$sibling_a" "$sibling_b"
  echo '#!/bin/bash' > "$sibling_b/taskgrind"
  chmod +x "$sibling_b/taskgrind"
  ln -s "../b/taskgrind" "$sibling_a/wrapper"
  local expected
  expected="$(_canonical_dir "$sibling_b")/taskgrind"

  run _run_resolve_script_path "$sibling_a/wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}

@test "resolve_script_path: chain of relative symlinks across sibling directories resolves correctly" {
  # Mix of relative and absolute hops to exercise both branches of
  # the case statement in the resolver loop. The wrapper lives inside
  # an `inner/` subdir so its `../z/hop2` target resolves to a real
  # sibling rather than escaping the test root.
  local real_dir="$TMP_ROOT/x/real"
  mkdir -p "$real_dir" "$TMP_ROOT/y" "$TMP_ROOT/z" "$TMP_ROOT/inner"
  echo '#!/bin/bash' > "$real_dir/taskgrind"
  chmod +x "$real_dir/taskgrind"
  ln -s "../x/real/taskgrind" "$TMP_ROOT/y/hop1"
  ln -s "$TMP_ROOT/y/hop1" "$TMP_ROOT/z/hop2"
  ln -s "../z/hop2" "$TMP_ROOT/inner/wrapper"
  local expected
  expected="$(_canonical_dir "$real_dir")/taskgrind"

  run _run_resolve_script_path "$TMP_ROOT/inner/wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "$expected" ]]
}
