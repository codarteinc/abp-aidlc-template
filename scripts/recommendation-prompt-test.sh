#!/usr/bin/env bash
# scripts/recommendation-prompt-test.sh — assert the canonical example
# output inside recommendation-prompt.md is valid JSON conforming to
# scaffold-config-schema.yml.
#
# The prompt's canonical example is the contract surface the
# recommendation engine targets. If we cannot validate THAT, the prompt
# is broken — so this script runs in CI (via tests/recommendation_prompt.bats)
# and in the local smoke wrapper.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT="${ROOT}/recommendation-prompt.md"

if [[ ! -f "$PROMPT" ]]; then
    echo "FAIL: recommendation-prompt.md missing at $PROMPT" >&2
    exit 1
fi

# Extract the LAST ```json…``` block from the prompt. Convention: any
# earlier ```json blocks (if any) are illustrative fragments; the LAST
# one is the full canonical example.
json="$(awk '
    /^```json$/ { in_block=1; buf=""; next }
    /^```$/ && in_block { last=buf; in_block=0; next }
    in_block { buf = buf $0 "\n" }
    END { printf "%s", last }
' "$PROMPT")"

if [[ -z "$json" ]]; then
    echo "FAIL: no canonical \`\`\`json block found in $PROMPT" >&2
    exit 1
fi

# 1. Valid JSON.
if ! printf '%s' "$json" | jq -e . > /dev/null; then
    echo "FAIL: canonical example is not valid JSON" >&2
    exit 1
fi

# 2. Required top-level structure.
if ! printf '%s' "$json" | jq -e '
    .abp.template and
    .abp.ui and
    .abp.db_provider and
    .abp.dbms and
    (.abp.multi_tenancy != null) and
    (.abp.tiered != null) and
    .abp.default_culture and
    (.abp.optional_modules | type == "array") and
    .reasoning and (.reasoning | type == "object")
' > /dev/null; then
    echo "FAIL: canonical example missing required fields" >&2
    exit 1
fi

# 3. The example MUST be the multi-tenant SaaS case the unit success
#    criterion calls out (specific anchor — locks the fixture).
if ! printf '%s' "$json" | jq -e '
    .abp.template == "app" and
    .abp.ui == "angular" and
    .abp.db_provider == "ef" and
    .abp.dbms == "postgresql" and
    .abp.multi_tenancy == true
' > /dev/null; then
    echo "FAIL: canonical example does not match the unit-02 success-criterion case" >&2
    exit 1
fi

# 4. Convert to YAML and re-validate against the real schema. This is
#    the strongest assertion: the example output, if pasted into a
#    config (with operator-confirmed fields backfilled), MUST pass
#    validate-config.sh.
tmp_yaml="$(mktemp -t rec-fixture.XXXXXX.yml)"
trap 'rm -f "$tmp_yaml"' EXIT
printf '%s' "$json" | yq -P > "$tmp_yaml"

# validate-config.sh requires project_name + github_owner +
# infra.cloudflare_zone at top level; the recommendation only fills
# abp.* + sometimes project_name. Backfill the operator-confirmed bits
# before validating.
yq -i '
    .project_name = (.project_name // "SupportDesk") |
    .github_owner = "codarteinc" |
    .infra.cloudflare_zone = "example.com" |
    del(.reasoning)
' "$tmp_yaml"

if ! bash "${ROOT}/lib/validate-config.sh" "$tmp_yaml"; then
    echo "FAIL: canonical example does not pass schema validation" >&2
    exit 1
fi

echo "OK: recommendation-prompt canonical example passes structural + schema validation"
