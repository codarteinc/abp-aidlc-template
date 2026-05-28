#!/usr/bin/env bash
# lib/validate-config.sh — validates a scaffold config against
# `scaffold-config-schema.yml`.
#
# Two entry points:
#   - Executable:    `./lib/validate-config.sh <config.yml>`
#                    `./lib/validate-config.sh --describe`
#   - Sourced lib:   `source lib/validate-config.sh` then call
#                    `validate_config <config.yml>` or `describe_schema`.
#
# Validation rules per schema leaf:
#   - `type` must match the YAML node kind (string / bool / int / array /
#     object).
#   - `required: true` and a null/empty value -> MISSING_REQUIRED error.
#   - `enum: [...]` and the value isn't a member -> ENUM_VIOLATION error.
#   - `regex: '...'` and the value doesn't match -> REGEX_VIOLATION error.
#   - `type: array` + `item_enum: [...]` -> each item must be in the enum.
#   - `default_from: <other.path>` fields fall back to that field's value
#     when unset (no error).
#   - Unset fields with a `default` literal default-value are NOT errors.
#
# Exits 0 if zero errors. Exits 1 on any error. Warnings (if added later)
# don't affect exit code.
#
# Error format (one per line, machine-parseable):
#   ERROR: <field.path>: <REASON_CODE> <human-readable detail>

if [[ -n "${__LH_VALIDATE_CONFIG_SH_SOURCED:-}" ]]; then
    : # allow re-source
else
    __LH_VALIDATE_CONFIG_SH_SOURCED=1
fi

# Resolve our own dir so we can locate the schema file regardless of cwd.
__LH_VALIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__LH_VALIDATE_SCHEMA_DEFAULT="$(cd "$__LH_VALIDATE_DIR/.." && pwd)/scaffold-config-schema.yml"

# Pull in log helpers when run as a script (not strictly needed sourced).
if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh
    source "$__LH_VALIDATE_DIR/log.sh"
fi

# Walk the schema and emit `dot.path:meta` lines for every leaf field.
# A "leaf" is any node that has a `type` key. Objects with a `fields:` map
# recurse; nothing else recurses.
__lh_schema_leaves() {
    local schema="$1"
    # Top-level keys
    local key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        __lh_schema_walk "$schema" "$key" "$key"
    done < <(yq 'keys | .[]' "$schema")
}

__lh_schema_walk() {
    local schema="$1"
    local node_path="$2"   # path within the schema YAML, e.g. abp.fields.ui
    local dotted_path="$3" # path the operator sees, e.g. abp.ui
    local node_type
    node_type=$(yq ".${node_path}.type // \"\"" "$schema")
    if [[ -z "$node_type" || "$node_type" == "null" ]]; then
        return 0
    fi
    if [[ "$node_type" == "object" ]]; then
        # Recurse into fields.
        local has_fields
        has_fields=$(yq ".${node_path}.fields | type" "$schema")
        if [[ "$has_fields" == "!!map" ]]; then
            local child
            while IFS= read -r child; do
                [[ -z "$child" ]] && continue
                __lh_schema_walk "$schema" "${node_path}.fields.${child}" "${dotted_path}.${child}"
            done < <(yq ".${node_path}.fields | keys | .[]" "$schema")
        fi
        return 0
    fi
    # Leaf — emit a record. Format: <dotted_path>|<schema_path>|<type>
    printf '%s|%s|%s\n' "$dotted_path" "$node_path" "$node_type"
}

# Read a value from the config at a dotted path. Returns the empty
# string when the field is absent / null.
__lh_config_get() {
    local config="$1"
    local dotted="$2"
    local v
    v=$(yq ".${dotted}" "$config" 2>/dev/null || printf 'null')
    if [[ "$v" == "null" ]]; then
        printf ''
    else
        printf '%s' "$v"
    fi
}

# What kind of node yq reports for the leaf in the config? `!!str`,
# `!!bool`, `!!int`, `!!seq`, `!!map`, `!!null`, or empty if missing.
__lh_config_kind() {
    local config="$1"
    local dotted="$2"
    yq ".${dotted} | tag" "$config" 2>/dev/null
}

# Pretty-print the schema for `--describe` / scaffold.sh --help.
describe_schema() {
    local schema="${1:-$__LH_VALIDATE_SCHEMA_DEFAULT}"
    if [[ ! -f "$schema" ]]; then
        echo "schema not found: $schema" >&2
        return 1
    fi
    echo "Scaffold config schema (source: ${schema}):"
    echo
    local dotted schema_path stype
    while IFS='|' read -r dotted schema_path stype; do
        local required enum regex default default_from item_enum desc
        required=$(yq ".${schema_path}.required // false" "$schema")
        enum=$(yq ".${schema_path}.enum // [] | join(\",\")" "$schema")
        regex=$(yq ".${schema_path}.regex // \"\"" "$schema")
        default=$(yq ".${schema_path}.default // \"\"" "$schema")
        default_from=$(yq ".${schema_path}.default_from // \"\"" "$schema")
        item_enum=$(yq ".${schema_path}.item_enum // [] | join(\",\")" "$schema")
        desc=$(yq ".${schema_path}.description // \"\"" "$schema")
        printf '  %-32s type=%s required=%s' "$dotted" "$stype" "$required"
        [[ -n "$enum" && "$enum" != "null" ]] && printf ' enum=[%s]' "$enum"
        [[ -n "$item_enum" && "$item_enum" != "null" ]] && printf ' item_enum=[%s]' "$item_enum"
        [[ -n "$regex" && "$regex" != "null" ]] && printf ' regex=%s' "$regex"
        [[ -n "$default" && "$default" != "null" ]] && printf ' default=%s' "$default"
        [[ -n "$default_from" && "$default_from" != "null" ]] && printf ' default_from=%s' "$default_from"
        printf '\n'
        [[ -n "$desc" && "$desc" != "null" ]] && printf '    %s\n' "$desc"
    done < <(__lh_schema_leaves "$schema")
}

# validate_config <config> [<schema>]
# Exits 0 if no errors, 1 otherwise.
validate_config() {
    local config="$1"
    local schema="${2:-$__LH_VALIDATE_SCHEMA_DEFAULT}"
    if [[ ! -f "$config" ]]; then
        printf 'ERROR: <config>: FILE_NOT_FOUND %s\n' "$config" >&2
        printf 'validate-config: 1 error(s), 0 warning(s)\n' >&2
        return 1
    fi
    if [[ ! -f "$schema" ]]; then
        printf 'ERROR: <schema>: FILE_NOT_FOUND %s\n' "$schema" >&2
        printf 'validate-config: 1 error(s), 0 warning(s)\n' >&2
        return 1
    fi
    # YAML well-formedness check up-front so we don't emit confusing
    # field-level errors on a broken file.
    if ! yq 'true' "$config" >/dev/null 2>&1; then
        printf 'ERROR: <config>: PARSE_ERROR not valid YAML: %s\n' "$config" >&2
        printf 'validate-config: 1 error(s), 0 warning(s)\n' >&2
        return 1
    fi

    local errors=0
    local warnings=0
    local dotted schema_path stype
    while IFS='|' read -r dotted schema_path stype; do
        local required enum regex default_from item_enum
        required=$(yq ".${schema_path}.required // false" "$schema")
        enum=$(yq ".${schema_path}.enum // [] | join(\",\")" "$schema")
        regex=$(yq ".${schema_path}.regex // \"\"" "$schema")
        default_from=$(yq ".${schema_path}.default_from // \"\"" "$schema")
        item_enum=$(yq ".${schema_path}.item_enum // [] | join(\",\")" "$schema")

        local value
        value=$(__lh_config_get "$config" "$dotted")
        local kind
        kind=$(__lh_config_kind "$config" "$dotted")

        # Missing-required check (default_from satisfies required even when unset).
        if [[ -z "$value" || "$kind" == "!!null" ]]; then
            if [[ "$required" == "true" && ( -z "$default_from" || "$default_from" == "null" ) ]]; then
                printf 'ERROR: %s: MISSING_REQUIRED field is required\n' "$dotted" >&2
                errors=$((errors + 1))
            fi
            # Unset optional fields don't need further checks.
            continue
        fi

        # Type check.
        case "$stype" in
            string)
                if [[ "$kind" != "!!str" ]]; then
                    printf 'ERROR: %s: TYPE_MISMATCH expected string, got %s\n' "$dotted" "$kind" >&2
                    errors=$((errors + 1))
                    continue
                fi
                ;;
            bool)
                if [[ "$kind" != "!!bool" ]]; then
                    printf 'ERROR: %s: TYPE_MISMATCH expected bool, got %s\n' "$dotted" "$kind" >&2
                    errors=$((errors + 1))
                    continue
                fi
                ;;
            int)
                if [[ "$kind" != "!!int" ]]; then
                    printf 'ERROR: %s: TYPE_MISMATCH expected int, got %s\n' "$dotted" "$kind" >&2
                    errors=$((errors + 1))
                    continue
                fi
                ;;
            array)
                if [[ "$kind" != "!!seq" ]]; then
                    printf 'ERROR: %s: TYPE_MISMATCH expected array, got %s\n' "$dotted" "$kind" >&2
                    errors=$((errors + 1))
                    continue
                fi
                ;;
            *)
                printf 'ERROR: %s: SCHEMA_BUG unknown type %s in schema\n' "$dotted" "$stype" >&2
                errors=$((errors + 1))
                continue
                ;;
        esac

        # Enum check (strings only).
        if [[ -n "$enum" && "$enum" != "null" && "$stype" == "string" ]]; then
            local IFS=','
            local allowed=()
            read -r -a allowed <<< "$enum"
            local match=0
            for opt in "${allowed[@]}"; do
                if [[ "$value" == "$opt" ]]; then
                    match=1
                    break
                fi
            done
            unset IFS
            if (( match == 0 )); then
                printf "ERROR: %s: ENUM_VIOLATION value '%s' not in [%s]\n" "$dotted" "$value" "$enum" >&2
                errors=$((errors + 1))
                continue
            fi
        fi

        # Regex check (strings only).
        if [[ -n "$regex" && "$regex" != "null" && "$stype" == "string" ]]; then
            if ! [[ "$value" =~ $regex ]]; then
                printf "ERROR: %s: REGEX_VIOLATION value '%s' does not match %s\n" "$dotted" "$value" "$regex" >&2
                errors=$((errors + 1))
                continue
            fi
        fi

        # item_enum (array element membership).
        if [[ "$stype" == "array" && -n "$item_enum" && "$item_enum" != "null" ]]; then
            local count
            count=$(yq ".${dotted} | length" "$config")
            if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
                local idx
                for (( idx = 0; idx < count; idx++ )); do
                    local item
                    item=$(yq ".${dotted}[${idx}]" "$config")
                    local IFS=','
                    local allowed=()
                    read -r -a allowed <<< "$item_enum"
                    local match=0
                    for opt in "${allowed[@]}"; do
                        if [[ "$item" == "$opt" ]]; then
                            match=1
                            break
                        fi
                    done
                    unset IFS
                    if (( match == 0 )); then
                        printf "ERROR: %s[%d]: ENUM_VIOLATION value '%s' not in [%s]\n" \
                            "$dotted" "$idx" "$item" "$item_enum" >&2
                        errors=$((errors + 1))
                    fi
                done
            fi
        fi
    done < <(__lh_schema_leaves "$schema")

    printf 'validate-config: %d error(s), %d warning(s)\n' "$errors" "$warnings" >&2
    if (( errors > 0 )); then
        return 1
    fi
    return 0
}

# When executed directly (not sourced), expose a simple CLI.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    case "${1:-}" in
        --describe|-d)
            describe_schema "${2:-$__LH_VALIDATE_SCHEMA_DEFAULT}"
            ;;
        --help|-h|"")
            cat <<EOF
Usage: validate-config.sh <config.yml>
       validate-config.sh --describe [<schema.yml>]

Validates a scaffold config against scaffold-config-schema.yml.
Exit 0 on success, 1 on any validation error.
EOF
            ;;
        *)
            validate_config "$1" "${2:-$__LH_VALIDATE_SCHEMA_DEFAULT}"
            ;;
    esac
fi
