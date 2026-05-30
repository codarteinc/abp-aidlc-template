#!/usr/bin/env bats
# tests/overlay_terraform.bats — end-to-end test of unit-07's
# terraform-overlay phase.
#
# Stands up a minimal abp-new-like tree, copies the template/terraform/
# overlay onto it, then runs the unit-07 phase entrypoints
# (terraform_overlay_render_templated_files +
# terraform_overlay_install_script_perms +
# terraform_overlay_splice_gitignore) and asserts the rendered surface
# matches the plan §1 layout.
#
# Terraform-CLI-gated tests skip cleanly when terraform isn't on PATH.

load _helper

_setup_phase_env() {
    local target="$1" pn="$2"
    export PROJECT_NAME="$pn"
    export PROJECT_NAME_LOWER="${pn,,}"
    export PROJECTNAME_UPPER="${pn^^}"
    export TARGET_DIR="$target"
    export ABP_VERSION=10.3.0
    export IF_UI_ANGULAR=1 IF_UI_MVC=0 IF_UI_BLAZOR=0 IF_UI_BLAZOR_SERVER=0 IF_UI_NONE=0
    export IF_DB_EF=1 IF_DB_MONGODB=0 IF_MULTI_TENANCY=0 IF_TIERED=0
    export GITHUB_OWNER=codarteinc HCP_ORG=codarteinc
    export DBMS=postgresql UI=angular DB_PROVIDER=ef DEFAULT_CULTURE=en
    export MULTI_TENANCY=false TIERED=false
    export HETZNER_LOCATION=hel1 HETZNER_SERVER_TYPE=cx23 CLOUDFLARE_ZONE=example.com
    unset __LH_LOG_SH_SOURCED __LH_SUBSTITUTE_SH_SOURCED \
          __LH_DOTNET_OVERLAY_SH_SOURCED __LH_SECURITY_OVERLAY_SH_SOURCED \
          __LH_DOCKER_OVERLAY_SH_SOURCED __LH_TERRAFORM_OVERLAY_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/substitute.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/substitute.sh"
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/dotnet-overlay.sh"
    # shellcheck source=lib/terraform-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/terraform-overlay.sh"
    LIB_DIR="${SCAFFOLD_ROOT}/lib"
    TEMPLATE_DIR="${SCAFFOLD_ROOT}/template"
    DRY_RUN=0
    DRY_RUN_ABP_NEW=0
    CURRENT_PHASE=""
    STEP_TOTAL=1
    STEP=0
    _phase_start() {
        CURRENT_PHASE="$1"
        STEP=$((STEP + 1))
        log_step "$STEP" "$STEP_TOTAL" "$CURRENT_PHASE"
    }
}

# Copy the unit-07 terraform-overlay template tree into the seeded
# target tree, mirroring what phase_apply_overlays does (substitute
# {{PROJECTNAME}} -> $PROJECT_NAME in path segments; .tmpl bodies go
# through substitute_tmpl; no-suffix bodies go through substitute_file;
# .template files are left in place for the unit-07 phase to render).
# Also drops a minimal .gitignore with the unit-07 marker pair so the
# splice test has something to operate on.
_apply_terraform_template_files() {
    local target="$1" pn="$2"
    local src dst rel rendered_rel
    while IFS= read -r -d '' src; do
        rel="${src#"${SCAFFOLD_ROOT}/template/"}"
        # Skip files unrelated to the terraform overlay to keep the seed
        # narrow (compose templates, dotnet csprojs etc. live elsewhere).
        case "$rel" in
            terraform/*) ;;
            scripts/new-terraform-env.sh.template) ;;
            docs/staging-runbook.md.tmpl) ;;
            *) continue ;;
        esac
        rendered_rel="${rel//\{\{PROJECTNAME\}\}/${pn}}"
        dst="${target}/${rendered_rel}"
        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
    done < <(find "${SCAFFOLD_ROOT}/template" -type f -print0)
    # Body substitution per phase_apply_overlays rules.
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            *.markers)  continue ;;
            *.template) continue ;;
            *.frag)     continue ;;
            *.tmpl)     substitute_tmpl "$f" || return 1 ;;
            *)          substitute_file "$f" || return 1 ;;
        esac
    done < <(find "${target}/terraform" "${target}/scripts" "${target}/docs" -type f -print0 2>/dev/null)
    # Seed a minimal .gitignore with the unit-07 marker pair (mirrors
    # what phase_apply_overlays + substitute_tmpl would produce from
    # .gitignore.tmpl's existing block).
    cat > "${target}/.gitignore" <<'EOF'
# Test seed
.idea/
# Terraform working files — see overlay-blocks/unit-07/gitignore-terraform.snippet
# <ScaffoldBlock name="terraform-gitignore">
# </ScaffoldBlock>
EOF
}

setup() {
    TMP="$(mktemp -d -t overlay-terraform-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    mkdir -p "$TARGET"
}

teardown() {
    rm -rf "$TMP"
}

# -----------------------------------------------------------------------
# T1 (CLI-gated): terraform fmt -check -recursive clean on rendered tree.
# -----------------------------------------------------------------------

@test "T1: terraform fmt clean (rendered tree)" {
    if ! command -v terraform >/dev/null; then
        skip "terraform not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    ( cd "$TARGET" && terraform fmt -check -recursive terraform/ )
}

# -----------------------------------------------------------------------
# T2 (CLI-gated): module terraform init -backend=false && validate.
# -----------------------------------------------------------------------

@test "T2: module init+validate (no backend)" {
    if ! command -v terraform >/dev/null; then
        skip "terraform not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    ( cd "$TARGET/terraform/modules/SmokeApp-env" && \
        terraform init -backend=false -no-color > /dev/null && \
        terraform validate -no-color )
}

# -----------------------------------------------------------------------
# T3 (CLI-gated): staging init -backend=false + validate.
# -----------------------------------------------------------------------

@test "T3: staging init -backend=false + validate" {
    if ! command -v terraform >/dev/null; then
        skip "terraform not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    ( cd "$TARGET/terraform/staging" && \
        terraform init -backend=false -no-color > /dev/null && \
        terraform validate -no-color )
}

# -----------------------------------------------------------------------
# T4 (CLI-gated): dns_provider="none" produces zero cloudflare records.
# -----------------------------------------------------------------------

@test "T4: dns_provider=none plans zero cloudflare records" {
    if ! command -v terraform >/dev/null; then
        skip "terraform not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    cat > "$TARGET/terraform/staging/terraform.tfvars" <<EOF
hcloud_token         = "fake"
ssh_allowed_cidrs    = ["198.51.100.1/32"]
operator_ssh_pubkeys = { "validate" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST validate" }
dns_provider         = "none"
EOF
    ( cd "$TARGET/terraform/staging" && \
        terraform init -backend=false -no-color > /dev/null && \
        terraform validate -no-color )
    # Static check on the module HCL: dns_provider default is "none".
    grep -qE 'default[[:space:]]+=[[:space:]]+"none"' "$TARGET/terraform/modules/SmokeApp-env/variables.tf"
}

# -----------------------------------------------------------------------
# T5: new-terraform-env.sh --dry-run produces correct sed commands.
# -----------------------------------------------------------------------

@test "T5: new-terraform-env.sh --dry-run output" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    terraform_overlay_install_script_perms "$TARGET"
    run bash "$TARGET/scripts/new-terraform-env.sh" production --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"cp -r terraform/staging terraform/production"* ]]
    [[ "$output" == *"workspace name"* ]]
    [[ "$output" == *"env_name"* ]]
}

# -----------------------------------------------------------------------
# T6: new-terraform-env.sh rejects invalid env-name.
# -----------------------------------------------------------------------

@test "T6: new-terraform-env.sh rejects invalid env-name" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    terraform_overlay_install_script_perms "$TARGET"
    run bash "$TARGET/scripts/new-terraform-env.sh" "BAD NAME"
    [ "$status" -eq 1 ]
    [[ "$output" == *"env-name must match"* ]]
}

# -----------------------------------------------------------------------
# T7: lint-cloud-init.sh passes against rendered cloud-init.
# -----------------------------------------------------------------------

@test "T7: lint-cloud-init.sh passes against rendered cloud-init" {
    if ! command -v shellcheck >/dev/null; then
        skip "shellcheck not on PATH"
    fi
    if ! python3 -c 'import yaml' 2>/dev/null; then
        skip "python3-yaml not installed"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    terraform_overlay_install_script_perms "$TARGET"
    # The cloud-init.yaml.tftpl source carries Terraform `%{ for ... }`
    # template directives that python3-yaml can't parse — same limitation
    # LinkHub's lint-cloud-init.sh has against its tftpl source. Strip
    # those out before linting (we lose iteration but shellcheck just
    # cares about per-line shell syntax of the static commands).
    local tmpyaml="${TARGET}/cloud-init-for-lint.yaml"
    sed '/^%{/d; /^%}/d' \
        "$TARGET/terraform/modules/SmokeApp-env/cloud-init.yaml.tftpl" \
        > "$tmpyaml"
    bash "$TARGET/terraform/staging/scripts/lint-cloud-init.sh" "$tmpyaml"
}

# -----------------------------------------------------------------------
# T8: gitignore splice landed the wildcard block.
# -----------------------------------------------------------------------

@test "T8: .gitignore carries the terraform wildcard block after splice" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_splice_gitignore "$TARGET"
    grep -qF 'terraform/**/.terraform/' "$TARGET/.gitignore"
    grep -qF '!terraform/**/*.tfvars.example' "$TARGET/.gitignore"
    grep -qF '!terraform/**/test/*.tfvars' "$TARGET/.gitignore"
}

# -----------------------------------------------------------------------
# T9: rebootstrap + lint-cloud-init + new-terraform-env are executable.
# -----------------------------------------------------------------------

@test "T9: rebootstrap + lint-cloud-init + new-terraform-env are executable" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    terraform_overlay_install_script_perms "$TARGET"
    [ -x "$TARGET/terraform/staging/rebootstrap.sh" ]
    [ -x "$TARGET/terraform/staging/scripts/lint-cloud-init.sh" ]
    [ -x "$TARGET/scripts/new-terraform-env.sh" ]
}

# -----------------------------------------------------------------------
# T10: rendered files carry no unsubstituted scaffold tokens.
# -----------------------------------------------------------------------

@test "T10: rendered files carry no unsubstituted scaffold tokens" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_terraform_template_files "$TARGET" SmokeApp
    terraform_overlay_render_templated_files "$TARGET"
    # The negation inverts grep's exit code — test passes iff grep finds
    # zero matches. Scaffold tokens are uppercase-only patterns; HCL
    # lowercase `${var.x}` / `${each.key}` / `${path.module}` survive.
    if grep -rnE '\$\{(PROJECT_NAME|PROJECTNAME_UPPER|GITHUB_OWNER|HCP_ORG|HETZNER_|CLOUDFLARE_ZONE)' \
            "$TARGET/terraform/" "$TARGET/scripts/new-terraform-env.sh" \
            "$TARGET/docs/staging-runbook.md" 2>/dev/null; then
        echo "found unsubstituted scaffold tokens" >&2
        return 1
    fi
}
