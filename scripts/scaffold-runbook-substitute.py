#!/usr/bin/env python3
"""scripts/scaffold-runbook-substitute.py — derive docs/scaffold-runbook.md
from a LinkHub-style staging runbook by performing the project-name +
intent + region substitution pass that unit-11 needs.

Usage:
  scaffold-runbook-substitute.py <input.md> <output.md>

The substitution is mechanical: every transformation is a regex
replacement, and the script prints a gate at the end that fails if any
'LinkHub' / 'linkhub' / 'codarteinc' compound identifier escaped (e.g.
'LinkHubAppService') so the operator catches a missed pattern.

Run once when bootstrapping unit-11; the produced
docs/scaffold-runbook.md is then committed verbatim.
"""

from __future__ import annotations

import re
import sys

LIVING_RUNBOOK_NOTE = """> **Living runbook.** This file is the scaffolded starting point — every
> ABP + AI-DLC repo gets a copy. As your operator experience grows, add
> project-specific gotchas, IP allowlist commits, and outage post-mortems
> directly here. The scaffold tool will not overwrite this file.

"""

# Patterns we want to genericize away from the LinkHub repo's intent
# history. Each entry maps a regex to its replacement. Order matters —
# the more specific patterns come first.
SUBSTITUTIONS = [
    # Project name compounds (already done by sed but defense-in-depth).
    # `LinkHub_App` (the OpenIddict client id), `__LinkHub_App__` (env-var
    # double-underscore separator), etc.
    (re.compile(r"LinkHub_"), "{{ProjectName}}_"),
    (re.compile(r"linkhub_"), "{{project_name_lower}}_"),
    (re.compile(r"\bLinkHub\b"), "{{ProjectName}}"),
    (re.compile(r"\blinkhub\b"), "{{project_name_lower}}"),
    (re.compile(r"\bLINKHUB_"), "{{PROJECTNAME_UPPER}}_"),
    (re.compile(r"codarteinc/linkhub"), "{{github_owner}}/{{project_name_lower}}"),
    (re.compile(r"\bcodarteinc\b"), "{{github_owner}}"),
    # Compound identifiers that still reference LinkHub.
    (re.compile(r"\bLinkHub([A-Z][A-Za-z]*)"), r"{{ProjectName}}\1"),
    # Specific commit SHAs from the LinkHub history.
    (
        re.compile(
            r"\b(?:49ca8d6|ee793e3|84b149e|c1dff16|d4a1859|b6cd75b)\b"
        ),
        "<last-green-commit-on-main>",
    ),
    # Intent slugs / discovery references — strip to generic phrasing.
    (
        re.compile(
            r"\[`\.ai-dlc/hetzner-deploy/intent\.md`\]"
            r"\(\.\./\.ai-dlc/hetzner-deploy/intent\.md\)"
        ),
        "the original intent (operator-managed at `.ai-dlc/<your-intent>/intent.md`)",
    ),
    (
        re.compile(
            r"\[`\.ai-dlc/hetzner-deploy/discovery\.md`\]"
            r"\(\.\./\.ai-dlc/hetzner-deploy/discovery\.md\)"
        ),
        "your `.ai-dlc/<your-intent>/discovery.md`",
    ),
    (
        re.compile(
            r"\[`\.ai-dlc/hetzner-deploy/`\]"
            r"\(\.\./\.ai-dlc/hetzner-deploy/\)"
        ),
        "your `.ai-dlc/<your-intent>/` tree",
    ),
    (re.compile(r"`hetzner-deploy`"), "your hetzner-deploy intent"),
    (re.compile(r"hetzner-deploy intent"), "your hetzner-deploy intent"),
    (re.compile(r"`multi-env-terraform`"), "the multi-env-terraform intent"),
    # Hetzner / Cloudflare placeholders.
    (re.compile(r"\bnbg1\b"), "{{hetzner_location}}"),
    (re.compile(r"\bhel1\b"), "{{hetzner_location}}"),
    (re.compile(r"\bcx23\b"), "{{hetzner_server_type}}"),
    (re.compile(r"\bcx22\b"), "{{hetzner_server_type}}"),
]


def transform(text: str) -> str:
    for pattern, replacement in SUBSTITUTIONS:
        text = pattern.sub(replacement, text)
    return text


def insert_living_runbook_note(text: str) -> str:
    """Insert the "Living runbook" callout right after the first heading."""
    lines = text.splitlines(keepends=True)
    if not lines:
        return text
    # First line is the H1; the audience callout starts at line 3. We
    # insert the Living runbook note BEFORE the audience callout so it's
    # the first thing the reader sees after the title.
    return lines[0] + "\n" + LIVING_RUNBOOK_NOTE + "".join(lines[1:]).lstrip("\n")


def gate(text: str, src: str, dst: str) -> int:
    leaks = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        if re.search(r"(LinkHub|linkhub|LINKHUB)", line):
            leaks.append((line_no, line))
        elif re.search(r"\bcodarteinc\b", line):
            leaks.append((line_no, line))
    if leaks:
        sys.stderr.write(
            f"[gate] {len(leaks)} residual LinkHub/codarteinc leaks in {dst}:\n"
        )
        for line_no, line in leaks[:20]:
            sys.stderr.write(f"  {line_no}: {line}\n")
        return 1
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("Usage: scaffold-runbook-substitute.py <input.md> <output.md>\n")
        return 64
    src, dst = argv[1], argv[2]
    with open(src, "r", encoding="utf-8") as fh:
        text = fh.read()
    text = transform(text)
    text = insert_living_runbook_note(text)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(text)
    return gate(text, src, dst)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
