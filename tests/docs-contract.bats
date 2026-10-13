#!/usr/bin/env bats
# Docs contract: the agent guide stays a short router, every top-level doc is
# on the docs map, and the README opens with a quickstart and the map link.
# The contract is shared with agentbrew and dotfiles (agentbrew docs/agent-guide-baseline.md).

REPO_DIR="$BATS_TEST_DIRNAME/.."
AGENT_GUIDE_MAX_BYTES=10000

@test "docs contract: AGENTS.md has the required H2 sections in order" {
  local expected actual
  expected=$'## Start here\n## Commands\n## Where to change what\n## Rules\n## Gotchas\n## Delivery\n## Docs upkeep'
  actual="$(grep -E '^## ' "$REPO_DIR/AGENTS.md")"
  [ "$actual" = "$expected" ] || {
    echo "expected:"; echo "$expected"; echo "actual:"; echo "$actual"
    return 1
  }
}

@test "docs contract: AGENTS.md stays within the always-loaded byte budget" {
  local bytes
  bytes="$(wc -c <"$REPO_DIR/AGENTS.md" | tr -d ' ')"
  [ "$bytes" -le "$AGENT_GUIDE_MAX_BYTES" ] || {
    echo "AGENTS.md is $bytes bytes; budget is $AGENT_GUIDE_MAX_BYTES. Move detail into docs/ and link it."
    return 1
  }
}

@test "docs contract: CLAUDE.md resolves to AGENTS.md" {
  [ -L "$REPO_DIR/CLAUDE.md" ]
  [ "$(readlink "$REPO_DIR/CLAUDE.md")" = "AGENTS.md" ]
}

@test "docs contract: every top-level docs/*.md is on the docs map" {
  local map="$REPO_DIR/docs/README.md" doc name missing=""
  [ -f "$map" ]
  for doc in "$REPO_DIR"/docs/*.md; do
    name="$(basename "$doc")"
    [ "$name" = "README.md" ] && continue
    grep -qF "]($name)" "$map" || missing="$missing $name"
  done
  [ -z "$missing" ] || {
    echo "add a row to docs/README.md for:$missing"
    return 1
  }
}

@test "docs contract: every link on the docs map resolves" {
  local map="$REPO_DIR/docs/README.md" target broken=""
  while IFS= read -r target; do
    case "$target" in http*|\#*) continue ;; esac
    [ -e "$REPO_DIR/docs/${target%%#*}" ] || broken="$broken $target"
  done < <(grep -oE '\]\([^)]+\)' "$map" | sed -E 's/^\]\((.*)\)$/\1/')
  [ -z "$broken" ] || {
    echo "broken links on docs/README.md:$broken"
    return 1
  }
}

@test "docs contract: README opens with a quickstart and the docs map link" {
  local head
  head="$(head -n 60 "$REPO_DIR/README.md")"
  grep -q '^```bash' <<<"$head"
  grep -qF '(docs/README.md)' <<<"$head"
}
