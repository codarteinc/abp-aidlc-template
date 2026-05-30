#!/usr/bin/env bats
# tests/smoke/app_nolayers.bats — end-to-end smoke test for the single-
# layer variant: app-nolayers + angular + ef + postgresql.
#
# Gated behind RUN_SMOKE_TESTS=1.

load _smoke_helper

setup()    { smoke_setup; }
teardown() { smoke_teardown; }

@test "app-nolayers: scaffold.sh runs to completion" {
    run smoke_scaffold app-nolayers.yml
    [ "$status" -eq 0 ]
    [ -d "$TARGET" ]
}

@test "app-nolayers: dotnet build succeeds" {
    smoke_scaffold app-nolayers.yml
    cd "$TARGET"
    # nolayers template uses a single project shape; the .slnx may or
    # may not exist depending on abp CLI version. Build the solution
    # file if present, else build the .sln, else build the cwd.
    local sln
    if [ -f "$PROJECT.slnx" ]; then
        sln="$PROJECT.slnx"
    elif [ -f "$PROJECT.sln" ]; then
        sln="$PROJECT.sln"
    else
        sln=.
    fi
    run dotnet build "$sln"
    [ "$status" -eq 0 ]
}

@test "app-nolayers: dotnet test succeeds (if test project present)" {
    smoke_scaffold app-nolayers.yml
    cd "$TARGET"
    # nolayers may or may not ship a separate test project depending on
    # abp CLI version. If there's no .csproj under test/, skip.
    if ! find . -path '*/test/*.csproj' -print -quit | grep -q .; then
        skip "no test project in app-nolayers shape"
    fi
    dotnet build
    run dotnet test --no-build
    [ "$status" -eq 0 ]
}

@test "app-nolayers: yarn install + build succeed for angular" {
    command -v yarn >/dev/null 2>&1 || skip "yarn not installed"
    smoke_scaffold app-nolayers.yml
    cd "$TARGET/angular"
    run yarn install --frozen-lockfile
    [ "$status" -eq 0 ]
    run yarn build
    [ "$status" -eq 0 ]
}

@test "app-nolayers: no LinkHub residue in scaffold output" {
    smoke_scaffold app-nolayers.yml
    cd "$TARGET"
    run grep -rIE 'LinkHub|linkhub|codarteinc/linkhub' \
        --include='*.cs' --include='*.json' --include='*.yml' \
        --include='*.md' --include='*.ts' .
    [ "$status" -ne 0 ]
}
