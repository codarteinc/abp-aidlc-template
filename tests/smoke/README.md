# Smoke tests (slow tier — `RUN_SMOKE_TESTS=1`)

End-to-end smoke harness. Each test runs `scaffold.sh` against a fresh
tmpdir with a real `abp new` + `dotnet build` + `dotnet test`. Time
budget: 5-10 min per combo.

## Why gated

`abp new` does NuGet + npm fetches each run (~3-5 min uncached). Total
suite runtime is ~20-30 min — too slow for PR-tier CI. We gate behind
`RUN_SMOKE_TESTS=1` and run on `workflow_dispatch` + nightly schedule
only.

## Running locally

```bash
sudo apt-get install bats dotnet-sdk-10.0 nodejs
dotnet tool install -g Volo.Abp.Studio.Cli
RUN_SMOKE_TESTS=1 bats tests/smoke/
```

If any of `abp`, `dotnet`, or `yq` is missing the tests skip with a
clear message rather than fail — set `RUN_SMOKE_TESTS=1` on CI runners
that have the full toolchain.

## Combos covered in v1

| File | Combo | Why |
|---|---|---|
| `linkhub_equivalent.bats` | app + angular + ef + postgresql | Mirrors the upstream reference shape; the definitive E2E gate |
| `app_nolayers.bats` | app-nolayers + angular + ef + postgresql | Smaller single-project variant |
| `mvc_ui.bats` | app + mvc + ef + postgresql | MVC UI variant exercises `abp install-libs` + `wwwroot/libs` |

## Coverage gaps (v2 follow-up)

- `multi-tenancy.bats` — `multi_tenancy=true` + `db_provider=ef`
  exercises the `--separate-tenant-schema` branch of `phase_abp_new`.
- `mongodb.bats` — `db_provider=mongodb` exercises the EF-migration-skip
  branch in `lib/post-init.sh`.
- `microservice.bats` — `template=microservice` is v2 (the microservice
  template is fundamentally different from `app` and needs its own
  overlay branch).
- `api-only.bats` — `ui=none` (API-only). Optional 4th combo for v1.

Open an issue against `codarteinc/abp-aidlc-template` if a coverage gap
blocks your work.
