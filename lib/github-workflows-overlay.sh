#!/usr/bin/env bash
# lib/github-workflows-overlay.sh — unit-08 github-workflows-overlay
# orchestration helpers.
#
# Sourced by scaffold.sh's `phase_apply_github_workflows_overlay`. Runs
# AFTER `phase_apply_terraform_overlay` so the rendered tree (copied by
# phase_apply_overlays) is on disk.
#
# Public entry-point:
#   github_workflows_overlay_render_templated_files <target_real>
#       For every *.template file the github-workflows overlay owns
#       (every workflow YAML + the dependabot config), do a targeted
#       PROJECT_NAME-family envsubst pass + drop the .template suffix.
#       Bash `${VAR}` references inside `run:` shell blocks (e.g.
#       `${PR_NUM}`, `${TITLE}`, `${HEAD_SHA}`) AND GitHub Actions
#       context refs `${{ ... }}` are preserved verbatim — they would
#       otherwise trip substitute_file's unresolved-token check.
#
# Why .template suffix + a per-unit helper rather than the default
# substitute_file path:
#   - Workflow YAMLs intermix three layers of variable references:
#       1. scaffold-time tokens (e.g., `${PROJECT_NAME_LOWER}`) — must
#          expand at scaffold time.
#       2. bash runtime refs (e.g., `${PR_NUM}`) — must NOT expand;
#          preserved verbatim for the workflow runner.
#       3. GitHub Actions context refs (`${{ github.* }}`) — preserved
#          verbatim; the `{{` form already escapes the envsubst check.
#     substitute_file's strict unresolved-check fires on (2), so we
#     route workflows through a targeted-allowlist envsubst that
#     deliberately preserves anything outside the scaffold-time set.

if [[ -n "${__LH_GITHUB_WORKFLOWS_OVERLAY_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_GITHUB_WORKFLOWS_OVERLAY_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# _github_workflows_overlay_targeted_envsubst <src> <dst>
# Run envsubst against <src> with the scaffold-time allowlist
# (PROJECT_NAME, PROJECT_NAME_LOWER, PROJECTNAME_UPPER, GITHUB_OWNER) and
# write to <dst>. Every other `${VAR}` reference (bash runtime,
# `${{ github.* }}`, etc.) is preserved verbatim.
_github_workflows_overlay_targeted_envsubst() {
    local src="$1" dst="$2"
    if [[ ! -f "$src" ]]; then
        log_fail "_github_workflows_overlay_targeted_envsubst: missing src: $src" \
            "_github_workflows_overlay_targeted_envsubst"
        return 1
    fi
    # shellcheck disable=SC2016  # literal envsubst pattern; not a shell expansion.
    PROJECT_NAME="${PROJECT_NAME:-}" \
    PROJECT_NAME_LOWER="${PROJECT_NAME_LOWER:-}" \
    PROJECTNAME_UPPER="${PROJECTNAME_UPPER:-}" \
    GITHUB_OWNER="${GITHUB_OWNER:-}" \
        envsubst '${PROJECT_NAME} ${PROJECT_NAME_LOWER} ${PROJECTNAME_UPPER} ${GITHUB_OWNER}' \
        < "$src" > "$dst"
}

# github_workflows_overlay_render_templated_files <target_real>
#
# Walks the rendered tree looking for the unit-08-owned *.template files
# (14 workflow YAMLs + dependabot.yml) and runs a targeted envsubst pass
# on each, dropping the .template suffix. Idempotent — a second pass
# finds no *.template files and is a no-op.
github_workflows_overlay_render_templated_files() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "github_workflows_overlay_render_templated_files: missing target: $target" \
            "github_workflows_overlay_render_templated_files"
        return 1
    fi
    # Explicit allowlist of *.template files this phase owns. Listed
    # rather than glob-walked so the contract is grep-visible.
    local relpaths=(
        ".github/dependabot.yml.template"
        ".github/workflows/cicd.yml.template"
        ".github/workflows/dependabot-auto-merge.yml.template"
        ".github/workflows/runner-cache-cleanup.yml.template"
        ".github/workflows/staging-deploy.yml.template"
        ".github/workflows/staging-rollback.yml.template"
        ".github/workflows/_terraform-apply.yml.template"
        ".github/workflows/_terraform-plan.yml.template"
        ".github/workflows/_terraform-drift.yml.template"
        ".github/workflows/_terraform-destroy.yml.template"
        ".github/workflows/staging-terraform-apply.yml.template"
        ".github/workflows/staging-terraform-plan.yml.template"
        ".github/workflows/staging-terraform-drift.yml.template"
        ".github/workflows/staging-terraform-destroy.yml.template"
    )
    local rel src dst tmp
    for rel in "${relpaths[@]}"; do
        src="${target}/${rel}"
        if [[ ! -f "$src" ]]; then
            log_info "[overlay-github-workflows] skip (not present): ${rel}"
            continue
        fi
        # Drop the trailing .template suffix.
        dst="${src%.template}"
        tmp="${src}.gh-workflows-overlay.tmp"
        _github_workflows_overlay_targeted_envsubst "$src" "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        mv "$tmp" "$dst"
        rm -f "$src"
        log_info "[overlay-github-workflows] rendered ${rel} -> ${dst#"$target"/}"
    done
}
