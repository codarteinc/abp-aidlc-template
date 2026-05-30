#!/usr/bin/env bats
# tests/smoke/linkhub_equivalent.bats — end-to-end smoke test for the
# LinkHub-equivalent combo: app + angular + ef + postgresql.
#
# Definitive E2E gate for v1. Gated behind RUN_SMOKE_TESTS=1.

load _smoke_helper

setup()    { smoke_setup; }
teardown() { smoke_teardown; }

@test "linkhub-equivalent: scaffold.sh runs to completion" {
    run smoke_scaffold linkhub-equivalent.yml
    [ "$status" -eq 0 ]
    [ -d "$TARGET" ]
}

@test "linkhub-equivalent: dotnet build succeeds on .slnx" {
    smoke_scaffold linkhub-equivalent.yml
    cd "$TARGET"
    run dotnet build "$PROJECT.slnx"
    [ "$status" -eq 0 ]
}

@test "linkhub-equivalent: dotnet test succeeds on .slnx" {
    smoke_scaffold linkhub-equivalent.yml
    cd "$TARGET"
    dotnet build "$PROJECT.slnx"
    run dotnet test "$PROJECT.slnx" --no-build
    [ "$status" -eq 0 ]
}

@test "linkhub-equivalent: yarn install + build succeed for angular" {
    command -v yarn >/dev/null 2>&1 || skip "yarn not installed"
    smoke_scaffold linkhub-equivalent.yml
    cd "$TARGET/angular"
    run yarn install --frozen-lockfile
    [ "$status" -eq 0 ]
    run yarn build
    [ "$status" -eq 0 ]
}

@test "linkhub-equivalent: no LinkHub residue in scaffold output" {
    smoke_scaffold linkhub-equivalent.yml
    cd "$TARGET"
    # Intent-level success criterion — promoted from doc-only to full-tree
    # assertion since by smoke phase ALL overlays have run.
    run grep -rIE 'LinkHub|linkhub|codarteinc/linkhub' \
        --include='*.cs' --include='*.json' --include='*.yml' \
        --include='*.md' --include='*.ts' .
    [ "$status" -ne 0 ]
}

@test "linkhub-equivalent: GitHub Actions workflows present" {
    smoke_scaffold linkhub-equivalent.yml
    cd "$TARGET"
    local wf
    for wf in cicd.yml dependabot-auto-merge.yml runner-cache-cleanup.yml \
              staging-deploy.yml staging-rollback.yml \
              _terraform-apply.yml _terraform-plan.yml \
              _terraform-drift.yml _terraform-destroy.yml \
              staging-terraform-apply.yml staging-terraform-plan.yml \
              staging-terraform-drift.yml staging-terraform-destroy.yml; do
        [ -f ".github/workflows/$wf" ] || { echo "missing workflow: $wf"; return 1; }
    done
    [ -f ".github/dependabot.yml" ]
}
