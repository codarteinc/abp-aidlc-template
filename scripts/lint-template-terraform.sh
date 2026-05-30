#!/usr/bin/env bash
# scripts/lint-template-terraform.sh — terraform fmt/validate the templated
# .tf files under template/terraform/.
#
# Usage: scripts/lint-template-terraform.sh fmt|validate
#
# Runs envsubst over template/terraform/ to materialize a syntactically
# valid tree in a tmpdir, then runs the requested terraform subcommand.
# Validate also runs `terraform init -backend=false` so providers
# resolve; this needs network egress to the public Terraform registry
# on cold cache.

set -euo pipefail

cmd="${1:-fmt}"
case "$cmd" in
    fmt|validate) ;;
    *)
        echo "Usage: $0 fmt|validate" >&2
        exit 64
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/template/terraform"

if [ ! -d "$SRC_DIR" ]; then
    echo "No template terraform at $SRC_DIR — nothing to lint." >&2
    exit 0
fi

if ! command -v terraform >/dev/null 2>&1; then
    echo "terraform not installed; install from https://www.terraform.io/downloads" >&2
    exit 0
fi

TMP="$(mktemp -d -t lint-tmpl-tf.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export PROJECT_NAME=SmokeApp
export PROJECT_NAME_LOWER=smokeapp
export PROJECTNAME_UPPER=SMOKEAPP
export GITHUB_OWNER=codarteinc-test
export HCP_ORG=codarteinc-test
export HETZNER_LOCATION=hel1
export HETZNER_SERVER_TYPE=cx23
export CLOUDFLARE_ZONE=example.com

# Walk the tree, envsubst .tf/.tfvars files, copy everything else verbatim.
cd "$SRC_DIR"
while IFS= read -r -d '' src; do
    rel="${src#./}"
    dest="$TMP/$rel"
    mkdir -p "$(dirname "$dest")"
    case "$rel" in
        *.tf|*.tfvars|*.hcl|*.tftpl|*.tf.template|*.tfvars.template)
            # shellcheck disable=SC2016
            envsubst '${PROJECT_NAME} ${PROJECT_NAME_LOWER} ${PROJECTNAME_UPPER} ${GITHUB_OWNER} ${HCP_ORG} ${HETZNER_LOCATION} ${HETZNER_SERVER_TYPE} ${CLOUDFLARE_ZONE}' \
                < "$src" > "$dest"
            # Drop a stray .template suffix once substituted.
            case "$dest" in
                *.template)
                    mv "$dest" "${dest%.template}"
                    ;;
            esac
            ;;
        *)
            cp "$src" "$dest"
            ;;
    esac
done < <(find . -type f -print0)

cd "$TMP"
case "$cmd" in
    fmt)
        terraform fmt -check -recursive
        ;;
    validate)
        # Validate each top-level workspace dir (excludes modules/, which
        # are validated implicitly via their root caller).
        rc=0
        for dir in */; do
            name="${dir%/}"
            case "$name" in
                modules) continue ;;
            esac
            ( cd "$name" && terraform init -backend=false -input=false >/dev/null && terraform validate ) || rc=1
        done
        exit "$rc"
        ;;
esac
