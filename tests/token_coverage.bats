#!/usr/bin/env bats
# tests/token_coverage.bats — assert that every ${VAR} token used in
# template/ overlay files is exported by scaffold.sh (or lib/*.sh).
# Catches drift introduced by adding a new substitution token without a
# matching export.

load _helper

@test "check-token-coverage.sh passes after unit-03 overlay files are added" {
    run "${SCAFFOLD_ROOT}/scripts/check-token-coverage.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'token coverage OK'
}
