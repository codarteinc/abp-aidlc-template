#!/usr/bin/env bash
# scripts/check-token-coverage.sh — drift gate between `template/` overlay
# files and the env-var exports the scaffold tool actually emits.
#
# For every `${VAR}` token referenced anywhere under `template/`, there
# must be a matching `export VAR=` in `scaffold.sh` or `lib/*.sh`. If a
# variable is referenced but never exported, envsubst silently substitutes
# the empty string — a class of bugs we want CI to catch.
#
# Exits 0 when every template-referenced var is exported (trivially true
# while `template/` is empty in unit-01). Exits 1 with the missing vars
# listed when drift is detected.
#
# Usage:
#   ./scripts/check-token-coverage.sh
#
# Wired into .github/workflows/ci.yml as the `token-coverage` job.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Note: `grep` exits 1 when nothing matches. We tolerate that — it's the
# normal case in unit-01 (empty `template/`). The `|| true` swallows the
# non-zero so `set -e` doesn't fire on a benign empty result.
#
# Excludes:
#   - *.template files — deploy-time envsubst targets; their ${VAR}
#     references are operator-supplied at container start, NOT scaffold-
#     time tokens. The scaffold's phase_apply_overlays skips substitution
#     on *.template, so this script must match.
#   - overlay-blocks/   — per-unit block-body fragments. Their ${VAR}
#     references ARE scaffold-time (rendered before splicing into the
#     marker pair), so they're INCLUDED in coverage (not excluded).
# shellcheck disable=SC2016  # literal token-pattern; not a shell expansion.
template_vars=$(
    if [[ -d template ]]; then
        { grep -rho --include='*' --exclude='*.template' \
            '\${[A-Z_]\+}' template/ 2>/dev/null || true; } \
            | tr -d '${}' \
            | sort -u
    fi
)

# Exported env vars in the scaffold tool. Grep `export NAME` lines in
# scaffold.sh and lib/*.sh. Multi-var `export A B C` lines and the
# `export A=value` form are both handled.
exported_vars=$(
    { grep -hE '^[[:space:]]*export [A-Z_][A-Z0-9_ ]*' \
        scaffold.sh lib/*.sh 2>/dev/null || true; } \
        | sed -E 's/^[[:space:]]*export[[:space:]]+//; s/=.*$//' \
        | tr ' ' '\n' \
        | { grep -E '^[A-Z_][A-Z0-9_]*$' || true; } \
        | sort -u
)

missing=$(comm -23 <(printf '%s\n' "$template_vars") <(printf '%s\n' "$exported_vars"))

if [[ -n "$missing" ]]; then
    {
        echo "TOKEN COVERAGE FAILURE — these vars appear in template/ but are not exported by scaffold.sh:"
        while IFS= read -r v; do
            printf '  - %s\n' "$v"
        done <<< "$missing"
        echo
        echo "Fix: add the missing var(s) to _export_config_env in scaffold.sh AND to the allowlist in lib/substitute.sh."
    } >&2
    exit 1
fi

echo "token coverage OK"
