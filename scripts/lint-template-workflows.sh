#!/usr/bin/env bash
# scripts/lint-template-workflows.sh — actionlint the workflow .template
# files under template/.github/workflows/.
#
# The .template files carry envsubst tokens (${PROJECT_NAME}, etc.) that
# actionlint can't resolve. This script:
#   1. Copies each *.template file to a tmpdir with the `.template`
#      suffix stripped.
#   2. Runs a placeholder substitution pass to give actionlint syntactically
#      valid YAML.
#   3. Invokes `actionlint` over the substituted tree.
#
# Returns 0 if all workflows lint clean, non-zero on first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/template/.github/workflows"

if [ ! -d "$SRC_DIR" ]; then
    echo "No template workflows at $SRC_DIR — nothing to lint." >&2
    exit 0
fi

if ! command -v actionlint >/dev/null 2>&1; then
    echo "actionlint not installed; install from https://github.com/rhysd/actionlint" >&2
    exit 0
fi

TMP="$(mktemp -d -t lint-tmpl-wf.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export PROJECT_NAME=SmokeApp
export PROJECT_NAME_LOWER=smokeapp
export PROJECTNAME_UPPER=SMOKEAPP
export GITHUB_OWNER=codarteinc-test
export HCP_ORG=codarteinc-test
export DBMS=postgresql
export HETZNER_LOCATION=hel1
export HETZNER_SERVER_TYPE=cx23
export CLOUDFLARE_ZONE=example.com

mkdir -p "$TMP/.github/workflows"
for src in "$SRC_DIR"/*.template; do
    dest_name="$(basename "$src" .template)"
    # shellcheck disable=SC2016  # envsubst variable list is intentional literal.
    envsubst '${PROJECT_NAME} ${PROJECT_NAME_LOWER} ${PROJECTNAME_UPPER} ${GITHUB_OWNER} ${HCP_ORG} ${DBMS} ${HETZNER_LOCATION} ${HETZNER_SERVER_TYPE} ${CLOUDFLARE_ZONE}' \
        < "$src" > "$TMP/.github/workflows/$dest_name"
done

cd "$TMP"
actionlint -ignore '"on" section'
