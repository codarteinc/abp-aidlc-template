# abp-aidlc-template — Usage Reference

Full operator reference for the `scaffold.sh` tool. Read this file when
you want the complete flag matrix, config-knob enumeration, worked
examples, or a quick troubleshooting catalogue. For a one-paragraph
pitch + install, start at [`README.md`](README.md). For the operator
runbook on deploying the scaffolded app to Hetzner staging, see
[`docs/scaffold-runbook.md`](docs/scaffold-runbook.md).

## 1. Two ways to invoke

### 1.1 `/scaffold-app` Claude skill (recommended)

Invoke from a Claude Code session. The skill drives a 7-step flow:

1. Ask for a free-text app description.
2. Call the recommendation engine (loads
   `recommendation-prompt.md` as the model's instruction block).
3. Present the recommended ABP solution shape as a confirmable table.
4. Optionally walk the operator through per-knob overrides.
5. Write the config YAML to disk.
6. Shell out to `scaffold.sh --config <generated-config>`.
7. Surface the operator-handoff checklist at the end.

See `.claude/skills/scaffold-app/SKILL.md` for the implementation
contract.

### 1.2 `scaffold.sh --config` (CI / automation)

For repeatable runs where the config is already known:

```bash
scaffold.sh --config my-app.yml
```

In this mode `phase_recommend` and `phase_confirm` are documented
no-ops (the recommendation engine is the skill's responsibility; a
validated config IS the confirmed shape). Every other phase runs
identically to the skill-driven path.

## 2. Full flag matrix

### 2.1 CLI flags (consumed by `scaffold.sh` directly)

| Flag | Default | Purpose |
|---|---|---|
| `--config <path>` | (interactive) | Skip prompts; load YAML config |
| `--target <dir>` | `./<project_name_lower>` | Override scaffold output dir |
| `--abp-version <X.Y.Z>` | autodetect or `$ABP_VERSION` | Pin ABP framework version |
| `--dry-run` | off | Run pipeline; emit log lines; write nothing |
| `--skip-gh-create` | off | Skip `gh repo create` + branch protection + push |
| `--help`, `-h` | — | Show usage banner with every flag + knob |

Test-only flags (undocumented in `--help`; bats consumers):

| Flag | Purpose |
|---|---|
| `--dry-run-abp-new` | Skip the real `abp new`; emit `ABP_NEW_FLAG: …` lines so bats can assert on flag composition. |
| `--dry-run-github` | Skip real `gh` calls in `phase_github_repo_init`; emit `GH_CMD: …` lines instead. |
| `--skip-post-init` | Skip `dotnet ef migrations add Initial`, `abp install-libs`, `yarn install`, and the post-init `dotnet build`. |

### 2.2 Config-file knobs (validated against `scaffold-config-schema.yml`)

| Knob | Type | Default | Valid values | Recommendation heuristic |
|---|---|---|---|---|
| `project_name` | string | (required) | `^[A-Z][a-zA-Z0-9]+$` | PascalCase noun — becomes the .NET root namespace AND the GitHub repo name (lowercased) |
| `github_owner` | string | (required) | gh user/org slug | The org under which `gh repo create` runs |
| `hcp_org` | string | `= github_owner` | HCP slug | Override only if the HCP Terraform org name differs from the GH org name |
| `abp.template` | enum | `app` | `app`, `app-nolayers`, `module`, `microservice` | `app` for SaaS / line-of-business; `app-nolayers` for prototypes / small CRUD; `module` for reusable libs; `microservice` is v2 |
| `abp.ui` | enum | `angular` | `angular`, `mvc`, `blazor`, `blazor-server`, `none` | `angular` for a polished customer-facing SPA; `mvc` for internal admin; `none` for API-only |
| `abp.db_provider` | enum | `ef` | `ef`, `mongodb` | `ef` for relational / structured-data domains; `mongodb` for document-shape domains |
| `abp.dbms` | enum | `postgresql` | `postgresql`, `sqlserver`, `mysql`, `oracle`, `sqlite` | `postgresql` is the tested baseline (relevant only when `db_provider=ef`) |
| `abp.tiered` | bool | `false` | `true`, `false` | `true` only if AuthServer must run on a separate process (rare in v1) |
| `abp.multi_tenancy` | bool | `false` | `true`, `false` | `true` for SaaS with tenant isolation. `--separate-tenant-schema` is exercised when both `multi_tenancy=true` AND `db_provider=ef` |
| `abp.default_culture` | string | `en` | BCP-47 tag | `en` for English-first; `pt-BR` for Brazilian-Portuguese-first |
| `abp.optional_modules` | array | `[]` | `file-management`, `chat`, `audit-log-ui`, `language-management`, `text-template-management` | Add only what you need on day one |
| `infra.hetzner_location` | string | `hel1` | Hetzner region code | `hel1` (Helsinki) is the baseline; `nbg1` (Nuremberg) for EU-central preference |
| `infra.hetzner_server_type` | string | `cx23` | Hetzner type code | `cx23` is the smallest viable shape (cx22 was retired by Hetzner in 2026) |
| `infra.cloudflare_zone` | string | `REPLACE_ME` | DNS zone | Use `REPLACE_ME` for the first scaffold and bind a real zone before deploy |
| `discord_webhook` | string | (unset) | Discord webhook URL | Optional — `_terraform-apply.yml` tolerates absence |

The schema is the ground truth; run `scaffold.sh --help` to print it
at runtime.

## 3. Worked example 1 — reference combo

The "build something that looks like the reference shape" combo:
`app` template + `angular` UI + `ef` provider + `postgresql` DBMS.

```yaml
# my-app.yml
project_name: MyApp
github_owner: myorg
abp:
  template: app
  ui: angular
  db_provider: ef
  dbms: postgresql
  tiered: false
  multi_tenancy: false
  default_culture: en
  optional_modules: []
infra:
  hetzner_location: hel1
  hetzner_server_type: cx23
  cloudflare_zone: REPLACE_ME
```

Run:

```bash
scaffold.sh --config my-app.yml
```

Expected outcomes (per the v1 smoke-test assertions):

- `MyApp.slnx` builds + tests green.
- `angular/` builds with `yarn build`.
- 13 GitHub Actions workflows present under `.github/workflows/`.
- `gh repo create myorg/myapp --private` runs (unless `--skip-gh-create`).
- Handoff message lists exact `gh api` / `openssl` / HCP-UI commands.

## 4. Worked example 2 — single-layer prototype

```yaml
project_name: QuickPrototype
github_owner: myorg
abp:
  template: app-nolayers
  ui: angular
  db_provider: ef
  dbms: postgresql
infra:
  hetzner_location: hel1
  hetzner_server_type: cx23
  cloudflare_zone: REPLACE_ME
```

Differences vs the reference combo:

- One `.csproj` instead of 12; faster build.
- Feature-based file organization (per the `abp-app-nolayers` skill).
- No separate `Domain.Tests` / `Application.Tests` projects.

## 5. Worked example 3 — MVC internal admin

```yaml
project_name: InternalAdmin
github_owner: myorg
abp:
  template: app
  ui: mvc
  db_provider: ef
  dbms: postgresql
infra:
  hetzner_location: hel1
  hetzner_server_type: cx23
  cloudflare_zone: REPLACE_ME
```

Differences:

- No `angular/` directory.
- `wwwroot/libs/` populated by `abp install-libs`.
- LeptonX MVC theme instead of LeptonX Lite (Angular).
- Razor pages instead of standalone Angular components.

## 6. ABP version resolution

`phase_abp_new` resolves the ABP framework version in this priority order:

1. `--abp-version <X.Y.Z>` CLI flag.
2. `ABP_VERSION` environment variable (useful for CI pinning).
3. Auto-detect via `abp --version | head -1 | awk '{print $NF}'`.

**Gotcha:** the `abp` CLI's `--version` reports the CLI version (e.g.
`3.0.2`), which is NOT always the same as the ABP framework version the
scaffolded project uses. The tested baseline is framework version
`10.3.0`. If autodetect picks up a CLI version that `abp new` rejects
as a framework version, pass `--abp-version 10.3.0` explicitly:

```bash
scaffold.sh --config my-app.yml --abp-version 10.3.0
```

## 7. Local smoke test (slow — not in PR CI)

To verify `phase_abp_new` end-to-end against a real `abp new` +
`dotnet build`:

```bash
./scripts/smoke-abp-new.sh
```

For the full end-to-end smoke harness covering 3 knob combinations,
opt-in via `RUN_SMOKE_TESTS=1`:

```bash
RUN_SMOKE_TESTS=1 bats tests/smoke/
```

Each smoke combo asserts scaffold exit 0, `dotnet build`, `dotnet
test`, the UI build (yarn or `abp install-libs` as applicable), and
zero residue references to the upstream reference project's name.
See [`tests/smoke/README.md`](tests/smoke/README.md) for combo
coverage + known v2 gaps.

## 8. Troubleshooting

Common errors + fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `target directory is not empty; v1 is greenfield-only` | Pre-existing files in target dir | Pick an empty dir or remove existing |
| `abp new` exits 1 with "ABP framework version not found" | CLI version not the same as framework version | Pass `--abp-version 10.3.0` explicitly |
| `dotnet ef migrations add Initial` fails | Wrong dbms / unreachable Postgres | Check `appsettings.secrets.json` Default connection string |
| `gh repo create` exits 422 | Workflow-create-PR not enabled at org level | See "Required repo + org settings" in `docs/scaffold-runbook.md` |
| `terraform validate` fails on `hcloud` provider | `hetznercloud/hcloud ~> 1.63` provider mismatch | Run `terraform init -upgrade` in `terraform/staging/` |
| markdownlint MD041 in `CLAUDE.md.tmpl` | First line is `{{#if ... }}` not `#` | The shipped `.markdownlint.json` disables MD041; ensure it's at repo root |
| `phase_apply_overlays` errors with "anchor not found" | Real `abp new` output drifted from the templated markers file | Verify the host module file still contains `PreConfigureServices(...)`, `ConfigureServices(...)`, and `OnApplicationInitialization(...)` |
| `abp install-libs` hangs | npm network egress blocked | Pre-populate the npm cache or run from a network-reachable host |

The operator-side runbook for the deployed app
([`docs/scaffold-runbook.md`](docs/scaffold-runbook.md)) covers deploy /
rollback / IP rotation / Cloudflare flip / Hetzner outages — read that
when something goes wrong AFTER the scaffold completes.
