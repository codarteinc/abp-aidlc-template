#!/usr/bin/env bash
# lib/terraform-overlay.sh — unit-07 terraform-overlay orchestration helpers.
#
# Sourced by scaffold.sh's `phase_apply_terraform_overlay`. The phase runs
# AFTER `phase_apply_docker_overlay` so the rendered terraform/ tree (copied
# by phase_apply_overlays) is on disk and the .gitignore is already in place.
#
# Public entry-points:
#   terraform_overlay_render_templated_files <target_real>
#       For every *.template file the terraform overlay owns (the two
#       operator-facing shell scripts that mix scaffold-time tokens with
#       bash `${VAR}` references), do a targeted PROJECT_NAME-family
#       envsubst pass + drop the .template suffix. Bash `${VAR}` references
#       NOT in the allowlist are preserved verbatim — they'd otherwise
#       trip the substitute_tmpl unresolved-check.
#
#   terraform_overlay_install_script_perms <target_real>
#       chmod +x on the three operator-facing terraform scripts. Idempotent.
#
#   terraform_overlay_splice_gitignore <target_real>
#       Splice the unit-07 gitignore snippet into the ScaffoldBlock marker
#       pair that ships in .gitignore.tmpl. Uses scaffold_insert_block.

if [[ -n "${__LH_TERRAFORM_OVERLAY_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_TERRAFORM_OVERLAY_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi
if [[ -z "${__LH_DOTNET_OVERLAY_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/dotnet-overlay.sh"
fi

# The unit-07 gitignore snippet ships under this well-known path. Tests
# can override TERRAFORM_OVERLAY_SNIPPET to point at a fixture.
__TERRAFORM_OVERLAY_DEFAULT_SNIPPET="$(dirname "${BASH_SOURCE[0]}")/../overlay-blocks/unit-07/gitignore-terraform.snippet"

# _terraform_overlay_targeted_envsubst <src> <dst>
# Run envsubst against <src> with the scaffold-time allowlist
# (PROJECT_NAME, PROJECT_NAME_LOWER, PROJECTNAME_UPPER, GITHUB_OWNER,
# HCP_ORG, HETZNER_LOCATION, HETZNER_SERVER_TYPE, CLOUDFLARE_ZONE) and
# write to <dst>. Bash `${VAR}` references for runtime variables (e.g.,
# `${SCRIPT_DIR}`, `${SSH_TIMEOUT_SECONDS}`) are preserved verbatim.
_terraform_overlay_targeted_envsubst() {
    local src="$1" dst="$2"
    if [[ ! -f "$src" ]]; then
        log_fail "_terraform_overlay_targeted_envsubst: missing src: $src" \
            "_terraform_overlay_targeted_envsubst"
        return 1
    fi
    # shellcheck disable=SC2016  # literal envsubst pattern; not a shell expansion.
    PROJECT_NAME="${PROJECT_NAME:-}" \
    PROJECT_NAME_LOWER="${PROJECT_NAME_LOWER:-}" \
    PROJECTNAME_UPPER="${PROJECTNAME_UPPER:-}" \
    GITHUB_OWNER="${GITHUB_OWNER:-}" \
    HCP_ORG="${HCP_ORG:-}" \
    HETZNER_LOCATION="${HETZNER_LOCATION:-}" \
    HETZNER_SERVER_TYPE="${HETZNER_SERVER_TYPE:-}" \
    CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-}" \
        envsubst '${PROJECT_NAME} ${PROJECT_NAME_LOWER} ${PROJECTNAME_UPPER} ${GITHUB_OWNER} ${HCP_ORG} ${HETZNER_LOCATION} ${HETZNER_SERVER_TYPE} ${CLOUDFLARE_ZONE}' \
        < "$src" > "$dst"
}

# terraform_overlay_render_templated_files <target_real>
#
# Walks the rendered tree looking for the unit-07-owned *.template files
# (operator-facing shell scripts that mix scaffold-time tokens with bash
# `${VAR}` references the unresolved-check would otherwise reject).
# Renders each in place + drops the .template suffix. Idempotent.
terraform_overlay_render_templated_files() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "terraform_overlay_render_templated_files: missing target: $target" \
            "terraform_overlay_render_templated_files"
        return 1
    fi
    # Explicit allowlist of *.template files this phase owns.
    local relpaths=(
        "scripts/new-terraform-env.sh.template"
        "terraform/staging/rebootstrap.sh.template"
    )
    local rel src dst tmp
    for rel in "${relpaths[@]}"; do
        src="${target}/${rel}"
        if [[ ! -f "$src" ]]; then
            log_info "[overlay-terraform] skip (not present): ${rel}"
            continue
        fi
        # Drop the trailing .template suffix.
        dst="${src%.template}"
        tmp="${src}.terraform-overlay.tmp"
        _terraform_overlay_targeted_envsubst "$src" "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        mv "$tmp" "$dst"
        rm -f "$src"
        log_info "[overlay-terraform] rendered ${rel} -> ${dst#"$target"/}"
    done
}

# terraform_overlay_install_script_perms <target_real>
#
# chmod +x the three operator-facing scripts the unit-07 overlay ships.
# Idempotent — chmod +x on an already-executable file is a no-op.
terraform_overlay_install_script_perms() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "terraform_overlay_install_script_perms: missing target: $target" \
            "terraform_overlay_install_script_perms"
        return 1
    fi
    local script
    for script in \
        "${target}/terraform/staging/rebootstrap.sh" \
        "${target}/terraform/staging/scripts/lint-cloud-init.sh" \
        "${target}/scripts/new-terraform-env.sh"
    do
        [[ -f "$script" ]] || continue
        chmod +x "$script"
        log_info "[overlay-terraform] chmod +x ${script#"$target"/}"
    done
}

# terraform_overlay_splice_gitignore <target_real>
#
# Splice the unit-07 gitignore snippet into the ScaffoldBlock marker pair
# that ships in .gitignore.tmpl. Idempotent on re-run via
# scaffold_insert_block.
terraform_overlay_splice_gitignore() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "terraform_overlay_splice_gitignore: missing target: $target" \
            "terraform_overlay_splice_gitignore"
        return 1
    fi
    local gitignore="${target}/.gitignore"
    local snippet="${TERRAFORM_OVERLAY_SNIPPET:-$__TERRAFORM_OVERLAY_DEFAULT_SNIPPET}"

    if [[ ! -f "$gitignore" ]]; then
        log_warn "[overlay-terraform] .gitignore missing — skipping splice"
        return 0
    fi
    if [[ ! -f "$snippet" ]]; then
        log_fail "[overlay-terraform] snippet missing: $snippet" \
            "terraform_overlay_splice_gitignore"
        return 1
    fi

    scaffold_insert_block "$gitignore" "terraform-gitignore" "$snippet" || return 1
    log_info "[overlay-terraform] spliced terraform gitignore block into .gitignore"
}
