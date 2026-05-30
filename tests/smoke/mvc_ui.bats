#!/usr/bin/env bats
# tests/smoke/mvc_ui.bats — end-to-end smoke test for the MVC UI
# variant: app + mvc + ef + postgresql.
#
# Gated behind RUN_SMOKE_TESTS=1.

load _smoke_helper

setup()    { smoke_setup; }
teardown() { smoke_teardown; }

@test "mvc-ui: scaffold.sh runs to completion" {
    run smoke_scaffold mvc-ui.yml
    [ "$status" -eq 0 ]
    [ -d "$TARGET" ]
}

@test "mvc-ui: dotnet build succeeds on .slnx" {
    smoke_scaffold mvc-ui.yml
    cd "$TARGET"
    run dotnet build "$PROJECT.slnx"
    [ "$status" -eq 0 ]
}

@test "mvc-ui: dotnet test succeeds on .slnx" {
    smoke_scaffold mvc-ui.yml
    cd "$TARGET"
    dotnet build "$PROJECT.slnx"
    run dotnet test "$PROJECT.slnx" --no-build
    [ "$status" -eq 0 ]
}

@test "mvc-ui: no angular/ directory present" {
    smoke_scaffold mvc-ui.yml
    [ ! -d "$TARGET/angular" ]
}

@test "mvc-ui: wwwroot/libs populated by abp install-libs (proxy check)" {
    smoke_scaffold mvc-ui.yml
    # When the MVC project ran post-init's abp install-libs, wwwroot/libs
    # should be non-empty under the Web project. Since we --skip-post-init
    # in the smoke run, run abp install-libs explicitly here.
    cd "$TARGET"
    command -v abp >/dev/null 2>&1 || skip "abp CLI not installed"
    run abp install-libs
    [ "$status" -eq 0 ]
    # Find a wwwroot/libs anywhere in the MVC project shape.
    run find . -type d -path '*/wwwroot/libs' -print -quit
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "mvc-ui: no LinkHub residue in scaffold output" {
    smoke_scaffold mvc-ui.yml
    cd "$TARGET"
    run grep -rIE 'LinkHub|linkhub|codarteinc/linkhub' \
        --include='*.cs' --include='*.json' --include='*.yml' \
        --include='*.md' --include='*.cshtml' .
    [ "$status" -ne 0 ]
}
