# INSTALL.md — agent install playbook

An AI agent follows these steps to install or update taskgrind for a person.
Every command also works by hand. Run the steps in order.

## 1. Install or update

- Homebrew present: `brew install fyodoriv/tap/taskgrind`. Already installed: `brew upgrade taskgrind`.
- No Homebrew: `[ -d ~/apps/taskgrind ] || git clone https://github.com/fyodoriv/taskgrind.git ~/apps/taskgrind`, then `cd ~/apps/taskgrind && git pull --rebase && make install`.
- Check: `taskgrind --version` prints a commit hash and date.

## 2. Ask one question

Ask: "Do you only use taskgrind, or do you also contribute to it?"

- Use only: go on with step 3.
- Contribute: use the clone in `~/apps/taskgrind`, read `AGENTS.md`, and run `env -u BASH_ENV make check` once.

## 3. Preflight, and fix each failing line

In the repo the person wants ground, run `taskgrind --preflight .`.
Fix each failing line with the person. The README "Backend setup matrix" and "Troubleshooting" sections name the fix for each message.
Run preflight again until it passes.

## 4. Audit local skills

taskgrind ships repo-local skills in `.agents/skills/` (for example `grind-log-analyze` and `standing-audit-gap-loop`).
Compare them with the skills already on this machine. For each overlap, propose adopt or merge, and act on the person's choice.

## 5. First run

1. `taskgrind --dry-run 1 .` prints the config and the first prompt. Walk the person through it.
2. `taskgrind 1 .` runs a one-hour grind. Show where the log is and what the summary line means.
3. Tell the person that each finished grind writes one content-free line to a local usage log (`TG_USAGE_LOG`). Nothing is uploaded. `TG_USAGE_LOG=off` or `DO_NOT_TRACK=1` stops it.

## 6. Close

List anything that could work better. Offer an issue or a PR on `github.com/fyodoriv/taskgrind` for each one, and post only after the person says yes.
