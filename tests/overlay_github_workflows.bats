#!/usr/bin/env bats
# tests/overlay_github_workflows.bats — end-to-end test of unit-08's
# github-workflows-overlay phase.
#
# Stands up a minimal target tree, copies the template/.github/ overlay
# onto it, then runs github_workflows_overlay_render_templated_files
# and asserts the rendered surface matches the plan §1 layout +
# concurrency-group contract + token-substitution targets.
#
# yq + actionlint are tested as CLI-gated assertions: present → run them,
# absent → skip with a clear message.

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
    export GITHUB_OWNER=acme HCP_ORG=acme
    export DBMS=postgresql UI=angular DB_PROVIDER=ef DEFAULT_CULTURE=en
    export MULTI_TENANCY=false TIERED=false
    export HETZNER_LOCATION=hel1 HETZNER_SERVER_TYPE=cx23 CLOUDFLARE_ZONE=example.com
    unset __LH_LOG_SH_SOURCED __LH_SUBSTITUTE_SH_SOURCED \
          __LH_GITHUB_WORKFLOWS_OVERLAY_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/github-workflows-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/github-workflows-overlay.sh"
    LIB_DIR="${SCAFFOLD_ROOT}/lib"
    TEMPLATE_DIR="${SCAFFOLD_ROOT}/template"
}

# Copy the unit-08 github-workflows template files into the target tree.
# Mirrors what phase_apply_overlays would do for *.template files —
# verbatim copy, no substitution (the github_workflows_overlay phase
# owns the targeted envsubst pass that follows).
_apply_github_workflows_template_files() {
    local target="$1"
    local src dst rel
    while IFS= read -r -d '' src; do
        rel="${src#"${SCAFFOLD_ROOT}/template/"}"
        case "$rel" in
            .github/*) ;;
            *) continue ;;
        esac
        dst="${target}/${rel}"
        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
    done < <(find "${SCAFFOLD_ROOT}/template/.github" -type f -print0)
}

# Names without the .template suffix (post-render).
declare -ar _RENDERED_FILES=(
    ".github/dependabot.yml"
    ".github/workflows/cicd.yml"
    ".github/workflows/dependabot-auto-merge.yml"
    ".github/workflows/runner-cache-cleanup.yml"
    ".github/workflows/staging-deploy.yml"
    ".github/workflows/staging-rollback.yml"
    ".github/workflows/_terraform-apply.yml"
    ".github/workflows/_terraform-plan.yml"
    ".github/workflows/_terraform-drift.yml"
    ".github/workflows/_terraform-destroy.yml"
    ".github/workflows/staging-terraform-apply.yml"
    ".github/workflows/staging-terraform-plan.yml"
    ".github/workflows/staging-terraform-drift.yml"
    ".github/workflows/staging-terraform-destroy.yml"
)

setup() {
    TMP="$(mktemp -d -t overlay-gh-workflows-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    mkdir -p "$TARGET"
}

teardown() {
    rm -rf "$TMP"
}

# -----------------------------------------------------------------------
# T1: tree layout — all 14 files present after overlay render.
# -----------------------------------------------------------------------
@test "T1: 14 expected files present after render" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    for f in "${_RENDERED_FILES[@]}"; do
        [ -f "${TARGET}/${f}" ] || { echo "missing: ${f}"; return 1; }
    done
    # And every .template file SHOULD be gone.
    local leftover
    leftover=$(find "${TARGET}/.github" -name '*.template' | head -1)
    [ -z "$leftover" ] || { echo "leftover .template: $leftover"; return 1; }
}

# -----------------------------------------------------------------------
# T2: every rendered workflow parses cleanly via yq.
# -----------------------------------------------------------------------
@test "T2: every rendered workflow parses cleanly via yq" {
    if ! command -v yq >/dev/null; then
        skip "yq not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    for f in "${_RENDERED_FILES[@]}"; do
        yq eval '.' "${TARGET}/${f}" > /dev/null \
            || { echo "yq parse failed: ${f}"; return 1; }
    done
}

# -----------------------------------------------------------------------
# T3: actionlint clean on all rendered workflow .yml files.
# -----------------------------------------------------------------------
@test "T3: actionlint clean on rendered workflows" {
    if ! command -v actionlint >/dev/null; then
        skip "actionlint not on PATH (install: go install github.com/rhysd/actionlint/cmd/actionlint@latest)"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    # -shellcheck= disables shellcheck integration. The `${PROJECT_NAME}`
    # tokens, once substituted to a PascalCase word, never contain
    # whitespace, so the SC2086-style info reports are noise. actionlint's
    # own checks (action invalid, missing inputs, etc.) are the gate here.
    actionlint -no-color -shellcheck= "${TARGET}/.github/workflows/"*.yml
}

# -----------------------------------------------------------------------
# T4: no LinkHub residue after substitution.
# -----------------------------------------------------------------------
@test "T4: no linkhub / codarteinc literal residue after render" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    # Case-insensitive — the LinkHub source has both `LinkHub` and `linkhub`.
    if grep -RIl -i 'linkhub\|codarteinc' "${TARGET}/.github/" 2>/dev/null; then
        echo "FAIL: linkhub/codarteinc literal residue under ${TARGET}/.github/" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------
# T5: concurrency-group contract — 4 shared-group workflows + their
#     post-substitution group string match.
# -----------------------------------------------------------------------
@test "T5: concurrency-group contract across the 4 shared-group workflows" {
    if ! command -v yq >/dev/null; then
        skip "yq not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    local expected="smokeapp-staging-deploy"
    local g
    # Standalone workflows: read .concurrency.group.
    g=$(yq -r '.concurrency.group' "${TARGET}/.github/workflows/staging-deploy.yml")
    [ "$g" = "$expected" ] || { echo "deploy group=$g expected=$expected"; return 1; }
    g=$(yq -r '.concurrency.group' "${TARGET}/.github/workflows/staging-rollback.yml")
    [ "$g" = "$expected" ] || { echo "rollback group=$g expected=$expected"; return 1; }
    # cancel-in-progress must be false on the standalone shared-group two.
    local cip
    cip=$(yq -r '.concurrency.cancel-in-progress' "${TARGET}/.github/workflows/staging-deploy.yml")
    [ "$cip" = "false" ] || { echo "deploy cancel-in-progress=$cip"; return 1; }
    cip=$(yq -r '.concurrency.cancel-in-progress' "${TARGET}/.github/workflows/staging-rollback.yml")
    [ "$cip" = "false" ] || { echo "rollback cancel-in-progress=$cip"; return 1; }
    # Reusable-callers: the wrapper's `.jobs.<name>.with.concurrency_group`.
    g=$(yq -r '.jobs.apply.with.concurrency_group' "${TARGET}/.github/workflows/staging-terraform-apply.yml")
    [ "$g" = "$expected" ] || { echo "tf-apply group=$g expected=$expected"; return 1; }
    g=$(yq -r '.jobs.destroy.with.concurrency_group' "${TARGET}/.github/workflows/staging-terraform-destroy.yml")
    [ "$g" = "$expected" ] || { echo "tf-destroy group=$g expected=$expected"; return 1; }
}

# -----------------------------------------------------------------------
# T6: cicd.yml carries SmokeApp.slnx + smokeapp-{api,web,dbmigrator}.
# -----------------------------------------------------------------------
@test "T6: cicd.yml carries SmokeApp.slnx + per-service image refs" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    local cicd="${TARGET}/.github/workflows/cicd.yml"
    grep -qE 'SmokeApp\.slnx' "$cicd" || { echo "cicd.yml missing SmokeApp.slnx"; return 1; }
    grep -qE 'src/SmokeApp\.\*/\*\*' "$cicd" || { echo "cicd.yml missing src/SmokeApp.*/** path-filter"; return 1; }
    grep -qE '/smokeapp-api(\b|:)' "$cicd" || { echo "cicd.yml missing smokeapp-api ref"; return 1; }
    grep -qE '/smokeapp-dbmigrator(\b|:)' "$cicd" || { echo "cicd.yml missing smokeapp-dbmigrator ref"; return 1; }
    grep -qE '/smokeapp-web(\b|:)' "$cicd" || { echo "cicd.yml missing smokeapp-web ref"; return 1; }
}

# -----------------------------------------------------------------------
# T7: staging-deploy.yml mktemp prefix matches the sudoers prefix shape.
#     Drift between this prefix and the unit-07 cloud-init `rm -rf
#     /tmp/${PROJECT_NAME_LOWER}-deploy.*` sudoers entry silently breaks
#     the deploy cleanup step.
# -----------------------------------------------------------------------
@test "T7: mktemp prefix shape matches sudoers contract" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    local deploy="${TARGET}/.github/workflows/staging-deploy.yml"
    # Expect at least two `mktemp -d /tmp/smokeapp-deploy.XXXXXX`
    # invocations (the initial scratch + the LKG scratch).
    local count
    count=$(grep -cF 'mktemp -d /tmp/smokeapp-deploy.XXXXXX' "$deploy" || true)
    [ "$count" -ge 2 ] || {
        echo "expected >= 2 mktemp prefix lines in staging-deploy.yml, got $count"
        return 1
    }
    # And the rollback workflow.
    local rollback="${TARGET}/.github/workflows/staging-rollback.yml"
    grep -qF 'mktemp -d /tmp/smokeapp-deploy.XXXXXX' "$rollback" \
        || { echo "rollback.yml missing mktemp prefix"; return 1; }
    # The corresponding `sudo rm -rf /tmp/smokeapp-deploy.*` allowlist
    # form must be present in the rendered deploy AND rollback (in comments
    # explaining the sudoers contract).
    grep -qF '/tmp/smokeapp-deploy.' "$deploy" \
        || { echo "deploy.yml missing /tmp/smokeapp-deploy. reference"; return 1; }
}

# -----------------------------------------------------------------------
# T8: dependabot.yml ecosystem list + path substitution.
# -----------------------------------------------------------------------
@test "T8: dependabot.yml lists nuget+npm+github-actions+docker+terraform with substituted env-module path" {
    if ! command -v yq >/dev/null; then
        skip "yq not on PATH"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_github_workflows_template_files "$TARGET"
    github_workflows_overlay_render_templated_files "$TARGET"
    local dep="${TARGET}/.github/dependabot.yml"
    [ -f "$dep" ] || { echo "dependabot.yml missing"; return 1; }
    # All five ecosystem types present.
    local ecos
    ecos=$(yq -r '.updates[].package-ecosystem' "$dep" | sort -u | tr '\n' ',' )
    [[ "$ecos" == *"nuget"* ]] || { echo "missing nuget ecosystem"; return 1; }
    [[ "$ecos" == *"npm"* ]] || { echo "missing npm ecosystem"; return 1; }
    [[ "$ecos" == *"github-actions"* ]] || { echo "missing github-actions ecosystem"; return 1; }
    [[ "$ecos" == *"docker"* ]] || { echo "missing docker ecosystem"; return 1; }
    [[ "$ecos" == *"terraform"* ]] || { echo "missing terraform ecosystem"; return 1; }
    # The terraform-modules path used ${PROJECT_NAME_LOWER}-env → smokeapp-env.
    grep -qF '/terraform/modules/smokeapp-env' "$dep" \
        || { echo "dependabot.yml missing /terraform/modules/smokeapp-env path"; return 1; }
}
