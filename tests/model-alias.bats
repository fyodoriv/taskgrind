#!/usr/bin/env bats
# Direct unit-style coverage for dvb_resolve_model_alias() in lib/constants.sh.
#
# dvb_resolve_model_alias reads the newline-separated DVB_MODEL_ALIASES table
# and powers every alias shortcut the docs promise — opus, sonnet, haiku,
# swe, codex, gpt. The only existing coverage is implicit integration tests
# such as `--model alias resolves before backend invocation` in
# tests/features.bats, which means a future edit to the alias table or the
# parsing loop could silently change which concrete model ID `sonnet`
# resolves to without a focused failure.
#
# This suite sources lib/constants.sh in each test (matching the established
# pattern for dvb_format_duration coverage in tests/logging.bats) and asserts
# that every documented alias in the README / man page plus "unknown values
# pass through unchanged" behaves as promised. A doc-drift guard also fails
# if the DVB_MODEL_ALIASES table and the README alias list disagree on the
# set of aliases so a future addition to one file forces the other to follow.

load test_helper

_source_constants() {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../lib/constants.sh"
}

@test "dvb_resolve_model_alias: opus resolves to claude-opus-4-7-max" {
  _source_constants
  result=$(dvb_resolve_model_alias "opus")
  [[ "$result" == "claude-opus-4-7-max" ]]
}

@test "dvb_resolve_model_alias: sonnet resolves to a claude-sonnet-* model id" {
  _source_constants
  result=$(dvb_resolve_model_alias "sonnet")
  [[ "$result" == claude-sonnet-* ]]
}

@test "dvb_resolve_model_alias: haiku resolves to a claude-haiku-* model id" {
  _source_constants
  result=$(dvb_resolve_model_alias "haiku")
  [[ "$result" == claude-haiku-* ]]
}

@test "dvb_resolve_model_alias: swe resolves to an swe-* model id" {
  _source_constants
  result=$(dvb_resolve_model_alias "swe")
  [[ "$result" == swe-* ]]
}

@test "dvb_resolve_model_alias: codex resolves to a gpt-*-codex model id" {
  _source_constants
  result=$(dvb_resolve_model_alias "codex")
  [[ "$result" == gpt-*-codex ]]
}

@test "dvb_resolve_model_alias: gpt resolves to a gpt-* model id that is not codex" {
  _source_constants
  result=$(dvb_resolve_model_alias "gpt")
  [[ "$result" == gpt-* ]]
  [[ "$result" != *-codex ]]
}

@test "dvb_resolve_model_alias: unknown alias passes through unchanged" {
  _source_constants
  result=$(dvb_resolve_model_alias "not-a-real-alias")
  [[ "$result" == "not-a-real-alias" ]]
}

@test "dvb_resolve_model_alias: empty string passes through unchanged" {
  _source_constants
  result=$(dvb_resolve_model_alias "")
  [[ -z "$result" ]]
}

@test "dvb_resolve_model_alias: quoted multi-word value passes through unchanged" {
  _source_constants
  result=$(dvb_resolve_model_alias "gpt-5.4 XHigh thinking fast")
  [[ "$result" == "gpt-5.4 XHigh thinking fast" ]]
}

@test "dvb_resolve_model_alias: alias resolution is deterministic across repeated calls" {
  _source_constants
  a=$(dvb_resolve_model_alias "opus")
  b=$(dvb_resolve_model_alias "opus")
  [[ "$a" == "$b" ]]
}

@test "doc-drift: DVB_MODEL_ALIASES table matches the alias set documented in README.md" {
  _source_constants
  local table_aliases
  table_aliases=$(printf '%s\n' "$DVB_MODEL_ALIASES" \
    | awk -F= 'NF > 0 { print $1 }' \
    | sort -u \
    | paste -sd, -)

  # README documents the aliases as backtick-quoted single words in the
  # "Model selection" feature bullet. Extract every backtick token on that
  # line and filter down to the ones that correspond to alias keys (lower-
  # case kebab-free single words that also appear in the alias table).
  local readme_path="$BATS_TEST_DIRNAME/../README.md"
  local readme_aliases
  readme_aliases=$(awk '/short aliases/ {print}' "$readme_path" \
    | grep -oE '`[a-z]+`' \
    | tr -d '`' \
    | sort -u \
    | paste -sd, -)

  [[ -n "$table_aliases" ]]
  [[ -n "$readme_aliases" ]]
  [[ "$table_aliases" == "$readme_aliases" ]]
}

@test "doc-drift: DVB_MODEL_ALIASES table matches the alias set documented in man/taskgrind.1" {
  _source_constants
  local table_aliases
  table_aliases=$(printf '%s\n' "$DVB_MODEL_ALIASES" \
    | awk -F= 'NF > 0 { print $1 }' \
    | sort -u \
    | paste -sd, -)

  # Man page documents aliases as \fBname\fR tokens in the --model
  # description. Extract every such token and filter to names that also
  # appear in the alias table to avoid matching unrelated bold words.
  local man_path="$BATS_TEST_DIRNAME/../man/taskgrind.1"
  local man_aliases
  man_aliases=$(awk '/^\\fBopus\\fR/,/current preferred model IDs\./' "$man_path" \
    | grep -oE '\\fB[a-z]+\\fR' \
    | sed 's|\\fB||; s|\\fR||' \
    | sort -u \
    | paste -sd, -)

  [[ -n "$table_aliases" ]]
  [[ -n "$man_aliases" ]]
  [[ "$table_aliases" == "$man_aliases" ]]
}
