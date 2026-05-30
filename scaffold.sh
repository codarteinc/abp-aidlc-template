#!/usr/bin/env bash
# scaffold.sh — top-level orchestration entry-point for the
# abp-aidlc-template scaffold tool.
#
# Runs the 11-phase pipeline (preflight -> load/prompt config -> validate ->
# recommend -> confirm -> create target -> abp new -> apply overlays ->
# post-init -> github init -> handoff). In unit-01 most `phase_*`
# functions are no-op stubs; downstream units 02-10 swap in real bodies.
#
# Usage:
#   scaffold.sh                              # interactive mode
#   scaffold.sh --config my-app.yml          # config-file mode
#   scaffold.sh --config ... --target DIR    # override target dir
#   scaffold.sh --config ... --dry-run       # run all phases as no-ops, exit 0
#   scaffold.sh --config ... --skip-gh-create  # skip gh repo create + push + branch protection
#   scaffold.sh --help                       # show usage banner
#
# Exit codes:
#   0  success (incl. --dry-run)
#   1  validation / runtime failure
#   2  target directory exists and is non-empty (greenfield-only)

set -euo pipefail

# BASH_SOURCE-relative path resolution so the script works when invoked
# from any cwd (e.g. /opt/abp-aidlc-template/scaffold.sh).
SCAFFOLD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCAFFOLD_ROOT}/lib"
TEMPLATE_DIR="${SCAFFOLD_ROOT}/template"
SCHEMA_FILE="${SCAFFOLD_ROOT}/scaffold-config-schema.yml"

# shellcheck source=lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=lib/validate-config.sh
source "${LIB_DIR}/validate-config.sh"
# shellcheck source=lib/prompt.sh
source "${LIB_DIR}/prompt.sh"
# shellcheck source=lib/substitute.sh
source "${LIB_DIR}/substitute.sh"

# Total number of orchestration phases. Bump as unit-10 adds real bodies.
# 15 includes unit-05's phase_apply_security_overlay (inserted between
# phase_apply_overlays and phase_run_post_init_commands), unit-06's
# phase_apply_docker_overlay (inserted between security overlay and
# post-init), unit-07's phase_apply_terraform_overlay (inserted between
# docker overlay and post-init), and unit-08's
# phase_apply_github_workflows_overlay (inserted between terraform
# overlay and post-init).
STEP_TOTAL=15
STEP=0
CURRENT_PHASE=""

# --- flag parsing ---------------------------------------------------------

CONFIG_PATH=""
TARGET_DIR=""
DRY_RUN=0
DRY_RUN_ABP_NEW=0
# unit-10 — pre-push escape hatches.
# SKIP_GH_CREATE: documented flag — operator-visible in --help. Skips
#   gh repo create / push / branch-protection / workflow-perms check.
#   Local git init + initial commit still happen.
# DRY_RUN_GITHUB: undocumented; bats-only. Causes gh-touching helpers
#   to print 'GH_CMD: ...' lines and return 0 WITHOUT invoking gh.
# SKIP_POST_INIT: undocumented; operator/test escape hatch when the
#   dotnet/abp/yarn toolchain isn't available on the running host.
SKIP_GH_CREATE="${SKIP_GH_CREATE:-false}"
DRY_RUN_GITHUB="${DRY_RUN_GITHUB:-0}"
SKIP_POST_INIT="${SKIP_POST_INIT:-0}"
# ABP_VERSION may be set by --abp-version flag, by env, or autodetected
# inside phase_abp_new. Initialize from env so an operator export wins
# over autodetect but loses to an explicit --abp-version flag.
ABP_VERSION="${ABP_VERSION:-}"

print_help() {
    cat <<EOF
scaffold.sh — one-command ABP scaffold with LinkHub-grade infra/CI/devops baked in.

USAGE:
  scaffold.sh [--config <path>] [--target <dir>] [--dry-run] [--abp-version <X.Y.Z>]
  scaffold.sh --help

FLAGS:
  --config <path>       Path to a scaffold config YAML (skips interactive prompts).
  --target <dir>        Target directory for the scaffolded project.
                        Defaults to ./<project_name_lower> once config is loaded.
  --dry-run             Run every phase as a no-op and exit 0. Useful for smoke
                        tests of the orchestration pipeline.
  --abp-version <X.Y.Z> Pin the ABP framework version passed to 'abp new'.
                        Defaults to the locally-installed CLI's reported version.
  --skip-gh-create      Skip 'gh repo create' (and the push + branch-protection
                        + workflow-perms check). git init + initial commit
                        still happen so the operator can push manually later.
  --help, -h            Show this banner.

CONFIG FLAGS (enumerated from scaffold-config-schema.yml):
EOF
    describe_schema "$SCHEMA_FILE" 2>/dev/null || printf '  (schema describe failed — is yq installed?)\n'
    cat <<EOF

EXAMPLES:
  scaffold.sh
  scaffold.sh --config scaffold-config.example.yml
  scaffold.sh --config scaffold-config.example.yml --dry-run
  scaffold.sh --config my-app.yml --target /tmp/my-app

DOCS:
  https://github.com/codarteinc/abp-aidlc-template
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_PATH="${2:-}"
            shift 2
            ;;
        --target)
            TARGET_DIR="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --abp-version)
            ABP_VERSION="${2:-}"
            export ABP_VERSION
            shift 2
            ;;
        --dry-run-abp-new)
            # Test-only short-circuit for bats. Intentionally undocumented
            # in --help so operators never see it. Causes phase_abp_new to
            # print the assembled flag array and return 0 without invoking
            # the real `abp new` binary.
            DRY_RUN_ABP_NEW=1
            shift
            ;;
        --dry-run-github)
            # Test-only short-circuit for bats. Intentionally undocumented
            # in --help. Causes phase_github_repo_init's gh-touching
            # helpers to print 'GH_CMD: <cmd>' lines and return 0 WITHOUT
            # invoking the real gh CLI. git init + initial commit DO
            # still happen (we want the bats tests to verify the commit
            # graph).
            DRY_RUN_GITHUB=1
            shift
            ;;
        --skip-gh-create)
            # Operator-visible escape hatch. Runs git init + initial
            # commit but skips gh repo create / push / branch-protection.
            SKIP_GH_CREATE=true
            shift
            ;;
        --skip-post-init)
            # Test/operator escape hatch when the dotnet/abp/yarn
            # toolchain is not available on the running host. Causes
            # phase_run_post_init_commands to log_info + return 0.
            SKIP_POST_INIT=1
            shift
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        *)
            log_err "unknown flag: $1"
            print_help >&2
            exit 1
            ;;
    esac
done

# --- helpers --------------------------------------------------------------

# Convenience wrapper: every phase opens with this so the orchestrator
# (or a `set -x`-style trace) sees consistent headers.
_phase_start() {
    CURRENT_PHASE="$1"
    STEP=$((STEP + 1))
    log_step "$STEP" "$STEP_TOTAL" "$CURRENT_PHASE"
}

# Export config-derived env vars from a YAML file. Reads via yq.
# Sets PROJECT_NAME / PROJECT_NAME_LOWER / PROJECTNAME_UPPER etc. plus
# IF_<FLAG>=1/0 flags. Safe to call multiple times.
_export_config_env() {
    local cfg="$1"
    PROJECT_NAME=$(yq '.project_name // ""' "$cfg")
    GITHUB_OWNER=$(yq '.github_owner // ""' "$cfg")
    HCP_ORG=$(yq ".hcp_org // .github_owner // \"\"" "$cfg")
    DBMS=$(yq '.abp.dbms // "postgresql"' "$cfg")
    UI=$(yq '.abp.ui // "angular"' "$cfg")
    DB_PROVIDER=$(yq '.abp.db_provider // "ef"' "$cfg")
    DEFAULT_CULTURE=$(yq '.abp.default_culture // "en"' "$cfg")
    MULTI_TENANCY=$(yq '.abp.multi_tenancy // false' "$cfg")
    TIERED=$(yq '.abp.tiered // false' "$cfg")
    HETZNER_LOCATION=$(yq '.infra.hetzner_location // "hel1"' "$cfg")
    HETZNER_SERVER_TYPE=$(yq '.infra.hetzner_server_type // "cx23"' "$cfg")
    CLOUDFLARE_ZONE=$(yq '.infra.cloudflare_zone // "REPLACE_ME"' "$cfg")
    # Derived cases.
    PROJECT_NAME_LOWER="${PROJECT_NAME,,}"
    PROJECTNAME_UPPER="${PROJECT_NAME^^}"
    export PROJECT_NAME PROJECT_NAME_LOWER PROJECTNAME_UPPER GITHUB_OWNER HCP_ORG
    export DBMS UI DB_PROVIDER DEFAULT_CULTURE MULTI_TENANCY TIERED
    export HETZNER_LOCATION HETZNER_SERVER_TYPE CLOUDFLARE_ZONE

    # IF_* flags for conditional blocks in .tmpl overlays.
    IF_UI_ANGULAR=0
    IF_UI_MVC=0
    IF_UI_BLAZOR=0
    IF_UI_BLAZOR_SERVER=0
    IF_UI_NONE=0
    case "$UI" in
        angular)       IF_UI_ANGULAR=1 ;;
        mvc)           IF_UI_MVC=1 ;;
        blazor)        IF_UI_BLAZOR=1 ;;
        blazor-server) IF_UI_BLAZOR_SERVER=1 ;;
        none)          IF_UI_NONE=1 ;;
    esac
    IF_DB_EF=0
    IF_DB_MONGODB=0
    case "$DB_PROVIDER" in
        ef)      IF_DB_EF=1 ;;
        mongodb) IF_DB_MONGODB=1 ;;
    esac
    IF_MULTI_TENANCY=0
    [[ "$MULTI_TENANCY" == "true" ]] && IF_MULTI_TENANCY=1
    IF_TIERED=0
    [[ "$TIERED" == "true" ]] && IF_TIERED=1
    export IF_UI_ANGULAR IF_UI_MVC IF_UI_BLAZOR IF_UI_BLAZOR_SERVER IF_UI_NONE
    export IF_DB_EF IF_DB_MONGODB IF_MULTI_TENANCY IF_TIERED

    # unit-02 ABP_* aliases — stable namespaced contract for the abp_new
    # wrapper and downstream overlays. Keep in lock-step with the unit-01
    # bareword exports above. ABP_VERSION is NOT set here; phase_abp_new
    # resolves it from the --abp-version flag / env / `abp --version`.
    ABP_TEMPLATE=$(yq '.abp.template // "app"' "$cfg")
    ABP_UI="$UI"
    ABP_DB_PROVIDER="$DB_PROVIDER"
    ABP_DBMS="$DBMS"
    ABP_MULTI_TENANCY="$MULTI_TENANCY"
    ABP_TIERED="$TIERED"
    ABP_DEFAULT_CULTURE="$DEFAULT_CULTURE"
    ABP_THEME="${ABP_THEME:-leptonx-lite}"
    # yq emits a YAML array; flatten to CSV (empty string when []).
    ABP_OPTIONAL_MODULES=$(yq -r '.abp.optional_modules // [] | join(",")' "$cfg")
    export ABP_TEMPLATE ABP_UI ABP_DB_PROVIDER ABP_DBMS ABP_MULTI_TENANCY
    export ABP_TIERED ABP_DEFAULT_CULTURE ABP_THEME ABP_OPTIONAL_MODULES
}

# --- phases ---------------------------------------------------------------

phase_preflight() {
    _phase_start "phase_preflight"
    # Linux-only v1 — friendly warn rather than hard fail.
    if [[ "$(uname)" != "Linux" ]]; then
        log_warn "v1 is Linux-only — macOS support tracked in v2 roadmap"
    fi
    local required=(bash git gh yq envsubst awk file)
    local missing=()
    for tool in "${required[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log_fail "missing required tools: ${missing[*]}" "command -v"
        log_info "install hint: apt-get install -y git gh yq gettext-base file gawk"
        return 1
    fi
    # bash >= 4 (unit-01 spec assumption #6: needs ${var,,} / ${var^^}).
    if (( BASH_VERSINFO[0] < 4 )); then
        log_fail "bash >= 4 required (you have ${BASH_VERSION})" "bash --version"
        return 1
    fi
    log_info "deferred preflight (checked once unit-02+ phases run): abp dotnet node yarn docker terraform"
    log_ok "preflight passed"
}

phase_load_or_prompt_config() {
    _phase_start "phase_load_or_prompt_config"
    if [[ -n "$CONFIG_PATH" ]]; then
        if [[ ! -f "$CONFIG_PATH" ]]; then
            log_fail "config file not found: $CONFIG_PATH" "phase_load_or_prompt_config"
            return 1
        fi
        log_info "loading config from $CONFIG_PATH"
    else
        log_info "no --config supplied; entering interactive mode"
        local tmp
        tmp=$(mktemp --suffix=.yml)
        local pn go use_defaults
        pn=$(prompt_text "Project name (PascalCase, e.g. MyApp)" "MyApp")
        go=$(prompt_text "GitHub owner" "codarteinc")
        use_defaults=$(prompt_yesno "Use defaults for everything else (UI=angular, db=ef/postgresql, infra=hel1/cx23)?" y)
        # Build a minimal YAML; unit-02 will populate the rest from the
        # recommendation engine. cloudflare_zone uses REPLACE_ME so the
        # operator notices before deploy.
        {
            printf 'project_name: %s\n' "$pn"
            printf 'github_owner: %s\n' "$go"
            printf 'abp:\n'
            printf '  template: app\n'
            printf '  ui: angular\n'
            printf '  db_provider: ef\n'
            printf '  dbms: postgresql\n'
            printf '  tiered: false\n'
            printf '  multi_tenancy: false\n'
            printf '  default_culture: en\n'
            printf '  optional_modules: []\n'
            printf 'infra:\n'
            printf '  hetzner_location: hel1\n'
            printf '  hetzner_server_type: cx23\n'
            printf '  cloudflare_zone: REPLACE_ME\n'
        } > "$tmp"
        if [[ "$use_defaults" != "yes" ]]; then
            log_warn "interactive override of defaults is implemented in unit-02; using defaults for now"
        fi
        CONFIG_PATH="$tmp"
        log_info "wrote interactive config to $CONFIG_PATH"
    fi
    _export_config_env "$CONFIG_PATH"
    log_info "exported env: PROJECT_NAME=$PROJECT_NAME GITHUB_OWNER=$GITHUB_OWNER UI=$UI DB_PROVIDER=$DB_PROVIDER"
}

phase_validate_config() {
    _phase_start "phase_validate_config"
    if ! validate_config "$CONFIG_PATH" "$SCHEMA_FILE"; then
        log_fail "config validation failed for $CONFIG_PATH" "validate_config"
        return 1
    fi
    log_ok "config valid"
}

phase_recommend() {
    _phase_start "phase_recommend"
    # The recommendation engine lives in the /scaffold-app Claude skill,
    # not in scaffold.sh. Standalone runs (config-file mode) already
    # know what they want — this phase is intentionally a no-op here.
    log_info "standalone mode — recommendation engine skipped (config supplied)"
}

phase_confirm() {
    _phase_start "phase_confirm"
    # Interactive confirmation lives in the /scaffold-app Claude skill;
    # standalone runs read a confirmed config. No-op here keeps the
    # orchestrator self-consistent.
    log_info "standalone mode — confirmation prompts handled by /scaffold-app skill"
}

phase_create_target_dir() {
    _phase_start "phase_create_target_dir"
    if [[ -z "$TARGET_DIR" ]]; then
        if (( DRY_RUN == 1 )); then
            TARGET_DIR=$(mktemp -d -t "scaffold-dryrun.XXXXXX")
            log_info "dry-run: using ephemeral target dir $TARGET_DIR"
        else
            TARGET_DIR="./${PROJECT_NAME_LOWER:-scaffold-out}"
        fi
    fi
    if [[ -d "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
        log_err "target directory '$TARGET_DIR' is not empty; v1 is greenfield-only"
        exit 2
    fi
    mkdir -p "$TARGET_DIR"
    log_ok "target dir ready: $TARGET_DIR"
}

phase_abp_new() {
    _phase_start "phase_abp_new"

    # ABP version resolution: ABP_VERSION env / --abp-version flag wins.
    # Otherwise autodetect from the locally-installed CLI. The resolved
    # value is exported so unit-10's post-init banner can record it in
    # the scaffolded CHANGELOG.md.
    if [[ -z "${ABP_VERSION:-}" ]]; then
        if ! command -v abp >/dev/null 2>&1; then
            log_fail "abp CLI not found; install with 'dotnet tool install -g Volo.Abp.Studio.Cli'" \
                "command -v abp"
            return 1
        fi
        ABP_VERSION="$(abp --version 2>/dev/null | head -1 | awk '{print $NF}')"
        if [[ -z "$ABP_VERSION" ]]; then
            log_fail "could not detect abp version" "abp --version"
            return 1
        fi
    fi
    export ABP_VERSION
    log_info "abp version: $ABP_VERSION"

    # Resolve the target dir. `abp new` writes its output into the dir
    # passed via --output-folder, so we use TARGET_DIR directly. The
    # operator-supplied TARGET_DIR is empty per phase_create_target_dir.
    # TARGET_PARENT_DIR is still exported for downstream units (overlay
    # logic in unit-03+ may want the parent for sibling-file work).
    local target_real
    target_real="$(realpath "$TARGET_DIR")"
    TARGET_PARENT_DIR="$(dirname "$target_real")"
    export TARGET_PARENT_DIR

    # Assemble flags. Bash array preserves quoting; we both exec it and
    # (under --dry-run-abp-new) echo it for tests.
    local -a flags=(
        "$PROJECT_NAME"
        "-t" "${ABP_TEMPLATE}"
        "--ui-framework" "${ABP_UI}"
        "--database-provider" "${ABP_DB_PROVIDER}"
        "--database-management-system" "${ABP_DBMS}"
        "--theme" "${ABP_THEME:-leptonx-lite}"
        "--version" "${ABP_VERSION}"
        "--skip-migration"
        "--skip-migrator"
        "--dont-run-install-libs"
        "--dont-run-bundling"
        "--without-cms-kit"
        "--no-social-logins"
        "-no-gdpr"
        "-no-openiddict-admin-ui"
        "-no-audit-logging"
    )
    # Multi-tenancy + separate-tenant-schema (only when ef + multi-tenancy).
    if [[ "${ABP_MULTI_TENANCY}" == "true" ]]; then
        if [[ "${ABP_DB_PROVIDER}" == "ef" ]]; then
            flags+=("--separate-tenant-schema")
        fi
    else
        flags+=("--no-multi-tenancy")
    fi
    # Tiered.
    if [[ "${ABP_TIERED}" == "true" ]]; then
        flags+=("--tiered")
    fi
    # Optional ABP modules: emit -no-<mod> for those NOT in the positive
    # list. Positive modules are re-added via `abp install-module` AFTER
    # `abp new` so the host module registers them.
    local mod
    for mod in file-management language-management text-template-management; do
        if [[ ",${ABP_OPTIONAL_MODULES}," != *",${mod},"* ]]; then
            flags+=("-no-${mod}")
        fi
    done
    # Mobile [FIXED] off for v1.
    flags+=("--mobile" "none")

    # --dry-run-abp-new short-circuit for bats tests: emit the assembled
    # flag array, one token per line, to stdout, then return success
    # WITHOUT invoking abp.
    if (( DRY_RUN_ABP_NEW == 1 )); then
        printf 'ABP_NEW_FLAG: %s\n' "${flags[@]}"
        log_ok "dry-run-abp-new: assembled ${#flags[@]} flag tokens"
        return 0
    fi

    # Top-level --dry-run (unit-01 contract) ALSO skips abp invocation.
    if (( DRY_RUN == 1 )); then
        log_info "dry-run: would run: abp new ${flags[*]} --output-folder ${target_real}"
        return 0
    fi

    # Real run. Capture combined stdout+stderr so we can both stream it
    # AND inspect for the [ERR] marker — abp new sometimes logs ERR but
    # exits 0 (e.g., "output folder is not empty"), so a process-exit
    # check alone is insufficient. We also verify the .sln/.slnx file
    # actually got written, which is the strongest success signal.
    local out_log
    out_log="$(mktemp -t scaffold-abp-new.XXXXXX.log)"
    local abp_exit=0
    abp new "${flags[@]}" --output-folder "${target_real}" \
        > >(tee "$out_log") 2>&1 || abp_exit=$?

    # Heuristic failure detection: process exit OR an [ERR] line OR no
    # .sln/.slnx produced. Any of these means rollback + log_fail.
    local sln_count
    sln_count=$(find "$target_real" -maxdepth 3 \( -name '*.sln' -o -name '*.slnx' \) 2>/dev/null | wc -l)
    if (( abp_exit != 0 )) || grep -q '\[ERR\]' "$out_log" || (( sln_count == 0 )); then
        local last_err
        last_err="$(grep -E '\[(ERR|FATAL)\]' "$out_log" | tail -n 1 | tr -d '\r')"
        if [[ -z "$last_err" ]]; then
            last_err="$(tail -n 1 "$out_log" | tr -d '\r')"
        fi
        rm -f "$out_log"
        # Rollback: nuke the partial target dir.
        rm -rf "$target_real"
        log_fail "[step abp new] failed: ${last_err:-<no stderr captured>}" \
            "abp new ${PROJECT_NAME}"
        return 1
    fi
    rm -f "$out_log"

    # Positive optional modules: re-add via `abp install-module` so the
    # host module registers them. `abp new` already succeeded; on
    # install-module failure we DO NOT roll back (the solution is valid,
    # just missing one optional module — operator can inspect + retry).
    if [[ -n "${ABP_OPTIONAL_MODULES}" ]]; then
        local positive_mod
        for positive_mod in ${ABP_OPTIONAL_MODULES//,/ }; do
            [[ -z "$positive_mod" ]] && continue
            log_info "abp install-module ${positive_mod}"
            if ! ( cd "${target_real}" && abp install-module "$positive_mod" ); then
                log_fail "abp install-module ${positive_mod} failed" \
                    "abp install-module"
                return 1
            fi
        done
    fi

    log_ok "abp new complete: ${target_real}"
}

phase_apply_overlays() {
    _phase_start "phase_apply_overlays"
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        log_warn "template/ dir missing — skipping overlays"
        return 0
    fi

    # Lazy-source the .NET overlay helpers. Unit-01 tests that only
    # exercise dry-run-abp-new don't need to pay the cost of sourcing.
    # shellcheck source=lib/dotnet-overlay.sh
    source "${LIB_DIR}/dotnet-overlay.sh"

    # Dry-run mode: no real target tree exists (or it's an ephemeral
    # tmpdir created by phase_create_target_dir). Enumerate what would
    # be written and stop — matches the unit-01 contract that --dry-run
    # is a no-op operationally.
    #
    # Also short-circuit on --dry-run-abp-new (the bats test-only flag):
    # in that mode phase_abp_new returned WITHOUT actually scaffolding a
    # tree, so the .markers files have no sibling files to merge into.
    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        local count=0
        while IFS= read -r -d '' f; do
            count=$((count + 1))
            log_info "[overlay-dotnet] dry-run candidate: ${f#"$TEMPLATE_DIR"/}"
        done < <(find "$TEMPLATE_DIR" -type f ! -name '.keep' -print0)
        log_info "[overlay-dotnet] overlay files discovered: $count"
        return 0
    fi

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    # 1. Copy every file under template/ to the target. For each file:
    #    a. Strip template/ prefix.
    #    b. Substitute {{PROJECTNAME}} -> $PROJECT_NAME in every segment.
    #    c. mkdir -p the destination parent.
    #    d. cp -p the file (preserves mode/mtime; binary-safe — text
    #       substitution skips binaries via the file --mime sniff).
    #    e. Log the destination so operators see what was touched.
    #
    # Two prefixes are intentionally skipped:
    #   - template/overlay-blocks/    — per-unit block-body fragments
    #     consumed by step 6 (block injection). Sourced directly from
    #     ${TEMPLATE_DIR}/overlay-blocks/<unit>/<block>.<ext>.frag.
    #     Never lands in the scaffolded tree (operators shouldn't ship it).
    local src dst rendered_rel rel
    local -a applied_files=()
    while IFS= read -r -d '' src; do
        rel="${src#"$TEMPLATE_DIR"/}"
        [[ "$rel" == ".keep" ]] && continue
        # Skip the overlay-blocks/ namespace — sourced directly by step 6.
        [[ "$rel" == overlay-blocks/* ]] && continue
        rendered_rel="${rel//\{\{PROJECTNAME\}\}/${PROJECT_NAME}}"
        dst="${target_real}/${rendered_rel}"
        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
        applied_files+=("$dst")
        log_info "[overlay-dotnet] writing ${rendered_rel}"
    done < <(find "$TEMPLATE_DIR" -type f -print0)

    # 2. Substitute content. Per-suffix dispatch:
    #    - *.markers -> deferred to step 3.
    #    - *.tmpl    -> substitute_tmpl (drops .tmpl on success).
    #    - *.template -> deploy-time envsubst targets; NO scaffold-time
    #                    substitution (preserves ${DEPLOY_TIME_VAR}
    #                    markers verbatim). The file is left in place
    #                    with the .template suffix so deploy tooling
    #                    (entrypoint scripts) can envsubst against it.
    #    - *.frag    -> overlay-block content fragments; consumed by
    #                    block injection in step 6 and not part of the
    #                    scaffolded tree (skip here).
    #    - else      -> substitute_file (no-op on binaries).
    local f
    for f in "${applied_files[@]}"; do
        case "$f" in
            *.markers)  continue ;;
            *.template) continue ;;
            *.frag)     continue ;;
            *.tmpl)     substitute_tmpl "$f" || return 1 ;;
            *)          substitute_file "$f" || return 1 ;;
        esac
    done

    # 3. Marker-file merge: for each *.markers file under target_real,
    #    locate its sibling file (sans .markers) and inject the empty
    #    ScaffoldBlock pairs at the documented anchors. Then delete
    #    the .markers file (it has served its purpose).
    local markers existing
    while IFS= read -r -d '' markers; do
        existing="${markers%.markers}"
        if [[ ! -f "$existing" ]]; then
            log_fail "[overlay-dotnet] marker target missing: $existing" \
                "merge_markers_into_existing"
            return 1
        fi
        merge_markers_into_existing "$existing" "$markers" || return 1
        rm -f "$markers"
        log_info "[overlay-dotnet] merged ScaffoldBlock markers into ${existing#"$target_real"/}"
    done < <(find "$target_real" -type f -name '*.markers' -print0)

    # 4. RootNamespace injection on every csproj under src/ + test/.
    #    Idempotent — running on a csproj that already carries the
    #    correct value is a no-op (and on one missing it inserts).
    local csproj
    while IFS= read -r -d '' csproj; do
        dotnet_overlay_set_root_namespace "$csproj" "${PROJECT_NAME}" || return 1
        log_info "[overlay-dotnet] RootNamespace -> ${csproj#"$target_real"/}"
    done < <(find "${target_real}/src" "${target_real}/test" -type f -name '*.csproj' -print0 2>/dev/null)

    # 5. Mapperly swap on the Application csproj + DependsOn on the
    #    application module. Both idempotent — unit-11's order-
    #    independence smoke test depends on re-runs being byte-identical.
    local app_csproj="${target_real}/src/${PROJECT_NAME}.Application/${PROJECT_NAME}.Application.csproj"
    local app_module="${target_real}/src/${PROJECT_NAME}.Application/${PROJECT_NAME}ApplicationModule.cs"
    if [[ -f "$app_csproj" ]]; then
        dotnet_overlay_swap_automapper_for_mapperly "$app_csproj" || return 1
        log_info "[overlay-dotnet] AutoMapper -> Mapperly on ${app_csproj#"$target_real"/}"
    fi
    if [[ -f "$app_module" ]]; then
        dotnet_overlay_add_dependson_attribute "$app_module" \
            "AbpMapperlyModule" "using Volo.Abp.Mapperly;" || return 1
        log_info "[overlay-dotnet] DependsOn(AbpMapperlyModule) -> ${app_module#"$target_real"/}"
    fi

    # 6. Block-body injection — splice content fragments into the empty
    #    ScaffoldBlock marker pairs that step 3 created. Per-unit
    #    fragments live under template/overlay-blocks/unit-NN/ with the
    #    naming convention <block-name>.<target-suffix>.frag. The
    #    target file is recovered from the suffix + a special-case for
    #    serilog-bootstrap (which lives in Program.cs, not the host
    #    module). The fragments themselves are NEVER copied to the
    #    scaffolded tree (step 1 skips template/overlay-blocks/).
    local host_module_path="${target_real}/src/${PROJECT_NAME}.HttpApi.Host/${PROJECT_NAME}HttpApiHostModule.cs"
    local program_cs_path="${target_real}/src/${PROJECT_NAME}.HttpApi.Host/Program.cs"
    local appsettings_path="${target_real}/src/${PROJECT_NAME}.HttpApi.Host/appsettings.json"
    local block_name target_file frag_ext frag_base
    local rendered_tmp
    if [[ -d "${TEMPLATE_DIR}/overlay-blocks" ]]; then
        local frag
        while IFS= read -r -d '' frag; do
            frag_base="${frag##*/}"               # otel.cs.frag
            block_name="${frag_base%.*.frag}"     # otel
            frag_ext="${frag_base%.frag}"
            frag_ext="${frag_ext##*.}"            # cs
            case "$frag_ext" in
                cs)
                    target_file="$host_module_path"
                    # serilog-bootstrap lives in Program.cs.
                    [[ "$block_name" == serilog-bootstrap ]] && target_file="$program_cs_path"
                    ;;
                json)
                    target_file="$appsettings_path"
                    ;;
                *)
                    log_fail "[overlay-dotnet] unknown frag ext: $frag" "block-inject"
                    return 1
                    ;;
            esac
            if [[ ! -f "$target_file" ]]; then
                log_info "[overlay-dotnet] skip block '${block_name}' — target missing: ${target_file#"$target_real"/}"
                continue
            fi
            # Render the fragment through envsubst so ${PROJECT_NAME} /
            # ${PROJECT_NAME_LOWER} expand to the operator's project.
            rendered_tmp="$(mktemp -t scaffold-frag.XXXXXX)"
            cp -p "$frag" "$rendered_tmp"
            substitute_file "$rendered_tmp" || {
                rm -f "$rendered_tmp"
                return 1
            }
            scaffold_insert_block "$target_file" "$block_name" "$rendered_tmp" || {
                rm -f "$rendered_tmp"
                return 1
            }
            rm -f "$rendered_tmp"
            log_info "[overlay-dotnet] injected block '${block_name}' -> ${target_file#"$target_real"/}"
        done < <(find "${TEMPLATE_DIR}/overlay-blocks" -type f -name '*.frag' -print0)
    fi

    # 7. unit-04 — ensure host-module usings for the OTel + health-checks
    #    blocks (the splice itself only writes block bodies; using-lines
    #    must be added separately). Idempotent.
    if [[ -f "$host_module_path" ]]; then
        local using_line
        for using_line in \
            "using ${PROJECT_NAME}.HealthChecks;" \
            "using OpenTelemetry;" \
            "using OpenTelemetry.Metrics;" \
            "using OpenTelemetry.Resources;" \
            "using OpenTelemetry.Trace;"
        do
            _ensure_using_line "$host_module_path" "$using_line" || return 1
        done
        log_info "[overlay-dotnet] OTel + HealthChecks using-lines ensured on host module"
    fi

    # 8. unit-04 — observability NuGet packages on the HttpApi.Host
    #    csproj. Versions match LinkHub's current pins
    #    (src/LinkHub.HttpApi.Host/LinkHub.HttpApi.Host.csproj as of
    #    2026-05). Idempotent — re-adds are a no-op via
    #    dotnet_overlay_add_package_reference's fast-path.
    local host_csproj="${target_real}/src/${PROJECT_NAME}.HttpApi.Host/${PROJECT_NAME}.HttpApi.Host.csproj"
    if [[ -f "$host_csproj" ]]; then
        # Format: "<package-id>:<version>"
        local pkg_spec
        for pkg_spec in \
            "OpenTelemetry.Extensions.Hosting:1.15.3" \
            "OpenTelemetry.Instrumentation.AspNetCore:1.15.2" \
            "OpenTelemetry.Instrumentation.Http:1.15.1" \
            "OpenTelemetry.Instrumentation.EntityFrameworkCore:1.11.0-beta.2" \
            "OpenTelemetry.Exporter.OpenTelemetryProtocol:1.15.3" \
            "OpenTelemetry.Exporter.Prometheus.AspNetCore:1.11.2-beta.1" \
            "Serilog.AspNetCore:9.0.0" \
            "Serilog.Enrichers.Span:3.1.0" \
            "Serilog.Sinks.Async:2.1.0"
        do
            local pkg_id="${pkg_spec%%:*}"
            local pkg_ver="${pkg_spec#*:}"
            dotnet_overlay_add_package_reference "$host_csproj" "$pkg_id" "$pkg_ver" || return 1
        done
        log_info "[overlay-dotnet] observability NuGet packages ensured on HttpApi.Host csproj"
    fi

    log_ok "overlay-dotnet applied"
}

phase_apply_security_overlay() {
    _phase_start "phase_apply_security_overlay"

    # Dry-run short-circuit — phase_apply_overlays produced no target tree
    # under --dry-run / --dry-run-abp-new.
    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        log_info "[overlay-security] dry-run: skipping security overlay (no rendered tree)"
        return 0
    fi

    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[overlay-security] TARGET_DIR not set or missing; skipping"
        return 0
    fi

    # shellcheck source=lib/security-overlay.sh
    source "${LIB_DIR}/security-overlay.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    security_overlay_insert_blocks "$target_real" || return 1
    security_overlay_render_staging_secrets "$target_real" || return 1
    security_overlay_install_cert_script "$target_real" || return 1
    security_overlay_merge_dbmigrator_markers "$target_real" || return 1
    security_overlay_append_gitignore "${target_real}/.gitignore" || return 1

    log_ok "overlay-security applied"
}

phase_apply_docker_overlay() {
    _phase_start "phase_apply_docker_overlay"

    # Dry-run short-circuit — phase_apply_overlays produced no target tree
    # under --dry-run / --dry-run-abp-new.
    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        log_info "[overlay-docker] dry-run: skipping docker overlay (no rendered tree)"
        return 0
    fi

    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[overlay-docker] TARGET_DIR not set or missing; skipping"
        return 0
    fi

    # shellcheck source=lib/docker-overlay.sh disable=SC1091
    source "${LIB_DIR}/docker-overlay.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    docker_overlay_render_templated_files "$target_real" || return 1
    docker_overlay_install_dockerfile_perms "$target_real" || return 1
    docker_overlay_splice_nginx_conf "$target_real" || return 1
    docker_overlay_prune_ui_none "$target_real" || return 1

    log_ok "overlay-docker applied"
}

phase_apply_terraform_overlay() {
    _phase_start "phase_apply_terraform_overlay"

    # Dry-run short-circuit — phase_apply_overlays produced no target tree
    # under --dry-run / --dry-run-abp-new.
    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        log_info "[overlay-terraform] dry-run: skipping terraform overlay (no rendered tree)"
        return 0
    fi

    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[overlay-terraform] TARGET_DIR not set or missing; skipping"
        return 0
    fi

    # shellcheck source=lib/terraform-overlay.sh disable=SC1091
    source "${LIB_DIR}/terraform-overlay.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    terraform_overlay_render_templated_files "$target_real" || return 1
    terraform_overlay_install_script_perms "$target_real" || return 1
    terraform_overlay_splice_gitignore "$target_real" || return 1

    log_ok "overlay-terraform applied"
}

phase_apply_github_workflows_overlay() {
    _phase_start "phase_apply_github_workflows_overlay"

    # Dry-run short-circuit — phase_apply_overlays produced no target tree
    # under --dry-run / --dry-run-abp-new.
    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        log_info "[overlay-github-workflows] dry-run: skipping github-workflows overlay (no rendered tree)"
        return 0
    fi

    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[overlay-github-workflows] TARGET_DIR not set or missing; skipping"
        return 0
    fi

    # shellcheck source=lib/github-workflows-overlay.sh disable=SC1091
    source "${LIB_DIR}/github-workflows-overlay.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    github_workflows_overlay_render_templated_files "$target_real" || return 1

    log_ok "overlay-github-workflows applied"
}

phase_run_post_init_commands() {
    _phase_start "phase_run_post_init_commands"

    # Dry-run / --skip-post-init short-circuit. phase_apply_overlays
    # produced no real tree under --dry-run / --dry-run-abp-new — there
    # is nothing meaningful to dotnet-build against.
    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )) \
        || (( SKIP_POST_INIT == 1 )); then
        log_info "[post-init] dry-run / --skip-post-init: skipping"
        return 0
    fi

    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[post-init] TARGET_DIR missing; skipping"
        return 0
    fi

    # shellcheck source=lib/post-init.sh disable=SC1091
    source "${LIB_DIR}/post-init.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    post_init_run_ef_migration       "$target_real" || return 1
    post_init_install_libs           "$target_real" || return 1
    post_init_smoke_dotnet_build     "$target_real" || return 1

    log_ok "post-init commands complete"
}

phase_github_repo_init() {
    _phase_start "phase_github_repo_init"

    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        log_info "[github-init] dry-run: skipping"
        return 0
    fi
    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[github-init] TARGET_DIR missing; skipping"
        return 0
    fi

    # shellcheck source=lib/github-init.sh disable=SC1091
    source "${LIB_DIR}/github-init.sh"
    # shellcheck source=lib/handoff.sh disable=SC1091
    source "${LIB_DIR}/handoff.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    # Pre-commit safety: a known-dangerous file inside the target must
    # NOT be staged by `git add -A`. Fail loudly if the .gitignore would
    # let one through.
    handoff_assert_safe_to_commit "$target_real" || return 1

    github_init_git_repo "$target_real" || return 1

    if [[ "${SKIP_GH_CREATE:-false}" == "true" ]]; then
        log_info "[github-init] --skip-gh-create: skipping gh repo create + push + branch protection"
        return 0
    fi

    # gh auth precondition. phase_preflight verifies the gh BINARY;
    # here we verify the auth is wired. Hard fail before touching any
    # GitHub state. Bypass when --dry-run-github (tests can't be
    # expected to be `gh auth login`'d).
    if (( DRY_RUN_GITHUB == 0 )); then
        if ! gh auth status >/dev/null 2>&1; then
            log_fail "[github-init] gh CLI not authenticated; run 'gh auth login' first" \
                "gh auth status"
            return 1
        fi
    fi

    github_init_create_remote        "$target_real" || return 1
    github_init_branch_protection    "$target_real" || true   # soft-fail
    github_init_check_workflow_perms "$target_real" || true   # report-only

    log_ok "github-init complete"
}

phase_handoff() {
    _phase_start "phase_handoff"

    if (( DRY_RUN == 1 )) || (( DRY_RUN_ABP_NEW == 1 )); then
        log_info "[handoff] dry-run: skipping"
        return 0
    fi
    if [[ -z "${TARGET_DIR:-}" || ! -d "$TARGET_DIR" ]]; then
        log_warn "[handoff] TARGET_DIR missing; skipping"
        return 0
    fi

    # shellcheck source=lib/handoff.sh disable=SC1091
    source "${LIB_DIR}/handoff.sh"

    local target_real
    target_real="$(realpath "$TARGET_DIR")"

    handoff_render_message "$target_real" || return 1
    log_ok "operator handoff written to ${target_real}/SCAFFOLD-HANDOFF.md"
}

# --- main -----------------------------------------------------------------

main() {
    phase_preflight
    phase_load_or_prompt_config
    phase_validate_config
    phase_recommend
    phase_confirm
    phase_create_target_dir
    phase_abp_new
    phase_apply_overlays
    phase_apply_security_overlay
    phase_apply_docker_overlay
    phase_apply_terraform_overlay
    phase_apply_github_workflows_overlay
    phase_run_post_init_commands
    phase_github_repo_init
    phase_handoff
    if (( DRY_RUN == 1 )); then
        log_ok "dry-run complete (no app was scaffolded)"
    fi
}

main
