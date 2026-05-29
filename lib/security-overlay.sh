#!/usr/bin/env bash
# lib/security-overlay.sh — unit-05 security-overlay orchestration helpers.
#
# Sourced by scaffold.sh's `phase_apply_security_overlay`. The phase runs
# AFTER `phase_apply_overlays` so it can rely on the rendered host/migrator
# tree existing.
#
# Public entry-points:
#   security_overlay_insert_blocks <target_real>
#       Insert every unit-05-owned ScaffoldBlock payload into its target
#       file. Idempotent — re-running is byte-identical.
#
#   security_overlay_render_staging_secrets <target_real>
#       Copy the *.staging.json.template fragments into the rendered tree.
#       The fragments live OUTSIDE template/ so `phase_apply_overlays`
#       doesn't try to substitute the ${STAGING_*} envsubst tokens
#       (which would trip _substitute_check_unresolved). PROJECT_NAME
#       references inside the fragments are substituted here manually.
#
#   security_overlay_append_gitignore <gitignore_file>
#       Idempotent append of the staging-rendered-secrets ignore stanza.
#
#   security_overlay_install_cert_script <target_real>
#       Mark the generate-dev-openiddict-cert.sh script executable.
#
#   security_overlay_merge_dbmigrator_markers <target_real>
#       Probe both candidate paths for the DbMigrationService.cs file,
#       merge the markers if found, insert the admin-password fail-fast
#       block, and clean up the markers file. log_warn and return 0 if no
#       candidate exists (matches plan §4 fallback behavior).

if [[ -n "${__LH_SECURITY_OVERLAY_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_SECURITY_OVERLAY_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi
if [[ -z "${__LH_DOTNET_OVERLAY_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/dotnet-overlay.sh"
fi

# OVERLAY_BLOCKS_DIR can be overridden by tests; defaults to the layout
# we ship under abp-aidlc-template/overlay-blocks/unit-05/. NOT under
# template/ on purpose — the staging *.template fragments contain
# ${STAGING_*} envsubst targets that would trip phase_apply_overlays'
# substitute-unresolved gate.
__SECURITY_OVERLAY_DEFAULT_BLOCKS="$(dirname "${BASH_SOURCE[0]}")/../overlay-blocks/unit-05"

# _security_overlay_resolve_blocks_dir
# Echoes the path containing the unit-05 block fragments. Tests can set
# SECURITY_OVERLAY_BLOCKS_DIR to override.
_security_overlay_resolve_blocks_dir() {
    if [[ -n "${SECURITY_OVERLAY_BLOCKS_DIR:-}" ]]; then
        printf '%s\n' "$SECURITY_OVERLAY_BLOCKS_DIR"
        return 0
    fi
    if [[ -d "$__SECURITY_OVERLAY_DEFAULT_BLOCKS" ]]; then
        printf '%s\n' "$(cd "$__SECURITY_OVERLAY_DEFAULT_BLOCKS" && pwd)"
        return 0
    fi
    log_fail "security-overlay: blocks dir not found: $__SECURITY_OVERLAY_DEFAULT_BLOCKS" \
        "_security_overlay_resolve_blocks_dir"
    return 1
}

# _security_overlay_render_block <src_block_file>
# Echoes a tmpfile containing the block payload with ${PROJECT_NAME}
# substituted. Caller is responsible for removing the tmpfile.
_security_overlay_render_block() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        log_fail "security-overlay: block source missing: $src" \
            "_security_overlay_render_block"
        return 1
    fi
    local tmp
    tmp="$(mktemp -t scaffold-sec-block.XXXXXX)"
    # Only substitute PROJECT_NAME-family tokens. The rest is verbatim.
    # shellcheck disable=SC2016  # literal envsubst pattern; not a shell expansion.
    PROJECT_NAME="${PROJECT_NAME:-}" \
        envsubst '${PROJECT_NAME}' < "$src" > "$tmp"
    printf '%s\n' "$tmp"
}

# security_overlay_insert_blocks <target_real>
security_overlay_insert_blocks() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "security_overlay_insert_blocks: missing target: $target" \
            "security_overlay_insert_blocks"
        return 1
    fi
    local blocks
    blocks="$(_security_overlay_resolve_blocks_dir)" || return 1

    local host_module="${target}/src/${PROJECT_NAME}.HttpApi.Host/${PROJECT_NAME}HttpApiHostModule.cs"
    local program="${target}/src/${PROJECT_NAME}.HttpApi.Host/Program.cs"
    local appsettings="${target}/src/${PROJECT_NAME}.HttpApi.Host/appsettings.json"

    if [[ ! -f "$host_module" ]]; then
        log_fail "security_overlay_insert_blocks: host module missing: $host_module" \
            "security_overlay_insert_blocks"
        return 1
    fi
    if [[ ! -f "$program" ]]; then
        log_fail "security_overlay_insert_blocks: Program.cs missing: $program" \
            "security_overlay_insert_blocks"
        return 1
    fi
    if [[ ! -f "$appsettings" ]]; then
        log_fail "security_overlay_insert_blocks: appsettings.json missing: $appsettings" \
            "security_overlay_insert_blocks"
        return 1
    fi

    # Each tuple: <file> <block_name> <fragment_filename>
    local pair file name fragment rendered rc
    local -a all_pairs=(
        "$host_module|secrets-json-loader|module-secrets-json-loader.cs"
        "$host_module|csp-middleware|module-csp-middleware.cs"
        "$host_module|hsts|module-hsts.cs"
        "$host_module|openiddict-cert|module-openiddict-cert.cs"
        "$program|fwd-headers|program-fwd-headers.cs"
        "$program|cookie-antiforgery-cors|program-cookie-antiforgery-cors.cs"
        "$program|production-fail-fast|program-production-fail-fast.cs"
        "$appsettings|csp-defaults|appsettings-csp-defaults.json"
    )

    for pair in "${all_pairs[@]}"; do
        file="${pair%%|*}"
        rest="${pair#*|}"
        name="${rest%%|*}"
        fragment="${rest#*|}"
        if [[ ! -f "${blocks}/${fragment}" ]]; then
            log_fail "security_overlay_insert_blocks: fragment missing: ${blocks}/${fragment}" \
                "security_overlay_insert_blocks"
            return 1
        fi
        rendered="$(_security_overlay_render_block "${blocks}/${fragment}")" || return 1
        scaffold_insert_block "$file" "$name" "$rendered"
        rc=$?
        rm -f "$rendered"
        if (( rc != 0 )); then
            return 1
        fi
        log_info "[overlay-security] inserted block '${name}' -> ${file#"${target}"/}"
    done

    # Program.cs uses System.Linq.Where(...) in the production-fail-fast
    # block — ensure the using line is present.
    _ensure_using_line "$program" "using System.Linq;" || return 1
}

# security_overlay_render_staging_secrets <target_real>
security_overlay_render_staging_secrets() {
    local target="$1"
    local blocks
    blocks="$(_security_overlay_resolve_blocks_dir)" || return 1

    local host_staging_src="${blocks}/staging/appsettings.secrets.staging.json.template"
    local migrator_staging_src="${blocks}/staging/dbmigrator.appsettings.secrets.staging.json.template"

    local host_dst="${target}/src/${PROJECT_NAME}.HttpApi.Host/appsettings.secrets.staging.json.template"
    local migrator_dst="${target}/src/${PROJECT_NAME}.DbMigrator/appsettings.secrets.staging.json.template"

    if [[ ! -f "$host_staging_src" || ! -f "$migrator_staging_src" ]]; then
        log_fail "security_overlay_render_staging_secrets: staging fragments missing under ${blocks}/staging" \
            "security_overlay_render_staging_secrets"
        return 1
    fi

    # PROJECT_NAME-only substitution. ${STAGING_*} tokens are left verbatim.
    mkdir -p "$(dirname "$host_dst")" "$(dirname "$migrator_dst")"
    # shellcheck disable=SC2016  # literal envsubst pattern; not a shell expansion.
    PROJECT_NAME="${PROJECT_NAME:-}" envsubst '${PROJECT_NAME}' < "$host_staging_src" > "$host_dst"
    # shellcheck disable=SC2016  # literal envsubst pattern; not a shell expansion.
    PROJECT_NAME="${PROJECT_NAME:-}" envsubst '${PROJECT_NAME}' < "$migrator_staging_src" > "$migrator_dst"
    log_info "[overlay-security] rendered staging secrets templates (envsubst targets preserved)"
}

# security_overlay_append_gitignore <gitignore_file>
security_overlay_append_gitignore() {
    local gi="$1"
    if [[ ! -f "$gi" ]]; then
        log_warn "security_overlay_append_gitignore: .gitignore not found at $gi; skipping"
        return 0
    fi
    local sentinel='# unit-05 — staging-rendered secrets (rendered at deploy time, NOT committed)'
    if grep -qF "$sentinel" "$gi"; then
        # Already appended — idempotent.
        return 0
    fi
    {
        printf '\n%s\n' "$sentinel"
        printf '%s\n' 'appsettings.secrets.*.json'
        printf '%s\n' '!appsettings.secrets.json.template'
        printf '%s\n' '!appsettings.secrets.staging.json.template'
    } >> "$gi"
    log_info "[overlay-security] appended staging-secrets ignore stanza to ${gi}"
}

# security_overlay_install_cert_script <target_real>
security_overlay_install_cert_script() {
    local target="$1"
    local script="${target}/etc/generate-dev-openiddict-cert.sh"
    if [[ ! -f "$script" ]]; then
        log_warn "security_overlay_install_cert_script: $script not found; nothing to chmod"
        return 0
    fi
    chmod +x "$script"
    log_info "[overlay-security] chmod +x $script"
}

# security_overlay_merge_dbmigrator_markers <target_real>
security_overlay_merge_dbmigrator_markers() {
    local target="$1"
    local blocks
    blocks="$(_security_overlay_resolve_blocks_dir)" || return 1

    # Probe both candidate paths (plan §4 §15 assumption #2).
    local candidates=(
        "${target}/src/${PROJECT_NAME}.DbMigrator/${PROJECT_NAME}DbMigrationService.cs"
        "${target}/src/${PROJECT_NAME}.Domain/Data/${PROJECT_NAME}DbMigrationService.cs"
    )
    local service_file=""
    local cand
    for cand in "${candidates[@]}"; do
        if [[ -f "$cand" ]]; then
            service_file="$cand"
            break
        fi
    done

    if [[ -z "$service_file" ]]; then
        log_warn "security_overlay_merge_dbmigrator_markers: no DbMigrationService.cs found under candidates; admin-password fail-fast not wired"
        return 0
    fi

    # Locate the (template-copied) markers file. phase_apply_overlays
    # processes *.markers files and removes them. If it ran, the markers
    # file is gone — re-create it from the source-of-truth in the scaffold
    # repo (sibling of the blocks dir).
    local markers_src="${blocks}/dbmigrationservice.markers"
    if [[ ! -f "$markers_src" ]]; then
        log_fail "security_overlay_merge_dbmigrator_markers: markers source missing: $markers_src" \
            "security_overlay_merge_dbmigrator_markers"
        return 1
    fi

    # Insert the empty marker pair into the service file (idempotent via
    # scaffold_assert_block_present).
    if ! scaffold_assert_block_present "$service_file" "admin-password-fail-fast"; then
        merge_markers_into_existing "$service_file" "$markers_src" || return 1
    fi

    # Insert the block body.
    local rendered
    rendered="$(_security_overlay_render_block "${blocks}/dbmigrationservice-admin-password-fail-fast.cs")" || return 1
    scaffold_insert_block "$service_file" "admin-password-fail-fast" "$rendered"
    local rc=$?
    rm -f "$rendered"
    if (( rc != 0 )); then
        return 1
    fi
    log_info "[overlay-security] inserted admin-password-fail-fast into ${service_file#"${target}"/}"
}
