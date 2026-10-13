# Documentation map

Find the doc that answers your question. Rows are grouped by type
([Diátaxis](https://diataxis.fr/)): how-to guides solve one task, reference
states facts, and explanation gives the why.

Audience: **human** = people who run or review taskgrind; **agent** = coding
agents that change this repo; **both** = either.

New `docs/*.md` file? Add a row here in the same PR. `tests/docs-contract.bats`
fails when a doc is missing from this map.

## Start

| Doc | Answers | Audience |
|---|---|---|
| [`../README.md`](../README.md) | What is taskgrind, how do I install and run it, which flags and env vars exist? | human |
| [`../AGENTS.md`](../AGENTS.md) | How do I change this repo fast and safely? Commands, routing table, gotchas. | agent |
| [`../man/taskgrind.1`](../man/taskgrind.1) | The full CLI reference (`man taskgrind`). | both |

## How-to guides

| Doc | Answers | Audience |
|---|---|---|
| [`user-stories.md`](user-stories.md) | How do operators run taskgrind in practice, with commands and sample output? | human |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | How do I set up, test, and send a change? | both |

## Reference

| Doc | Answers | Audience |
|---|---|---|
| [`resume-state.md`](resume-state.md) | Which fields does `--resume` save, and how are they checked and restored? | both |
| [`defaults-rationale.md`](defaults-rationale.md) | Why does each `TG_*` default have its value? | both |
| [`../SECURITY.md`](../SECURITY.md) | Which versions are supported, and how do I report a problem? | human |

## Explanation

| Doc | Answers | Audience |
|---|---|---|
| [`architecture.md`](architecture.md) | Why is taskgrind built this way: loop, prompt, watchdogs, git sync? | both |
| [`research/`](research/) | Research notes behind past decisions. | agent |

## Repo-local skills

| Doc | Answers | Audience |
|---|---|---|
| [`../.agents/skills/`](../.agents/skills/) | Skills taskgrind sessions use in this repo: audit loop, log analysis, repo setup. | agent |
