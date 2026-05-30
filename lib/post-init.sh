#!/usr/bin/env bash
# lib/post-init.sh — unit-10 post-init orchestration helpers.
#
# Sourced by scaffold.sh's `phase_run_post_init_commands`. Runs AFTER every
# overlay phase has stamped its files into the target tree (security,
# docker, terraform, github-workflows) so this layer can safely invoke
# `dotnet ef migrations add Initial`, `abp install-libs`/`yarn install`,
# and the `dotnet build` smoke against a complete scaffolded tree.
#
# Public entry-points:
#   post_init_run_ef_migration       <target_real>
#       Gate on db_provider == "ef" AND template ∈ {app, module} AND the
#       expected EntityFrameworkCore project dir exists. Calls
#       `dotnet ef migrations add Initial`. Smoke-checks that a
#       *Initial.cs file landed on disk. HARD failure → `rm -rf` target.
#
#   post_init_install_libs           <target_real>
#       UI-gated: angular → `yarn install --frozen-lockfile`,
#       mvc/blazor → `abp install-libs`, blazor-server/none → no-op.
#       SOFT failure on network hiccups — log_warn and continue (operator
#       can re-run from the handoff message).
#
#   post_init_smoke_dotnet_build     <target_real>
#       Find the top-level .slnx/.sln and run `dotnet build` against it.
#       HARD failure → `rm -rf` target so the operator can retry from
#       a clean state.

if [[ -n "${__LH_POST_INIT_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_POST_INIT_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# post_init_run_ef_migration <target_real>
#
# `dotnet ef migrations add Initial` on the freshly-scaffolded tree.
# Triple-gated:
#   1. ABP_DB_PROVIDER == "ef"
#   2. ABP_TEMPLATE ∈ {app, module}
#   3. <target>/src/${PROJECT_NAME}.EntityFrameworkCore/ exists
# Any gate miss → log_info + return 0 (no-op skip).
#
# On failure (non-zero exit, or success but no Initial.cs landed):
#   - log_fail with the offending command + last stderr line
#   - rm -rf "$target_real" so the operator can retry from clean state
#   - return 1
post_init_run_ef_migration() {
    local target="$1"
    if [[ "${ABP_DB_PROVIDER:-ef}" != "ef" ]]; then
        log_info "[post-init] skipping EF initial migration: db_provider=${ABP_DB_PROVIDER:-<unset>}"
        return 0
    fi
    if [[ "${ABP_TEMPLATE:-app}" != "app" && "${ABP_TEMPLATE:-app}" != "module" ]]; then
        log_info "[post-init] skipping EF initial migration: template=${ABP_TEMPLATE:-<unset>}"
        return 0
    fi
    local ef_proj="${target}/src/${PROJECT_NAME}.EntityFrameworkCore"
    if [[ ! -d "$ef_proj" ]]; then
        log_warn "[post-init] expected ${ef_proj} missing; skipping EF migration"
        return 0
    fi
    log_info "[post-init] dotnet ef migrations add Initial"
    local out_log
    out_log="$(mktemp -t scaffold-ef-migrations.XXXXXX.log)"
    local rc=0
    ( cd "$target" && \
      dotnet ef migrations add Initial \
        -p "src/${PROJECT_NAME}.EntityFrameworkCore" \
        -s "src/${PROJECT_NAME}.DbMigrator" \
        -o Migrations \
        > "$out_log" 2>&1 ) || rc=$?
    if (( rc != 0 )); then
        local last_err
        last_err="$(grep -E '(error|fail)' "$out_log" | tail -n1 | tr -d '\r')"
        [[ -z "$last_err" ]] && last_err="$(tail -n1 "$out_log" | tr -d '\r')"
        log_fail "[step post-init] dotnet ef migrations add Initial failed: ${last_err}" \
            "dotnet ef migrations add Initial"
        rm -f "$out_log"
        # Per unit-01 contract: rollback target dir on HARD failure.
        rm -rf "$target"
        return 1
    fi
    rm -f "$out_log"
    # Smoke-check the migration files made it onto disk.
    if ! find "${ef_proj}/Migrations" -maxdepth 1 -name '*Initial.cs' -print -quit \
            2>/dev/null | grep -q .; then
        log_fail "[step post-init] dotnet ef succeeded but no *Initial.cs found under Migrations/" \
            "dotnet ef migrations add Initial"
        rm -rf "$target"
        return 1
    fi
    log_info "[post-init] EF Initial migration generated"
}

# post_init_install_libs <target_real>
#
# UI-gated client-lib install. SOFT failure (log_warn, no rollback)
# because both `abp install-libs` and `yarn install` are network-bound
# and transient registry hiccups should not nuke a successfully-scaffolded
# tree. Operator can re-run them post-handoff.
post_init_install_libs() {
    local target="$1"
    case "${UI:-angular}" in
        mvc|blazor)
            log_info "[post-init] abp install-libs"
            local rc=0
            ( cd "$target" && abp install-libs ) || rc=$?
            if (( rc != 0 )); then
                log_warn "[post-init] abp install-libs failed (rc=${rc}); operator can retry post-handoff"
            fi
            ;;
        angular)
            if [[ ! -d "${target}/angular" ]]; then
                log_warn "[post-init] UI=angular but ${target}/angular missing; skipping yarn install"
                return 0
            fi
            log_info "[post-init] yarn --cwd ${target}/angular install"
            local rc=0
            ( cd "${target}/angular" && yarn install --frozen-lockfile ) || rc=$?
            if (( rc != 0 )); then
                log_warn "[post-init] yarn install failed (rc=${rc}); operator can retry post-handoff"
            fi
            ;;
        blazor-server|none)
            log_info "[post-init] UI=${UI:-<unset>}: nothing to install"
            ;;
        *)
            log_warn "[post-init] unknown UI=${UI:-<unset>}; skipping client lib install"
            ;;
    esac
}

# post_init_smoke_dotnet_build <target_real>
#
# Build the top-level .slnx (preferred) or .sln to confirm the scaffolded
# tree compiles. HARD failure → rm -rf target + return 1. Skips with a
# log_warn (rc=0) when no solution file is found (e.g., during a partial
# unit-test fixture).
post_init_smoke_dotnet_build() {
    local target="$1"
    local sln
    sln=$(find "$target" -maxdepth 2 \( -name '*.slnx' -o -name '*.sln' \) \
            -print -quit 2>/dev/null)
    if [[ -z "$sln" ]]; then
        log_warn "[post-init] no .slnx/.sln found at top of ${target}; skipping build smoke"
        return 0
    fi
    local sln_name
    sln_name="$(basename "$sln")"
    log_info "[post-init] dotnet build ${sln_name}"
    local out_log
    out_log="$(mktemp -t scaffold-dotnet-build.XXXXXX.log)"
    local rc=0
    ( cd "$target" && dotnet build "$sln_name" --nologo -v minimal \
        > "$out_log" 2>&1 ) || rc=$?
    if (( rc != 0 )); then
        local last_err
        last_err="$(grep -E '(error|FAIL)' "$out_log" | tail -n1 | tr -d '\r')"
        [[ -z "$last_err" ]] && last_err="$(tail -n1 "$out_log" | tr -d '\r')"
        log_fail "[step post-init] dotnet build smoke failed: ${last_err}" \
            "dotnet build ${sln_name}"
        rm -f "$out_log"
        rm -rf "$target"
        return 1
    fi
    rm -f "$out_log"
    log_info "[post-init] dotnet build smoke passed"
}
