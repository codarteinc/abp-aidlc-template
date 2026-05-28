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
STEP_TOTAL=11
STEP=0
CURRENT_PHASE=""

# --- flag parsing ---------------------------------------------------------

CONFIG_PATH=""
TARGET_DIR=""
DRY_RUN=0

print_help() {
    cat <<EOF
scaffold.sh — one-command ABP scaffold with LinkHub-grade infra/CI/devops baked in.

USAGE:
  scaffold.sh [--config <path>] [--target <dir>] [--dry-run]
  scaffold.sh --help

FLAGS:
  --config <path>   Path to a scaffold config YAML (skips interactive prompts).
  --target <dir>    Target directory for the scaffolded project.
                    Defaults to ./<project_name_lower> once config is loaded.
  --dry-run         Run every phase as a no-op and exit 0. Useful for smoke
                    tests of the orchestration pipeline.
  --help, -h        Show this banner.

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
    HETZNER_SERVER_TYPE=$(yq '.infra.hetzner_server_type // "cx22"' "$cfg")
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
        use_defaults=$(prompt_yesno "Use defaults for everything else (UI=angular, db=ef/postgresql, infra=hel1/cx22)?" y)
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
            printf '  hetzner_server_type: cx22\n'
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
    _phase_start "phase_recommend (stub — unit-02)"
    log_info "recommendation engine populates here in unit-02"
}

phase_confirm() {
    _phase_start "phase_confirm (stub — unit-02)"
    log_info "operator confirmation prompt populates here in unit-02"
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
    _phase_start "phase_abp_new (stub — unit-02)"
    log_info "abp new invocation populates here in unit-02"
}

phase_apply_overlays() {
    _phase_start "phase_apply_overlays"
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        log_warn "template/ dir missing — skipping overlays"
        return 0
    fi
    # Iterate every file under template/ (placeholder loop — units 03-10
    # drop real overlay files here and this iterator handles them
    # unchanged). NOTE: we don't actually copy + substitute in unit-01
    # because the target tree from `abp new` doesn't exist yet; we
    # only enumerate so operators see what would happen.
    local count=0
    while IFS= read -r -d '' f; do
        count=$((count + 1))
        log_info "overlay candidate: ${f#"$TEMPLATE_DIR"/}"
    done < <(find "$TEMPLATE_DIR" -type f ! -name '.keep' -print0)
    log_info "overlay files discovered: $count"
}

phase_run_post_init_commands() {
    _phase_start "phase_run_post_init_commands (stub — unit-10)"
    log_info "post-init commands populate here in unit-10"
}

phase_github_repo_init() {
    _phase_start "phase_github_repo_init (stub — unit-10)"
    log_info "github repo init populates here in unit-10"
}

phase_handoff() {
    _phase_start "phase_handoff (stub — unit-10)"
    log_info "scaffold complete — see operator handoff in unit-10"
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
    phase_run_post_init_commands
    phase_github_repo_init
    phase_handoff
    if (( DRY_RUN == 1 )); then
        log_ok "dry-run complete (no app was scaffolded)"
    fi
}

main
