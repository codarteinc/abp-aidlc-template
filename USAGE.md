<!-- Populated by unit-11 (operator docs). -->

## Recommendation engine + `abp new` wrapper (unit-02)

The scaffold tool exposes two complementary entry points:

### Path A: Claude skill (`/scaffold-app`)

Invoke from a Claude Code session. The skill asks for a free-text app
description, calls the recommendation engine (loads
`recommendation-prompt.md` as the model's instruction block), presents
the recommended ABP solution shape as a confirmable table, optionally
walks the operator through per-knob overrides, then shells out to
`scaffold.sh --config <generated-config>`.

See `.claude/skills/scaffold-app/SKILL.md` for the 7-step flow.

### Path B: standalone `scaffold.sh --config`

For CI / repeatable runs where the config is already known:

```bash
scaffold.sh --config my-app.yml
```

In this mode `phase_recommend` and `phase_confirm` are documented
no-ops (the recommendation engine is the skill's responsibility; a
config file already represents a confirmed shape). `phase_abp_new`
composes the `abp new` invocation from the validated config and runs
it inside the target directory's parent.

### ABP version resolution

`phase_abp_new` resolves the ABP framework version in this priority
order:

1. `--abp-version <X.Y.Z>` CLI flag.
2. `ABP_VERSION` environment variable (useful for CI pinning).
3. Auto-detect via `abp --version | head -1 | awk '{print $NF}'`.

**Gotcha:** the `abp` CLI's `--version` reports the CLI version (e.g.
`3.0.2`), which is NOT always the same as the ABP framework version
the scaffolded project uses. LinkHub's tested baseline is framework
version `10.3.0`. If autodetect picks up a CLI version that `abp new`
rejects as a framework version, pass `--abp-version 10.3.0` explicitly:

```bash
scaffold.sh --config my-app.yml --abp-version 10.3.0
```

### Local smoke test (slow — not in CI)

To verify `phase_abp_new` end-to-end against a real `abp new` +
`dotnet build`:

```bash
./scripts/smoke-abp-new.sh
```

Runs the LinkHub baseline combo into a `/tmp/abp-aidlc-template-smoke-…`
scratch dir, asserts the assembled flag count, runs `abp new`, then
runs `dotnet build` on the generated solution. The scratch dir is
cleaned up via `trap EXIT` — copy `build.log` out before the trap
fires if you need it for post-mortem.

If `abp new` prompts for `abp login`, run `abp login` first and
re-invoke the script. The LinkHub baseline (LeptonX Lite + free
modules) does not require a paid license.

### Flag-composition tests (CI)

`tests/abp_new_flags.bats` exercises the flag-composition matrix
without invoking the real `abp` binary, via the test-only
`--dry-run-abp-new` flag. The flag is intentionally undocumented in
`scaffold.sh --help`; operators never see it.

## Claude Code + AI-DLC overlay (unit-09)

The `template/.claude/` and `template/.ai-dlc/` trees ship the
day-one Claude Code + AI-DLC config that every scaffolded repo
inherits:

- **`template/.claude/settings.json`** — enables the upstream
  `ai-dlc`, `chrome-devtools-mcp`, `typescript-lsp`,
  `frontend-design`, and `csharp-lsp` plugins. No skill enumeration
  is needed; Claude Code auto-discovers any `.claude/skills/<name>/
  SKILL.md` in the repo.
- **`template/.claude/settings.local.json.template`** — per-
  developer override stub. Operators copy it to
  `.claude/settings.local.json` (gitignored) on first use.
- **`template/.claude/skills/abp-*/SKILL.md`** — 18 ABP-specific
  Claude skills bulk-copied verbatim from LinkHub. These are
  reusable across any ABP project and freeze at scaffold release
  time (operators update independently via plugin manager).
- **`template/CLAUDE.md.tmpl`** — UI- and DB-conditional project
  guide. UI-specific bullets (Angular proxy, MVC/Blazor wwwroot
  libs, Vitest) only render when the matching UI is selected; the
  EF Core migrations bullet only renders when `db_provider=ef` (a
  MongoDB-specific bullet replaces it otherwise). LinkHub-specific
  "Where things live" and "Runtime artifacts" sections are dropped
  and replaced with placeholder blocks pointing operators at
  LinkHub's CLAUDE.md as the canonical shape.
- **`template/.ai-dlc/settings.yml.tmpl`** — UI-conditional AI-DLC
  defaults. `default_passes` is `[product, dev]` for every UI value
  except `ui=none`, which collapses to `[dev]` only (no UI surface
  to design against).
- **`template/.ai-dlc/ELABORATION.md.tmpl`** — generalized worktree
  + ticket-sync rules. The yarn-install snippet inside the
  worktree-secrets-copy block is `{{#if ui_angular}}`-wrapped.
- **`template/.ai-dlc/knowledge/README.md`** — empty-on-day-one
  marker, points operators at `/ai-dlc:elaborate` to synthesize the
  knowledge artifacts on first deep run.

`tests/overlay_claude_aidlc.bats` exercises the per-file rendering
for `ui=angular,db=ef` (Angular section + EF migrations bullet
present, MongoDB / MVC absent), `ui=mvc,db=mongodb` (Angular absent,
MongoDB + wwwroot/libs present, EF migrations absent),
`ui=none,db=mongodb` (no UI-conditional content at all), and
asserts no LinkHub feature-specific residue beyond the two
explicit reference links in the placeholder blocks.
