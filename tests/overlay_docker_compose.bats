#!/usr/bin/env bats
# tests/overlay_docker_compose.bats — end-to-end test of unit-06's
# docker-overlay phase.
#
# Stands up a minimal abp-new-like tree, runs phase_apply_overlays
# (which copies template/ + merges *.markers) followed by
# phase_apply_docker_overlay (which renders the *.template files,
# splices the nginx security-headers + getEnvConfig blocks, and chmods
# the entrypoint script). Asserts the rendered docker / compose /
# Caddy / nginx surface matches the unit-06 plan §1 layout.

load _helper

# Seed a minimal abp-new-like tree. Mirrors the seed pattern used by
# overlay_dotnet_application.bats — we only care about the directories
# the docker-overlay phase needs (src/{PN}.HttpApi.Host,
# src/{PN}.DbMigrator, angular/), not the full 12-project shape.
_seed_fake_target() {
    local root="$1" pn="$2"
    mkdir -p "$root/src/${pn}.HttpApi.Host" \
             "$root/src/${pn}.DbMigrator" \
             "$root/angular/docker-entrypoint.d"
}

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
    export HETZNER_LOCATION=hel1 HETZNER_SERVER_TYPE=cx22 CLOUDFLARE_ZONE=example.com
    unset __LH_LOG_SH_SOURCED __LH_SUBSTITUTE_SH_SOURCED \
          __LH_DOTNET_OVERLAY_SH_SOURCED __LH_SECURITY_OVERLAY_SH_SOURCED \
          __LH_DOCKER_OVERLAY_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/substitute.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/substitute.sh"
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/dotnet-overlay.sh"
    # shellcheck source=lib/docker-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/docker-overlay.sh"
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

# Copy the unit-06 docker-overlay-owned templates into the seeded
# target tree, mirroring what phase_apply_overlays does for these files
# (substitute {{PROJECTNAME}} -> $PROJECT_NAME in path segments;
# preserve content of *.template files verbatim). Skips the unrelated
# files (csproj, app modules etc.) so the test stays focused on
# unit-06 surfaces.
_apply_docker_template_files() {
    local target="$1" pn="$2"
    local src dst rel
    for rel in \
        ".env.template" \
        ".env.staging.template" \
        "docker-compose.yml.template" \
        "docker-compose.dev.yml.template" \
        "docker-compose.staging.yml.template" \
        "Caddyfile.dev" \
        "Caddyfile.staging" \
        "src/Dockerfile.dotnet.template" \
        "src/{{PROJECTNAME}}.HttpApi.Host/Dockerfile.local.template" \
        "src/{{PROJECTNAME}}.DbMigrator/Dockerfile.local.template" \
        "angular/Dockerfile.template" \
        "angular/Dockerfile.local.template" \
        "angular/nginx.conf.template" \
        "angular/nginx.conf.template.markers" \
        "angular/docker-entrypoint.d/25-envsubst-dynamic-env.sh.template"
    do
        src="${SCAFFOLD_ROOT}/template/${rel}"
        [ -f "$src" ] || continue
        # Substitute path segments.
        local rel_substituted="${rel//\{\{PROJECTNAME\}\}/${pn}}"
        dst="${target}/${rel_substituted}"
        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
    done
    # Run scaffold-time substitute_file on the non-*.template files
    # (Caddyfile.dev / Caddyfile.staging carry PROJECT_NAME tokens).
    substitute_file "${target}/Caddyfile.dev" 2>/dev/null || true
    substitute_file "${target}/Caddyfile.staging" 2>/dev/null || true
    # Merge the nginx markers into the nginx.conf.template (mirrors
    # phase_apply_overlays step 3).
    merge_markers_into_existing \
        "${target}/angular/nginx.conf.template" \
        "${target}/angular/nginx.conf.template.markers"
    rm -f "${target}/angular/nginx.conf.template.markers"
}

setup() {
    TMP="$(mktemp -d -t overlay-docker-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    _seed_fake_target "$TARGET" SmokeApp
}

teardown() {
    rm -rf "$TMP"
}

# -----------------------------------------------------------------------
# T1-T2: compose-file parse cleanliness (best-effort — requires docker).
# -----------------------------------------------------------------------

@test "T1: docker-compose.yml + dev overlay parses cleanly (skipped if no docker)" {
    if ! command -v docker >/dev/null; then
        skip "docker not on PATH; covered by smoke-abp-new.sh's optional step"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    docker_overlay_install_dockerfile_perms "$TARGET"
    docker_overlay_splice_nginx_conf "$TARGET"
    ( cd "$TARGET" && \
        APP_ENVIRONMENT=Development DB_PASSWORD=test API_PUBLIC_URL=https://api.localhost \
        WEB_PUBLIC_URL=https://localhost APP_API_HOSTNAME=api.localhost \
        APP_WEB_HOSTNAME=localhost \
        docker compose -f docker-compose.yml -f docker-compose.dev.yml config ) > /dev/null
}

@test "T2: docker-compose.yml + staging overlay parses cleanly (skipped if no docker)" {
    if ! command -v docker >/dev/null; then
        skip "docker not on PATH; covered by smoke-abp-new.sh's optional step"
    fi
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    docker_overlay_install_dockerfile_perms "$TARGET"
    docker_overlay_splice_nginx_conf "$TARGET"
    ( cd "$TARGET" && \
        APP_ENVIRONMENT=Staging DB_PASSWORD=test API_VERSION=v1 WEB_VERSION=v1 \
        MIGRATOR_VERSION=v1 API_PUBLIC_URL=https://api.example.com \
        WEB_PUBLIC_URL=https://example.com APP_API_HOSTNAME=api.example.com \
        APP_WEB_HOSTNAME=example.com APP_ACME_EMAIL=ops@example.com \
        docker compose -f docker-compose.yml -f docker-compose.staging.yml config ) > /dev/null
}

# -----------------------------------------------------------------------
# T3: yq-based structural validation (compose-file fallback for no-docker).
# -----------------------------------------------------------------------

@test "T3: docker-compose.yml lists all 5 expected services" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    docker_overlay_install_dockerfile_perms "$TARGET"
    docker_overlay_splice_nginx_conf "$TARGET"
    [ -f "$TARGET/docker-compose.yml" ]
    for svc in db migrator api web caddy; do
        yq ".services | has(\"$svc\")" "$TARGET/docker-compose.yml" | grep -q '^true$'
    done
}

# -----------------------------------------------------------------------
# T4: Caddyfile syntactic validity (best-effort).
# -----------------------------------------------------------------------

@test "T4: Caddyfile.dev + Caddyfile.staging carry expected site blocks" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    [ -f "$TARGET/Caddyfile.dev" ]
    [ -f "$TARGET/Caddyfile.staging" ]
    # Dev has 4 site blocks: 2 HTTPS + 2 HTTP-redirect.
    n_dev=$(grep -cE '^[a-z\{].*\{[[:space:]]*$' "$TARGET/Caddyfile.dev")
    [ "$n_dev" -ge 4 ]
    # Staging has 2 site blocks (HTTPS auto-provisioned).
    n_stg=$(grep -cE '^[a-z\{].*\{[[:space:]]*$' "$TARGET/Caddyfile.staging")
    [ "$n_stg" -ge 2 ]
    # Optional `caddy validate` if binary is available.
    if command -v caddy >/dev/null; then
        caddy validate --adapter caddyfile --config "$TARGET/Caddyfile.dev" || true
    fi
}

# -----------------------------------------------------------------------
# T5: rendered nginx.conf.template includes all 6 security directives.
# -----------------------------------------------------------------------

@test "T5: rendered nginx.conf.template includes all 6 security directives" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_splice_nginx_conf "$TARGET"
    f="$TARGET/angular/nginx.conf.template"
    [ -f "$f" ]
    grep -qF 'Content-Security-Policy-Report-Only' "$f"
    grep -qF 'Strict-Transport-Security "max-age=2592000"' "$f"
    grep -qF 'X-Frame-Options "DENY"' "$f"
    grep -qF 'X-Content-Type-Options "nosniff"' "$f"
    grep -qF 'Referrer-Policy "strict-origin-when-cross-origin"' "$f"
    grep -qF 'location = /csp-report' "$f"
}

# -----------------------------------------------------------------------
# T6: rendered nginx.conf.template includes the /getEnvConfig route.
# -----------------------------------------------------------------------

@test "T6: rendered nginx.conf.template includes the /getEnvConfig route" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_splice_nginx_conf "$TARGET"
    f="$TARGET/angular/nginx.conf.template"
    grep -qF 'location /getEnvConfig' "$f"
    grep -qF 'try_files $uri /dynamic-env.json' "$f"
}

# -----------------------------------------------------------------------
# T7: rendered nginx.conf.template includes the /csp-report 204 stub.
# -----------------------------------------------------------------------

@test "T7: rendered nginx.conf.template includes the /csp-report 204 stub" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_splice_nginx_conf "$TARGET"
    f="$TARGET/angular/nginx.conf.template"
    # Match `location = /csp-report` followed by `return 204;` within 3
    # lines.
    awk '/location = \/csp-report/{found=1; nl=0} found && /return 204/{print "OK"; exit} found{nl++; if (nl>3) exit 1}' \
        "$f" | grep -q OK
}

# -----------------------------------------------------------------------
# T8: .env is well-formed key=value.
# -----------------------------------------------------------------------

@test "T8: .env is well-formed key=value with project-substituted defaults" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    [ -f "$TARGET/.env" ]
    # No leftover .env.template (rename happened).
    [ ! -f "$TARGET/.env.template" ]
    # Every non-comment / non-blank line matches key=value shape.
    grep -vE '^[[:space:]]*(#|$)' "$TARGET/.env" | \
        grep -vE '^[A-Z_][A-Z0-9_]*=' && return 1 || true
    grep -q '^OPENIDDICT_DEV_CERT_PASS=smokeapp-dev-cert-pass$' "$TARGET/.env"
    grep -q '^DB_PASSWORD=smokeapp-dev$' "$TARGET/.env"
}

# -----------------------------------------------------------------------
# T9: .env.staging.template preserves deploy-time tokens verbatim.
# -----------------------------------------------------------------------

@test "T9: .env.staging.template carries only \${STAGING_*} deploy-time tokens" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    f="$TARGET/.env.staging.template"
    [ -f "$f" ]
    # Every ${VAR} reference is either STAGING_* or PROJECTNAME_UPPER-
    # prefixed (the SPA / Caddy env-var contract). Scaffold-time tokens
    # (${PROJECT_NAME_LOWER}, ${GITHUB_OWNER}) must all be resolved.
    ! grep -qE '\$\{(PROJECT_NAME|PROJECT_NAME_LOWER|PROJECTNAME_UPPER|GITHUB_OWNER)\}' "$f"
    grep -qE '\$\{STAGING_' "$f"
}

# -----------------------------------------------------------------------
# T10: UI=none prune drops angular/ + web: + SPA stanzas.
# -----------------------------------------------------------------------

@test "T10: UI=none prune drops angular/ + web: service + SPA stanzas" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    export IF_UI_NONE=1
    docker_overlay_prune_ui_none "$TARGET"
    [ ! -d "$TARGET/angular" ]
    # `web:` removed from every compose file.
    for f in docker-compose.yml docker-compose.dev.yml docker-compose.staging.yml; do
        [ -f "$TARGET/$f" ] || continue
        yq '.services | has("web")' "$TARGET/$f" | grep -q '^false$'
    done
    # SPA blocks pruned from Caddyfile.dev.
    ! grep -qF 'reverse_proxy web:8080' "$TARGET/Caddyfile.dev"
}

# -----------------------------------------------------------------------
# T11: Dockerfile.dotnet syntactic sanity (4 FROM stages).
# -----------------------------------------------------------------------

@test "T11: Dockerfile.dotnet has all 4 expected FROM stages" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    f="$TARGET/src/Dockerfile.dotnet"
    [ -f "$f" ]
    n=$(grep -c '^FROM ' "$f")
    [ "$n" -ge 4 ]
    grep -qF 'AS build' "$f"
    grep -qF 'AS libs' "$f"
    grep -qF 'AS api' "$f"
    grep -qF 'AS migrator' "$f"
}

# -----------------------------------------------------------------------
# T12: nginx splice idempotency.
# -----------------------------------------------------------------------

@test "T12: nginx splice is idempotent (byte-identical second run)" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_splice_nginx_conf "$TARGET"
    f="$TARGET/angular/nginx.conf.template"
    h1=$(sha256sum "$f" | awk '{print $1}')
    docker_overlay_splice_nginx_conf "$TARGET"
    h2=$(sha256sum "$f" | awk '{print $1}')
    [ "$h1" = "$h2" ]
}

# -----------------------------------------------------------------------
# T13: secret bind-mount paths are documented in compose comments.
# -----------------------------------------------------------------------

@test "T13: secret bind-mount paths reference /etc/\${PROJECT_NAME_LOWER}/" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    # Dev compose bind-mounts `./src/{PN}.HttpApi.Host/appsettings.secrets.json`.
    grep -qF 'appsettings.secrets.json' "$TARGET/docker-compose.dev.yml"
    # Staging compose bind-mounts under /etc/smokeapp/.
    grep -qF '/etc/smokeapp/api/appsettings.secrets.json' "$TARGET/docker-compose.staging.yml"
    grep -qF '/etc/smokeapp/migrator/appsettings.secrets.json' "$TARGET/docker-compose.staging.yml"
    grep -qF '/etc/smokeapp/openiddict.pfx' "$TARGET/docker-compose.staging.yml"
}

# -----------------------------------------------------------------------
# T14: uid:gid 10001 contract on api + migrator runtime stages.
# -----------------------------------------------------------------------

@test "T14: Dockerfile.dotnet creates uid 10001 on both api + migrator stages" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    f="$TARGET/src/Dockerfile.dotnet"
    n=$(grep -cE 'adduser .* -u 10001' "$f")
    [ "$n" -eq 2 ]
}

# -----------------------------------------------------------------------
# T15: image-size budget marker (alpine runtime base).
# -----------------------------------------------------------------------

@test "T15: Dockerfile.dotnet pins aspnet:10.0-alpine runtime base" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    f="$TARGET/src/Dockerfile.dotnet"
    grep -qE 'aspnet:10\.0-alpine' "$f"
}

# -----------------------------------------------------------------------
# Additional sanity: docker_overlay_render_templated_files renames + envsubsts.
# -----------------------------------------------------------------------

@test "render: docker-compose.yml drops .template suffix and substitutes PROJECT_NAME tokens" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    [ -f "$TARGET/docker-compose.yml" ]
    [ ! -f "$TARGET/docker-compose.yml.template" ]
    grep -q 'name: smokeapp' "$TARGET/docker-compose.yml"
    grep -q 'image: smokeapp-api' "$TARGET/docker-compose.yml"
}

@test "render: 25-envsubst-dynamic-env.sh is executable after install_dockerfile_perms" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    docker_overlay_install_dockerfile_perms "$TARGET"
    f="$TARGET/angular/docker-entrypoint.d/25-envsubst-dynamic-env.sh"
    [ -f "$f" ]
    [ -x "$f" ]
}

@test "render: angular Dockerfile pins NGINX_ENVSUBST_FILTER to '^APP_'" {
    _setup_phase_env "$TARGET" SmokeApp
    _apply_docker_template_files "$TARGET" SmokeApp
    docker_overlay_render_templated_files "$TARGET"
    f="$TARGET/angular/Dockerfile"
    [ -f "$f" ]
    grep -qF "NGINX_ENVSUBST_FILTER='^APP_'" "$f"
}
