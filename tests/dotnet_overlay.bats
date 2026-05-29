#!/usr/bin/env bats
# tests/dotnet_overlay.bats — coverage for lib/dotnet-overlay.sh.
#
# Tests run against tmpdir-copied fixtures so we never mutate the
# repo-tracked fixture files.

load _helper

setup() {
    TMP="$(mktemp -d -t dotnet-overlay-bats.XXXXXX)"
    cp -r "${SCAFFOLD_ROOT}/tests/fixtures/dotnet-overlay/." "${TMP}/"
    # Source helpers in this subshell.
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/dotnet-overlay.sh"
}

teardown() {
    rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# dotnet_overlay_set_root_namespace
# ---------------------------------------------------------------------------

@test "dotnet_overlay_set_root_namespace inserts when absent" {
    f="${TMP}/csproj-fixture-without-rootnamespace.csproj"
    run dotnet_overlay_set_root_namespace "$f" SmokeApp
    [ "$status" -eq 0 ]
    grep -q '<RootNamespace>SmokeApp</RootNamespace>' "$f"
}

@test "dotnet_overlay_set_root_namespace rewrites when present with wrong value" {
    f="${TMP}/csproj-fixture-with-rootnamespace.csproj"
    run dotnet_overlay_set_root_namespace "$f" SmokeApp
    [ "$status" -eq 0 ]
    grep -q '<RootNamespace>SmokeApp</RootNamespace>' "$f"
    ! grep -q '<RootNamespace>OldName</RootNamespace>' "$f"
}

@test "dotnet_overlay_set_root_namespace is a no-op when value matches" {
    f="${TMP}/csproj-fixture-with-rootnamespace.csproj"
    dotnet_overlay_set_root_namespace "$f" OldName
    before=$(sha256sum "$f" | cut -d' ' -f1)
    dotnet_overlay_set_root_namespace "$f" OldName
    after=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$before" = "$after" ]
}

@test "dotnet_overlay_set_root_namespace is idempotent across runs" {
    f="${TMP}/csproj-fixture-without-rootnamespace.csproj"
    dotnet_overlay_set_root_namespace "$f" SmokeApp
    h1=$(sha256sum "$f" | cut -d' ' -f1)
    dotnet_overlay_set_root_namespace "$f" SmokeApp
    h2=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$h1" = "$h2" ]
}

@test "dotnet_overlay_set_root_namespace fails loudly when no PropertyGroup with TargetFramework" {
    f="${TMP}/bad.csproj"
    cat > "$f" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="X" Version="1.0.0" />
  </ItemGroup>
</Project>
EOF
    run dotnet_overlay_set_root_namespace "$f" SmokeApp
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# dotnet_overlay_swap_automapper_for_mapperly
# ---------------------------------------------------------------------------

@test "dotnet_overlay_swap_automapper_for_mapperly removes AutoMapper + adds Mapperly" {
    f="${TMP}/csproj-fixture-with-automapper.csproj"
    export ABP_VERSION=10.3.0
    run dotnet_overlay_swap_automapper_for_mapperly "$f"
    [ "$status" -eq 0 ]
    ! grep -q 'Include="Volo.Abp.AutoMapper"' "$f"
    ! grep -q 'Include="AutoMapper"' "$f"
    grep -q 'Include="Volo.Abp.Mapperly"' "$f"
    # Riok.Mapperly.Abstractions comes transitively from Volo.Abp.Mapperly —
    # we DO NOT add it as a separate PackageReference (matches LinkHub
    # canonical shape; explicit add caused NU1101 with packageSourceMapping).
    ! grep -q 'Include="Riok.Mapperly.Abstractions"' "$f"
}

@test "dotnet_overlay_swap_automapper_for_mapperly is idempotent" {
    f="${TMP}/csproj-fixture-with-automapper.csproj"
    export ABP_VERSION=10.3.0
    dotnet_overlay_swap_automapper_for_mapperly "$f"
    h1=$(sha256sum "$f" | cut -d' ' -f1)
    dotnet_overlay_swap_automapper_for_mapperly "$f"
    h2=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$h1" = "$h2" ]
}

# ---------------------------------------------------------------------------
# dotnet_overlay_add_dependson_attribute
# ---------------------------------------------------------------------------

@test "dotnet_overlay_add_dependson_attribute inserts typeof() into multi-line DependsOn" {
    f="${TMP}/application-module-fixture.cs"
    run dotnet_overlay_add_dependson_attribute "$f" AbpMapperlyModule "using Volo.Abp.Mapperly;"
    [ "$status" -eq 0 ]
    grep -q 'typeof(AbpMapperlyModule)' "$f"
    grep -qxF 'using Volo.Abp.Mapperly;' "$f"
}

@test "dotnet_overlay_add_dependson_attribute is idempotent" {
    f="${TMP}/application-module-fixture.cs"
    dotnet_overlay_add_dependson_attribute "$f" AbpMapperlyModule "using Volo.Abp.Mapperly;"
    h1=$(sha256sum "$f" | cut -d' ' -f1)
    dotnet_overlay_add_dependson_attribute "$f" AbpMapperlyModule "using Volo.Abp.Mapperly;"
    h2=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$h1" = "$h2" ]
}

@test "dotnet_overlay_add_dependson_attribute adds using when missing" {
    f="${TMP}/application-module-fixture.cs"
    ! grep -qxF 'using Volo.Abp.Mapperly;' "$f"
    dotnet_overlay_add_dependson_attribute "$f" AbpMapperlyModule "using Volo.Abp.Mapperly;"
    grep -qxF 'using Volo.Abp.Mapperly;' "$f"
}

@test "dotnet_overlay_add_dependson_attribute handles inline single-line DependsOn" {
    f="${TMP}/inline.cs"
    cat > "$f" <<'EOF'
using Volo.Abp.Modularity;

namespace Demo;

[DependsOn(typeof(FirstModule), typeof(SecondModule))]
public class DemoModule : AbpModule { }
EOF
    dotnet_overlay_add_dependson_attribute "$f" AbpThirdModule "using Volo.Abp.Third;"
    grep -q 'typeof(AbpThirdModule)' "$f"
    grep -qxF 'using Volo.Abp.Third;' "$f"
}

# ---------------------------------------------------------------------------
# scaffold_insert_block / scaffold_assert_block_present
# ---------------------------------------------------------------------------

@test "scaffold_insert_block replaces body between markers" {
    f="${TMP}/has-markers.cs"
    cat > "$f" <<'EOF'
public class A {
    void M() {
        // <ScaffoldBlock name="otel">
        // </ScaffoldBlock>
    }
}
EOF
    body="${TMP}/body.txt"
    printf '        DoOtelSetup();\n' > "$body"
    scaffold_insert_block "$f" otel "$body"
    grep -q 'DoOtelSetup();' "$f"
}

@test "scaffold_insert_block is idempotent" {
    f="${TMP}/has-markers.cs"
    cat > "$f" <<'EOF'
public class A {
    void M() {
        // <ScaffoldBlock name="otel">
        // </ScaffoldBlock>
    }
}
EOF
    body="${TMP}/body.txt"
    printf '        DoOtelSetup();\n' > "$body"
    scaffold_insert_block "$f" otel "$body"
    h1=$(sha256sum "$f" | cut -d' ' -f1)
    scaffold_insert_block "$f" otel "$body"
    h2=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$h1" = "$h2" ]
}

@test "scaffold_insert_block fails loudly when marker pair missing" {
    f="${TMP}/no-markers.cs"
    cat > "$f" <<'EOF'
public class A { void M() { } }
EOF
    body="${TMP}/body.txt"
    printf 'X\n' > "$body"
    run scaffold_insert_block "$f" otel "$body"
    [ "$status" -ne 0 ]
}

@test "scaffold_assert_block_present finds intact pairs" {
    f="${TMP}/p.cs"
    cat > "$f" <<'EOF'
// <ScaffoldBlock name="x">
// </ScaffoldBlock>
EOF
    run scaffold_assert_block_present "$f" x
    [ "$status" -eq 0 ]
}

@test "scaffold_assert_block_present rejects orphan open marker" {
    f="${TMP}/orphan.cs"
    cat > "$f" <<'EOF'
// <ScaffoldBlock name="x">
EOF
    run scaffold_assert_block_present "$f" x
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# merge_markers_into_existing
# ---------------------------------------------------------------------------

@test "merge_markers_into_existing inserts BLOCKs after Allman brace following ANCHOR" {
    f="${TMP}/host-module-fixture.cs"
    m="${TMP}/host.markers"
    cat > "$m" <<'EOF'
ANCHOR ^[[:space:]]*public override void OnApplicationInitialization\(.*\)[[:space:]]*$
BLOCK otel
BLOCK health-endpoints
EOF
    run merge_markers_into_existing "$f" "$m"
    [ "$status" -eq 0 ]
    grep -q '// <ScaffoldBlock name="otel">' "$f"
    grep -q '// <ScaffoldBlock name="health-endpoints">' "$f"
    # Both markers land INSIDE the method body (after the `{`).
    awk '/OnApplicationInitialization/{found=1} found && /<ScaffoldBlock name="otel"/{print "OK"; exit}' "$f" | grep -q OK
}

@test "merge_markers_into_existing ANCHOR_INLINE inserts after the matched line" {
    f="${TMP}/program-fixture.cs"
    m="${TMP}/prog.markers"
    cat > "$m" <<'EOF'
ANCHOR_INLINE ^[[:space:]]*var[[:space:]]+builder[[:space:]]*=[[:space:]]*WebApplication\.CreateBuilder\(args\)
BLOCK fwd-headers
EOF
    run merge_markers_into_existing "$f" "$m"
    [ "$status" -eq 0 ]
    grep -q '// <ScaffoldBlock name="fwd-headers">' "$f"
    # The marker MUST land after the var builder = ... line, not before
    # the next brace-only line (which doesn't exist).
    grep -B1 'ScaffoldBlock name="fwd-headers"' "$f" | grep -q 'var builder = WebApplication.CreateBuilder(args);'
}

@test "merge_markers_into_existing fails when ANCHOR regex does not match" {
    f="${TMP}/host-module-fixture.cs"
    m="${TMP}/bad.markers"
    cat > "$m" <<'EOF'
ANCHOR ^DOES_NOT_EXIST$
BLOCK x
EOF
    run merge_markers_into_existing "$f" "$m"
    [ "$status" -ne 0 ]
}

@test "merge_markers_into_existing is idempotent" {
    f="${TMP}/host-module-fixture.cs"
    m="${TMP}/host.markers"
    cat > "$m" <<'EOF'
ANCHOR ^[[:space:]]*public override void OnApplicationInitialization\(.*\)[[:space:]]*$
BLOCK otel
BLOCK health-endpoints
EOF
    merge_markers_into_existing "$f" "$m"
    h1=$(sha256sum "$f" | cut -d' ' -f1)
    merge_markers_into_existing "$f" "$m"
    h2=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$h1" = "$h2" ]
}

@test "merge_markers_into_existing supports JSON sentinel-key markers" {
    f="${TMP}/appsettings-fixture.json"
    m="${TMP}/app.markers"
    cat > "$m" <<'EOF'
ANCHOR ^\{$
BLOCK serilog-config
BLOCK csp-defaults
EOF
    run merge_markers_into_existing "$f" "$m"
    [ "$status" -eq 0 ]
    grep -q '"//scaffold-block-serilog-config-start"' "$f"
    grep -q '"//scaffold-block-csp-defaults-end"' "$f"
    # Verify resulting file is valid JSON.
    if command -v python3 >/dev/null; then
        python3 -c "import json,sys;json.load(open('$f'))"
    fi
}
