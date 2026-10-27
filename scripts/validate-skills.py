#!/usr/bin/env python3
"""Validate repo-local skills: .agents/skills/<name>/SKILL.md.

Checks the basic contract: '---' frontmatter delimiters, a lowercase
hyphenated directory name that equals the frontmatter `name`, a non-empty
`description`, and a constraints section ('## Constraints', '## Guardrails',
or '## Rules'). Prints one line per problem; exits 1 when any exist.

Usage: scripts/validate-skills.py [skills-dir]   (default .agents/skills)
"""
import pathlib
import re
import sys

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
RULES_RE = re.compile(r"^## (Constraints|Guardrails|Rules)\b", re.M)


def frontmatter(text):
    """Return (fields, body) or None when the delimiters are missing."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return None
    fields, key = {}, None
    for line in lines[1:end]:
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if m:
            key = m.group(1)
            value = m.group(2).strip()
            fields[key] = "" if value in (">", "|", ">-", "|-") else value
        elif key and line.startswith((" ", "\t")):
            fields[key] = (fields[key] + " " + line.strip()).strip()
    return fields, "\n".join(lines[end + 1:])


def check(path):
    rel = f"{path.parent.name}/{path.name}"
    problems = []
    parsed = frontmatter(path.read_text(encoding="utf-8"))
    if parsed is None:
        return [f"{rel}: missing '---' frontmatter delimiters"]
    fields, body = parsed
    dirname = path.parent.name
    name = fields.get("name", "")
    if name != dirname:
        problems.append(f"{rel}: name '{name}' does not match directory '{dirname}'")
    if not NAME_RE.match(dirname):
        problems.append(f"{rel}: directory name is not lowercase-hyphenated")
    if not fields.get("description", "").strip():
        problems.append(f"{rel}: description is empty")
    if not RULES_RE.search(body):
        problems.append(f"{rel}: no '## Constraints', '## Guardrails', or '## Rules' section")
    return problems


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".agents/skills")
    skills = sorted(root.glob("*/SKILL.md"))
    problems = [p for s in skills for p in check(s)]
    for p in problems:
        print(p)
    if problems:
        print(f"validate-skills: {len(problems)} problem(s) in {root}", file=sys.stderr)
        return 1
    print(f"validate-skills: {len(skills)} skill(s) OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
