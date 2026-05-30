# abp-aidlc-template

> One-command ABP scaffold with grade-A infra / CI / DevOps / observability
> baked in.

Generates a fresh ABP solution plus everything needed to run it: a
Dockerized stack, Hetzner staging on Terraform, GitHub Actions CI/CD,
an AI-DLC workflow seeded for day-one elaboration, observability hooks
(OTel + Prometheus + Sentry), and a full operator runbook.

## What you get

- **A scaffolded ABP repo on GitHub** (private or public, your choice),
  pre-wired for local-dev (`docker compose up`), CI (lint + build +
  test workflows), and staging deploy (Hetzner Cloud + Cloudflare DNS).
- **A grade-A `.ai-dlc/` workflow** seeded so the team can run
  `/ai-dlc:elaborate` from day one. 18 ABP-specific Claude skills are
  bulk-included so Claude Code drives ABP-shaped work correctly.
- **An opinionated stack**: PostgreSQL, EF Core, Angular, OTel /
  Prometheus, Caddy edge, Sentry SPA reporting — every component
  individually toggle-able via the config schema.

## Quick start — two paths

### Path A — Claude skill (recommended)

```bash
git clone https://github.com/codarteinc/abp-aidlc-template /opt/abp-aidlc-template
# Then in a Claude Code session:
/scaffold-app
```

The skill asks for an app description, runs the recommendation engine,
presents a confirmable solution shape, then shells out to `scaffold.sh`.

### Path B — CLI (for CI, repeat runs, automation)

```bash
git clone https://github.com/codarteinc/abp-aidlc-template /opt/abp-aidlc-template
sudo ln -sf /opt/abp-aidlc-template/scaffold.sh /usr/local/bin/scaffold-app
scaffold-app --config my-app.yml
```

Per-user install path also works: `~/abp-aidlc-template`. `scaffold.sh`
uses `BASH_SOURCE`-relative path resolution so cwd doesn't matter.

## Install path

`/opt/abp-aidlc-template` is the canonical system-wide install path
(unit-01 contract). For a per-user install, clone to
`~/abp-aidlc-template` instead — both work; the script discovers its
own `lib/` and `template/` from `BASH_SOURCE`.

## Example invocations

```bash
# Smoke-test the pipeline without writing anything
scaffold.sh --config scaffold-config.example.yml --dry-run

# Generate an app from a known-good config
scaffold.sh --config my-app.yml

# Generate but skip the gh repo create + push step
scaffold.sh --config my-app.yml --skip-gh-create

# Pin the ABP framework version explicitly
scaffold.sh --config my-app.yml --abp-version 10.3.0

# Show the full flag + knob matrix
scaffold.sh --help
```

See [`USAGE.md`](USAGE.md) for the full flag + knob reference, three
worked configs, and the troubleshooting catalogue. See
[`docs/scaffold-runbook.md`](docs/scaffold-runbook.md) for the operator
runbook covering deploy / rollback / IP rotation / Cloudflare flip in
the scaffolded app.

## Architecture

The scaffold tool has two surfaces:

1. **`scaffold.sh`** — the Bash executor. Ground truth. Runs a
   15-phase pipeline (preflight, load/validate config, `abp new`, apply
   overlays from `template/`, security overlay, docker overlay,
   terraform overlay, github-workflows overlay, post-init commands,
   GitHub repo init, operator handoff).
2. **`/scaffold-app` Claude skill** — a thin wrapper that adds a
   recommendation step (asks the user a handful of questions, picks
   sensible defaults), writes the config YAML, and shells out to
   `scaffold.sh`. The skill NEVER duplicates orchestration logic — it
   just generates the config file and invokes `scaffold.sh`.

Full architecture in [`docs/architecture.md`](docs/architecture.md).

## Status — v1.0.0

| Unit | Description | Status |
|---|---|---|
| 01 | Foundation skeleton (`scaffold.sh`, `lib/`, schema, `template/`) | [x] |
| 02 | Recommendation engine + `abp new` + Claude skill | [x] |
| 03 | .NET project structure overlays | [x] |
| 04 | Observability (OTel + Prometheus + Sentry) | [x] |
| 05 | Security (CSP + HSTS + auth + secrets handling) | [x] |
| 06 | Docker + docker-compose stack | [x] |
| 07 | Terraform (Hetzner + Cloudflare) | [x] |
| 08 | GitHub Actions CI/CD | [x] |
| 09 | AI-DLC + Claude skills overlay | [x] |
| 10 | Post-init + GitHub repo init + handoff | [x] |
| 11 | Smoke tests + operator docs (this unit) | [x] |

See [`CHANGELOG.md`](CHANGELOG.md) for the full v1.0.0 deliverables list.

## Requirements

Required on the operator's machine to invoke `scaffold.sh`:

- `bash >= 4`
- `git`
- `gh` (GitHub CLI, authenticated)
- `yq` (the Mike Farah Go yq — `yq --version` should mention `mikefarah`)
- `envsubst` (`gettext-base` package on Debian/Ubuntu)
- `awk` (GNU awk or BSD awk both work for the templating pass)
- `file`

Required for the actual scaffold (checked by `phase_preflight`):

- `abp` CLI (`Volo.Abp.Studio.Cli`)
- `dotnet` (`.NET 10` for the reference shape)
- `node` + `yarn` (for `ui=angular`)
- `docker` + `docker compose`
- `terraform` (`>= 1.10`)

Optional (cosmetic only — fallback uses plain `read -p`):

- [`gum`](https://github.com/charmbracelet/gum) — nicer interactive prompts.

## Linux-only (v1)

v1 is tested on `ubuntu-latest` only. macOS support is on the v2
roadmap — `envsubst` (BSD vs GNU), `sed -i` syntax, and `mktemp -d -t`
template strictness differ between platforms and need shimming. On
macOS today, run from a Linux container (Docker, OrbStack, WSL) or
wait for v2.

## Contributing

Local quality gates before pushing a PR:

```bash
shellcheck scaffold.sh lib/*.sh scripts/*.sh
./scripts/check-token-coverage.sh
./scripts/run-tests.sh                 # fast tier — runs in every PR
RUN_SMOKE_TESTS=1 bats tests/smoke/    # slow tier — opt-in (10-30 min)
```

The fast tier (163 tests) runs on every push and PR. The smoke tier
(`tests/smoke/`) runs on `workflow_dispatch` + nightly schedule in CI
and is opt-in locally — see [`tests/smoke/README.md`](tests/smoke/README.md)
for combo coverage + known v2 gaps.

Open issues + PRs at <https://github.com/codarteinc/abp-aidlc-template>.

## License

[MIT](LICENSE) — consistent with codarteinc OSS releases.
