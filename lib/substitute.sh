#!/usr/bin/env bash
# lib/substitute.sh — substitution engine for overlay files.
#
# Exports:
#   substitute_file <path>   - runs `envsubst` over a single text file in-place
#                              using an explicit allowlist. Binary files are
#                              skipped via `file --mime` sniff.
#   substitute_tmpl <path>   - for `.tmpl`-suffixed files. Two-pass:
#                              (1) envsubst with the same allowlist, then
#                              (2) `awk` strips `{{#if <flag>}}...{{/if}}`
#                              blocks based on `IF_<FLAG>` env vars.
#                              Strips the `.tmpl` suffix on output.
#
# Conventions:
#   - Always operate on files in-place.
#   - After substitution, any leftover `${[A-Z_]+}` token is a missing-var
#     bug — we fail loudly rather than ship an empty hole. (envsubst silently
#     substitutes the empty string for unset vars, which is a trap.)
#   - The allowlist below MUST stay in sync with the env-var exports
#     emitted by `phase_load_or_prompt_config` in scaffold.sh. Drift is
#     caught by `scripts/check-token-coverage.sh`.

if [[ -n "${__LH_SUBSTITUTE_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_SUBSTITUTE_SH_SOURCED=1

# Pull in log helpers if the caller hasn't already.
if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Single authoritative allowlist. Add new vars here AND export them from
# scaffold.sh's `phase_load_or_prompt_config`. The token-coverage CI check
# (scripts/check-token-coverage.sh) detects drift.
# shellcheck disable=SC2016  # literal ${VAR} names — envsubst expands at runtime.
__LH_SUBSTITUTE_ALLOWLIST='${PROJECT_NAME} ${PROJECT_NAME_LOWER} ${PROJECTNAME_UPPER} ${GITHUB_OWNER} ${HCP_ORG} ${DBMS} ${UI} ${DB_PROVIDER} ${DEFAULT_CULTURE} ${MULTI_TENANCY} ${TIERED} ${HETZNER_LOCATION} ${HETZNER_SERVER_TYPE} ${CLOUDFLARE_ZONE}'

# Returns 0 if the file looks like text we can substitute over, non-zero
# for binaries (PFX, PNG, etc.) that envsubst would corrupt.
_substitute_is_text() {
    local f="$1"
    # `file --mime` prints e.g. `foo.txt: text/plain; charset=utf-8` —
    # we accept us-ascii / utf-8 / iso-8859-* charsets. Binary files
    # report `charset=binary` and are skipped.
    file --mime "$f" 2>/dev/null | grep -qE 'charset=(us-ascii|utf-8|iso-8859-[0-9]+)'
}

# Fail loudly if any unresolved ${VAR} tokens remain in the file.
_substitute_check_unresolved() {
    local f="$1"
    local helper="$2"
    if grep -qE '\$\{[A-Z_]+\}' "$f"; then
        local leftover
        leftover=$(grep -oE '\$\{[A-Z_]+\}' "$f" | sort -u | tr '\n' ' ')
        log_fail "$helper: unresolved tokens in $f: $leftover" "envsubst on $f"
        return 1
    fi
    return 0
}

# substitute_file <path>
substitute_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        log_fail "substitute_file: not a regular file: $f" "substitute_file $f"
        return 1
    fi
    if ! _substitute_is_text "$f"; then
        log_info "skip binary (no substitution): $f"
        return 0
    fi
    local tmp="${f}.subst.tmp"
    if ! envsubst "$__LH_SUBSTITUTE_ALLOWLIST" < "$f" > "$tmp"; then
        rm -f "$tmp"
        log_fail "substitute_file: envsubst failed for $f" "envsubst < $f"
        return 1
    fi
    mv "$tmp" "$f"
    _substitute_check_unresolved "$f" "substitute_file" || return 1
}

# substitute_tmpl <path>
# `.tmpl` files use `{{#if <flag>}}...{{/if}}` blocks in addition to
# ${VAR} substitution. The orchestrator sets `IF_<FLAG>=1` for each
# enabled flag (e.g. IF_UI_ANGULAR=1) before invoking this helper.
# Output is written to the same path minus the `.tmpl` suffix and the
# original `.tmpl` file is removed.
substitute_tmpl() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        log_fail "substitute_tmpl: not a regular file: $f" "substitute_tmpl $f"
        return 1
    fi
    if [[ "$f" != *.tmpl ]]; then
        log_fail "substitute_tmpl: expected .tmpl suffix, got: $f" "substitute_tmpl $f"
        return 1
    fi
    local out="${f%.tmpl}"
    local pass1="${f}.pass1.tmp"
    # Pass 1: envsubst the variable references.
    if ! envsubst "$__LH_SUBSTITUTE_ALLOWLIST" < "$f" > "$pass1"; then
        rm -f "$pass1"
        log_fail "substitute_tmpl: envsubst failed for $f" "envsubst < $f"
        return 1
    fi
    # Pass 2: awk strips {{#if FLAG}}...{{/if}} blocks based on IF_<FLAG> env.
    # Rules:
    #   - {{#if flag}} on its own line OR inline opens a block.
    #   - {{/if}} closes the block.
    #   - Nesting is supported (stack of keep/skip decisions).
    #   - A block is KEPT if env var IF_<FLAG-UPPERCASED> == "1".
    #   - Inline tokens within a kept line: the markers themselves are stripped.
    awk '
        function decide(flag,    key) {
            key = "IF_" toupper(flag)
            return (ENVIRON[key] == "1") ? 1 : 0
        }
        BEGIN { depth = 0; keep[0] = 1 }
        {
            line = $0
            while (1) {
                # Open marker
                if (match(line, /\{\{#if[ ]+[a-zA-Z_][a-zA-Z0-9_]*\}\}/)) {
                    marker = substr(line, RSTART, RLENGTH)
                    flag = marker
                    sub(/^\{\{#if[ ]+/, "", flag)
                    sub(/\}\}$/, "", flag)
                    before = substr(line, 1, RSTART - 1)
                    after  = substr(line, RSTART + RLENGTH)
                    # Emit "before" if currently keeping
                    if (keep[depth] && before != "") printf "%s", before
                    depth++
                    keep[depth] = keep[depth-1] && decide(flag)
                    line = after
                    continue
                }
                # Close marker
                if (match(line, /\{\{\/if\}\}/)) {
                    before = substr(line, 1, RSTART - 1)
                    after  = substr(line, RSTART + RLENGTH)
                    if (keep[depth] && before != "") printf "%s", before
                    if (depth > 0) depth--
                    line = after
                    continue
                }
                break
            }
            if (keep[depth]) print line
        }
    ' "$pass1" > "$out"
    rm -f "$pass1" "$f"
    _substitute_check_unresolved "$out" "substitute_tmpl" || return 1
}
