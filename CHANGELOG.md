# Changelog

All notable changes to abp-aidlc-template are documented here. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-05-30

First production release. Eleven units of work, each landed in a
verifiable slice with bats coverage, shellcheck-clean shell, and a
verification artifact in `verification-unit-NN.md`.

### Added

#### Foundation (unit-01)

- `scaffold.sh` orchestration entry-point with a 15-phase pipeline
  (preflight, load config, validate, recommend, confirm, create target,
  abp new, apply overlays, security overlay, docker overlay, terraform
  overlay, github-workflows overlay, post-init, github repo init,
  handoff).
- `lib/` helper modules: `log.sh`, `validate-config.sh`, `prompt.sh`,
  `substitute.sh`.
- `scaffold-config-schema.yml` (typed schema with `enum`, `regex`,
  `default`, `default_from` validation primitives) and
  `scaffold-config.example.yml` (canonical reference config).
- `LICENSE` (MIT), placeholder `template/` overlay tree, repo-level
  `.editorconfig` + `.gitignore`.
- `docs/architecture.md` (overlay layout, substitution model, phase
  contracts).

#### Recommendation engine + abp new (unit-02)

- `/scaffold-app` Claude skill at `.claude/skills/scaffold-app/SKILL.md`
  with a 7-step flow (description → recommendation → confirm →
  overrides → write config → invoke `scaffold.sh` → handoff).
- `recommendation-prompt.md` loaded by the skill at runtime.
- `phase_abp_new` flag-composition logic with `--abp-version` CLI flag,
  `ABP_VERSION` env-var fallback, and `abp --version` autodetect.
- `tests/abp_new_flags.bats` exercises the flag matrix without
  invoking real `abp` via the `--dry-run-abp-new` test-only flag.
- `scripts/smoke-abp-new.sh` end-to-end harness (real `abp new` +
  `dotnet build`).

#### .NET project structure overlays (unit-03)

- `lib/dotnet-overlay.sh` with `ScaffoldBlock` insertion-block helper +
  order-independent marker merging via `merge_markers_into_existing`.
- `template/` tree carrying the reference project shape: 12 `.csproj`
  projects, `common.props`, `global.json`, `NuGet.Config`,
  `Directory.DotSettings`, root namespace + table-prefix wiring.
- Mapperly-based DTO mapping (NOT AutoMapper) baked in via
  `{{PROJECTNAME}}ApplicationMappers.cs`.
- `template/.markdownlint.json` (canonical lint config).

#### Observability (unit-04)

- OTel + Prometheus + Serilog with trace correlation:
  `AddOpenTelemetry` + `AddPrometheusExporter` + `AddOtlpExporter`
  block, custom `{{ProjectName}}.<Feature>` meter naming convention,
  Serilog `Enrich.WithSpan()` enricher emitting
  `[trace=<32-hex> span=<16-hex>]` on every log line.
- Auth-gated health endpoints: `/health-live` (anonymous, empty body),
  `/health-ready` + `/metrics` (HealthChecksPolicy gated to `admin`
  OR `health-monitor` role), `App:Metrics:Auth=false` override.
- Sentry SPA no-op contract: `REPLACE_ME_AT_DEPLOY` DSN means no
  `Sentry.init` call; `error-reporting.module.ts` +
  `server-error-reporting.interceptor.ts` + specs ported.
- `template/docs/observability.md` operator runbook (OTLP / Grafana /
  Sentry wiring).
- `dynamic-env.json` + `dynamic-env.json.template` for deploy-time
  Sentry DSN injection.

#### Security (unit-05)

- CSP middleware at
  `{{PROJECTNAME}}.HttpApi.Host/Middleware/ContentSecurityPolicyMiddleware.cs`
  with `App:Csp:Mode=report-only` default + nginx report-uri stub.
- HSTS 30-day starter (operators ramp to 1-year after soak).
- Four secrets templates: `appsettings.secrets.json.template` (host +
  DbMigrator), `appsettings.Development.local.json.template`,
  `environment.local.ts.template`.
- Admin-password fail-fast logic in the DbMigrator (rejects unset key
  + known-leaked placeholder list).
- OpenIddict prod-vs-dev cert switch in `PreConfigureServices`.
- `etc/generate-dev-openiddict-cert.sh` for greenfield certificates.

#### Docker + Compose stack (unit-06)

- `docker-compose.yml.template` (production-shaped multi-service stack:
  api / web / db / migrator / caddy).
- `docker-compose.dev.yml.template` (developer inner-loop overrides).
- `docker-compose.staging.yml.template` (staging-only overrides).
- `Caddyfile.dev` + `Caddyfile.staging` with `LE-staging` ACME default
  and operator flip path to production.
- `Dockerfile.local.template` per project (api / dbmigrator / web).
- `nginx.conf.template` SPA bundle with `/getEnvConfig` runtime-env
  endpoint.
- `.dockerignore.tmpl` + `.env.template` + `.env.staging.template`.

#### Terraform — Hetzner + Cloudflare (unit-07)

- `terraform/modules/{{ProjectName}}-env/` reusable env module
  (Hetzner VM + Cloudflare DNS, optional Floating IP, lifecycle hooks
  for SSH key rotation).
- `terraform/staging/` single-env workspace (HCP Terraform backend,
  `execution_mode = local`).
- `terraform/staging2.example/` second-env reference (operator copies
  into `terraform/staging2/` for multi-env work).
- `terraform/staging/scripts/lint-cloud-init.sh` operator gate.
- `terraform/staging/rebootstrap.sh.template` rescue script.

#### GitHub Actions workflows (unit-08)

- `cicd.yml.template`: shellcheck + dotnet build + dotnet test + yarn
  lint + yarn build + yarn test on every push and PR.
- `dependabot.yml.template`: monthly bumps for npm + nuget + docker +
  github-actions ecosystems.
- `dependabot-auto-merge.yml.template`: semver-patch/minor auto-merge
  after CICD green (with the title-parse + ecosystem-exclude gates).
- `runner-cache-cleanup.yml.template`: monthly stale-runner-cache GC.
- `staging-deploy.yml.template` + `staging-rollback.yml.template`:
  push-button deploy + per-service rollback with the
  `confirm_schema_compatible=yes` migrator gate.
- Four reusable Terraform composites:
  `_terraform-{apply,plan,drift,destroy}.yml.template`.
- Four per-env wrappers for the shipped `staging` env:
  `staging-terraform-{apply,plan,drift,destroy}.yml.template`.

#### Claude + AI-DLC overlay (unit-09)

- `template/.claude/settings.json` enabling `ai-dlc`,
  `chrome-devtools-mcp`, `typescript-lsp`, `frontend-design`,
  `csharp-lsp` plugins.
- `template/.claude/settings.local.json.template` per-developer
  override stub.
- 18 `template/.claude/skills/abp-*/SKILL.md` files bulk-copied
  (frozen at scaffold release; operators update independently).
- `template/CLAUDE.md.tmpl` with UI- and DB-conditional rendering
  (Angular / MVC / Blazor sections; EF Core / MongoDB migrations
  sections).
- `template/.ai-dlc/settings.yml.tmpl` UI-conditional default-passes
  (`[product, dev]` for UI != none; `[dev]` only otherwise).
- `template/.ai-dlc/ELABORATION.md.tmpl` with conditional yarn-install
  step for `ui_angular`.
- `template/.ai-dlc/knowledge/README.md` empty-day-one marker.

#### Post-init + GitHub repo init + handoff (unit-10)

- `lib/post-init.sh`: `dotnet ef migrations add Initial` (gated by
  `db_provider=ef` AND template has separate EF Core project) +
  `abp install-libs` (gated by UI=mvc/angular/blazor-server) +
  `yarn install` (gated by UI=angular) + `dotnet build` smoke gate.
- `lib/github-init.sh`: `gh repo create` + initial commit + push +
  branch protection setup.
- `lib/handoff.sh`: operator one-time-actions checklist with exact
  `gh api` / `openssl` / HCP-UI commands.
- New operator-visible flag `--skip-gh-create` (and test-only
  `--dry-run-github` + `--skip-post-init`).

#### Smoke tests + operator docs (unit-11)

- `tests/smoke/` end-to-end smoke harness (gated behind
  `RUN_SMOKE_TESTS=1`) covering 3 knob combinations: the reference
  combo (app/angular/ef-pg), app-nolayers, and mvc-ui. Each combo
  asserts scaffold exit 0, `dotnet build`, `dotnet test`, the UI build
  (yarn or `abp install-libs` as applicable), and zero residue
  references to the upstream reference project's name.
- `tests/smoke/_smoke_helper.bash` shared setup/teardown with toolchain
  skip gates (`abp`, `dotnet`, `yq`) so the suite is benign on a fresh
  checkout.
- `tests/smoke/README.md` coverage-gap disclosure (multi-tenancy,
  mongodb, microservice, api-only — all v2 follow-up).
- `tests/fixtures/smoke/*.yml` schema-valid configs for the 3 combos.
- `README.md` rewritten with skill-vs-CLI quick-start, v1.0.0 status
  table, three example invocations, and `/opt/abp-aidlc-template`
  install path.
- `USAGE.md` full flag + knob matrix with 3 worked examples and a
  troubleshooting catalogue.
- `docs/scaffold-runbook.md` operator runbook covering first-time
  setup, deploy, rollback, SSH/IP rotation, Cloudflare flip, and
  troubleshooting (derived from the reference staging runbook with
  `sed -E` substitution + post-substitution residue grep).
- `scripts/run-tests.sh` PATH-discovery wrapper for `bats`.
- `scripts/lint-template-workflows.sh` + `scripts/lint-template-terraform.sh`
  CI helpers that envsubst the templated workflow / terraform files and
  hand them to actionlint / `terraform fmt` / `terraform validate`.
- `.github/workflows/ci.yml` extended with `markdownlint`,
  `actionlint`, `terraform-fmt`, `terraform-validate`, and `smoke` jobs.
  The smoke job runs on `workflow_dispatch` + nightly schedule with a
  45-minute timeout per matrix shard.

### Fixed

- 17 pre-existing failures in `tests/overlay_observability.bats` — the
  fake host module fixture now includes `PreConfigureServices(...)` so
  `merge_markers_into_existing` finds all three required anchors. Total
  bats suite: 163/163 green.
