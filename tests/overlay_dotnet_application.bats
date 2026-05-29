#!/usr/bin/env bats
# tests/overlay_dotnet_application.bats — end-to-end test of
# phase_apply_overlays against a fake `abp new`-shaped tree.
#
# Stands up a TARGET_DIR with csproj files at every LinkHub-canonical
# path PLUS the host module + Program.cs + appsettings.json — then
# invokes scaffold.sh's phase_apply_overlays via direct sourcing and
# function call. Verifies file outputs match the unit-03 success criteria.

load _helper

# Build a minimal abp-new-like tree under $1 with PROJECT_NAME $2.
_seed_fake_abp_new() {
    local root="$1" pn="$2"
    mkdir -p "$root/src"
    mkdir -p "$root/test"

    # The 12 csproj projects LinkHub carries with <RootNamespace>.
    local proj
    for proj in \
        "src/${pn}.Application.Contracts" \
        "src/${pn}.Application" \
        "src/${pn}.Domain" \
        "src/${pn}.Domain.Shared" \
        "src/${pn}.EntityFrameworkCore" \
        "src/${pn}.HttpApi.Client" \
        "src/${pn}.HttpApi.Host" \
        "src/${pn}.HttpApi" \
        "test/${pn}.Application.Tests" \
        "test/${pn}.Domain.Tests" \
        "test/${pn}.EntityFrameworkCore.Tests" \
        "test/${pn}.TestBase"
    do
        mkdir -p "$root/$proj"
        local csproj_name="${proj##*/}.csproj"
        cat > "$root/$proj/$csproj_name" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Volo.Abp.Core" Version="10.3.0" />
  </ItemGroup>
</Project>
EOF
    done

    # Application module file (vanilla shape) — for the DependsOn helper.
    cat > "$root/src/${pn}.Application/${pn}ApplicationModule.cs" <<EOF
using Volo.Abp.Modularity;
using Volo.Abp.AutoMapper;
using Microsoft.Extensions.DependencyInjection;

namespace ${pn};

[DependsOn(
    typeof(${pn}DomainModule),
    typeof(AbpAutoMapperModule)
    )]
public class ${pn}ApplicationModule : AbpModule
{
    public override void ConfigureServices(ServiceConfigurationContext context)
    {
    }
}
EOF
    # Inject an AutoMapper PackageReference so the swap helper has work.
    sed -i.bak 's|<PackageReference Include="Volo.Abp.Core" Version="10.3.0" />|<PackageReference Include="Volo.Abp.AutoMapper" Version="10.3.0" />\n    <PackageReference Include="Volo.Abp.Core" Version="10.3.0" />|' \
        "$root/src/${pn}.Application/${pn}.Application.csproj"
    rm -f "$root/src/${pn}.Application/${pn}.Application.csproj.bak"

    # Host module + Program.cs + appsettings.json (for marker injection).
    cat > "$root/src/${pn}.HttpApi.Host/${pn}HttpApiHostModule.cs" <<EOF
using Microsoft.AspNetCore.Builder;
using Volo.Abp.Modularity;

namespace ${pn};

public class ${pn}HttpApiHostModule : AbpModule
{
    public override void ConfigureServices(ServiceConfigurationContext context)
    {
        var configuration = context.Services.GetConfiguration();
    }

    public override void OnApplicationInitialization(ApplicationInitializationContext context)
    {
        var app = context.GetApplicationBuilder();
        app.UseRouting();
    }
}
EOF
    cat > "$root/src/${pn}.HttpApi.Host/Program.cs" <<EOF
using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;

public class Program
{
    public static async Task<int> Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);
        var app = builder.Build();
        await app.RunAsync();
        return 0;
    }
}
EOF
    cat > "$root/src/${pn}.HttpApi.Host/appsettings.json" <<'EOF'
{
  "App": {
    "SelfUrl": "https://localhost:44326"
  }
}
EOF
}

# Sources scaffold.sh in a non-main mode so we can call phase functions
# directly. Sets the env so phase_apply_overlays runs as if in real mode.
_load_phase_apply_overlays() {
    local target="$1" pn="$2"
    export PROJECT_NAME="$pn"
    export PROJECT_NAME_LOWER="${pn,,}"
    export PROJECTNAME_UPPER="${pn^^}"
    export TARGET_DIR="$target"
    export ABP_VERSION=10.3.0
    export IF_UI_ANGULAR=1 IF_UI_MVC=0 IF_UI_BLAZOR=0 IF_UI_BLAZOR_SERVER=0 IF_UI_NONE=0
    export IF_DB_EF=1 IF_DB_MONGODB=0 IF_MULTI_TENANCY=0 IF_TIERED=0
    # Other exports needed by the scaffold libs.
    export GITHUB_OWNER=codarteinc HCP_ORG=codarteinc
    export DBMS=postgresql UI=angular DB_PROVIDER=ef DEFAULT_CULTURE=en
    export MULTI_TENANCY=false TIERED=false
    export HETZNER_LOCATION=hel1 HETZNER_SERVER_TYPE=cx22 CLOUDFLARE_ZONE=example.com
    # Force re-source.
    unset __LH_LOG_SH_SOURCED __LH_SUBSTITUTE_SH_SOURCED __LH_DOTNET_OVERLAY_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/substitute.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/substitute.sh"
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/dotnet-overlay.sh"
    # Define LIB_DIR + TEMPLATE_DIR for the function.
    LIB_DIR="${SCAFFOLD_ROOT}/lib"
    TEMPLATE_DIR="${SCAFFOLD_ROOT}/template"
    DRY_RUN=0
    CURRENT_PHASE=""
    STEP_TOTAL=1
    STEP=0
    # Provide the _phase_start helper that scaffold.sh's main script defines.
    _phase_start() {
        CURRENT_PHASE="$1"
        STEP=$((STEP + 1))
        log_step "$STEP" "$STEP_TOTAL" "$CURRENT_PHASE"
    }
}

# Pull the phase_apply_overlays function definition out of scaffold.sh.
# We can't source scaffold.sh directly because its top-level main()
# call would run the entire pipeline. Extract just the function with awk.
_extract_function() {
    local func="$1" file="$2"
    awk -v f="$func" '
        $0 ~ "^"f"\\(\\)" { in_func = 1 }
        in_func { print }
        in_func && /^\}[[:space:]]*$/ { exit }
    ' "$file"
}

setup() {
    TMP="$(mktemp -d -t overlay-app-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    mkdir -p "$TARGET"
    _seed_fake_abp_new "$TARGET" SmokeApp
}

teardown() {
    rm -rf "$TMP"
}

@test "phase_apply_overlays writes overlay files to TARGET_DIR" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    run phase_apply_overlays
    [ "$status" -eq 0 ]
    # Root files present.
    [ -f "$TARGET/common.props" ]
    [ -f "$TARGET/global.json" ]
    [ -f "$TARGET/.editorconfig" ]
    [ -f "$TARGET/.gitignore" ]
    [ -f "$TARGET/.dockerignore" ]
    [ -f "$TARGET/.abpignore" ]
    [ -f "$TARGET/.markdownlint.json" ]
    [ -f "$TARGET/Directory.DotSettings" ]
    [ -f "$TARGET/NuGet.Config" ]
    # Project-rename verified.
    [ -f "$TARGET/src/SmokeApp.Application/SmokeAppApplicationMappers.cs" ]
    [ -f "$TARGET/src/SmokeApp.Domain/SmokeAppConsts.cs" ]
    [ -f "$TARGET/test/SmokeApp.TestBase/SmokeAppTestBase.cs" ]
    # NOTE: SmokeAppTestDataSeedContributor.cs is NOT shipped by this
    # overlay — ABP CLI 3.0.2+ ships an equivalent file under
    # test/SmokeApp.TestBase/SmokeAppTestDataBuilder.cs which would
    # collide. Operators extend ABP's file directly.
    # No leftover .tmpl or .markers files.
    [ ! -f "$TARGET/.gitignore.tmpl" ]
    [ ! -f "$TARGET/.dockerignore.tmpl" ]
    ! find "$TARGET" -name '*.markers' | grep -q .
    # ${PROJECT_NAME} token resolved everywhere.
    ! grep -rE '\$\{PROJECT_NAME[^}]*\}' "$TARGET/src" "$TARGET/test" \
        2>/dev/null
}

@test "phase_apply_overlays sets RootNamespace on every csproj under src/ + test/" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    # All 12 LinkHub-canonical csproj should carry the namespace.
    n=$(grep -RIl '<RootNamespace>SmokeApp</RootNamespace>' \
        "$TARGET/src" "$TARGET/test" 2>/dev/null | wc -l)
    [ "$n" -ge 12 ]
}

@test "phase_apply_overlays swaps AutoMapper -> Mapperly on Application csproj" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.Application/SmokeApp.Application.csproj"
    ! grep -q 'Volo.Abp.AutoMapper' "$f"
    grep -q 'Volo.Abp.Mapperly' "$f"
}

@test "phase_apply_overlays adds AbpMapperlyModule DependsOn to application module" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.Application/SmokeAppApplicationModule.cs"
    grep -q 'typeof(AbpMapperlyModule)' "$f"
    grep -qxF 'using Volo.Abp.Mapperly;' "$f"
}

@test "phase_apply_overlays injects all expected ScaffoldBlock marker pairs into host module" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs"
    for block in otel health-endpoints csp-middleware hsts openiddict-cert secrets-json-loader; do
        grep -q "<ScaffoldBlock name=\"${block}\">" "$f"
        grep -q '</ScaffoldBlock>' "$f"
    done
}

@test "phase_apply_overlays injects all expected ScaffoldBlock marker pairs into Program.cs" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/Program.cs"
    for block in serilog-bootstrap fwd-headers cookie-antiforgery-cors production-fail-fast; do
        grep -q "<ScaffoldBlock name=\"${block}\">" "$f"
    done
}

@test "phase_apply_overlays injects all expected ScaffoldBlock sentinel pairs into appsettings.json" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/appsettings.json"
    grep -q '"//scaffold-block-serilog-config-start"' "$f"
    grep -q '"//scaffold-block-csp-defaults-start"' "$f"
    grep -q '"//scaffold-block-serilog-config-end"' "$f"
    grep -q '"//scaffold-block-csp-defaults-end"' "$f"
    if command -v python3 >/dev/null; then
        python3 -c "import json,sys;json.load(open('$f'))"
    fi
}

@test "phase_apply_overlays is idempotent — second run produces byte-identical files" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    h1=$(find "$TARGET" -type f -exec sha256sum {} + | sort | sha256sum)
    phase_apply_overlays
    h2=$(find "$TARGET" -type f -exec sha256sum {} + | sort | sha256sum)
    [ "$h1" = "$h2" ]
}

@test "phase_apply_overlays emits an [overlay-dotnet] log line per written file" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    run phase_apply_overlays
    [ "$status" -eq 0 ]
    # At least one [overlay-dotnet] writing log for each root file we ship.
    echo "$output" | grep -q '\[overlay-dotnet\] writing common.props'
    echo "$output" | grep -q '\[overlay-dotnet\] writing global.json'
    echo "$output" | grep -q '\[overlay-dotnet\] writing .editorconfig'
    echo "$output" | grep -q '\[overlay-dotnet\] writing src/SmokeApp.Domain/SmokeAppConsts.cs'
    echo "$output" | grep -q '\[overlay-dotnet\] merged ScaffoldBlock markers'
}

@test "Angular ON: .gitignore.tmpl strips MVC/Blazor blocks but keeps environment.local.ts" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/.gitignore"
    grep -q 'environment.local.ts' "$f"
    ! grep -q 'SmokeApp.Blazor.Server/Logs' "$f"
    ! grep -q 'SmokeApp.Web/Logs' "$f"
    # Project-substituted log paths present.
    grep -q 'SmokeApp.HttpApi.Host/Logs' "$f"
}

@test "MVC ON: .gitignore.tmpl drops Angular block and adds MVC log dirs" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    # Override AFTER _load_phase_apply_overlays (which forces a default Angular).
    export IF_UI_ANGULAR=0 IF_UI_MVC=1
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/.gitignore"
    ! grep -q 'environment.local.ts' "$f"
    grep -q 'SmokeApp.Web/Logs' "$f"
}
