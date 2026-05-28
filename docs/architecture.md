# Scaffold Tool Architecture

## Overview

The scaffold tool has two surfaces working in lock-step:

1. **`scaffold.sh`** — the Bash executor. Source of truth for orchestration.
   Runs an 11-phase pipeline and can be invoked directly by a human or by
   the Claude skill.
2. **`/scaffold-app` Claude skill** (at `.claude/skills/scaffold-app/SKILL.md`)
   — a thin wrapper that runs a recommendation step (asks the user a handful
   of questions, picks sensible defaults), emits a config YAML, and shells
   out to `scaffold.sh --config <file>`.

The skill never duplicates orchestration logic. If a phase needs to change,
the change lives in `scaffold.sh`.

## Run flow

The 11-phase pipeline (`scaffold.sh:main`):

```
+-------------------------------------+
| 1. phase_preflight                  |   tools on PATH, bash >= 4
| 2. phase_load_or_prompt_config      |   --config file OR interactive prompts
| 3. phase_validate_config            |   schema check; bail on error
| 4. phase_recommend          [u-02]  |   recommendation engine
| 5. phase_confirm            [u-02]  |   operator confirms recommendation
| 6. phase_create_target_dir          |   fail-fast on non-empty dir (exit 2)
| 7. phase_abp_new            [u-02]  |   `abp new <project_name> ...`
| 8. phase_apply_overlays             |   iterate template/, substitute, copy
| 9. phase_run_post_init_commands     |   migrations, install-libs, etc. [u-10]
| 10. phase_github_repo_init  [u-10]  |   gh repo create + push
| 11. phase_handoff           [u-10]  |   print operator checklist
+-------------------------------------+
```

Phases marked `[u-NN]` are stubs in unit-01 and get real bodies from the
named downstream unit.

The model is borrowed straight from
`discovery.md ## Scaffold Run Flow` — keep the phase names exactly matching
so unit-03..unit-10 can plug into known slots.

## Overlay convention

`template/` mirrors the scaffolded repo's layout. Files in `template/` are
applied AFTER `abp new` writes its baseline; the overlay either creates
new files (`docker-compose.yml`, `terraform/`, `.github/workflows/`) or
overwrites ABP-shipped scaffolding with the LinkHub-grade version.

Tags used in unit specs / discovery to classify each overlay file:

| Tag | Meaning |
|---|---|
| `[FIXED]`     | Same content in every scaffolded app; no substitution. Copied verbatim. |
| `[CONFIG]`    | Contains `${VAR}` tokens substituted from the config. |
| `[ASK_USER]`  | Operator-tunable post-scaffold; ships a `REPLACE_ME` placeholder. |

Layout convention:

- Flat tree mirroring the scaffolded app. `template/docker-compose.yml`
  goes to `<target>/docker-compose.yml`; `template/src/Foo.cs.tmpl` goes
  to `<target>/src/Foo.cs`.
- Plain files are passed through `substitute_file` (single-pass
  `envsubst`).
- `.tmpl`-suffixed files are passed through `substitute_tmpl` (two-pass:
  `envsubst` + `awk` conditional-block strip; suffix removed on output).

## Substitution engine

`lib/substitute.sh` exports two helpers:

- `substitute_file <path>` — `envsubst` with an explicit allowlist
  (`PROJECT_NAME`, `GITHUB_OWNER`, `DBMS`, ...) so host env vars don't
  accidentally leak in. Binary files (detected via `file --mime`) are
  skipped to avoid corrupting them.
- `substitute_tmpl <path>` — same envsubst pass, then `awk` strips
  `{{#if <flag>}}...{{/if}}` blocks based on `IF_<FLAG>` env vars set by
  the orchestrator. Output is written to the path minus the `.tmpl`
  suffix; the source `.tmpl` is removed.

Both helpers fail loudly if any unresolved `${VAR}` tokens remain after
substitution (envsubst silently expands missing vars to the empty string,
which is a trap — we re-grep and exit non-zero).

## How to extend

- **Add a new knob:**
  1. Add a leaf to `scaffold-config-schema.yml`.
  2. Export a matching env var in `_export_config_env` (scaffold.sh).
  3. Add the var to the allowlist in `lib/substitute.sh`.
  4. (If conditional-only) add an `IF_<FLAG>` export.
  5. Add the prompt to `phase_load_or_prompt_config` if you want
     interactive support.
  6. Reference `${NEW_VAR}` in `template/...` overlay files.

- **Add a new overlay file:**
  1. Drop it under `template/<target-path>` (use `.tmpl` if it needs
     conditional blocks).
  2. `phase_apply_overlays` iterates `template/` and dispatches
     `substitute_file` / `substitute_tmpl` automatically — no code change
     needed in `scaffold.sh`.

- **Add a new phase:**
  1. Append a `phase_<name>` function to `scaffold.sh`.
  2. Bump `STEP_TOTAL`.
  3. Add a call site in `main`.

## Rollback / re-run

The scaffold tool is greenfield-only in v1: it refuses to write into a
non-empty target dir (exits 2 with a clear message). To redo a scaffold:

```bash
# Local cleanup
rm -rf <target-dir>

# Remote cleanup (if `gh repo create` already ran via phase_github_repo_init)
gh repo delete <owner>/<project_name_lower> --yes

# Re-run
./scaffold.sh --config my-app.yml
```

There is intentionally no in-place "update" mode in v1. If the operator
wants to add a new overlay file to an existing scaffolded repo, they
either copy it manually or re-scaffold into a fresh dir and diff.

## Relationship to the Claude skill

The `/scaffold-app` Claude skill (populated by unit-02) does two things
the Bash tool can't do on its own:

1. Hold a conversation with the user to elicit project requirements
   (instead of forcing them to know every knob up-front).
2. Generate a config YAML from the conversation, write it to a temp
   file, and call `scaffold.sh --config <file>`.

Everything else — the actual `abp new` invocation, overlay application,
GitHub repo creation — is in `scaffold.sh`. The skill is a UX wrapper,
not a parallel implementation.
