#!/usr/bin/env bats
# tests/overlay_claude_aidlc.bats — verify the unit-09 overlay tree:
#   1. Required files exist under template/.claude and template/.ai-dlc.
#   2. .claude/settings.json is valid JSON.
#   3. .ai-dlc/settings.yml.tmpl renders to valid YAML for each
#      IF_UI_* path.
#   4. All 18 abp-*/SKILL.md files are present and byte-identical
#      to LinkHub's source (sanity check on the bulk copy).
#   5. CLAUDE.md.tmpl renders with ui=angular + db=ef and the output
#      contains the Angular section markers + EF section.
#   6. CLAUDE.md.tmpl renders with ui=mvc + db=mongodb and the output
#      does NOT contain the Angular section, DOES contain the
#      MongoDB-conditional bullet, and DOES include the wwwroot/libs
#      bullet (MVC-conditional).
#   7. CLAUDE.md.tmpl renders without LinkHub-feature residue beyond
#      the placeholder-block GitHub reference links.

load _helper
TEMPLATE="$SCAFFOLD_ROOT/template"
SKILLS_SRC="/home/dev/projects/linkhub/.claude/skills"

# Shared fixture env exporter — keeps test setup terse and consistent.
# Sets every variable in __LH_SUBSTITUTE_ALLOWLIST plus every IF_* flag,
# then lets callers override UI/DB-specific bits.
_export_fixture_env() {
    export PROJECT_NAME=SmokeApp
    export PROJECT_NAME_LOWER=smokeapp
    export PROJECTNAME_UPPER=SMOKEAPP
    export GITHUB_OWNER=acme
    export HCP_ORG=acme
    export DBMS=postgresql
    export UI=angular
    export DB_PROVIDER=ef
    export DEFAULT_CULTURE=en
    export MULTI_TENANCY=false
    export TIERED=false
    export HETZNER_LOCATION=hel1
    export HETZNER_SERVER_TYPE=cx22
    export CLOUDFLARE_ZONE=example.com
    export IF_UI_ANGULAR=1
    export IF_UI_MVC=0
    export IF_UI_BLAZOR=0
    export IF_UI_BLAZOR_SERVER=0
    export IF_UI_NONE=0
    export IF_DB_EF=1
    export IF_DB_MONGODB=0
    export IF_MULTI_TENANCY=0
    export IF_TIERED=0
}

@test "unit-09 files exist" {
    [ -f "$TEMPLATE/CLAUDE.md.tmpl" ]
    [ -f "$TEMPLATE/.claude/settings.json" ]
    [ -f "$TEMPLATE/.claude/settings.local.json.template" ]
    [ -f "$TEMPLATE/.ai-dlc/settings.yml.tmpl" ]
    [ -f "$TEMPLATE/.ai-dlc/ELABORATION.md.tmpl" ]
    [ -f "$TEMPLATE/.ai-dlc/knowledge/README.md" ]
}

@test ".claude/settings.json is valid JSON" {
    run jq empty "$TEMPLATE/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test ".claude/settings.local.json.template is valid JSON" {
    run jq empty "$TEMPLATE/.claude/settings.local.json.template"
    [ "$status" -eq 0 ]
}

@test "all 18 abp-* SKILL.md files present" {
    local count
    count=$(find "$TEMPLATE/.claude/skills" -name 'SKILL.md' | wc -l)
    [ "$count" -eq 18 ]
}

@test "abp-*/SKILL.md byte-identical to LinkHub source" {
    for d in "$SKILLS_SRC"/abp-*; do
        local name; name=$(basename "$d")
        run diff -q "$d/SKILL.md" "$TEMPLATE/.claude/skills/$name/SKILL.md"
        [ "$status" -eq 0 ]
    done
}

@test ".ai-dlc/settings.yml.tmpl renders + parses for ui=angular" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/.ai-dlc/settings.yml.tmpl" "$tmp/settings.yml.tmpl"
    _export_fixture_env
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/settings.yml.tmpl"
    run yq '.default_passes | length' "$tmp/settings.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
    rm -rf "$tmp"
}

@test ".ai-dlc/settings.yml.tmpl renders for ui=none with only [dev] pass" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/.ai-dlc/settings.yml.tmpl" "$tmp/settings.yml.tmpl"
    _export_fixture_env
    export UI=none
    export IF_UI_ANGULAR=0
    export IF_UI_NONE=1
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/settings.yml.tmpl"
    run yq '.default_passes | length' "$tmp/settings.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run yq '.default_passes[0]' "$tmp/settings.yml"
    [ "$output" = "dev" ]
    rm -rf "$tmp"
}

@test "CLAUDE.md.tmpl renders with ui=angular,db=ef and contains Angular + EF sections" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/CLAUDE.md.tmpl" "$tmp/CLAUDE.md.tmpl"
    _export_fixture_env
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/CLAUDE.md.tmpl"
    grep -q 'angular/src/app/proxy' "$tmp/CLAUDE.md"
    grep -q 'yarn --cwd angular' "$tmp/CLAUDE.md"
    grep -q 'EF Core' "$tmp/CLAUDE.md"
    grep -q 'EntityFrameworkCore/Migrations' "$tmp/CLAUDE.md"
    ! grep -q 'wwwroot/libs/' "$tmp/CLAUDE.md"
    ! grep -q 'Blazor WebAssembly' "$tmp/CLAUDE.md"
    ! grep -q 'Blazor Server' "$tmp/CLAUDE.md"
    ! grep -q -i 'mongodb' "$tmp/CLAUDE.md"
    # PROJECT_NAME substituted correctly
    grep -q 'SmokeApp' "$tmp/CLAUDE.md"
    ! grep -q '\${PROJECT_NAME}' "$tmp/CLAUDE.md"
    rm -rf "$tmp"
}

@test "CLAUDE.md.tmpl renders with ui=mvc,db=mongodb without Angular, with MongoDB + wwwroot/libs" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/CLAUDE.md.tmpl" "$tmp/CLAUDE.md.tmpl"
    _export_fixture_env
    export UI=mvc
    export DB_PROVIDER=mongodb
    export IF_UI_ANGULAR=0
    export IF_UI_MVC=1
    export IF_DB_EF=0
    export IF_DB_MONGODB=1
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/CLAUDE.md.tmpl"
    ! grep -q 'angular/src/app/proxy' "$tmp/CLAUDE.md"
    ! grep -q 'yarn --cwd angular' "$tmp/CLAUDE.md"
    grep -q 'wwwroot/libs/' "$tmp/CLAUDE.md"
    grep -q -i 'MongoDB' "$tmp/CLAUDE.md"
    # No EF Core migration section
    ! grep -q 'EntityFrameworkCore/Migrations' "$tmp/CLAUDE.md"
    rm -rf "$tmp"
}

@test "CLAUDE.md.tmpl ui=none,db=mongodb drops all UI-conditional content" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/CLAUDE.md.tmpl" "$tmp/CLAUDE.md.tmpl"
    _export_fixture_env
    export UI=none
    export DB_PROVIDER=mongodb
    export IF_UI_ANGULAR=0
    export IF_UI_NONE=1
    export IF_DB_EF=0
    export IF_DB_MONGODB=1
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/CLAUDE.md.tmpl"
    ! grep -q 'angular/src/app/proxy' "$tmp/CLAUDE.md"
    ! grep -q 'wwwroot/libs/' "$tmp/CLAUDE.md"
    ! grep -q 'Blazor' "$tmp/CLAUDE.md"
    grep -q -i 'MongoDB' "$tmp/CLAUDE.md"
    rm -rf "$tmp"
}

@test "CLAUDE.md.tmpl renders without LinkHub-feature residue" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/CLAUDE.md.tmpl" "$tmp/CLAUDE.md.tmpl"
    _export_fixture_env
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/CLAUDE.md.tmpl"
    # Allowed: the two references to "LinkHub" in the placeholder
    # blocks' GitHub URLs ("Where things live" + "Runtime artifacts").
    local hits
    hits=$(grep -cE 'LinkHub|UserProfile|link-management|PictureUpload|UserProfileConsts' "$tmp/CLAUDE.md" || true)
    [ "$hits" -le 2 ]
    rm -rf "$tmp"
}

@test "ELABORATION.md.tmpl renders with PROJECT_NAME substitution" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/.ai-dlc/ELABORATION.md.tmpl" "$tmp/ELABORATION.md.tmpl"
    _export_fixture_env
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/ELABORATION.md.tmpl"
    grep -q 'Elaboration Guidance — SmokeApp' "$tmp/ELABORATION.md"
    grep -q 'src/SmokeApp.HttpApi.Host/appsettings.secrets.json' "$tmp/ELABORATION.md"
    grep -q 'acme/smokeapp#N' "$tmp/ELABORATION.md"
    grep -q 'yarn --cwd angular install' "$tmp/ELABORATION.md"
    ! grep -q '\${PROJECT_NAME}' "$tmp/ELABORATION.md"
    rm -rf "$tmp"
}

@test "ELABORATION.md.tmpl with ui=none drops yarn install snippet" {
    local tmp; tmp=$(mktemp -d)
    cp "$TEMPLATE/.ai-dlc/ELABORATION.md.tmpl" "$tmp/ELABORATION.md.tmpl"
    _export_fixture_env
    export UI=none
    export IF_UI_ANGULAR=0
    export IF_UI_NONE=1
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/log.sh"
    # shellcheck disable=SC1091
    source "$SCAFFOLD_ROOT/lib/substitute.sh"
    substitute_tmpl "$tmp/ELABORATION.md.tmpl"
    ! grep -q 'yarn --cwd angular install' "$tmp/ELABORATION.md"
    grep -q 'abp install-libs' "$tmp/ELABORATION.md"
    rm -rf "$tmp"
}
