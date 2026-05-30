#!/usr/bin/env bash
# lib/docker-overlay.sh — unit-06 docker-overlay orchestration helpers.
#
# Sourced by scaffold.sh's `phase_apply_docker_overlay`. The phase runs
# AFTER `phase_apply_security_overlay` so it can rely on the rendered
# host/migrator tree existing AND on the unit-05 + unit-04 block
# fragments being on disk for the nginx splice.
#
# Public entry-points:
#   docker_overlay_render_templated_files <target_real>
#       For every *.template file that ships in the docker-overlay set
#       (docker-compose.{yml,dev.yml,staging.yml}, .env, .env.staging,
#       Dockerfile.{dotnet,local}, angular/Dockerfile{,.local}, angular/
#       docker-entrypoint.d/25-envsubst-dynamic-env.sh), do a targeted
#       PROJECT_NAME-family envsubst pass + drop the .template suffix.
#       Deploy-time ${VAR} tokens (compose's own env resolution,
#       nginx:alpine's entrypoint envsubst, .env.staging deploy envsubst)
#       are preserved verbatim — they MUST NOT be resolved at scaffold
#       time.
#
#   docker_overlay_install_dockerfile_perms <target_real>
#       Mark angular/docker-entrypoint.d/25-envsubst-dynamic-env.sh
#       executable (mode 0755). Idempotent.
#
#   docker_overlay_splice_nginx_conf <target_real>
#       Splice the unit-05 nginx-security-headers payload + unit-04
#       /getEnvConfig snippet into the ScaffoldBlock marker pairs that
#       phase_apply_overlays merged into angular/nginx.conf.template.
#       Returns silently with log_info if angular/ is absent (UI=none).
#
#   docker_overlay_prune_ui_none <target_real>
#       Iff UI=none, delete the entire angular/ subtree, drop the `web:`
#       service block from docker-compose.yml + the `web:` overlay
#       sections from docker-compose.dev.yml + docker-compose.staging.yml,
#       drop the `web` dep from caddy.depends_on, and drop the SPA
#       reverse_proxy block from the Caddyfiles.

if [[ -n "${__LH_DOCKER_OVERLAY_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_DOCKER_OVERLAY_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi
if [[ -z "${__LH_DOTNET_OVERLAY_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/dotnet-overlay.sh"
fi

# The unit-05 + unit-04 block payloads ship under these well-known paths
# in the scaffold repo. Tests can override DOCKER_OVERLAY_BLOCKS_DIR to
# point at a fixture tree.
__DOCKER_OVERLAY_DEFAULT_UNIT05="$(dirname "${BASH_SOURCE[0]}")/../overlay-blocks/unit-05"
__DOCKER_OVERLAY_DEFAULT_UNIT04_SNIPPET="$(dirname "${BASH_SOURCE[0]}")/../template/angular/_partials/nginx-getenvconfig.snippet"

# _docker_overlay_targeted_envsubst <src> <dst>
# Run envsubst against <src> with the scaffold-time allowlist
# (PROJECT_NAME, PROJECT_NAME_LOWER, PROJECTNAME_UPPER, GITHUB_OWNER) and
# write to <dst>. Deploy-time tokens (compose ${VAR:?...}, etc.) are
# preserved verbatim.
_docker_overlay_targeted_envsubst() {
    local src="$1" dst="$2"
    if [[ ! -f "$src" ]]; then
        log_fail "_docker_overlay_targeted_envsubst: missing src: $src" \
            "_docker_overlay_targeted_envsubst"
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

# docker_overlay_render_templated_files <target_real>
#
# Walks the rendered tree looking for the unit-06-owned *.template files
# (compose YAML, .env*, Dockerfiles, nginx entrypoint), runs a targeted
# envsubst pass on each, and drops the .template suffix. Idempotent — a
# second pass finds no *.template files and is a no-op.
docker_overlay_render_templated_files() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "docker_overlay_render_templated_files: missing target: $target" \
            "docker_overlay_render_templated_files"
        return 1
    fi
    # Explicit allowlist of *.template files this phase owns. We don't
    # blanket-process every *.template under the tree because unit-05 +
    # the operator's secrets templates (`*.secrets.json.template`,
    # `appsettings.Development.local.json.template`, `appsettings.secrets.
    # staging.json.template`, `environment.local.ts.template`) MUST stay
    # in .template form — they're operator pre-flight inputs, not
    # scaffold-time rendered files.
    #
    # The list splits into two classes:
    #   * "render"  — scaffold-time envsubst PASS and drop the .template
    #                  suffix (compose YAML, .env, Dockerfiles, the
    #                  nginx entrypoint script). These ship as final
    #                  artifacts the operator commits / uses directly.
    #   * "in_place" — scaffold-time envsubst PASS but PRESERVE the
    #                  .template suffix. Used for `.env.staging.template`
    #                  whose `${STAGING_*}` markers are deploy-time
    #                  envsubst targets (rendered to `.env.staging` on
    #                  the VM by the unit-08 deploy workflow). The
    #                  scaffold-time pass resolves project-name family
    #                  tokens while leaving `${STAGING_*}` untouched.
    local render_relpaths=(
        ".env.template"
        "docker-compose.yml.template"
        "docker-compose.dev.yml.template"
        "docker-compose.staging.yml.template"
        "src/Dockerfile.dotnet.template"
        "src/${PROJECT_NAME}.HttpApi.Host/Dockerfile.local.template"
        "src/${PROJECT_NAME}.DbMigrator/Dockerfile.local.template"
        "angular/Dockerfile.template"
        "angular/Dockerfile.local.template"
        "angular/docker-entrypoint.d/25-envsubst-dynamic-env.sh.template"
    )
    local in_place_relpaths=(
        ".env.staging.template"
    )
    local rel src dst tmp
    for rel in "${render_relpaths[@]}"; do
        src="${target}/${rel}"
        if [[ ! -f "$src" ]]; then
            log_info "[overlay-docker] skip (not present): ${rel}"
            continue
        fi
        # Drop the trailing .template suffix.
        dst="${src%.template}"
        tmp="${src}.docker-overlay.tmp"
        _docker_overlay_targeted_envsubst "$src" "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        mv "$tmp" "$dst"
        # Remove the .template original (the operator only needs the
        # rendered sibling).
        if [[ "$dst" != "$src" ]]; then
            rm -f "$src"
        fi
        log_info "[overlay-docker] rendered ${rel} -> ${dst#"$target"/}"
    done
    # In-place rendering for deploy-time .template files.
    for rel in "${in_place_relpaths[@]}"; do
        src="${target}/${rel}"
        if [[ ! -f "$src" ]]; then
            log_info "[overlay-docker] skip (not present): ${rel}"
            continue
        fi
        tmp="${src}.docker-overlay.tmp"
        _docker_overlay_targeted_envsubst "$src" "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        mv "$tmp" "$src"
        log_info "[overlay-docker] in-place rendered ${rel}"
    done
}

# docker_overlay_install_dockerfile_perms <target_real>
docker_overlay_install_dockerfile_perms() {
    local target="$1"
    local script="${target}/angular/docker-entrypoint.d/25-envsubst-dynamic-env.sh"
    if [[ ! -f "$script" ]]; then
        log_info "[overlay-docker] skip chmod: $script not present"
        return 0
    fi
    chmod +x "$script"
    log_info "[overlay-docker] chmod +x ${script#"$target"/}"
}

# docker_overlay_splice_nginx_conf <target_real>
docker_overlay_splice_nginx_conf() {
    local target="$1"
    local nginx_conf="${target}/angular/nginx.conf.template"
    if [[ ! -f "$nginx_conf" ]]; then
        log_info "[overlay-docker] skip nginx splice: ${nginx_conf#"$target"/} not present (UI=none or non-angular)"
        return 0
    fi

    # phase_apply_overlays step 3 already merged the .markers file into
    # nginx.conf.template (the .markers sibling was named
    # nginx.conf.template.markers; the merge call resolved to nginx.conf.
    # template as the existing file). So the empty marker pairs are
    # already in place. We splice the bodies here.
    local unit05_blocks="${DOCKER_OVERLAY_BLOCKS_DIR:-$__DOCKER_OVERLAY_DEFAULT_UNIT05}"
    local sec_headers="${unit05_blocks}/nginx-security-headers.conf"
    if [[ ! -f "$sec_headers" ]]; then
        log_fail "docker_overlay_splice_nginx_conf: nginx-security-headers.conf missing: $sec_headers" \
            "docker_overlay_splice_nginx_conf"
        return 1
    fi

    local getenv_snippet="${DOCKER_OVERLAY_GETENV_SNIPPET:-$__DOCKER_OVERLAY_DEFAULT_UNIT04_SNIPPET}"
    if [[ ! -f "$getenv_snippet" ]]; then
        log_fail "docker_overlay_splice_nginx_conf: getenvconfig snippet missing: $getenv_snippet" \
            "docker_overlay_splice_nginx_conf"
        return 1
    fi

    # Splice both payloads. scaffold_insert_block is idempotent on
    # already-spliced content (the second run finds the body between
    # markers and just rewrites it identically).
    scaffold_insert_block "$nginx_conf" "security-headers" "$sec_headers" || return 1
    scaffold_insert_block "$nginx_conf" "getenvconfig"     "$getenv_snippet" || return 1
    log_info "[overlay-docker] spliced security-headers + getenvconfig into ${nginx_conf#"$target"/}"
}

# docker_overlay_prune_ui_none <target_real>
#
# Iff IF_UI_NONE=1, drop the angular subtree + the `web:` service from
# every compose file + the SPA blocks from both Caddyfiles + the `web`
# dep from caddy.depends_on. yq is a hard preflight dep — used here for
# precise YAML edits.
docker_overlay_prune_ui_none() {
    local target="$1"
    if [[ "${IF_UI_NONE:-0}" != "1" ]]; then
        return 0
    fi
    # 1. Angular subtree.
    if [[ -d "${target}/angular" ]]; then
        rm -rf "${target}/angular"
        log_info "[overlay-docker] UI=none — removed angular/"
    fi

    # 2. Compose files: drop services.web and caddy.depends_on.web.
    local compose
    for compose in \
        "${target}/docker-compose.yml" \
        "${target}/docker-compose.dev.yml" \
        "${target}/docker-compose.staging.yml"
    do
        [[ -f "$compose" ]] || continue
        local tmp="${compose}.uinone.tmp"
        yq 'del(.services.web) | del(.services.caddy.depends_on.web)' \
            "$compose" > "$tmp"
        mv "$tmp" "$compose"
        log_info "[overlay-docker] UI=none — pruned web: from ${compose#"$target"/}"
    done

    # 3. Caddyfiles: drop the SPA reverse_proxy stanzas. The blocks are
    # marked with `# Public SPA endpoint` / `http://{$APP_WEB_HOSTNAME}`
    # headers — use awk-range deletion bounded by the block close `}`
    # on its own line.
    local caddy
    for caddy in \
        "${target}/Caddyfile.dev" \
        "${target}/Caddyfile.staging"
    do
        [[ -f "$caddy" ]] || continue
        local tmp="${caddy}.uinone.tmp"
        awk '
            /^# Public SPA endpoint/             { drop=1; next }
            /^http:\/\/\{\$APP_WEB_HOSTNAME\}/   { drop=1; next }
            /^\{\$APP_WEB_HOSTNAME\}/            { drop=1; next }
            drop && /^\}/                        { drop=0; next }
            !drop { print }
        ' "$caddy" > "$tmp"
        mv "$tmp" "$caddy"
        log_info "[overlay-docker] UI=none — pruned SPA blocks from ${caddy#"$target"/}"
    done
}
