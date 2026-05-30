#!/usr/bin/env bats
# tests/handoff.bats — unit-10 operator-handoff helpers.
#
# T3 is the 21-assertion line-content gate from the plan §4 list. T4
# guards against the heredoc silently leaking `${PROJECT_NAME}`
# un-substituted (we use unquoted <<EOF so shell expansion happens;
# a regression to <<'EOF' would be caught here).

load _helper

_setup_handoff_env() {
    TMP="$(mktemp -d -t handoff-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    mkdir -p "$TARGET"
    PN="SmokeApp"

    unset __LH_LOG_SH_SOURCED __LH_HANDOFF_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/handoff.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/handoff.sh"

    export PROJECT_NAME="$PN"
    export PROJECT_NAME_LOWER="${PN,,}"
    export GITHUB_OWNER=acme
    export UI=angular
}

teardown() {
    if [[ -n "${TMP:-}" && -d "${TMP}" ]]; then
        rm -rf "$TMP"
    fi
}

@test "T1: handoff_render_message writes SCAFFOLD-HANDOFF.md to target" {
    _setup_handoff_env
    run handoff_render_message "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/SCAFFOLD-HANDOFF.md" ]
}

@test "T2: handoff_render_message also writes to stdout" {
    _setup_handoff_env
    run handoff_render_message "$TARGET"
    [ "$status" -eq 0 ]
    # Header line lands in stdout.
    echo "$output" | grep -q '# Operator handoff — SmokeApp'
}

@test "T3: rendered handoff contains every required substring (21 assertions)" {
    _setup_handoff_env
    handoff_render_message "$TARGET" > /dev/null
    f="${TARGET}/SCAFFOLD-HANDOFF.md"
    # 1. Project URL substituted.
    grep -qF 'https://github.com/acme/smokeapp' "$f"
    # 2. Secrets templates copy.
    grep -qF 'appsettings.secrets.json.template' "$f"
    # 3. Org workflow-perms verify line.
    grep -qF 'gh api orgs/acme/actions/permissions/workflow' "$f"
    # 4. GitHub Environment 'staging' line.
    grep -qF "GitHub Environment 'staging'" "$f"
    # 5. HCP Terraform workspace section.
    grep -qF 'HCP Terraform workspace' "$f"
    # 6. Execution Mode hint.
    grep -qF 'Execution Mode → Local' "$f"
    # 7. HCP_TF_TOKEN secret.
    grep -qF 'HCP_TF_TOKEN' "$f"
    # 8. SSH key secret.
    grep -qF 'STAGING_DEPLOY_SSH_KEY' "$f"
    # 9. Kill-switch variable.
    grep -qF 'STAGING_DEPLOY_ENABLED' "$f"
    # 10. Firewall variable.
    grep -qF 'STAGING_SSH_ALLOWED_CIDRS' "$f"
    # 11. Sentry DSN section.
    grep -qF 'Sentry DSN' "$f"
    grep -qF 'angular/dynamic-env.json' "$f"
    # 12. CSP report-uri repoint.
    grep -qF 'CSP report-uri' "$f"
    grep -qF 'angular/nginx.conf' "$f"
    # 13. Cloudflare API token.
    grep -qF 'CLOUDFLARE_API_TOKEN' "$f"
    # 14. Hetzner Cloud token.
    grep -qF 'HCLOUD_TOKEN' "$f"
    # 15. OpenIddict dev cert script.
    grep -qF 'generate-dev-openiddict-cert.sh' "$f"
    # 16. Prod cert pfx.
    grep -qF 'openiddict.pfx' "$f"
    # 17. Quality gates header.
    grep -qF '## Quality gates' "$f"
    # 18. dotnet build line (substituted).
    grep -qF 'dotnet build SmokeApp.slnx' "$f"
    # 19. dotnet test line (substituted).
    grep -qF 'dotnet test SmokeApp.slnx' "$f"
    # 20. ai-dlc:elaborate.
    grep -qF '/ai-dlc:elaborate' "$f"
    # 21. Rollback line (substituted).
    grep -qF 'gh repo delete acme/smokeapp --yes' "$f"
}

@test "T4: rendered handoff substitutes \${PROJECT_NAME} / \${GITHUB_OWNER} (no literal \${} tokens)" {
    _setup_handoff_env
    handoff_render_message "$TARGET" > /dev/null
    f="${TARGET}/SCAFFOLD-HANDOFF.md"
    # No literal ${PROJECT_NAME} / ${GITHUB_OWNER} / ${PROJECT_NAME_LOWER}
    # tokens leak through.
    ! grep -qF '${PROJECT_NAME}' "$f"
    ! grep -qF '${GITHUB_OWNER}' "$f"
    ! grep -qF '${PROJECT_NAME_LOWER}' "$f"
}

@test "T5: rendered handoff selects angular install for UI=angular" {
    _setup_handoff_env
    export UI=angular
    handoff_render_message "$TARGET" > /dev/null
    f="${TARGET}/SCAFFOLD-HANDOFF.md"
    grep -qF 'abp install-libs' "$f"
    grep -qF 'yarn --cwd angular install' "$f"
}

@test "T6: rendered handoff selects abp install-libs for UI=mvc" {
    _setup_handoff_env
    export UI=mvc
    handoff_render_message "$TARGET" > /dev/null
    f="${TARGET}/SCAFFOLD-HANDOFF.md"
    grep -qF 'abp install-libs' "$f"
    # No yarn line (we're MVC, not angular).
    ! grep -qF 'yarn --cwd angular install' "$f"
}

@test "T7: rendered handoff omits 'yarn --cwd angular build' for UI=mvc" {
    _setup_handoff_env
    export UI=mvc
    handoff_render_message "$TARGET" > /dev/null
    f="${TARGET}/SCAFFOLD-HANDOFF.md"
    ! grep -qF 'yarn --cwd angular build' "$f"
}

@test "T8: rendered handoff handles blazor-server UI gracefully" {
    _setup_handoff_env
    export UI=blazor-server
    handoff_render_message "$TARGET" > /dev/null
    f="${TARGET}/SCAFFOLD-HANDOFF.md"
    # No yarn-install line.
    ! grep -qF 'yarn --cwd angular install' "$f"
    # And the "no client libs needed" hint is present.
    grep -qF 'blazor-server' "$f"
}

@test "T9: phase_handoff is a no-op under --dry-run" {
    TMP2="$(mktemp -d -t handoff-phase-bats.XXXXXX)"
    trap "rm -rf '$TMP2'" RETURN
    cfg="${TMP2}/c.yml"
    cat > "$cfg" <<'EOF'
project_name: SmokeApp
github_owner: acme
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
  hetzner_server_type: cx22
  cloudflare_zone: example.com
EOF
    run bash "${SCAFFOLD_ROOT}/scaffold.sh" \
        --config "$cfg" \
        --target "${TMP2}/out" \
        --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[handoff\] dry-run: skipping'
    # No SCAFFOLD-HANDOFF.md written under --dry-run.
    [ ! -f "${TMP2}/out/SCAFFOLD-HANDOFF.md" ]
}

@test "T10: phase_handoff renders correctly for all valid UI values" {
    for ui in angular mvc blazor blazor-server none; do
        TMP_LOOP="$(mktemp -d -t handoff-ui-bats.XXXXXX)"
        TARGET_LOOP="${TMP_LOOP}/SmokeApp"
        mkdir -p "$TARGET_LOOP"
        unset __LH_LOG_SH_SOURCED __LH_HANDOFF_SH_SOURCED
        # shellcheck source=lib/log.sh disable=SC1091
        source "${SCAFFOLD_ROOT}/lib/log.sh"
        # shellcheck source=lib/handoff.sh disable=SC1091
        source "${SCAFFOLD_ROOT}/lib/handoff.sh"
        export PROJECT_NAME=SmokeApp PROJECT_NAME_LOWER=smokeapp \
               GITHUB_OWNER=acme UI="$ui"
        run handoff_render_message "$TARGET_LOOP"
        [ "$status" -eq 0 ] || { echo "ui=$ui failed: $output"; rm -rf "$TMP_LOOP"; return 1; }
        [ -f "${TARGET_LOOP}/SCAFFOLD-HANDOFF.md" ]
        rm -rf "$TMP_LOOP"
    done
}
