#!/usr/bin/env bash
# lib/handoff.sh — unit-10 operator-handoff orchestration helpers.
#
# Sourced by scaffold.sh's `phase_handoff` (and also by phase_github_repo_init
# for the pre-commit .gitignore safety gate). The rendered handoff message
# lands on BOTH stdout (operator sees it inline) AND
# <target>/SCAFFOLD-HANDOFF.md (operator can revisit later or commit
# alongside if desired — NOT auto-committed per spec §Notes).
#
# Public entry-points:
#   handoff_render_message           <target_real>
#       Render the operator handoff via an unquoted heredoc that expands
#       ${PROJECT_NAME} / ${GITHUB_OWNER} / ${PROJECT_NAME_LOWER}. Writes
#       to BOTH stdout and ${target_real}/SCAFFOLD-HANDOFF.md.
#
#   handoff_assert_safe_to_commit    <target_real>
#       Pre-commit .gitignore tripwire. Refuses to git-init when known
#       dangerous patterns (appsettings.secrets*.json, *.tfstate*,
#       .terraform/, *.pfx) are NOT covered by the target's .gitignore.
#       Uses `git check-ignore` (side-effect-free; no file creation).

if [[ -n "${__LH_HANDOFF_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_HANDOFF_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# _handoff_inner_loop_install_libs
# Emit the right inner-loop install-libs / yarn-install lines for the
# resolved UI. Command-substituted INSIDE the unquoted heredoc.
_handoff_inner_loop_install_libs() {
    case "${UI:-angular}" in
        angular)
            printf 'abp install-libs\n'
            printf 'yarn --cwd angular install\n'
            ;;
        mvc|blazor)
            printf 'abp install-libs\n'
            ;;
        blazor-server)
            printf '# (no client libs needed for blazor-server)\n'
            ;;
        none)
            printf '# (UI=none — no client libs)\n'
            ;;
        *)
            printf 'abp install-libs\n'
            ;;
    esac
}

# _handoff_inner_loop_spa_start
# Emit the SPA start line for UIs that ship a separate SPA process.
_handoff_inner_loop_spa_start() {
    case "${UI:-angular}" in
        angular) printf 'yarn --cwd angular start\n' ;;
        *)       printf '# (host runs the UI for ui=%s)\n' "${UI:-<unset>}" ;;
    esac
}

# _handoff_quality_gates_ui
# Emit the SPA-side quality-gate commands when applicable.
_handoff_quality_gates_ui() {
    case "${UI:-angular}" in
        angular)
            printf 'yarn --cwd angular lint\n'
            printf 'yarn --cwd angular test --watch=false\n'
            printf 'yarn --cwd angular build\n'
            ;;
        *)
            printf '# (angular-specific quality gates skipped for ui=%s)\n' "${UI:-<unset>}"
            ;;
    esac
}

# handoff_render_message <target_real>
#
# Render the operator handoff message to stdout AND to
# ${target_real}/SCAFFOLD-HANDOFF.md. The heredoc is UNQUOTED so
# ${PROJECT_NAME} etc. expand. Every literal `$` inside command examples
# is escaped as `\$` so it lands verbatim.
handoff_render_message() {
    local target="$1"
    local handoff_file="${target}/SCAFFOLD-HANDOFF.md"

    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "[handoff] target dir missing: ${target}" \
            "handoff_render_message"
        return 1
    fi

    local install_libs_block spa_start_block quality_gates_ui_block
    install_libs_block="$(_handoff_inner_loop_install_libs)"
    spa_start_block="$(_handoff_inner_loop_spa_start)"
    quality_gates_ui_block="$(_handoff_quality_gates_ui)"

    local tmp
    tmp="$(mktemp -t scaffold-handoff.XXXXXX.md)"

    # Unquoted heredoc — ${PROJECT_NAME} / ${GITHUB_OWNER} etc. expand.
    # Literal `$` in command examples MUST be `\$` to land verbatim.
    cat > "$tmp" <<EOF
# Operator handoff — ${PROJECT_NAME}

Scaffold complete! Your new repo is at:
  https://github.com/${GITHUB_OWNER}/${PROJECT_NAME_LOWER}

## Inner-loop commands (do these next)

# 1. Copy secrets templates + fill in REPLACE_ME values
for f in src/${PROJECT_NAME}.HttpApi.Host src/${PROJECT_NAME}.DbMigrator; do
  cp \$f/appsettings.secrets.json.template \$f/appsettings.secrets.json
done
# Required keys: ConnectionStrings:Default, App:AdminPassword (both files);
# Host also needs: AuthServer:CertificatePassPhrase, StringEncryption:DefaultPassPhrase.

# 2. Install ABP client libs + Angular deps (UI=${UI:-angular})
${install_libs_block}
# 3. Generate OpenIddict dev cert
bash etc/generate-dev-openiddict-cert.sh

# 4. Apply migrations + seed
dotnet run --project src/${PROJECT_NAME}.DbMigrator

# 5. Run the host + Angular
dotnet run --project src/${PROJECT_NAME}.HttpApi.Host
${spa_start_block}
## Manual one-time setup (REQUIRED for full functionality)

[ ] **GitHub org setting**: enable "Allow Actions to create and approve PRs"
    at Settings → Actions → General → Workflow permissions
    Verify: gh api orgs/${GITHUB_OWNER}/actions/permissions/workflow \\
              --jq '.can_approve_pull_request_reviews'   # → true

[ ] **GitHub Environment 'staging'**: create at Settings → Environments
    → New environment → 'staging'. Required for staging-deploy.yml's
    \`environment: staging\` block to gate approvals + scope secrets.
    Verify: gh api repos/${GITHUB_OWNER}/${PROJECT_NAME_LOWER}/environments/staging

[ ] **HCP Terraform workspace**: open the HCP UI for workspace
    \`${PROJECT_NAME_LOWER}-staging\`, set Execution Mode → Local, save.
    (No API for this — must be clicked in the UI.)

[ ] **HCP_TF_TOKEN secret**: create at Settings → Secrets and variables
    → Actions → New repository secret. Value: an HCP Terraform user
    or team API token with workspace-write access to ${PROJECT_NAME_LOWER}-staging.
    Used by every \`_terraform-*.yml\` workflow.
    Verify: gh secret list -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER} | grep HCP_TF_TOKEN

[ ] **STAGING_DEPLOY_SSH_KEY secret**: ssh-ed25519 PRIVATE key that
    matches terraform/staging/terraform.tfvars' \`ssh_public_key\`.
    Required by staging-deploy.yml to ssh into the VM.
    Verify: gh secret list -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER} | grep STAGING_DEPLOY_SSH_KEY

[ ] **STAGING_DEPLOY_ENABLED variable** (kill switch, defaults OFF):
    set to \`true\` AFTER you've verified a manual workflow_dispatch
    deploy works. WITHOUT this, the auto-deploy-after-CICD trigger
    never fires — main-branch merges produce green CI but no deploy.
    This is intentional (default-off auto-deploy lets you smoke-test
    before enabling).
    Set:    gh variable set STAGING_DEPLOY_ENABLED --body true -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER}
    Verify: gh variable list -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER} | grep STAGING_DEPLOY_ENABLED

[ ] **STAGING_SSH_ALLOWED_CIDRS + STAGING_OPERATOR_SSH_PUBKEYS variables**:
    operator IPs + ssh keys that the firewall + cloud-init authorize
    for ssh access to the staging VM. JSON-array values. Without these,
    no operator can ssh into the VM after \`terraform apply\`.
    Set:    gh variable set STAGING_SSH_ALLOWED_CIDRS  --body '["1.2.3.4/32"]' -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER}
            gh variable set STAGING_OPERATOR_SSH_PUBKEYS --body '["ssh-ed25519 AAAA... you@host"]' -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER}

[ ] **Sentry DSN** (optional but recommended): edit
    \`angular/dynamic-env.json\` and set the \`sentry.dsn\` value.
    Until then, SPA errors won't be reported (no-op contract — empty
    DSN means \`Sentry.init\` is not called, no network egress).

[ ] **CSP report-uri repoint**: edit \`angular/nginx.conf\` and replace
    the same-origin \`/csp-report\` stub with a real CSP-violation
    collector URL (Sentry-Security:
    https://sentry.io/api/<project>/security/?sentry_key=<key> ; or
    csper.io ; or a custom endpoint). Without this, every CSP
    violation report is silently dropped on the floor at deploy time.

[ ] **Cloudflare API token**: create a token scoped to
    \`Zone:DNS:Edit\` for your zone, store in HCP workspace as
    \`CLOUDFLARE_API_TOKEN\`. Required for \`terraform apply\` to
    create the DNS A record.

[ ] **Hetzner Cloud token**: create a token in Hetzner Cloud Console
    (Security → API tokens), store in HCP workspace as \`HCLOUD_TOKEN\`.

[ ] **Production OpenIddict cert**: generate with
      openssl pkcs12 -export -inkey prod-key.pem -in prod-cert.pem \\
        -out openiddict.pfx -password pass:\$PROD_PFX_PASS
    and bind-mount at deploy time. NEVER use the dev cert in prod.
    The host module's openiddict-cert ScaffoldBlock will throw
    InvalidOperationException at startup if AuthServer:CertificatePath
    is unset in Production.

[ ] **Optional Discord webhook**: set \`DISCORD_WEBHOOK_URL\` secret
    if you want deploy notifications.
    Set: gh secret set DISCORD_WEBHOOK_URL -R ${GITHUB_OWNER}/${PROJECT_NAME_LOWER}

## Quality gates

dotnet build ${PROJECT_NAME}.slnx
dotnet test ${PROJECT_NAME}.slnx
${quality_gates_ui_block}
## Documentation

- CLAUDE.md             → project guide (read at session start)
- docs/staging-runbook.md → operator runbook (deploy / rollback / troubleshooting)
- README.md             → user-facing project README

## Next: run /ai-dlc:elaborate

Now that the repo is set up, your first real intent can be elaborated:

  cd ${PROJECT_NAME_LOWER}
  claude    # or open the directory in Claude Code
  /ai-dlc:elaborate

The first deep elaboration will synthesize knowledge artifacts in .ai-dlc/knowledge/.

## Rollback (if you need to undo the scaffold)

  gh repo delete ${GITHUB_OWNER}/${PROJECT_NAME_LOWER} --yes
  rm -rf ${target}
EOF

    # tee to stdout + SCAFFOLD-HANDOFF.md.
    tee "$handoff_file" < "$tmp"
    rm -f "$tmp"
}

# handoff_assert_safe_to_commit <target_real>
#
# Tripwire that runs before `git add -A` in phase_github_repo_init.
# Enumerates dangerous-to-commit paths and verifies they would be
# ignored by the target's .gitignore. Uses `git check-ignore` so it's
# side-effect-free (no file creation).
#
# Returns 1 (caller hard-aborts) when:
#   - <target>/.gitignore is missing
#   - .gitignore is missing one of the required literal pattern lines
#   - `git check-ignore` says a danger path would NOT be ignored
handoff_assert_safe_to_commit() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "[handoff] target dir missing: ${target}" \
            "handoff_assert_safe_to_commit"
        return 1
    fi
    # Resolve project name with sane fallback for fixture-based tests.
    local pn="${PROJECT_NAME:-Sample}"
    local -a danger_files=(
        # secrets per CLAUDE.md (unit-05)
        "src/${pn}.HttpApi.Host/appsettings.secrets.json"
        "src/${pn}.DbMigrator/appsettings.secrets.json"
        "src/${pn}.HttpApi.Host/appsettings.secrets.staging.json"
        # dev/prod OpenIddict cert (unit-05)
        "openiddict.pfx"
        # terraform state + lockfiles (unit-07)
        "terraform/staging/terraform.tfstate"
        "terraform/staging/terraform.tfstate.backup"
        "terraform/staging/.terraform/"
        # private SSH keys (operator footgun)
        "id_ed25519"
        "id_rsa"
    )
    local -a danger_gitignore_lines=(
        "appsettings.secrets.json"
        "appsettings.secrets.*.json"
        "*.tfstate"
        ".terraform/"
        "*.pfx"
    )

    local gitignore="${target}/.gitignore"
    if [[ ! -f "$gitignore" ]]; then
        log_fail "[handoff] safety: ${target}/.gitignore missing — refusing to git-init" \
            "handoff_assert_safe_to_commit"
        return 1
    fi

    local violations=0
    local line
    for line in "${danger_gitignore_lines[@]}"; do
        # Whole-line, literal match. `*.tfstate` MUST NOT match
        # `*.tfstate.backup` — a gitignore that only has the longer
        # pattern still wouldn't ignore `terraform.tfstate`.
        if ! grep -qFx -- "$line" "$gitignore"; then
            log_fail "[handoff] safety: .gitignore missing required pattern: ${line}" \
                "handoff_assert_safe_to_commit"
            violations=$((violations + 1))
        fi
    done

    # check-ignore needs `.git/`. Bootstrap a temp one if absent.
    local needed_init=0
    if [[ ! -d "${target}/.git" ]]; then
        ( cd "$target" && git init -q )
        needed_init=1
    fi
    local f
    for f in "${danger_files[@]}"; do
        # check-ignore returns 0 if path is ignored, 1 if not. We want 0.
        if ! ( cd "$target" && git check-ignore -q "$f" 2>/dev/null ); then
            log_fail "[handoff] safety: '${f}' would NOT be ignored by .gitignore" \
                "git check-ignore ${f}"
            violations=$((violations + 1))
        fi
    done
    if (( needed_init == 1 )); then
        rm -rf "${target}/.git"
    fi

    if (( violations > 0 )); then
        log_fail "[handoff] safety gate found ${violations} violation(s); refusing to git-init" \
            "handoff_assert_safe_to_commit"
        return 1
    fi
    log_info "[handoff] safety gate clean (${#danger_files[@]} dangerous paths verified ignored)"
}
