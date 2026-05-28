# abp-aidlc-template

One-command ABP scaffold with LinkHub-grade infra / CI / DevOps / observability
baked in. Generates a fresh ABP solution plus everything needed to run it: a
Dockerized stack, Hetzner staging on Terraform, GitHub Actions CI/CD, an
AI-DLC workflow, observability hooks (OTel + Prometheus), and operator
runbooks.

## What you get

- A scaffolded ABP repo on GitHub (private or public, your choice), pre-wired
  for local-dev (`docker compose up`), CI (lint + build + test workflows),
  and staging deploy (Hetzner Cloud + Cloudflare DNS).
- A LinkHub-grade `.ai-dlc/` workflow seeded in the repo so the team can run
  `/ai-dlc:elaborate` on day one.
- An opinionated stack: PostgreSQL, EF Core, Angular, OTel/Prometheus, Caddy
  edge, Sentry SPA reporting — all individually toggle-able via the config
  schema.

## Install

Path A (system-wide):

```bash
sudo git clone https://github.com/codarteinc/abp-aidlc-template /opt/abp-aidlc-template
sudo ln -sf /opt/abp-aidlc-template/scaffold.sh /usr/local/bin/scaffold-app
```

Path B (per-user):

```bash
git clone https://github.com/codarteinc/abp-aidlc-template ~/abp-aidlc-template
~/abp-aidlc-template/scaffold.sh --help
```

`scaffold.sh` uses `BASH_SOURCE`-relative path resolution to locate `lib/`,
`template/`, and the config schema — so it works from any cwd regardless of
where you cloned it.

## Usage

```bash
# Interactive (prompts for project name, GitHub owner, etc.)
./scaffold.sh

# Config-file mode (skips prompts; use this for CI or repeat runs)
./scaffold.sh --config my-app.yml

# Smoke-test the pipeline without writing anything
./scaffold.sh --config scaffold-config.example.yml --dry-run

# Help banner (enumerates every config knob)
./scaffold.sh --help
```

## Architecture

The scaffold tool has two surfaces:

1. **`scaffold.sh`** — the Bash executor. Ground truth. Runs an 11-phase
   pipeline (preflight, load/validate config, `abp new`, apply overlays from
   `template/`, post-init commands, GitHub repo init, operator handoff).
2. **`/scaffold-app` Claude skill** — a thin wrapper that adds a
   recommendation step (asks the user a handful of questions, picks sensible
   defaults), writes the config YAML, and shells out to `scaffold.sh`.

The skill NEVER duplicates orchestration logic — it just generates the config
file and invokes `scaffold.sh`. Full architecture in
[`docs/architecture.md`](docs/architecture.md).

## Status

| Unit | Owner | Status |
|---|---|---|
| 01 — foundation skeleton (this repo's bootstrap)         | this unit | [x] |
| 02 — recommendation engine + `abp new` + skill body      | unit-02   | [ ] |
| 03 — .NET project structure overlays                     | unit-03   | [ ] |
| 04 — observability (OTel + Prometheus + Sentry)          | unit-04   | [ ] |
| 05 — security (CSP + HSTS + auth + secrets handling)     | unit-05   | [ ] |
| 06 — Docker + docker-compose stack                       | unit-06   | [ ] |
| 07 — Terraform (Hetzner + Cloudflare)                    | unit-07   | [ ] |
| 08 — GitHub Actions CI/CD                                | unit-08   | [ ] |
| 09 — AI-DLC + Claude skills                              | unit-09   | [ ] |
| 10 — `phase_run_post_init_commands` + handoff + repo init| unit-10   | [ ] |
| 11 — smoke tests + operator docs (`USAGE.md`, runbook)   | unit-11   | [ ] |

## Requirements

Required on the operator's machine:

- `bash >= 4`
- `git`
- `gh` (GitHub CLI, authenticated)
- `yq` (the Mike Farah Go yq — `yq --version` should mention `mikefarah`)
- `envsubst` (`gettext-base` package on Debian/Ubuntu)
- `awk` (GNU awk or BSD awk both work for the templating pass)
- `file`

For scaffolding (checked by `phase_preflight` once units 02-10 land):

- `abp` CLI
- `dotnet`
- `node` + `yarn`
- `docker` + `docker compose`
- `terraform`

Optional (cosmetic only — fallback uses plain `read -p`):

- [`gum`](https://github.com/charmbracelet/gum) — nicer interactive prompts.

## Linux-only (v1)

v1 is tested on `ubuntu-latest` only. macOS support is on the v2 roadmap —
`envsubst` (BSD vs GNU) and `sed -i` syntax differ between platforms and
need shimming. On macOS today, run from a Linux container (Docker, OrbStack,
WSL) or wait for v2.

## Contributing

Local quality gates before pushing:

```bash
shellcheck scaffold.sh lib/*.sh scripts/*.sh
./scripts/check-token-coverage.sh
bats tests/   # populated in unit-11
```

Open issues + PRs at https://github.com/codarteinc/abp-aidlc-template.

## License

[MIT](LICENSE) — consistent with codarteinc OSS releases.
