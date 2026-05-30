# {{ProjectName}} Staging Runbook

> **Living runbook.** This file is the scaffolded starting point — every
> ABP + AI-DLC repo gets a copy. As your operator experience grows, add
> project-specific gotchas, IP allowlist commits, and outage post-mortems
> directly here. The scaffold tool will not overwrite this file.

> Audience: Operators provisioning, deploying, and managing {{ProjectName}} on
> Hetzner Cloud staging. Assumes basic Linux + git + GitHub Actions
> familiarity. No Terraform or Docker experience required — this runbook
> walks through everything from scratch.

This is the single operator-facing document for the {{ProjectName}} staging
environment. It takes a new operator from "I just cloned the repo" to
"I have a working staging VM I can deploy to, roll back from, and
manage." For the historical context, see
the original intent (operator-managed at `.ai-dlc/<your-intent>/intent.md`);
for the local-Docker reference, see [`docs/docker.md`](docker.md).

---

## 1. Architecture overview

A single Hetzner Cloud VM in `{{hetzner_location}}` (Nuremberg) hosts the whole staging
stack as Docker Compose services behind Caddy. GitHub Actions (self-hosted
runner) builds + publishes images to GHCR on every push to `main`, then
auto-fires the deploy workflow which SCPs rendered secrets to the VM and
runs `docker compose pull && up -d`. Terraform state lives in HCP
Terraform (free tier, `execution_mode = local`). DNS defaults to
`sslip.io` so the greenfield environment works without any zone setup.

```
+-- Developer laptop -----------------------------+
|  git push origin main                           |
|  gh workflow run staging-deploy.yml (manual)    |
+-----------------+-------------------------------+
                  |
                  v
+-- GitHub Actions (self-hosted runner) ----------+
|  cicd.yml         -- builds + pushes --> GHCR   |
|      | workflow_run                             |
|      v                                          |
|  staging-deploy.yml                             |
|  staging-rollback.yml (workflow_dispatch only)  |
+-----+-------------------------------------------+
      |  scp /etc/{{project_name_lower}}/{secrets,.env.staging}
      |  ssh docker compose pull + up -d
      v
+-- Hetzner Cloud VM ({{hetzner_server_type}}, {{hetzner_location}}, Ubuntu 24.04) --+
|  Caddy edge (LE-staging ACME by default)        |
|    +--> web   (nginx + SPA bundle)              |
|    +--> api   (.NET 10 / ABP)                   |
|           +--> db        (postgres:17-alpine)   |
|           +--> migrator  (one-shot, --profile)  |
|  Pull from ghcr.io/{{github_owner}}/{{project_name_lower}}-{api,     |
|              dbmigrator,web}:sha-<short>        |
+-----+--------------------+----------------------+
      ^                    ^
      | 443/80 (world)     | 22 (allowlisted CIDRs)
      +--------------------+---- Hetzner Cloud Firewall
              |
              v
       +-- DNS ----------------+
       | sslip.io  (default)   |  -- greenfield (no zone setup)
       | Cloudflare (gated)    |  -- future flip (see Section 10)
       +-----------------------+

State + locks: HCP Terraform workspace `{{project_name_lower}}-staging`
               (free tier, execution_mode = local).
```

The IaC lives in [`terraform/staging/`](../terraform/staging/); the
deploy and rollback workflows live in
[`.github/workflows/staging-deploy.yml`](../.github/workflows/staging-deploy.yml)
and
[`.github/workflows/staging-rollback.yml`](../.github/workflows/staging-rollback.yml).

---

## 2. First-time setup (one-time per project)

This is the heaviest section. Once it is done, the rest is mostly "click
the workflow." Read top-to-bottom on your first pass; each step's first
sentence states its prerequisites.

### 2.1 Accounts you need

- **Hetzner Cloud** project + Read+Write API token
  (<https://accounts.hetzner.com/signUp>). An existing operator can
  add you to the staging project.
- **HCP Terraform** free account
  (<https://app.terraform.io/signup/account>).
- **GitHub** access to `{{github_owner}}/{{project_name_lower}}` with permission to create
  Environments and Secrets (typically `Maintain` or `Admin`).

### 2.2 Generate the Hetzner API token

The Terraform module reads the token via `TF_VAR_hcloud_token` (env
var, never `terraform.tfvars`).

1. Hetzner Cloud Console -> staging project.
2. **Security** -> **API Tokens** -> **Generate API Token**.
3. Name: `{{project_name_lower}}-staging-terraform`. Permission: **Read & Write**.
4. **Copy the token immediately** — Hetzner shows it once.

Paste it into two places: your shell environment when running
`terraform` (Section 3), and the GitHub Environment secret
`HCLOUD_TOKEN` (Section 2.4 — consumed by `staging-deploy.yml`,
`staging-rollback.yml`, and the three GitOps workflows in Section 13).
Never put the token in `terraform.tfvars` (even a gitignored one — env
vars are safer).

### 2.3 Create the HCP Terraform workspace

Terraform state lives in HCP Terraform. **Mandatory** before
`terraform init` works.

1. Sign in at <https://app.terraform.io/>.
2. Create or join the organization (the module expects a specific
   slug — edit `terraform/staging/versions.tf` if yours differs).
3. **Workspaces** -> **New** -> **CLI-driven workflow** -> name
   `{{project_name_lower}}-staging`.
4. **Settings** -> **General** -> **Execution Mode** -> **Local** ->
   **Save**.

**Why Local matters:** HCP's default "Remote" execution runs apply on
HCP workers, which have no access to your Hetzner / Cloudflare tokens.
With **Local**, HCP stores state and locks only; apply runs on your
laptop (or the self-hosted runner) where tokens live as env vars.

Then on your laptop:

```bash
terraform login
# Browser prompt writes credentials to ~/.terraform.d/credentials.tfrc.json (0600).
```

### 2.4 Create the GitHub Environment "staging"

The deploy + rollback workflows read every secret + variable from a
GitHub Environment named exactly `staging`. Create it:

1. Repo -> **Settings** -> **Environments** -> **New environment** ->
   name: `staging`.
2. Add the secrets in the table below (**Add environment secret**).
3. Add the variables in the table below (**Add environment variable**).

Note: secrets are write-once, never readable again from the UI;
variables are readable any time. Store both lists below in a secret
manager (1Password, Bitwarden) so you can rotate later.

| Type     | Name                          | Used by                            | How to get / generate |
|----------|-------------------------------|------------------------------------|-----------------------|
| Secret   | `HCLOUD_TOKEN`                | `staging-deploy.yml`, `staging-rollback.yml`, `staging-terraform-plan.yml`, `staging-terraform-apply.yml`, `staging-terraform-destroy.yml`, `staging-terraform-drift.yml` | Section 2.2 |
| Secret   | `HCP_TF_TOKEN`                | `staging-terraform-plan.yml`, `staging-terraform-apply.yml`, `staging-terraform-destroy.yml`, `staging-terraform-drift.yml` | User API token from HCP Terraform → **User Settings** → **Tokens** → **Create**. Scope: the user must have write access to the `{{project_name_lower}}-staging` workspace (see Section 2.3). Rotate every 12 months OR immediately on operator departure. |
| Secret   | `STAGING_DEPLOY_SSH_KEY`      | `staging-deploy.yml`, `staging-rollback.yml` | Section 2.6 (paste the PRIVATE key) |
| Secret   | `APP_ADMIN_PASSWORD`          | `staging-deploy.yml` (renders both api + migrator secrets) | `openssl rand -base64 24` |
| Secret   | `CONNECTION_STRING_DEFAULT`   | `staging-deploy.yml`               | `Host=db;Port=5432;Database={{ProjectName}};Username={{project_name_lower}};Password=<POSTGRES_PASSWORD>` (substitute the same password value from `POSTGRES_PASSWORD`) |
| Secret   | `AUTHSERVER_CERT_PASSPHRASE`  | `staging-deploy.yml` (api secrets render) | The passphrase used when generating `openiddict.pfx` (see Section 2.4.1 below) |
| Secret   | `STRINGENCRYPT_PASSPHRASE`    | `staging-deploy.yml`               | `openssl rand -base64 32` |
| Secret   | `POSTGRES_PASSWORD`           | `staging-deploy.yml` (`.env.staging`) | `openssl rand -base64 32` (must equal the `Password=` field inside `CONNECTION_STRING_DEFAULT`) |
| Secret   | `OPENIDDICT_PFX_BASE64`       | `staging-deploy.yml` (api signing cert) | `base64 -w0 openiddict.pfx` (see Section 2.4.1) |
| ~~Secret~~ | ~~`GHCR_PULL_TOKEN`~~        | _Retired_                          | The deploy + rollback workflows now use the auto-issued `secrets.GITHUB_TOKEN` (scoped via `permissions: packages: read`) for GHCR auth. No per-operator PAT is required. If you still have a `GHCR_PULL_TOKEN` secret in the staging Environment from an older runbook revision, you can delete it — it's no longer read by either workflow |
| Secret   | `SENTRY_DSN`                  | `staging-deploy.yml` (`.env.staging`) | OPTIONAL — paste from Sentry project settings. Empty = SDK no-ops, no egress. |
| Secret   | `SENTRY_INGEST_ORIGIN`        | `staging-deploy.yml` (`.env.staging`) | OPTIONAL — Sentry tunnel origin. Empty = direct ingest. |
| Secret   | `DISCORD_WEBHOOK_URL`         | `staging-deploy.yml`, `staging-rollback.yml` | OPTIONAL — Discord channel webhook URL for deploy/rollback notifications. If unset, notifications are silently skipped. See §2.7 for wiring. |
| Variable | `STAGING_VM_IP`               | Both workflows                     | `terraform output -raw vm_ipv4` after Section 3 |
| Variable | `STAGING_API_HOSTNAME`        | Both workflows                     | `api.<dashed-ip>.sslip.io` (Section 3.3) |
| Variable | `STAGING_WEB_HOSTNAME`        | Both workflows                     | `app.<dashed-ip>.sslip.io` (Section 3.3) |
| **Repository** Variable (NOT env) | `STAGING_DEPLOY_ENABLED` | `staging-deploy.yml` (auto-trigger only) | **Kill switch for auto-deploy.** Default unset = OFF. Set to literal string `true` ONLY after the VM is provisioned (Section 3) and every secret/variable above is wired. **Must be at REPO level**, not env level (Settings → Secrets and variables → Actions → Variables tab → "New repository variable"). GitHub Actions doesn't expose environment-scoped vars to job-level `if:` — an env-scoped value here silently skips every auto-fire. See callout below + the lessons-learned index in §12. |

> **⚠️ Auto-deploy kill switch.** The `staging-deploy.yml` workflow has
> two trigger paths: `workflow_run` (auto-fires after every successful
> `cicd.yml` on `main`) and `workflow_dispatch` (manual operator click).
> The `workflow_run` path is gated by `vars.STAGING_DEPLOY_ENABLED ==
> 'true'`. Until you set this variable to `true` in the `staging`
> environment, every merge to `main` will trigger `cicd.yml` (builds
> images, fine) but the chained `staging-deploy` job will be silently
> skipped. This is the **correct default** while the VM doesn't exist
> yet — flipping it to `true` is the last step of first-time setup
> (after Section 3 + Section 4 confirm the VM is ready and a manual
> dispatch succeeds). Manual `workflow_dispatch` is NEVER gated — you
> can always force a deploy from the GitHub UI.

#### 2.4.1 Generating `openiddict.pfx`

ABP's OpenIddict integration needs a signing cert. Generate once; keep
the `.pfx` + passphrase in a secret manager.

```bash
PASS=$(openssl rand -base64 24)
dotnet dev-certs https -v -ep openiddict.pfx -p "$PASS"
base64 -w0 openiddict.pfx > openiddict.pfx.b64
# Paste openiddict.pfx.b64 contents -> OPENIDDICT_PFX_BASE64 secret.
# Paste $PASS                       -> AUTHSERVER_CERT_PASSPHRASE secret.
```

Then **delete the local `.pfx` and `.b64`** (or move to a secret-manager
attachment). The CI pipeline decodes from the GitHub secret on every
deploy; you don't need the file locally again.

### 2.5 Install Terraform + lint tools

The `quality_gates` enforced by AI-DLC backpressure on this intent
require `terraform`, `tflint`, `actionlint`, and `shellcheck` on the
operator's local box and on the self-hosted runner. The exact install
paths verified during this intent are
`/usr/bin/terraform`, `/usr/local/bin/tflint`, `/usr/local/bin/actionlint`,
`/usr/bin/shellcheck`. Minimum versions: `terraform >= 1.10`,
`tflint >= 0.62`, `actionlint >= 1.7`, `shellcheck >= 0.9`.

#### Ubuntu 24.04 (operator dev box)

```bash
# 1. Terraform - HashiCorp apt repository
sudo apt-get install -y curl gnupg software-properties-common
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform
terraform version   # expect Terraform v1.10+ on linux_amd64

# 2. tflint - GitHub release install script
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh \
  | sudo bash
tflint --version    # expect TFLint version 0.62+

# 3. actionlint - GitHub release script
curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash \
  | bash
sudo mv ./actionlint /usr/local/bin/
actionlint --version   # expect 1.7+

# 4. shellcheck - apt
sudo apt-get install -y shellcheck
shellcheck --version   # expect 0.9+
```

#### Debian trixie (self-hosted runner)

The HashiCorp apt repository signs Debian packages too — `lsb_release
-cs` returns `trixie` and HashiCorp publishes a matching dist.
`software-properties-common` is heavier than needed on Debian; use
`apt-transport-https` alone.

```bash
sudo apt-get install -y curl gnupg apt-transport-https
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform shellcheck

# tflint + actionlint are not always in Debian's repos. Fall back to
# the GitHub release scripts (same commands as the Ubuntu block).
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh \
  | sudo bash
curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash \
  | bash
sudo mv ./actionlint /usr/local/bin/
```

#### Verify all four

```bash
terraform version  | head -1
tflint --version   | head -1
actionlint --version
shellcheck --version | head -2
```

All four must report a version on the first line. If any prints
"command not found," re-run the install for that tool.

### 2.6 Generate the SSH key + collect allowlist IPs

The deploy/rollback workflows SCP from the self-hosted runner over SSH.
Both the **runner's** outbound IP and your laptop IP must be in
`ssh_allowed_cidrs` (as `/32` CIDRs).

```bash
# Generate a passphrase-less keypair (CI secret store is the encryption boundary).
ssh-keygen -t ed25519 -C "{{project_name_lower}}-staging-deploy" -f ~/.ssh/{{project_name_lower}}_staging -N ""

cat ~/.ssh/{{project_name_lower}}_staging.pub   # PUBLIC: paste into operator_ssh_pubkeys
cat ~/.ssh/{{project_name_lower}}_staging       # PRIVATE: paste into STAGING_DEPLOY_SSH_KEY secret

curl -4 ifconfig.me                                 # your laptop's outbound IPv4
ssh runner@<runner-host> 'curl -4 ifconfig.me'      # the runner's outbound IPv4
```

Without the **runner's** IP in `ssh_allowed_cidrs`, every deploy
times out at the `SCP rendered files to VM scratch dir` step.

### 2.7 Wiring Discord notifications (optional)

The deploy + rollback workflows post Discord embeds at three points
(start, success, failure) when `DISCORD_WEBHOOK_URL` is set on the
`staging` Environment. Absent secret = silent no-op; the workflows
still run normally without it.

1. In Discord: **Server settings** → **Integrations** → **Webhooks**
   → **New Webhook**. Pick the channel (e.g., `#deploys-staging`),
   give it a name (e.g., `{{ProjectName}} Staging`), then **Copy Webhook
   URL**. The URL has the shape
   `https://discord.com/api/webhooks/<id>/<token>` — treat it as a
   secret (the token grants post rights to that channel).
2. In GitHub: **Settings** → **Environments** → **staging** →
   **Add secret** → name `DISCORD_WEBHOOK_URL`, paste the URL.
3. Done. The next deploy / rollback posts **2 messages**: a blue
   "started" embed and either a green "succeeded" or a red "failed"
   embed. Embeds include the trigger, actor, commit (linked), workflow
   run (linked), and — on success — the SPA + API URLs.

Rotating or revoking the webhook is a one-line operation in Discord
(**Edit Webhook** → **Delete Webhook**). Update the GitHub secret
afterward. Notification failure NEVER fails the deploy step
(`curl ... || true`), so a Discord outage or revoked webhook is safe.

To disable notifications without deleting the webhook, blank out the
secret in the staging Environment (set value to an empty string) —
the workflows treat empty as "skip" and short-circuit before the
`curl`.

See §12 "Notifications not appearing" for troubleshooting.

---

## 3. Provisioning the VM

Prerequisite: Sections 2.2, 2.3, 2.5, 2.6 complete. The
`terraform.tfvars` template lives at
[`terraform/staging/terraform.tfvars.example`](../terraform/staging/terraform.tfvars.example).

### 3.0 Two ways to provision / change infra

There are two paths for running `terraform plan` / `apply` against the
staging module — pick the right one for the task:

- **Manual flow (this section, §3.1–§3.3)** — operator runs `terraform`
  locally against the HCP backend. This is the **break-glass /
  first-provision** path: use it on a fresh checkout to stand the VM up
  from zero, or when GitHub Actions is unavailable (runner offline,
  GitHub outage, fork-PR limitation per §13.7).
- **GitOps flow (Section 13)** — open a PR touching
  `terraform/staging/**`, review the plan comment posted by
  `staging-terraform-plan.yml`, merge, then dispatch
  `staging-terraform-apply.yml`. A daily `staging-terraform-drift.yml`
  cron surfaces out-of-band state divergence. This is the **default**
  for ongoing changes after the VM is provisioned — every change has a
  reviewable plan, a typed-confirm apply gate, and an audit trail in
  the workflow run log.

The two flows share the same HCP Terraform workspace
(`{{project_name_lower}}-staging`), so state is consistent whichever path you take.
See Section 13 for the GitOps procedure end-to-end.

> Use this manual flow for first-time provision or when GitHub Actions is unavailable. For routine changes after the first provision, follow §13.

```bash
cd terraform/staging
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: fill ssh_allowed_cidrs + operator_ssh_pubkeys.

# Export the Hetzner token (never put it in terraform.tfvars).
export TF_VAR_hcloud_token="<paste from Section 2.2>"
# Optional, only when dns_provider = "cloudflare":
# export TF_VAR_cloudflare_api_token="<paste from Section 10>"

terraform init    # one-time per fresh clone; downloads providers, wires HCP backend
terraform plan    # preview - expect ~6 resources to create
terraform apply   # type 'yes' to confirm
```

`terraform apply` returns in ~30s once Hetzner accepts the create. The
VM exists at that point but cloud-init is still bootstrapping.

> **Shortcut for re-bootstraps:**
> [`terraform/staging/rebootstrap.sh`](../terraform/staging/rebootstrap.sh)
> wraps the destroy + apply + SSH wait + cloud-init wait + smoke test
> into one command. Use it when you've edited `cloud-init.yaml` (see
> §12 "Cloud-init didn't re-run...") or you're verifying the deploy
> pipeline against a clean VM:
>
> ```bash
> cd terraform/staging
> ./rebootstrap.sh           # targeted destroy, keeps IP (recommended)
> ./rebootstrap.sh --full    # full destroy, new IP (updates GH vars too)
> ./rebootstrap.sh --help    # show usage + env-var overrides
> ```
>
> The script reads the Hetzner token from
> `~/.config/{{project_name_lower}}/staging.env` (or `TF_VAR_hcloud_token` if already
> exported). Exits 0 only when the VM is fully ready — so it's safe to
> chain with `gh workflow run staging-deploy.yml` for an end-to-end
> rebuild test.

### 3.1 Wait for cloud-init

```bash
VM_IP=$(terraform output -raw vm_ipv4)
ssh deploy@"$VM_IP" 'cloud-init status --wait'
# Blocks for 3-5 minutes on a cold image. Exits 0 when done.
```

If this hangs past 5 minutes, see Section 12 "Cloud-init didn't
converge."

### 3.2 Verify the VM is ready

Smoke-test the load-bearing invariants. These match what
[`terraform/staging/README.md`](../terraform/staging/README.md) calls
out:

```bash
VM_IP=$(terraform output -raw vm_ipv4)
ssh deploy@"$VM_IP" '
  docker --version &&
  stat -c "%a %U:%G" /var/lib/{{project_name_lower}}/db &&
  stat -c "%a %U:%G" /etc/{{project_name_lower}}/api &&
  test -f /var/lib/{{project_name_lower}}/.bootstrap-complete && echo MARKER OK
'
# Expected:
#   Docker version 27.3.1, build ...
#   700 ?:?            (UID 70 / GID 70 — the postgres-alpine user)
#   750 root:deploy
#   MARKER OK
```

The `700` mode + numeric UID 70 on `/var/lib/{{project_name_lower}}/db` is the R1
mitigation: `postgres:17-alpine` runs as UID 70, NOT the more common
999. Cloud-init pre-creates the directory with the right ownership;
without it, the Postgres container crash-loops on first boot with
`FATAL: data directory "/var/lib/postgresql/data" has invalid
permissions`. See your `.ai-dlc/<your-intent>/discovery.md`
line ~1073 (Risks table, R1) for the full story.

### 3.3 Update the GitHub Environment with the VM details

Take the IPv4 from `terraform output` and write three values into the
`staging` Environment as **Variables** (not secrets — they are not
sensitive and being readable from the UI is useful):

```text
STAGING_VM_IP         = 5.75.10.22            # whatever terraform returned
STAGING_API_HOSTNAME  = api.5-75-10-22.sslip.io
STAGING_WEB_HOSTNAME  = app.5-75-10-22.sslip.io
```

`sslip.io` resolves `<dashed-or-dotted-ip>.sslip.io` to the encoded IP
with no zone setup. The hyphenated form is what Caddy will receive in
the `Host` header. Both `app.` and `api.` subdomains resolve to the
same IPv4.

---

## 4. First deploy

Prerequisite: Section 3 complete (VM provisioned, cloud-init done,
GitHub Environment populated).

After Section 3, the **next push to `main`** auto-fires the deploy
workflow via `workflow_run`. To trigger an immediate deploy without
waiting for a merge:

### 4.1 Trigger via the GitHub UI

1. Repo -> **Actions** -> **Staging Deploy** in the left sidebar ->
   **Run workflow**.
2. Branch: `main`.
3. Inputs:
   - `commit_sha`: leave empty (uses HEAD of `main`) OR paste a full
     commit SHA whose `cicd.yml` has already published GHCR images.
   - `skip_migrator`: leave `false`. Set to `true` only if you KNOW
     the schema has not changed since the last successful deploy and
     you want a faster api/web-only restart.
4. Click **Run workflow**.

### 4.2 Watch the job and what is normal

Expected duration: **~3-5 minutes on a warm cache, ~6-8 minutes on a
cold runner.** The workflow has 13 sequential steps; the slow ones are:

- **`SCP rendered files to VM scratch dir`** (~5s on a healthy link;
  >30s suggests a firewall problem — see Section 12).
- **`Pull all images`** (~30s warm, ~3 min cold per image).
- **`Run migrator (one-shot, blocking)`** (~10-30s — applies
  pending EF Core migrations + seeds default data).
- **`Health probe (60s budget)`** loops curl for up to 60s waiting for
  `https://<api-hostname>/health-live` AND `https://<web-hostname>/`
  to both return 200.

Normal signals in the logs:

- `::notice::Deploying sha-abc1234 (sha=..., trigger=workflow_dispatch)`
- `::notice::Healthy after Xs (api=200, web=200)`
- `Record last-known-good` step exits 0.

If any step prints `::error::`, read the message — the workflow's
error catalogue is documented inline (see `staging-deploy.yml` and
Section 12 here).

### 4.3 Visit the staging URL

Once `Healthy after Xs` appears, open:

- SPA: `https://app.<dashed-ip>.sslip.io/`
- API liveness: `https://api.<dashed-ip>.sslip.io/health-live`

The browser will warn about the cert — that is expected. See Section 5.

### 4.4 Flip the auto-deploy kill switch (last step of first-time setup)

Once Section 4.1-4.3 confirm a manual deploy works end-to-end, enable
auto-deploy on every push to `main`:

1. Repo -> **Settings** -> **Secrets and variables** -> **Actions** ->
   **Variables** tab -> **New repository variable** -> name
   `STAGING_DEPLOY_ENABLED`, value `true` (literal lowercase string).
2. Next merge to `main` will: build images via `cicd.yml`, then chain
   into `staging-deploy.yml` automatically.

> **⚠ Must be a REPOSITORY variable, NOT an environment variable.**
> Environment-scoped variables (Settings → Environments → staging →
> Variables) are NOT accessible to job-level `if:` expressions —
> GitHub Actions binds the environment to the job AFTER the `if:`
> evaluates, so the gate sees `''` and silently skips every
> auto-fire. The `staging-deploy.yml` job's `if:` is what reads this
> variable, hence the repo-level requirement. (Bug discovered on
> first auto-fire attempt; see lessons-learned index in §12.)

Until this var is `true`, the auto-deploy path is silently skipped
(intentional default — see the kill-switch callout in §2.4). To
temporarily disable auto-deploy later (incident, migration window,
etc.) flip the var to `false` or delete it; manual `workflow_dispatch`
keeps working regardless.

---

## 5. Accepting the self-signed certificate

By default, `Caddyfile.staging` uses **Let's Encrypt staging** as the
ACME directory. LE-staging is a real CA whose certs are valid TLS but
NOT browser-trusted. The trade is intentional (R3 mitigation): LE-prod
limits to 50 certs/domain/week, and during early iteration you can blow
that budget in a single afternoon. LE-staging has much looser limits.

You must accept the certificate **once per origin per browser per
device.** Two origins matter:

- `https://app.<dashed-ip>.sslip.io/` — the SPA.
- `https://api.<dashed-ip>.sslip.io/` — the API. OIDC redirects bounce
  here, and the SPA's `fetch` calls hit here. If only `app.` is
  accepted, login appears to work then fails silently when the
  refresh-token call dies on a CORS preflight that was actually a TLS
  failure.

Per-browser flow:

- **Chrome / Edge / Brave** — Click **Advanced** -> **Proceed to
  app.X.sslip.io (unsafe)**. Some Chromium builds hide the button: type
  `thisisunsafe` on the warning page (no input field — it is a magic
  literal).
- **Firefox** — Click **Advanced** -> **Accept the Risk and Continue**.
- **Safari** — Click **Show Details** -> **visit website**.

For the API origin, visit
`https://api.<dashed-ip>.sslip.io/health-live` once and accept the
warning. The response body is empty (200 OK) — that is by design (audit
finding F-038 prohibits a fingerprintable body).

After both accepts are in place, OIDC login, API calls, and the picture
upload flow all work normally. See Section 12
"Forgot to accept api.X cert; SPA login fails" if the SPA appears
broken after only accepting the `app.` origin.

---

## 6. Ongoing deploy procedure

### 6.1 Normal case (automatic)

Merge a PR to `main`. `cicd.yml` builds + publishes three images
(`{{project_name_lower}}-api`, `{{project_name_lower}}-dbmigrator`, `{{project_name_lower}}-web`) tagged
`sha-<short>` to GHCR. The `workflow_run` trigger on
`staging-deploy.yml` fires automatically — staging is running the new
commit ~5 minutes after the merge. No human action required.

Watch progress at **Actions** -> **Staging Deploy** -> the running
job. The workflow's step summary at the end shows the deployed tag and
target URL.

### 6.2 Override case (manual redeploy of a specific commit)

For "I want to roll forward to a slightly older commit that is known
green," or "the auto-trigger failed and I'm re-running":

1. **Actions** -> **Staging Deploy** -> **Run workflow**.
2. `commit_sha`:
   - **Leave empty (default, recommended for most operator-driven
     redeploys)** — deploy uses the floating `:main` tag per package,
     which `cicd.yml` atomically re-points on every successful main
     build. This always works as long as each component has ever had
     a successful main build, and naturally handles the case where
     HEAD of main is a sequence of infra-only commits that `cicd.yml`
     skipped (api/web/migrator builds are path-filtered). The deploy
     step summary surfaces the actual underlying SHA per package so
     you can see exactly what shipped.
   - **Paste a full SHA** to pin all three images to `sha-<short>`.
     The commit must already have green `cicd.yml` images on GHCR for
     ALL three components — manual deploys do NOT build images, only
     pull them. If any image is missing (typically because the cicd
     path filter skipped that component for the commit), `Pull all
     images` fails with `manifest unknown`. Fix: either re-dispatch
     with empty `commit_sha` to use the per-package `:main` floating
     tag, OR fire `cicd.yml` manually first with `force_rebuild=true`
     to republish all three images against that SHA, then re-run this
     deploy. **Also note:** the deploy workflow renders secrets
     templates from the **same** checked-out `commit_sha`, so if you
     target a SHA from before the your your hetzner-deploy intent intent landed
     (commit <last-green-commit-on-main>), the `Render API appsettings.secrets.json` step
     fails with `appsettings.secrets.staging.json.template: No such
     file or directory`. The fix is to use a SHA at or after <last-green-commit-on-main>
     (typically leave `commit_sha` empty).
3. `skip_migrator`: leave `false` unless you are certain the schema is
   unchanged.
4. Click **Run workflow**.

### 6.3 Why there is no `staging-deploy-v*` tag trigger

`cicd.yml` only publishes `sha-<short>` GHCR tags; there is no `v*`
tag publisher. The `release-tagging` future intent (Section 11) adds a
workflow that re-tags `sha-<short>` images as `vX.Y.Z` on a version-tag
push, which would enable a `staging-deploy-vX.Y.Z` trigger. Until that
ships, manual `workflow_dispatch` with `commit_sha` is the only
override path.

### 6.4 Forcing a fresh image build (cicd `workflow_dispatch`)

`cicd.yml`'s "Detect changed paths" job uses `dorny/paths-filter@v3` to
decide which of the three images to (re)build on each push. The
filters are:

| Filter   | Triggers builds of                | Watched paths (summary)                                                |
|----------|-----------------------------------|------------------------------------------------------------------------|
| `dotnet` | `{{project_name_lower}}-api` + `{{project_name_lower}}-dbmigrator` | `src/{{ProjectName}}.*/**`, `test/**`, `{{ProjectName}}.slnx`, `*.Dockerfile` for api+migrator |
| `web`    | `{{project_name_lower}}-web`                     | `angular/**`                                                           |
| `workflow` | All three (defensive)           | `.github/workflows/cicd.yml`                                           |

A series of infra-only commits — terraform changes, runbook edits,
operator scripts, anything outside `src/` and `angular/` — will pass
through `cicd.yml`'s Build & Test job (which runs unconditionally)
but **skip the three image-publish jobs entirely**. Net effect: HEAD
has no `sha-<HEAD>` images on GHCR, and the deploy workflow's `Pull
all images` step fails with `manifest unknown` when targeting HEAD.

To republish all three images against HEAD without a code change:

1. **Actions** -> **CICD** -> **Run workflow**.
2. Branch: `main`.
3. Input `force_rebuild`: leave at the default `true`.
4. Click **Run workflow**.

`force_rebuild=true` overrides the path-filter outputs and unblocks
all three image-publish jobs. Typical run time: ~3-5 min on a warm
self-hosted runner (the per-service buildcache on GHCR makes the
"unchanged context" case fast).

Once cicd is green for HEAD, re-trigger `staging-deploy.yml` with an
empty `commit_sha` (it defaults to HEAD).

---

## 7. Rollback procedure

### 7.1 Rolling back api or web (safe)

api and web rollbacks are independent — rolling api back to an older
tag does not touch web, db, or migrator. The other services keep
running their current tags.

1. **Actions** -> **Staging Rollback** -> **Run workflow**.
2. Inputs:
   - `service`: `api` (or `web`).
   - `target_tag`: leave empty to use the recorded last-known-good
     (read from `/etc/{{project_name_lower}}/last-known-good-<svc>.env` on the VM).
     Or paste an explicit tag like `sha-abc1234`.
   - `confirm_schema_compatible`: leave `no`.
3. Click **Run workflow**.

Expected duration: ~2-3 minutes. The workflow:

1. Reads `/etc/{{project_name_lower}}/last-known-good-<svc>.env` (skipped if
   `target_tag` was supplied).
2. Validates the tag against `^[A-Za-z0-9._-]+$` (defense against
   shell metacharacters in `sed`).
3. Edits `/etc/{{project_name_lower}}/.env.staging` to set `<VAR>=<TAG>` for the
   service's version env var (`API_VERSION` / `WEB_VERSION` /
   `MIGRATOR_VERSION`).
4. `docker compose pull <svc>` + `up -d --no-deps <svc>`.
5. Health-probes the rolled service for up to 60s.
6. Writes the new tag back to `/etc/{{project_name_lower}}/last-known-good-<svc>.env`
   so the next rollback (without `target_tag`) picks up here, not at
   the pre-rollback state.

If you see `No last-known-good tag recorded for <svc>`, this service
has never been successfully deployed (or the file got wiped). Pass an
explicit `target_tag` and check
`/etc/{{project_name_lower}}/last-known-good-<svc>.env` after the rollback succeeds.

### 7.2 Rolling back migrator (DANGEROUS — read Section 8 first)

Migrator rollback re-runs the older migrator image. **It does NOT undo
schema changes that are already applied.** Whether the older API code
is compatible with the forward schema depends on the forward-compatible
migration policy (Section 8) holding for every migration since the
target tag.

Procedure (after reading Section 8):

1. **Actions** -> **Staging Rollback** -> **Run workflow**.
2. Inputs:
   - `service`: `migrator`.
   - `target_tag`: paste the explicit older tag. The
     last-known-good for migrator does not auto-resolve to a safe
     point — the policy decision is yours.
   - `confirm_schema_compatible`: `yes`. The workflow exits 1 with
     `::error::Migrator rollback requires confirm_schema_compatible=yes.`
     otherwise — that is the safety gate, not a quirk.
3. Click **Run workflow**.

If the older API code crashes against the forward schema, **the only
fix is to redeploy forward to a compatible api tag.** Database restore
from a `pg_dump` is the other escape hatch, but `postgres-backups` is a
future intent (Section 11); until it ships, there are no automated
backups to restore from.

---

## 8. Forward-compatible migration policy

This is the contract that makes Section 7's per-service rollback safe.
Every PR that adds a file under
`src/{{ProjectName}}.EntityFrameworkCore/Migrations/` MUST satisfy ALL of:

1. **Add only — never drop.** New column: yes. New table: yes.
   `DropColumn(...)`: **no.** `DropTable(...)`: **no.**
   `RenameColumn(...)`: **no.**
2. **New columns are nullable OR have a server default.** So existing
   code that doesn't know about the column still INSERTs successfully.
3. **New tables don't have a required FK to existing tables that would
   break old code's INSERT path.** Add the FK as nullable; tighten in a
   future migration after old code is gone.

### 8.1 Why this exists

Rolling api from N+1 back to N keeps schema at "N+1's state." By
construction, the N+1 schema is backward-compatible with N's code:
N+1's INSERTs into old tables provide values for old columns; old
columns still exist (rule 1); new columns are nullable (rule 2); new
tables N didn't know about are never queried by N (no problem).

The concrete failure mode the policy prevents:

> A developer ships `migrationBuilder.DropColumn("Email", "AppUsers")`
> in migration N+1. The rollback workflow rolls api back to N. The N
> code calls `SELECT Email FROM AppUsers WHERE ...` and returns 500 on
> every request. Recovery: re-deploy forward to N+1 (undoing the
> rollback), OR restore the database from a `pg_dump` taken before
> N+1.

Without the policy, per-service rollback is a lie — the workflow will
happily roll api back, and the next request crashes. The policy makes
the lie a contract.

### 8.2 Enforcement

**Today: PR review.** Every migration PR includes a "rollback-safe?"
note in the review comments. The reviewer checks:

- (a) No `DropColumn` / `DropTable` / `RenameColumn` calls in the new
  migration's `Up()` method.
- (b) Every `AddColumn` has `nullable: true` OR `defaultValue:` set.
- (c) Every new FK column on an existing table is `nullable: true`
  (the constraint can be added; the column must be nullable so old
  INSERTs still work).

**Tomorrow: automated.** The `migration-lint-ci` future intent
(Section 11) adds a CI scan that fails the build on any of the above
patterns. Until that ships, PR review is the gate.

---

## 9. SSH access and IP rotation

Your home/office/VPN IP changes; you can no longer SSH into the VM.
The fix takes ~10 seconds and zero downtime — Hetzner's firewall is
managed independently of the VM.

> **Note:** `ssh_allowed_cidrs` gates **both SSH (port 22) and ICMP
> (ping / MTR)** at the firewall. External scanners get no ping reply
> and no SSH banner — the VM appears silent to the public internet
> (only ports 80/443 respond). Operators on allowlisted IPs get full
> diagnostics. If `ping <vm-ip>` returns "Request timed out" from a
> machine that USED to work, the first thing to check is whether
> that machine's public IP is still in `ssh_allowed_cidrs`.

```bash
cd terraform/staging
# Edit terraform.tfvars:
#   ssh_allowed_cidrs = [
#     "203.0.113.7/32",   # operator-1 home   (NEW)
#     "198.51.100.42/32", # self-hosted runner static IP (unchanged)
#   ]
terraform apply   # ~10s, only the firewall is touched
```

Same procedure for:

- **Adding a new operator.** Append their pubkey to
  `operator_ssh_pubkeys` AND their IP `/32` to `ssh_allowed_cidrs`,
  then `terraform apply`. Cloud-init injected pubkeys at VM-create time;
  changes to `operator_ssh_pubkeys` register new `hcloud_ssh_key`
  resources but the existing VM does NOT pick them up automatically
  (the cloud-init `users:` block runs once). For an existing VM, the
  operator pubkey must also be appended to `/home/deploy/.ssh/authorized_keys`
  via `ssh deploy@$VM_IP 'cat >> ~/.ssh/authorized_keys' < newkey.pub`.
- **Removing/rotating an IP.** Remove the stale `/32` from
  `ssh_allowed_cidrs` and `terraform apply`. Removed IPs are dropped
  from the Hetzner firewall in the same ~10s window.

The runner's IP is the most operationally load-bearing entry; if you
ever rebuild the self-hosted runner on a different host, update
`ssh_allowed_cidrs` BEFORE running the next deploy, or the deploy will
hang at the SCP step until SSH times out.

---

## 10. Switching to a real Cloudflare-managed domain

When the greenfield era ends and you want a memorable hostname:

1. **Transfer or set up the zone at Cloudflare.** Use Cloudflare's
   normal nameserver-delegation flow.
2. **Create a Cloudflare API token** with `Zone:Edit` scoped to the
   staging zone only. Cloudflare dashboard -> **My Profile** -> **API
   Tokens** -> **Create Token** -> custom permissions.
3. **Add secrets/vars to the `staging` GitHub Environment:**
   - `CLOUDFLARE_API_TOKEN` (secret).
   - `CLOUDFLARE_ZONE_ID` (variable — the zone ID from CF dashboard,
     NOT the domain name).
4. **Edit `terraform/staging/terraform.tfvars`:**
   ```hcl
   dns_provider          = "cloudflare"
   cloudflare_zone_id    = "0123456789abcdef0123456789abcdef"
   staging_app_hostname  = "app.{{project_name_lower}}-staging.example.com"
   staging_api_hostname  = "api.{{project_name_lower}}-staging.example.com"
   ```
5. **Export the Cloudflare token** as a Terraform env var:
   ```bash
   export TF_VAR_cloudflare_api_token="<paste from step 2>"
   ```
6. **Apply:**
   ```bash
   cd terraform/staging
   terraform apply   # adds 4 cloudflare_dns_record resources (A + AAAA × app + api)
   ```
7. **Update GH Environment variables** to the new hostnames:
   ```text
   STAGING_API_HOSTNAME = api.{{project_name_lower}}-staging.example.com
   STAGING_WEB_HOSTNAME = app.{{project_name_lower}}-staging.example.com
   ```
8. **Flip Caddy to LE production ACME.** Edit
   [`Caddyfile.staging`](../Caddyfile.staging) and remove the line:
   ```caddy
   acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
   ```
   from the global block. Commit + merge to `main` — the next deploy
   ships the new Caddyfile and Caddy auto-issues real Let's Encrypt
   production certs. **No more browser warning.**
9. **Trigger a deploy** (Section 6.2 — manual `workflow_dispatch`).
   First cert issuance takes ~30s; subsequent renewals are silent
   (~60 days before expiry, Caddy renews in the background).

If you hit a Let's Encrypt prod rate limit (50 certs/domain/week, 5
failed validations/hour) during a retry storm, re-add the `acme_ca`
line to flip back to LE-staging while you iterate. See Section 12
"Cert renewal stuck."

---

## 11. Future Work

Each entry is a candidate slug for `/ai-dlc:followup hetzner-deploy
<slug>`. Spell them exactly as written — misspelling fragments the
backlog. Every entry has a **Why deferred** line; new entries must
follow the same shape.

- **`observability-stack`** — Loki + Promtail + Prometheus + Grafana
  as `docker-compose.observability.yml`; default dashboards for the
  four `{{ProjectName}}.*` OTel meters listed in `CLAUDE.md` -> Operational
  endpoints. **Why deferred:** greenfield, no traffic to observe.
  **Trigger:** first real traffic or first incident.
- **`postgres-backups`** — Nightly `pg_dump` to Hetzner Object Storage
  via systemd timer; 30-day retention via bucket lifecycle; documented
  restore drill. **Why deferred:** no real data to lose yet.
  **Trigger:** first user signs up.
- **`production-overlay`** — `docker-compose.prod.yml`, managed
  Postgres, multi-AZ posture, blue/green deploy. **Why deferred:**
  product not ready for production users; needs its own conversation
  about managed DB, on-call rotation. **Trigger:** first paying
  customer.
- **`staging-hardening`** — Replace the `deploy` user's Docker group
  membership + raw `sudo install` / `sudo docker` allowlist with
  root-owned wrapper scripts that validate arguments and paths before
  acting (so the `deploy` user is no longer effectively-root via the
  Docker socket and the sudoers shape). Goal: a compromised
  `STAGING_DEPLOY_SSH_KEY` cannot pivot to arbitrary code execution
  as root. **Why deferred:** material redesign — touches sudoers,
  both `staging-deploy.yml` and `staging-rollback.yml` `sudo`
  invocations, and the per-unit contract documented in unit-02 /
  unit-04. Staging-only blast radius today (no real user data, single
  operator). **Trigger:** before any prod overlay ships, OR when an
  external dependency (compliance, security review, second operator
  joining with a junior trust posture) mandates least-privilege for
  the deploy path.
- **`migration-lint-ci`** — Automated check for the
  forward-compatible-migration policy (Section 8); fails the build on
  `DropColumn` / `DropTable` / `RenameColumn` in any migration file.
  **Why deferred:** PR review is fine while the team is one operator.
  **Trigger:** second operator joins, OR a Section-8 violation slips
  through review.
- **`dns-real-domain`** — Flip `dns_provider = "cloudflare"`,
  configure the zone, swap sslip.io for real hostnames (Section 10).
  **Why deferred:** greenfield staging doesn't need a memorable URL.
  **Trigger:** product launch or stakeholder demo.
- **`real-csp-report-collector`** — Repoint the SPA + Caddy
  `report-uri` directive from the same-origin 204-stub to a real
  collector (Sentry / csper.io / custom). See `CLAUDE.md` Conventions
  -> CSP for the contract. **Why deferred:** no observability
  collector yet. **Trigger:** after `observability-stack` ships.
- **`staging-known-hosts-secret`** — Replace the `ssh-keyscan` TOFU
  approach in `staging-deploy.yml` line 204 with a pinned
  `STAGING_KNOWN_HOSTS` GH Environment secret. **Why deferred:**
  current self-hosted runner is on trusted infrastructure; TOFU is
  acceptable. **Trigger:** cloud-hosted (untrusted) runner added.
- **`release-tagging`** — Workflow that re-tags `sha-<short>` GHCR
  images as `vX.Y.Z` on push of a version tag, enabling
  `staging-deploy-vX.Y.Z` semantics. **Why deferred:** greenfield
  doesn't have a stable release cadence; auto-deploy on every main
  push covers the current need. **Trigger:** first 1.0 release
  candidate.

---

## 12. Troubleshooting

Cases are in priority order — the first few are highest-stakes during
actual operator life.

### Auto-deploy not firing on merge to `main`

Symptoms: PR merges to `main`, `cicd.yml` runs and succeeds (builds
images, publishes to GHCR), but `staging-deploy.yml` is conspicuously
absent from the Actions tab.

Two causes, in order of likelihood:

1. **The kill switch is OFF or at the wrong scope.** Confirm:
   Repo -> Settings -> **Secrets and variables** -> **Actions** ->
   **Variables** tab (NOT the Environments tab) -> `STAGING_DEPLOY_ENABLED`
   must equal literal string `true`. Unset, empty, `false`, `True`,
   `TRUE`, or any value that isn't lowercase `true` keeps auto-deploy
   skipped. If the variable is on the `staging` **Environment** instead
   of the repository, it's effectively unset for the `if:` gate — GH
   Actions doesn't expose environment-scoped vars at job-if-evaluation
   time. See §4.4 callout. Manual `workflow_dispatch` is unaffected
   by this gate.
2. **The source workflow's `name:` drifted.** `staging-deploy.yml`
   `on.workflow_run.workflows` lists `[CICD]` (matching the literal
   `name:` of `cicd.yml`). If someone renames `cicd.yml`'s top-level
   `name:` field, the chain breaks silently. Re-align both files.

### Deploy fails: `Pull all images` returns `manifest unknown`

Symptoms: the deploy workflow gets through `SCP rendered files` +
`Atomic install` but dies at `Pull all images` with
`Error response from daemon: manifest unknown` for
`ghcr.io/{{github_owner}}/{{project_name_lower}}-{api,web,dbmigrator}:sha-<short>`.

Cause: the target commit's `cicd.yml` run skipped the image-publish
jobs because the `dorny/paths-filter@v3` config didn't match any
changes (e.g., a series of infra-only commits — terraform, runbook,
operator scripts — that touch nothing under `src/` or `angular/`).
HEAD has no `sha-<HEAD>` images.

Fix: §6.4 "Forcing a fresh image build" — **Actions** → **CICD** →
**Run workflow** with `force_rebuild=true`. Wait ~3-5 min for the
republish, then re-trigger `staging-deploy.yml`.

### Deploy fails: `Render API appsettings.secrets.json` (`No such file or directory`)

Symptoms: the deploy workflow fails very early (before any image
pull) with:
```text
src/{{ProjectName}}.HttpApi.Host/appsettings.secrets.staging.json.template:
No such file or directory
```

Cause: the deploy workflow checks out `commit_sha` (or HEAD if empty)
and renders secrets templates from that checkout. If `commit_sha`
predates the your your hetzner-deploy intent intent (commit `<last-green-commit-on-main>`), the template
file simply doesn't exist there.

Fix: use a SHA at or after `<last-green-commit-on-main>`. Easiest: leave `commit_sha`
empty so the workflow defaults to HEAD (which always has the template
on `main` once the intent landed). If HEAD lacks `sha-<HEAD>` images,
combine with §6.4 to republish them first.

### Cloud-init didn't converge in 5 minutes

```bash
ssh deploy@"$VM_IP" 'sudo cloud-init status --long'
ssh deploy@"$VM_IP" 'sudo less /var/log/cloud-init-output.log'
```

Common causes:

- apt-get hung on a slow mirror — wait, OR
  `terraform destroy -target=hcloud_server.staging && terraform apply`
  to rebuild (the primary IP survives, see
  [`terraform/staging/README.md`](../terraform/staging/README.md)
  Lifecycle notes).
- Docker version pin `5:27.3.1-1~ubuntu.24.04~noble` no longer in apt
  — Hetzner's Ubuntu mirror occasionally rotates a pin out. Bump the
  pin in
  [`terraform/staging/cloud-init.yaml`](../terraform/staging/cloud-init.yaml),
  push, `terraform destroy -target=hcloud_server.staging && terraform apply`.

### OOM kill in `journalctl -u docker`

The {{hetzner_server_type}}'s 4 GB RAM is tight for a 4-service stack. Symptoms: API
container restarting every few minutes; `dmesg | grep -i oom` returns
hits. Bump to cx33:

```bash
cd terraform/staging
# Edit terraform.tfvars: server_type = "cx33"
terraform apply   # Hetzner rebuilds in place, ~30s downtime, same IP
```

cx33 is €7.99/mo (+€3 vs {{hetzner_server_type}}). Bind-mount data on `/var/lib/{{project_name_lower}}/db`
survives the local-NVMe-to-local-NVMe rebuild. `cx -> ccx` flips storage
backend and is NOT safe — stay within the cx family.

### Cert renewal stuck (Caddy logs `acme: rate limited`)

`Caddyfile.staging` defaults to **LE staging** (R3, F007 fix) so
iteration doesn't burn the LE-prod 50-certs/week/domain budget.
LE-staging has much higher limits.

If you've flipped to LE prod (Section 10) and hit the prod limit: wait
7 days for the rolling window, OR re-add the
`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory` line
to `Caddyfile.staging` to flip back to staging while you iterate.
Caddy logs:

```bash
ssh deploy@"$VM_IP" 'docker compose -f /srv/{{project_name_lower}}/docker-compose.yml \
                                    -f /srv/{{project_name_lower}}/docker-compose.staging.yml \
                                    --env-file /etc/{{project_name_lower}}/.env.staging \
                                    logs --tail=200 caddy'
```

### Workflow died mid-pipeline — what's the VM state?

The deploy workflow has six sequential side-effecting VM steps: SCP
scratch -> atomic install -> GHCR login -> pull -> migrator -> restart.
If the workflow crashes mid-pipeline, the VM may be partial.

Decision tree by last-completed step (read the workflow log):

1. **`Atomic install` ran, `Run migrator` didn't:** new secrets on disk,
   old containers still using old config (they read at startup). Re-run
   the deploy — every install is idempotent (`install -m 0640` is an
   atomic overwrite). No data loss.
2. **`Run migrator` succeeded:** schema moved forward. The
   forward-compatible policy (Section 8) keeps old api/web compatible.
   Re-run the deploy to restart api/web with the new image.
3. **`Run migrator` failed:** schema MAY be partially applied. ABP's
   `DbMigrator` runs each EF Core migration in its own transaction.
   Check what's applied:

   ```bash
   ssh deploy@"$VM_IP" 'docker compose -f /srv/{{project_name_lower}}/docker-compose.yml \
                                       -f /srv/{{project_name_lower}}/docker-compose.staging.yml \
                                       --env-file /etc/{{project_name_lower}}/.env.staging \
                                       exec -T db psql -U {{project_name_lower}} -d {{ProjectName}} \
                                       -c "SELECT * FROM \"__EFMigrationsHistory\" ORDER BY \"ProductVersion\" DESC LIMIT 5;"'
   ```

   Compare to `src/{{ProjectName}}.EntityFrameworkCore/Migrations/`. Manual
   repair may be needed — check the migrator container logs for the
   SQL error.
4. **`Restart` ran, `Health probe` failed:** services up on new image,
   probes time out. `docker logs` the offending container; common
   causes are bad `{{PROJECTNAME_UPPER}}_*_HOSTNAME`, GHCR pull failure, OOM.
5. **`Record last-known-good` failed:** deploy worked, bookkeeping
   broke. Re-trigger the deploy (LKG re-runs on success), or manually:
   `ssh deploy@$VM_IP 'echo "API_VERSION=sha-abc1234" | sudo tee /etc/{{project_name_lower}}/last-known-good-api.env'`.

**The deploy is fully idempotent.** Re-running with the same commit SHA
re-installs files atomically, re-pulls, re-migrates (no-op if
up-to-date), re-restarts. When in doubt, re-trigger.

### Secret leak detected in workflow log

STOP. Don't re-trigger. Rotate immediately:

1. Generate a new value (`openssl rand -base64 32` for passphrases;
   regenerate the OpenIddict PFX if `OPENIDDICT_PFX_BASE64` leaked).
2. Update the GitHub Environment secret.
3. Force a new deploy via `workflow_dispatch` — `.env.staging` and the
   rendered `appsettings.secrets.json` must be regenerated on disk
   before container restart picks up the new value.
4. File an issue tracking the workflow change that caused the leak.
   The adversarial-pass posture in
   [`.github/workflows/staging-deploy.yml`](../.github/workflows/staging-deploy.yml)
   should make leaks hard; every PR touching the workflows should be
   reviewed against that posture.

### GHCR pull failed: `denied: denied`

Symptom in the workflow log:

```text
::error::Error response from daemon: denied: denied
```

The deploy + rollback workflows authenticate to GHCR using the
auto-issued `secrets.GITHUB_TOKEN` (scoped via
`permissions: packages: read`). There is no long-lived PAT to rotate.
Likely causes, in order of likelihood:

1. **The `permissions: packages: read` block went missing.** Check
   the top of `staging-deploy.yml` / `staging-rollback.yml`. Without
   it, `GITHUB_TOKEN` cannot pull GHCR images even from the same org.
   Re-add and push.
2. **The package was unlinked from the source repo.** GHCR packages
   inherit access from a "source repository." `cicd.yml`'s push step
   links each package to `{{github_owner}}/{{project_name_lower}}` automatically on first
   publish; if someone manually changed the package's "Manage Actions
   access" setting (Org → Packages → {{project_name_lower}}-api → Settings), the
   linkage breaks. Re-add `{{github_owner}}/{{project_name_lower}}` as the source repo
   with **Read** role.
3. **Package visibility flipped to Internal/Private with restricted
   access.** Verify `{{project_name_lower}}-{api,web,dbmigrator}` are accessible
   from the staging Environment context.

If none of the above and you genuinely need a long-lived PAT for a
service-account or cross-org scenario, the historical setup was a
classic PAT at <https://github.com/settings/tokens> with
`read:packages` scope, plumbed via `secrets.GHCR_PULL_TOKEN`. The
workflows would need to be reverted to read that secret again — see
the git history of `staging-deploy.yml` for the older shape.

### Cloud-init didn't re-run after editing `cloud-init.yaml`

Cloud-init runs **once** at first boot. `terraform apply` on an existing
`hcloud_server.staging` does NOT re-run it. To re-bootstrap (the
primary IP and `/var/lib/{{project_name_lower}}/db` bind-mount survive):

```bash
cd terraform/staging
./rebootstrap.sh           # destroy + apply + SSH wait + cloud-init wait + smoke
```

Or raw, if you want to control each step:

```bash
cd terraform/staging
terraform destroy -target=hcloud_server.staging
terraform apply
# After apply, re-run the smoke test in Section 3.2.
```

Server-type bumps ({{hetzner_server_type}} -> cx33) are an exception — Hetzner rebuilds
in place (~30s downtime) without re-running cloud-init.

### HCP Terraform workspace missing / `terraform init` returns 403

Symptom: `Error: Failed to get existing workspaces: HTTP 403`. Cause:
workspace `{{project_name_lower}}-staging` doesn't exist under your HCP org, OR
**Execution Mode != Local**, OR stale credentials at
`~/.terraform.d/credentials.tfrc.json`.

Fix: re-read Section 2.3; verify both workspace existence and
execution mode. `terraform login` refreshes the browser-issued token.
If you've changed orgs since the last login, delete the credentials
file and re-login.

### Postgres won't start — `permission denied` on data directory

`/var/lib/{{project_name_lower}}/db` ownership is wrong. The container runs as UID 70
(R1); the directory must be `700 70:70`. The `?:?` rendering is
normal — UID 70 has no matching name in the host's `/etc/passwd`.

```bash
ssh deploy@"$VM_IP" 'stat -c "%a %U:%G" /var/lib/{{project_name_lower}}/db'  # expect: 700 ?:?

# Fix (cloud-init does this on first boot; only re-run after manual mucking):
ssh deploy@"$VM_IP" 'sudo chown -R 70:70 /var/lib/{{project_name_lower}}/db && \
                     sudo chmod 700 /var/lib/{{project_name_lower}}/db'
```

See your `.ai-dlc/<your-intent>/discovery.md`
risk table R1 for the root cause.

### Browser says cert is for `app.localhost`

The Caddyfile default value kicked in because `{{PROJECTNAME_UPPER}}_WEB_HOSTNAME`
didn't reach the container. Verify the env was rendered:

```bash
ssh deploy@"$VM_IP" 'sudo cat /etc/{{project_name_lower}}/.env.staging | grep HOSTNAME'
# Expect:
#   {{PROJECTNAME_UPPER}}_API_HOSTNAME=api.5-75-10-22.sslip.io
#   {{PROJECTNAME_UPPER}}_WEB_HOSTNAME=app.5-75-10-22.sslip.io
```

If the values are missing or wrong, the `STAGING_API_HOSTNAME` /
`STAGING_WEB_HOSTNAME` GitHub Environment variables weren't populated
when the deploy ran. Re-check Section 3.3, then re-trigger the deploy.

### `/health-live` returns 404 instead of 200

You hit the wrong path. The contract is exactly `/health-live` —
no trailing slash, no `/api/` prefix.

- `/health-live` -> 200, empty body (anonymous, no DB hit).
- `/health-ready` -> 200/503, auth-gated (admin or `health-monitor`
  role).
- `/health`, `/health-status`, `/health-ui`, `/health-api` -> 404 by
  design. Audit finding F-021 removed the old `HealthChecks.UI`
  surface; migrate any external scrape to `/health-ready` with a
  service-account token.

See `CLAUDE.md` -> Operational endpoints.

### Forgot to accept api.X cert; SPA login fails

Symptom: SPA loads, click Login, OIDC roundtrip completes, SPA stalls
or `ERR_CERT_AUTHORITY_INVALID` shows in DevTools Network.

Cause: only the `app.X` cert is accepted; the SPA's `fetch` to `api.X`
hits an untrusted cert. Fix: visit
`https://api.<dashed-ip>.sslip.io/health-live` directly, accept the
warning, retry login. Each browser stores cert acceptance per-origin.

### Login: OIDC `/connect/authorize` returns 400 (redirect_uri not allowed)

Symptom: SPA POST `/Account/Login` succeeds (302), but the chained
GET `/connect/authorize?...&redirect_uri=https://app.<vm>.sslip.io...`
redirects to `https://api.<vm>.sslip.io/Error?httpStatusCode=400`. The
response body is `{"error":{"code":"{{ProjectName}}:OnboardingRequired",...}}`
which is misleading — the OnboardingRequired filter is overlaying the
underlying 400 from OpenIddict.

Cause: the OpenIddict client `{{ProjectName}}_App` row in
`OpenIddictApplications` has `RedirectUris` not matching the SPA's
configured `redirect_uri`. Most common: the row was seeded with the
compiled-in `http://localhost:4200` default because the migrator
didn't have the `OpenIddict__Applications__{{ProjectName}}_App__RootUrl`
env var set when it ran.

Verify the DB row:

```bash
ssh deploy@"$VM_IP" 'sudo /usr/bin/docker exec {{project_name_lower}}-db psql -U {{project_name_lower}} -d {{ProjectName}} \
  -c "SELECT \"ClientId\", \"RedirectUris\", \"PostLogoutRedirectUris\" \
      FROM \"OpenIddictApplications\" WHERE \"ClientId\" = '"'"'{{ProjectName}}_App'"'"';"'
```

Expected: both columns contain `["https://app.<dashed-ip>.sslip.io"]`.
If you see `["http://localhost:4200"]`, the migrator's env was wrong.

Fix:

1. Ensure `docker-compose.staging.yml`'s `migrator:` service has:
   ```yaml
   env_file:
     - path: /etc/{{project_name_lower}}/.env.staging
       required: false
   environment:
     OpenIddict__Applications__{{ProjectName}}_App__RootUrl: ${WEB_PUBLIC_URL}
   ```
2. Re-run the migrator from the workflow (`Staging Deploy` with
   `skip_migrator=false`) OR manually on the VM:
   ```bash
   ssh deploy@$VM_IP 'cd /srv/{{project_name_lower}} && sudo /usr/bin/docker compose \
     -f docker-compose.yml -f docker-compose.staging.yml \
     --env-file /etc/{{project_name_lower}}/.env.staging \
     --profile migrate run --rm --pull never migrator'
   ```
3. The seed contributor (`OpenIddictDataSeedContributor.cs`) uses
   `CreateOrUpdateApplicationAsync`, so re-running updates the existing
   row in-place. Verify with the SQL above.

The OpenIddict server caches client config — restart the api after
the DB update if the symptom persists for >30s:

```bash
ssh deploy@$VM_IP 'sudo /usr/bin/docker restart {{project_name_lower}}-api'
```

### Container can't read bind-mounted secret (`Permission denied` on `/app/appsettings.secrets.json`)

Symptom: `{{project_name_lower}}-api` or `{{project_name_lower}}-migrator` fails to start with:

```text
Unhandled exception. System.UnauthorizedAccessException: Access to the
path '/app/appsettings.secrets.json' is denied.
 ---> System.IO.IOException: Permission denied
```

Cause: the host file is owned `root:deploy` (or any other gid the
in-container `{{project_name_lower}}` user — uid `10001`, gid `10001` per the
Dockerfiles — is NOT a member of). Mode `0640` group-read doesn't
apply, and there's no world-read bit. The bind mount preserves host
uid/gid, so the container reads with its own uid against the file's
perm bits.

Fix: the deploy workflow now installs container-mounted secrets as
`-o 10001 -g 10001 -m 0640` (numeric ownership matches the in-image
`{{project_name_lower}}` user/group). The parent dir `/etc/{{project_name_lower}}/{api,migrator}`
stays `0750 root:deploy` (F001) so non-deploy host users still can't
traverse to reach the file. If you see this error after upgrading
from an older runbook revision, redeploy — the install lines in
`.github/workflows/staging-deploy.yml` were updated to set the right
ownership.

Quick check on the VM (via the docker workaround — `deploy` can't
read the file directly because the parent is gated):

```bash
ssh deploy@$VM_IP 'sudo /usr/bin/docker run --rm -v /etc/{{project_name_lower}}:/v:ro alpine \
  stat -c "%n %a %u:%g" /v/api/appsettings.secrets.json \
                       /v/migrator/appsettings.secrets.json \
                       /v/openiddict.pfx'
# Expected: %u:%g == 10001:10001 on all three files.
```

### Operator pitfalls discovered in first deploy (cross-ref index)

Curated list of non-obvious gotchas encountered during the initial
end-to-end staging deploy. Each one has detail elsewhere in the
runbook or in a commit message; this section is the index so future
operators can spot the pattern fast.

| Pitfall | Where to look |
|---|---|
| `gh secret set --body -` is interpreted as the LITERAL value `-`, not "read stdin." Use `gh secret set NAME --body "VALUE"` (literal) or `gh secret set NAME < file` (redirect). Symptom: every secret value renders as `"-"` in templates. | This section |
| Fine-grained PATs at `/tokens?type=beta` don't grant access to `{{github_owner}}/{{project_name_lower}}-*` packages unless the org explicitly enables them with org-level Packages:Read. Use `GITHUB_TOKEN` instead (workflows already do). | §12 "GHCR pull failed: `denied: denied`" |
| `cicd.yml`'s path-filter intentionally skips image builds for terraform-only / docs-only commits. To deploy HEAD after a series of infra commits, dispatch `cicd.yml` with `force_rebuild=true`. | §6.4 |
| `cloud-init.yaml` runs ONCE at first boot. Edits require `./rebootstrap.sh` (or raw `terraform destroy -target=hcloud_server.staging && terraform apply`) to re-bootstrap. The primary IP (`auto_delete=false`) and `/var/lib/{{project_name_lower}}/db` survive. | §12 "Cloud-init didn't re-run..." |
| The `deploy` user cannot stat anything under `/var/lib/{{project_name_lower}}` directly (parent is `0755 root:root` post-fix, but `db` subdir is `0700 70:70`). For files like `/var/lib/{{project_name_lower}}/.bootstrap-complete`, use the docker-mount workaround: `sudo docker run --rm -v /var/lib:/v:ro alpine cat /v/{{project_name_lower}}/.bootstrap-complete`. | This section |
| The migrator's compose service needs `env_file: .env.staging` AND `OpenIddict__Applications__{{ProjectName}}_App__RootUrl: ${WEB_PUBLIC_URL}` — without it, the OpenIddict client gets seeded with the compiled-in `http://localhost:4200` and login fails. | §12 "Login: OIDC ... returns 400" |
| Hetzner retired the `{{hetzner_server_type}}/cx32/cx42/cx52` server type names in 2026; current shapes are `{{hetzner_server_type}}/cx33/cx43/cx53` (same vCPU/RAM/disk, ~1 EUR more). | `terraform/staging/variables.tf` |
| `cloud-init.yaml` line `systemctl restart sshd` silently fails on Ubuntu 24.04 (unit is named `ssh.service`, not `sshd.service`); password auth stays enabled until manually restarted. | `terraform/staging/cloud-init.yaml` |
| `hcloud_server.ssh_keys` only injects pubkeys to `/root/.ssh/authorized_keys` (where Hetzner's image then forces a "login as user NONE" command); combined with `disable_root: true`, the deploy user gets ZERO pubkeys. Cloud-init must explicitly populate `ssh_authorized_keys:` for the deploy user via `templatefile()`. | `terraform/staging/cloud-init.yaml`, `terraform/staging/server.tf` |
| `docker-compose.yml` originally referenced `${ACME_EMAIL:-}` but `.env.staging` exposes `{{PROJECTNAME_UPPER}}_ACME_EMAIL`. Variable-name mismatch → Caddy crash-loops with empty `email` directive. | `docker-compose.yml:177` |
| `STAGING_DEPLOY_ENABLED` MUST be a repository-level variable, NOT environment-scoped. GitHub Actions doesn't expose environment-scoped vars to job-level `if:` expressions (the environment isn't bound until the job actually starts running). An env-scoped value silently fails the gate → auto-fire deploys are permanently skipped. | §4.4 |
| The deploy workflow's `Record last-known-good` step used `mktemp -d /tmp/{{project_name_lower}}-lkg.XXXXXX` but the cloud-init sudoers allowlist only permits `/usr/bin/rm -rf /tmp/{{project_name_lower}}-deploy.*`. The trailing `sudo rm -rf "$scratch"` failed with "password required"; `set -euo pipefail` killed the step AFTER the install commands had already landed the LKG files on disk. Use the `{{project_name_lower}}-deploy.*` prefix for any scratch directory the deploy will later `sudo rm -rf`. | `.github/workflows/staging-deploy.yml` "Record last-known-good" step |

### `terraform plan` parses `terraform.tfvars` incorrectly

CIDRs and pubkeys are strings — must be quoted.

```hcl
# CORRECT
ssh_allowed_cidrs    = ["1.2.3.4/32", "203.0.113.7/32"]
operator_ssh_pubkeys = ["ssh-ed25519 AAAA... op@laptop"]

# WRONG — unquoted CIDRs error with "Unsupported argument"
ssh_allowed_cidrs    = [1.2.3.4/32, 203.0.113.7/32]
```

### Deploy stalls at `SCP rendered files to VM scratch dir`

The runner's IP is not in `ssh_allowed_cidrs`. Either you've never
added it (Section 2.6), OR the runner's outbound IP rotated. SSH from
the runner to the VM verifies:

```bash
# Run ON the runner host:
ssh -i ~/.ssh/staging -o ConnectTimeout=10 deploy@"$VM_IP" 'echo ok'
# Expect 'ok' within 10s. A timeout = firewall blocking.
```

Fix: Section 9 ("SSH access and IP rotation"). After
`terraform apply` adds the runner's IP, the next workflow run succeeds.

### `docker login` works on the VM but `compose pull` fails with 401

The PAT's package scope doesn't cover the specific image.
Fine-grained PATs need owner + package access to match exactly: scope
the token to org `{{github_owner}}` with `read:packages` on `{{project_name_lower}}-api`,
`{{project_name_lower}}-dbmigrator`, `{{project_name_lower}}-web` (or "All packages" under the org).

### Stale Terraform state lock on `terraform apply`

If a previous apply was interrupted, HCP holds the lock. Retry first;
if the lock persists:

```bash
terraform force-unlock <LOCK_ID>   # paste lock ID from the error
```

Use `force-unlock` ONLY when no other apply is running (R2 — two
simultaneous operators can corrupt state). The GitOps flow (Section 13)
serializes `terraform apply` via the shared `staging-deploy` concurrency
group, which eliminates this race for any apply dispatched through
`staging-terraform-apply.yml`. For the manual flow (§3.1–§3.3): always
apply via one operator at a time and coordinate verbally.

### Notifications not appearing

Deploy/rollback ran but the Discord channel stayed silent. Walk the
list from cheapest to most-invasive check:

- **Secret unset.** `DISCORD_WEBHOOK_URL` not in the staging
  Environment. Workflow log shows
  `DISCORD_WEBHOOK_URL not set — skipping Discord notification`.
  Fix: §2.7.
- **Secret value typo'd.** Operator pasted only the trailing token,
  or the full URL with whitespace. Workflow log shows the curl
  invocation but no message lands. Fix: re-copy from Discord (no
  trailing newline) and paste fresh into the GitHub secret.
- **Channel deleted / webhook revoked.** Someone deleted the Discord
  channel, or used **Edit Webhook → Delete Webhook**. Discord returns
  HTTP 404; the `|| true` swallows it so the deploy still passes.
  Workflow log shows `curl: (22) The requested URL returned error: 404`.
  Fix: create a new webhook (§2.7 step 1) and update the secret.
- **Discord outage.** `curl --max-time 10 --retry 2` exits non-zero;
  the deploy step still passes (notification is best-effort).
  Check <https://discordstatus.com/>. No fix needed — re-trigger
  manually after recovery if the missed run was important.
- **Webhook posting to wrong channel.** Webhook is bound to the
  channel it was created in; you can change channels via **Edit
  Webhook → Channel**. No code change needed.

---

## 13. GitOps for terraform

The four workflows under `.github/workflows/staging-terraform-*.yml`
are the default flow for ongoing changes to `terraform/staging/**`
after the VM is first provisioned (Section 3). Use the manual
`terraform apply` flow only for break-glass / first-provision
(see §3.0).

### 13.1 Workflow layout — wrappers + reusable templates

The staging terraform workflows are organised in **two layers**:

1. **Reusable templates** under `.github/workflows/_terraform-*.yml`
   (`_terraform-plan.yml`, `_terraform-apply.yml`,
   `_terraform-destroy.yml`, `_terraform-drift.yml`). These hold the
   actual logic — terraform init/validate/plan/apply, PR-comment
   posting, drift-issue dedup, Discord embeds, secret masking — and
   are invoked only via `workflow_call` from per-env wrappers. The
   `_` prefix is a community convention signalling "private / not
   directly triggerable".
2. **Per-env wrappers** under
   `.github/workflows/<env>-terraform-*.yml` (staging:
   `staging-terraform-{plan,apply,destroy,drift}.yml`). Each wrapper
   is ~25-40 lines: it owns the trigger surface (`pull_request`,
   `workflow_dispatch`, `schedule`) and forwards env-specific values
   (env name, working directory, HCP workspace, concurrency group,
   drift-label prefix) to the matching reusable template via
   `uses: ./.github/workflows/_terraform-*.yml` + `with:`.

**Operators interact only with the wrappers.** A `gh workflow run`
invocation always names a `staging-terraform-*.yml` (or
`staging2-terraform-*.yml` for the staging2 env, once stood up);
the `_terraform-*.yml` files are never invoked directly. See the
reusable templates for implementation details when debugging.

Adding a new env (e.g., a future production env) is three pieces:
its operator runbook (`docs/env-setup.md`), a new `terraform/<env>/`
root, and four new `<env>-terraform-*.yml` wrappers — the reusable
templates are reused unchanged.

### 13.1.1 The four staging wrappers at a glance

`staging-terraform-plan.yml` runs on every pull request whose diff
touches `terraform/staging/**` (or the shared
`terraform/modules/{{project_name_lower}}-env/**.tf` / `**.tftpl` cloud-init
template) and posts the `terraform plan` output as a PR comment so
reviewers see the actual infrastructure diff before approving the
merge. `staging-terraform-apply.yml` is `workflow_dispatch`-only and
applies the reviewed plan against HCP Terraform after the operator
types the confirm string (see §13.4). `staging-terraform-destroy.yml`
is `workflow_dispatch`-only and tears down the staging VM (or a
targeted subset of resources) after a double-typed-confirm gate (see
§13.6). `staging-terraform-drift.yml` runs daily at `0 6 * * *`
(06:00 UTC) and opens a GitHub issue + Discord ping if actual Hetzner
state diverges from the committed module. All four wrappers live in
`.github/workflows/` and read `HCP_TF_TOKEN` + `HCLOUD_TOKEN` from
the `staging` Environment (Section 2.4) via `secrets: inherit`.

### 13.2 How to make an infra change

1. Open a PR against `main` that touches any file under
   `terraform/staging/**`. The PR must be from a branch in the
   `{{github_owner}}/{{project_name_lower}}` repo, NOT a fork (see §13.7).
2. Wait ~2 minutes for the plan comment posted by `github-actions[bot]`.
   The comment is identifiable by the literal HTML sentinel
   `<!-- terraform-plan-comment-marker-staging -->` on the first line
   of the body — the workflow uses that env-suffixed sentinel to find
   and edit its own prior comment on subsequent pushes.
3. Review the diff inside the collapsible `<details><summary>Plan
   output</summary>` block. Verify the add/change/destroy counts and
   the specific resource changes match your intent.
4. Push fixups as needed. Each push EDITS the same comment in place
   (the per-env per-PR concurrency group
   `terraform-plan-staging-<PR-number>` cancels the in-flight
   superseded run; only the latest commit's plan matters).
5. Merge the PR.
6. From the GitHub Actions UI (**Actions** → **Staging Terraform
   Apply** → **Run workflow**) or the `gh` CLI, dispatch
   `staging-terraform-apply.yml` with the confirm string (see §13.4).
7. Watch the Discord channel (if `DISCORD_WEBHOOK_URL` is configured
   per §2.7) for the green "✅ Terraform Apply Succeeded" embed.

### 13.3 How to read a plan comment

Every plan comment starts with the literal HTML marker
`<!-- terraform-plan-comment-marker-staging -->` on line 1 (the marker
is env-suffixed so a multi-env PR gets a distinct comment per env).
The status header on the next line is
`### terraform plan (staging) succeeded` or
`### terraform plan (staging) FAILED — outcome: <outcome>`. The plan
body is inside a collapsible `<details><summary>Plan output</summary>`
block.

If the rendered plan exceeds 60,000 chars, the comment body is
head/tail-truncated with the marker
`[... output truncated, see tfplan artifact ...]` — the first 25,000
chars + the truncation marker + the last 25,000 chars. Download the
full plan from the workflow run's `tfplan-staging-<PR-number>` artifact
(retained 7 days):

```bash
gh run download <run-id> -n tfplan-staging-<PR-number>
```

The artifact contains the binary `tfplan.bin` Terraform produced;
re-render it locally for forensic inspection:

```bash
terraform show tfplan.bin
```

### 13.4 How to dispatch apply

Run the dispatch from your operator box:

```bash
gh workflow run staging-terraform-apply.yml -f confirm="yes I have read the plan" [-f commit_sha=<full-sha>]
```

Omit `commit_sha` to apply HEAD of `origin/main` (resolved at dispatch
time via `gh api repos/<repo>/commits/main`, NOT `github.sha` — see
the safety note in the workflow header). Pass an explicit reviewed
commit SHA when multiple infra PRs are in flight and main has moved
past the SHA you reviewed.

**Wrong confirm string failure mode.** Any value other than the exact
literal `yes I have read the plan` (e.g., `confirm=yes`, a trailing
space, a missing word) causes the workflow to fail at the
`Validate confirm input` step with:

```text
::error::confirm input must be exactly: yes I have read the plan
```

This step runs BEFORE any HCP Terraform or Hetzner Cloud contact, so a
typo is fully recoverable — re-dispatch with the correct literal.

The apply step joins the `staging-deploy` concurrency group with
`cancel-in-progress: false`, so it queues behind any in-flight
`staging-deploy.yml` or `staging-rollback.yml` rather than racing
them. See §13.8 for the concurrency taxonomy.

**Apply waits for cloud-init.** After `terraform apply` succeeds, the
workflow SSHes into the new (or existing) VM, runs
`cloud-init status --wait`, and confirms the
`/var/lib/{{project_name_lower}}/.bootstrap-complete` marker is present BEFORE
reporting green. Mirrors `terraform/staging/rebootstrap.sh` Phase 3 +
Phase 4 — so when the green Discord embed fires ("VM is deploy-ready"),
the immediate next `staging-deploy.yml` dispatch will pass its own
cloud-init check. On a no-op apply (no resource changes), the wait
returns instantly because cloud-init was already done on a prior boot.
On a fresh VM where cloud-init errored, this step fails loud with a
pointer to `/var/log/cloud-init-output.log` on the VM — the terraform
state is already mutated, so the operator inspects the VM, fixes
`terraform/staging/cloud-init.yaml`, and re-applies (which is
idempotent for a healthy server; a fresh provision re-triggers
cloud-init naturally).

For the destroy-then-rebuild flow (e.g., re-applying `cloud-init.yaml`
changes to the live VM, or recovering from a wedged state), see §13.9.

### 13.5 How to respond to a drift alert

1. Open the auto-created GitHub issue. Drift issues carry the
   `infrastructure-drift-staging` label and the title
   `[infrastructure-drift-staging] YYYY-MM-DD: drift detected in {{project_name_lower}}-staging`.
2. Read the plan diff in the issue body (head/tail-truncated to 60,000
   chars with the same convention as PR plan comments; the full plan
   is in the linked workflow run log).
3. Decide whether the change was intentional:
   - **Intentional out-of-band change** (e.g., someone resized the VM
     in the Hetzner Cloud Console). Update `terraform/staging/**.tf`
     to match the actual state and open an infra PR (§13.2). Merging +
     applying re-aligns the committed code with reality. The drift
     issue auto-closes on the next clean drift run with the comment
     `Drift resolved at <timestamp>`.
   - **Accidental change** (stray console click, partial apply, etc.).
     Revert the change in the Hetzner Cloud Console (or via the
     `hcloud` CLI), then manually re-trigger the drift workflow to
     confirm clean state: `gh workflow run staging-terraform-drift.yml`.
     The drift issue auto-closes on the resulting clean run.

**For `infrastructure-drift-error-staging` issues** (terraform `plan`
itself errored — exit code 1, e.g., `HCP_TF_TOKEN` revoked, Hetzner
Cloud API outage, provider version mismatch, HCL syntax broken on the
default branch): no dedup. Every error opens a fresh issue so
operators cannot miss one. Triage by reading the workflow run log for
the actual terraform error message; rotate the token / wait out the
outage / fix the HCL / etc., then re-dispatch
`gh workflow run staging-terraform-drift.yml` to confirm.

**False-positive drift caveat.** Hetzner occasionally reports
cosmetic field changes (`updated` timestamps, server status flickers).
Re-run `gh workflow run staging-terraform-drift.yml` manually before
treating any single drift issue as actionable; a transient flicker
that disappears on the next run is not a real divergence.

### 13.6 Required one-time label setup

The drift workflow uses two per-env GitHub labels —
`infrastructure-drift-staging` (yellow, exit code 2) and
`infrastructure-drift-error-staging` (red, exit code 1). The
per-env suffix prevents multi-env drift from collapsing into a single
issue queue (each env owns its own label pair). The workflow assumes
both labels exist on the repo; if not, `gh issue create --label ...`
fails loudly and no drift issue is filed. Run these two commands once
per repo (idempotent — `gh label create` errors if the label already
exists, which is the correct signal that the one-time setup is
already done):

```bash
gh label create infrastructure-drift-staging \
  --color FFC107 \
  --description "Daily staging-terraform-drift workflow detected divergence between actual infra state and terraform/staging/"

gh label create infrastructure-drift-error-staging \
  --color D73A4A \
  --description "Daily staging-terraform-drift workflow errored (terraform plan exit 1) — operator triage needed"
```

**One-time rename note (pre-multi-env shape).** The drift labels
were previously named `infrastructure-drift` and
`infrastructure-drift-error` (no env suffix). If you are upgrading a
repo from the pre-multi-env shape, close all open drift issues
first, then rename the labels. This is load-bearing — the new drift
template's dedup search keys on the new title prefix
(`Drift detected on staging`), so old-titled open issues would
otherwise be orphaned under the renamed label.

```bash
# Step 1: close all open drift + drift-error issues
gh issue list --label infrastructure-drift --state open --json number --jq '.[].number' | \
  xargs -I {} gh issue close {} -c "Closing pre-migration; will reopen in next drift cycle if drift persists."
gh issue list --label infrastructure-drift-error --state open --json number --jq '.[].number' | \
  xargs -I {} gh issue close {} -c "Closing pre-migration; will reopen on next drift error."

# Step 2: rename the labels
gh label edit infrastructure-drift --name infrastructure-drift-staging
gh label edit infrastructure-drift-error --name infrastructure-drift-error-staging
```

### 13.7 Fork-PR limitation

GitHub does NOT pass repository or environment secrets to workflow
runs triggered by `pull_request` from a fork.
`staging-terraform-plan.yml` will therefore fail at `terraform init`
(no `HCP_TF_TOKEN` available) for any fork PR. **This is the correct
security posture** — fork PRs must not be able to exfiltrate staging
tokens.

**Operational implication:** infra PRs must be opened from a branch
in the `{{github_owner}}/{{project_name_lower}}` main repo, NOT from a fork. If a
community contributor proposes an infra change via a fork PR, an
operator pulls the branch locally, pushes it as a same-repo branch,
and re-opens the PR from the same-repo branch. The original fork PR
can then be closed with a pointer to the new same-repo PR.

### 13.8 Concurrency taxonomy

| Workflow | Concurrency group | Cancel-in-progress |
|---|---|---|
| `staging-terraform-plan.yml` | `terraform-plan-staging-<PR-number>` | `true` |
| `staging-terraform-apply.yml` | `staging-deploy` (shared with `staging-deploy.yml`, `staging-rollback.yml`) | `false` |
| `staging-terraform-destroy.yml` | `staging-deploy` (shared with `staging-deploy.yml`, `staging-rollback.yml`, `staging-terraform-apply.yml`) | `false` |
| `staging-terraform-drift.yml` | NONE (read-only, no state mutation) | n/a |

The shared `staging-deploy` group is the safety mutex that serializes
deploy ↔ apply ↔ destroy ↔ rollback so `terraform apply` /
`terraform destroy` never races with a deploy mid-flight; drift is
intentionally outside the lock so divergence is never blocked behind a
long-running deploy.

### 13.9 How to destroy and rebuild

`staging-terraform-destroy.yml` is the GitHub Actions analogue of
`terraform/staging/rebootstrap.sh` Phase 1. Use it when you need a
clean re-bootstrap of the staging VM (cloud-init.yaml change applied
to live VM, wedged state, verifying the destroy → apply → deploy
loop) and want the audit trail captured in GitHub Actions, or when
you don't have local Terraform set up.

**When to use this vs `rebootstrap.sh`.** `rebootstrap.sh` runs from
your operator box and is the preferred path when you already have
local Terraform + the Hetzner token in `~/.config/{{project_name_lower}}/staging.env`
(see runbook §2.2 and §3.0). Reach for this workflow when you want
the destroy captured in the GitHub Actions audit log, when you don't
have local Terraform installed, or when the in-VM tooling is broken.

**Scope choice — pick carefully.**

- `targeted` (default, recommended) destroys `hcloud_server.staging`,
  `hcloud_rdns.staging`, and `hcloud_firewall_attachment.staging`.
  The primary IP, firewall ruleset, DNS records, and SSH key
  resources all survive. The next `staging-terraform-apply.yml`
  dispatch re-creates the server and reuses the same IP —
  `STAGING_VM_IP` and the DNS records stay valid, no operator action
  needed before the next deploy.
- `full` destroys the entire workspace, including
  `hcloud_primary_ip.staging`. The primary IPv4 is released back to
  Hetzner's pool. The next apply allocates a fresh IP. After
  re-apply you MUST update `STAGING_VM_IP` in the staging
  Environment and the Cloudflare/sslip.io DNS records before the
  next deploy works (runbook §3.3).

**Exact invocation.**

```bash
gh workflow run staging-terraform-destroy.yml \
  -f confirm="yes I have read the destroy plan" \
  -f confirm_destroy="yes destroy the staging infrastructure" \
  -f scope=targeted
```

Set `scope=full` for the everything-including-IP variant. Add `-f
targets="<addr1>,<addr2>"` to override the canonical targeted set
when `scope=targeted` (rare; the default targeted set is what the
wrapper assembles automatically).

**Wrong confirm string failure mode.** Either confirm input that
doesn't match its expected literal causes the workflow to fail at
the corresponding `Validate confirm*` step with:

```text
::error::confirm input must be exactly: yes I have read the destroy plan
```

or:

```text
::error::confirm_destroy input must be exactly: yes destroy the staging infrastructure
```

Both checks run BEFORE any HCP Terraform or Hetzner Cloud contact, so
a typo is fully recoverable — re-dispatch with both correct literals.

**Rebuild after destroy.** Dispatch `staging-terraform-apply.yml`
(§13.4) once the destroy run is green. For `scope=full`, the order is:
(1) dispatch `staging-terraform-apply.yml` to re-allocate the primary
IP + re-create the server (the apply run's step summary contains the
new `vm_ipv4` from `terraform output -json`); (2) update `STAGING_VM_IP`
and the two `STAGING_*_HOSTNAME` repo/env variables in the staging
Environment to the new IP (runbook §3.3); (3) update
Cloudflare/sslip.io DNS records to point at the new IP; (4) dispatch
`staging-deploy.yml` to bring the app back up. Order matters — you
cannot pre-populate `STAGING_VM_IP` before apply because the IP
doesn't exist yet. `staging-deploy.yml` does NOT auto-fire after
destroy — the operator explicitly dispatches deploy at step (4).

**The known_hosts cleanup happens automatically.** The workflow
reads `terraform output -raw vm_ipv4` BEFORE destroy and runs
`ssh-keygen -R <ip>` against the self-hosted runner's
`~/.ssh/known_hosts` after destroy succeeds. The next
`staging-deploy.yml` run won't TOFU-fail on the replacement VM's
host key. A `::notice::Cleared stale known_hosts entry for <ip>`
line in the workflow log confirms the cleanup fired.

**Concurrency.** The destroy step joins the `staging-deploy` group
with `cancel-in-progress: false` (same as apply, deploy, rollback).
A destroy dispatched while a deploy / apply / rollback is in-flight
QUEUES rather than racing. Drift detection (§13.5) is the only
staging-workspace workflow NOT in this group — see §13.8.

### 13.10 Required one-time operator variable setup

The four `staging-terraform-*.yml` wrappers forward three required
terraform variables from the `staging` GitHub Environment to the
reusable templates. The values are
**operator-side inputs** (IP allowlist, SSH keys) — not secrets in
the cryptographic sense, but environment-specific. Without these set,
`terraform plan` exits at `Error: No value for required variable`
and the workflow run fails before any infra contact.

| Name | Type | Source variable | Example value |
|---|---|---|---|
| `TF_VAR_hcloud_token` | Environment **secret** | `HCLOUD_TOKEN` (already set per §2.4) | `<hetzner-api-token>` |
| `TF_VAR_ssh_allowed_cidrs` | Environment **variable** | `STAGING_SSH_ALLOWED_CIDRS` | `["203.0.113.7/32","198.51.100.42/32"]` |
| `TF_VAR_operator_ssh_pubkeys` | Environment **variable** | `STAGING_OPERATOR_SSH_PUBKEYS` | `["ssh-ed25519 AAAA... operator@laptop"]` |

The two list-valued variables use terraform's `TF_VAR_<name>` JSON
convention: the value is a JSON-encoded string of the list. Set via
`gh`:

```bash
gh variable set STAGING_SSH_ALLOWED_CIDRS    --env staging --body '["203.0.113.7/32"]'
gh variable set STAGING_OPERATOR_SSH_PUBKEYS --env staging --body '["ssh-ed25519 AAAA... operator@laptop"]'
```

Or via the GitHub UI: Settings → Environments → `staging` →
Environment variables → Add variable.

When an operator joins/leaves or an IP changes, re-set the relevant
variable; the next workflow dispatch picks up the new value
automatically. There is no in-VM equivalent of "re-issue the SSH key";
a `staging-terraform-apply.yml` dispatch after updating
`STAGING_OPERATOR_SSH_PUBKEYS` rotates the Hetzner SSH-key resources
on the next plan.

This wiring is a **quick patch**. The fuller treatment (multi-env
naming convention `STAGING_*` / `STAGING2_*` / `PROD_*`, Cloudflare
token handling, encrypted-tfvars vs env-vars decision, rotation
governance) is tracked in `.ai-dlc/terraform-var-wiring/intent.md`
for a dedicated elaboration pass.

---

## Appendix: Quick reference

| Need                                             | Command / location                                                       |
|--------------------------------------------------|--------------------------------------------------------------------------|
| Provision the VM                                 | `cd terraform/staging && terraform init && terraform apply`              |
| Get the VM IPv4                                  | `cd terraform/staging && terraform output -raw vm_ipv4`                  |
| SSH in                                           | `ssh deploy@$(terraform output -raw vm_ipv4)` (from `terraform/staging`) |
| Trigger a deploy manually                        | Actions -> Staging Deploy -> Run workflow (or `gh workflow run staging-deploy.yml`) |
| Force-rebuild all images for HEAD                | Actions -> CICD -> Run workflow with `force_rebuild=true` (§6.4)         |
| Trigger a rollback                               | Actions -> Staging Rollback -> Run workflow                              |
| Read last-known-good tags                        | `ssh deploy@$VM_IP 'cat /etc/{{project_name_lower}}/last-known-good-*.env'`             |
| Tail all service logs                            | `ssh deploy@$VM_IP 'docker compose -f /srv/{{project_name_lower}}/docker-compose.yml -f /srv/{{project_name_lower}}/docker-compose.staging.yml --env-file /etc/{{project_name_lower}}/.env.staging logs --tail=200'` |
| Rotate an operator IP                            | Edit `terraform/staging/terraform.tfvars` -> `terraform apply`           |
| ~~Rotate the GHCR PAT~~                          | No longer applicable — workflows use `secrets.GITHUB_TOKEN` with `permissions: packages: read`; the old `GHCR_PULL_TOKEN` secret is retired |
| Flip Caddy to LE prod                            | Remove `acme_ca` line in `Caddyfile.staging` (Section 10 step 8)         |
| Rebuild the VM (preserves DB volume + IP)        | `cd terraform/staging && ./rebootstrap.sh` (or raw: `terraform destroy -target=hcloud_server.staging && terraform apply`) |
| Rebuild the VM **and** trigger fresh deploy      | `cd terraform/staging && ./rebootstrap.sh && gh workflow run staging-deploy.yml --repo {{github_owner}}/{{project_name_lower}} --ref main` |
| Bump VM size                                     | Edit `server_type` in `terraform.tfvars` -> `terraform apply`            |
| Predecessor Docker / Compose / GHCR reference    | [`docs/docker.md`](docker.md)                                            |
| Terraform module reference                       | [`terraform/staging/README.md`](../terraform/staging/README.md)          |
| Deploy workflow                                  | [`.github/workflows/staging-deploy.yml`](../.github/workflows/staging-deploy.yml) |
| Rollback workflow                                | [`.github/workflows/staging-rollback.yml`](../.github/workflows/staging-rollback.yml) |
| Intent + discovery context (read-only)           | your `.ai-dlc/<your-intent>/` tree                  |
