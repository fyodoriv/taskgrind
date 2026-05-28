#!/usr/bin/env python3
"""Validate .devin/skills/*/SKILL.md frontmatter contract.

Checks per skill:
  - File exists at .devin/skills/<dir>/SKILL.md.
  - Frontmatter delimiters: starts with `---` and contains a closing `---`.
  - `name:` field is present, lowercase, kebab-case (lowercase letters,
    digits, hyphens only).
  - `name:` value matches the parent directory name.
  - `description:` field is present and non-empty (block-scalar `>` or
    inline string both supported).
  - Body after the closing `---` exists and is non-empty.

Exit codes:
  0 — every SKILL.md in the .devin/skills tree is valid.
  1 — at least one SKILL.md violates the contract (errors printed to stderr).

Usage:
  scripts/validate-skills.py [<skills-dir>]

Default skills-dir is `.devin/skills` resolved relative to the repo root
(the script's parent's parent).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def validate_one(skill_md: Path) -> list[str]:
    errors: list[str] = []
    root = repo_root()
    try:
        rel = skill_md.relative_to(root)
    except ValueError:
        rel = skill_md

    try:
        text = skill_md.read_text(encoding="utf-8")
    except OSError as e:
        return [f"{rel}: cannot read file: {e}"]

    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        errors.append(f"{rel}:1: first line must be `---` frontmatter delimiter")
        return errors

    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break
    if end_idx is None:
        errors.append(f"{rel}: missing closing `---` frontmatter delimiter")
        return errors

    front = "\n".join(lines[1:end_idx])
    body = "\n".join(lines[end_idx + 1 :]).strip()

    name_match = re.search(r"^name:\s*(\S+)\s*$", front, re.MULTILINE)
    if not name_match:
        errors.append(f"{rel}: frontmatter is missing `name: <kebab-case>` field")
    else:
        name = name_match.group(1)
        if not NAME_RE.match(name):
            errors.append(
                f"{rel}: name `{name}` must be lowercase kebab-case "
                f"(letters, digits, hyphens only)"
            )
        parent = skill_md.parent.name
        if name != parent:
            errors.append(
                f"{rel}: name `{name}` does not match directory `{parent}`"
            )

    desc_block = re.search(
        r"^description:\s*(?:>[-]?\s*\n((?:[ \t]+.*\n?)+)|(\S.*))",
        front,
        re.MULTILINE,
    )
    if not desc_block:
        errors.append(f"{rel}: frontmatter is missing `description:` field")
    else:
        desc = (desc_block.group(1) or desc_block.group(2) or "").strip()
        if not desc:
            errors.append(f"{rel}: `description:` field is empty")

    if not body:
        errors.append(f"{rel}: body after frontmatter is empty")

    return errors


def main() -> int:
    if len(sys.argv) > 1:
        skills_dir = Path(sys.argv[1])
    else:
        skills_dir = repo_root() / ".devin" / "skills"

    if not skills_dir.is_dir():
        print(f"validate-skills: no skills directory at {skills_dir}", file=sys.stderr)
        return 0

    skills = sorted(skills_dir.glob("*/SKILL.md"))
    if not skills:
        print(f"validate-skills: no SKILL.md files under {skills_dir}", file=sys.stderr)
        return 0

    all_errors: list[str] = []
    for skill in skills:
        all_errors.extend(validate_one(skill))

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}", file=sys.stderr)
        print(
            f"\nvalidate-skills: {len(all_errors)} error(s) across "
            f"{len(skills)} skill(s)",
            file=sys.stderr,
        )
        return 1

    print(f"validate-skills: {len(skills)} skill(s) OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
