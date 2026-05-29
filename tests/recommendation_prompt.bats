#!/usr/bin/env bats
# tests/recommendation_prompt.bats — assert recommendation-prompt.md
# structural correctness and the canonical example fixture.

load _helper

@test "recommendation-prompt.md exists and has required sections" {
    PROMPT="${SCAFFOLD_ROOT}/recommendation-prompt.md"
    [ -f "$PROMPT" ]
    grep -q '^## Role' "$PROMPT"
    grep -q '^## Output' "$PROMPT"
    grep -q '^## Heuristics' "$PROMPT"
    grep -q '^## Example' "$PROMPT"
    # Canonical example must include the SaaS phrasing.
    grep -q 'multi-tenant SaaS' "$PROMPT"
    # The example output JSON must include the key fields.
    grep -qE '"multi_tenancy":[[:space:]]*true' "$PROMPT"
    grep -qE '"template":[[:space:]]*"app"' "$PROMPT"
}

@test "recommendation-prompt-test.sh validates the canonical example output" {
    run bash "${SCAFFOLD_ROOT}/scripts/recommendation-prompt-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'OK: recommendation-prompt canonical example passes'
}
