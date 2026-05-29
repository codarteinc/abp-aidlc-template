# tests/_helper.bash — shared bats helper sourced via `load _helper`.
#
# Provides `run_scaffold_dry_abp_new` which builds an isolated tmpdir,
# writes a parameterized config from key=value pairs, runs scaffold.sh
# with --dry-run-abp-new, and emits the captured ABP_NEW_FLAG lines on
# stdout for the caller to assert against.
#
# Defaults match the LinkHub baseline. Override any field via
# `run_scaffold_dry_abp_new key=value [key=value ...]`. Valid keys:
#   project_name, github_owner, abp_template, abp_ui, abp_db_provider,
#   abp_dbms, abp_tiered, abp_multi_tenancy, abp_default_culture,
#   abp_optional_modules, cloudflare_zone.

# shellcheck disable=SC2034  # used by tests sourcing this helper.
SCAFFOLD_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

run_scaffold_dry_abp_new() {
    local tmpdir
    tmpdir="$(mktemp -d -t scaffold-bats.XXXXXX)"
    declare -A cfg=(
        [project_name]=SmokeApp
        [github_owner]=codarteinc
        [abp_template]=app
        [abp_ui]=angular
        [abp_db_provider]=ef
        [abp_dbms]=postgresql
        [abp_tiered]=false
        [abp_multi_tenancy]=false
        [abp_default_culture]=en
        [abp_optional_modules]='[]'
        [cloudflare_zone]=example.com
    )
    while [[ $# -gt 0 ]]; do
        local kv="$1"
        cfg["${kv%%=*}"]="${kv#*=}"
        shift
    done
    cat > "${tmpdir}/c.yml" <<EOF
project_name: ${cfg[project_name]}
github_owner: ${cfg[github_owner]}
abp:
  template: ${cfg[abp_template]}
  ui: ${cfg[abp_ui]}
  db_provider: ${cfg[abp_db_provider]}
  dbms: ${cfg[abp_dbms]}
  tiered: ${cfg[abp_tiered]}
  multi_tenancy: ${cfg[abp_multi_tenancy]}
  default_culture: ${cfg[abp_default_culture]}
  optional_modules: ${cfg[abp_optional_modules]}
infra:
  hetzner_location: hel1
  hetzner_server_type: cx22
  cloudflare_zone: ${cfg[cloudflare_zone]}
EOF
    bash "${SCAFFOLD_ROOT}/scaffold.sh" \
        --config "${tmpdir}/c.yml" \
        --target "${tmpdir}/${cfg[project_name]}" \
        --dry-run-abp-new 2>&1
    rm -rf "$tmpdir"
}
