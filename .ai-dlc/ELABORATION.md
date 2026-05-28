# ELABORATION.md — AI-DLC rituals for `abp-aidlc-template`

Read this when running any `/ai-dlc:*` command in this repo.

## Required: Sync tickets to GitHub Issues

Every intent / unit elaborated in this repo lives as a tracked GitHub Issue at
`codarteinc/abp-aidlc-template`. The standard AI-DLC ticketing layer
(`providers.ticketing.type = github-issues` in `.ai-dlc/settings.yml`) handles
the sync. Operators must NOT close or rename the GitHub Issues manually —
let the AI-DLC tooling drive lifecycle so the intent/unit files and the
GitHub state stay aligned.

If an issue ever drifts from a unit file's `ticket:` frontmatter, the
recovery is:

1. Find the right issue (`gh issue list -R codarteinc/abp-aidlc-template --search "<unit-name>"`).
2. Update the unit file's `ticket:` to point at it.
3. Push and let the next AI-DLC ritual reconcile.

## Required: Worktree convention

Each unit branch is checked out in its own worktree under
`.ai-dlc/worktrees/<intent>-<unit>/`. Do NOT switch branches in-place inside
the main checkout — it confuses the AI-DLC review hat and breaks parallel
builders.

```bash
git worktree add .ai-dlc/worktrees/<intent>-<unit> ai-dlc/<intent>/<unit>
cd .ai-dlc/worktrees/<intent>-<unit>
```

When a unit is fully merged + the issue is closed, prune the worktree:

```bash
git worktree remove .ai-dlc/worktrees/<intent>-<unit>
git branch -D ai-dlc/<intent>/<unit>   # if branch still local
```

## Reference

- High-level architecture: [`docs/architecture.md`](../docs/architecture.md).
- Project knowledge (populated on first elaborate run):
  [`.ai-dlc/knowledge/README.md`](knowledge/README.md).
- Operator usage: [`USAGE.md`](../USAGE.md) (populated by unit-11).

## Notes

This file is intentionally short. The scaffold tool is a single-purpose Bash
tool — it has no ABP compliance audit, no secrets-template ritual, no
database migration sequencing. If a future feature pulls in cross-cutting
operational concerns, document the ritual here.
