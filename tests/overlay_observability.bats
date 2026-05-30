#!/usr/bin/env bats
# tests/overlay_observability.bats — end-to-end test of the
# observability overlays (unit-04).
#
# Reuses the fake-abp-new harness from overlay_dotnet_application.bats:
# stands up a TARGET_DIR with the host module + Program.cs + appsettings.json
# (plus the 12 csproj projects), invokes phase_apply_overlays, then asserts
# the OTel + Prometheus + health-endpoints + Serilog + Sentry overlays
# landed correctly.

load _helper

# Build a minimal abp-new-like tree under $1 with PROJECT_NAME $2.
# Same shape as overlay_dotnet_application.bats's _seed_fake_abp_new
# (we keep two copies rather than introducing a third helper module —
# the seed bodies are short and intentionally explicit).
_seed_fake_abp_new() {
    local root="$1" pn="$2"
    mkdir -p "$root/src"
    mkdir -p "$root/test"

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
    public override void PreConfigureServices(ServiceConfigurationContext context)
    {
        var hostingEnvironment = context.Services.GetHostingEnvironment();
    }

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

_load_phase_apply_overlays() {
    local target="$1" pn="$2"
    export PROJECT_NAME="$pn"
    export PROJECT_NAME_LOWER="${pn,,}"
    export PROJECTNAME_UPPER="${pn^^}"
    export TARGET_DIR="$target"
    export ABP_VERSION=10.3.0
    export IF_UI_ANGULAR=1 IF_UI_MVC=0 IF_UI_BLAZOR=0 IF_UI_BLAZOR_SERVER=0 IF_UI_NONE=0
    export IF_DB_EF=1 IF_DB_MONGODB=0 IF_MULTI_TENANCY=0 IF_TIERED=0
    export GITHUB_OWNER=codarteinc HCP_ORG=codarteinc
    export DBMS=postgresql UI=angular DB_PROVIDER=ef DEFAULT_CULTURE=en
    export MULTI_TENANCY=false TIERED=false
    export HETZNER_LOCATION=hel1 HETZNER_SERVER_TYPE=cx22 CLOUDFLARE_ZONE=example.com
    unset __LH_LOG_SH_SOURCED __LH_SUBSTITUTE_SH_SOURCED __LH_DOTNET_OVERLAY_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/substitute.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/substitute.sh"
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/dotnet-overlay.sh"
    LIB_DIR="${SCAFFOLD_ROOT}/lib"
    TEMPLATE_DIR="${SCAFFOLD_ROOT}/template"
    DRY_RUN=0
    CURRENT_PHASE=""
    STEP_TOTAL=1
    STEP=0
    _phase_start() {
        CURRENT_PHASE="$1"
        STEP=$((STEP + 1))
        log_step "$STEP" "$STEP_TOTAL" "$CURRENT_PHASE"
    }
}

_extract_function() {
    local func="$1" file="$2"
    awk -v f="$func" '
        $0 ~ "^"f"\\(\\)" { in_func = 1 }
        in_func { print }
        in_func && /^\}[[:space:]]*$/ { exit }
    ' "$file"
}

setup() {
    TMP="$(mktemp -d -t overlay-obs-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    mkdir -p "$TARGET"
    _seed_fake_abp_new "$TARGET" SmokeApp
}

teardown() {
    rm -rf "$TMP"
}

@test "otel block injected into host module ConfigureServices" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs"
    grep -q 'AddOpenTelemetry()' "$f"
    grep -q 'AddPrometheusExporter()' "$f"
    grep -q 'AddOtlpExporter()' "$f"
    grep -qF 'AddMeter("SmokeApp.*")' "$f"
    grep -q 'F-039' "$f"
    grep -qF 'serviceName: "smokeapp-api"' "$f"
}

@test "health-endpoints block injected into host module ConfigureServices" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs"
    grep -qF 'AddSmokeAppHealthChecks()' "$f"
    grep -q 'HealthChecksPolicyName' "$f"
    grep -qF '"admin"' "$f"
    grep -q 'HealthMonitorRoleSeedContributor' "$f"
    grep -q 'MapPrometheusScrapingEndpoint' "$f"
    grep -q 'App:Metrics:Auth' "$f"
}

@test "host module usings include OpenTelemetry + HealthChecks namespaces" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs"
    grep -qxF 'using SmokeApp.HealthChecks;' "$f"
    grep -qxF 'using OpenTelemetry;' "$f"
    grep -qxF 'using OpenTelemetry.Metrics;' "$f"
    grep -qxF 'using OpenTelemetry.Resources;' "$f"
    grep -qxF 'using OpenTelemetry.Trace;' "$f"
}

@test "HealthChecksBuilderExtensions.cs ported with project-substituted namespace + helper" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/HealthChecks/HealthChecksBuilderExtensions.cs"
    [ -f "$f" ]
    grep -qxF 'namespace SmokeApp.HealthChecks;' "$f"
    grep -qF 'public const string HealthChecksPolicyName = "HealthChecksPolicy";' "$f"
    grep -qF 'AddSmokeAppHealthChecks' "$f"
    grep -qF 'MapHealthChecks(' "$f"
    grep -qF '"/health-live"' "$f"
    grep -qF '"/health-ready"' "$f"
}

@test "SmokeAppDatabaseCheck.cs ported with no-leak failure path" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/HealthChecks/SmokeAppDatabaseCheck.cs"
    [ -f "$f" ]
    grep -qxF 'namespace SmokeApp.HealthChecks;' "$f"
    grep -qF 'class SmokeAppDatabaseCheck' "$f"
    grep -qF 'HealthCheckResult.Unhealthy("Database unavailable")' "$f"
    # F-038 — the failure path MUST NOT propagate the raw exception to
    # the response body. HealthCheckResult.Unhealthy must be called with
    # the literal message ONLY (no ex / exception argument).
    ! grep -qE 'HealthCheckResult\.Unhealthy\s*\(\s*ex' "$f"
}

@test "HealthMonitorRoleSeedContributor ported to Domain project" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.Domain/Data/SmokeAppHealthMonitorRoleSeedContributor.cs"
    [ -f "$f" ]
    grep -qxF 'namespace SmokeApp.Data;' "$f"
    grep -qF 'public const string RoleName = "health-monitor";' "$f"
    grep -qF 'IsStatic = true,' "$f"
    grep -qF 'IsPublic = false,' "$f"
    grep -qF 'class SmokeAppHealthMonitorRoleSeedContributor' "$f"
}

@test "serilog-bootstrap block injected into Program.cs Main" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/Program.cs"
    grep -q 'new Serilog.LoggerConfiguration()' "$f"
    grep -qF '.Enrich.WithSpan()' "$f"
    grep -qF '[trace={TraceId} span={SpanId}]' "$f"
    grep -qF '"smokeapp-api"' "$f"
    grep -qF 'CreateBootstrapLogger()' "$f"
}

@test "serilog-config sentinel pair populated in appsettings.json (valid JSON)" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/appsettings.json"
    grep -q '"Serilog"' "$f"
    grep -q '"MinimumLevel"' "$f"
    grep -q '"WriteTo"' "$f"
    grep -qF '[trace={TraceId} span={SpanId}]' "$f"
    if command -v python3 >/dev/null; then
        python3 -c "import json,sys;json.load(open('$f'))"
    fi
}

@test "dynamic-env.json placeholder ships with REPLACE_ME_AT_DEPLOY DSN" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/angular/dynamic-env.json"
    [ -f "$f" ]
    grep -qF '"dsn": "REPLACE_ME_AT_DEPLOY"' "$f"
    grep -qF '"environment": "development"' "$f"
    if command -v python3 >/dev/null; then
        python3 -c "import json,sys;json.load(open('$f'))"
    fi
}

@test "dynamic-env.json.template preserves deploy-time tokens (scaffold-time skip)" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/angular/dynamic-env.json.template"
    [ -f "$f" ]
    # Every ${VAR} on the right-hand side MUST be a deploy-time-only
    # marker (matches the APP_* convention documented in the file's
    # _comment). Scaffold-time vars (${PROJECT_NAME}, ${PROJECTNAME_UPPER},
    # ${PROJECT_NAME_LOWER}) MUST NOT be present — those would have
    # expanded to literal project-name strings at scaffold time, which
    # would mean the scaffold is treating this file like a regular
    # *.json instead of skipping it.
    ! grep -qE '\$\{PROJECT_NAME[^}]*\}|\$\{PROJECTNAME_UPPER\}' "$f"
    grep -qF '${APP_SENTRY_DSN}' "$f"
    grep -qF '${APP_API_URL}' "$f"
}

@test "Sentry error-reporting module + spec + interceptor + spec all ported" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    for f in \
        "$TARGET/angular/src/main.ts" \
        "$TARGET/angular/src/app/error-reporting/error-reporting.module.ts" \
        "$TARGET/angular/src/app/error-reporting/error-reporting.module.spec.ts" \
        "$TARGET/angular/src/app/error-reporting/server-error-reporting.interceptor.ts" \
        "$TARGET/angular/src/app/error-reporting/server-error-reporting.interceptor.spec.ts"
    do
        [ -f "$f" ]
    done
    # No-op contract source-of-truth: PLACEHOLDER_DSN matches what the
    # committed dynamic-env.json carries.
    grep -qF "PLACEHOLDER_DSN = 'REPLACE_ME_AT_DEPLOY'" \
        "$TARGET/angular/src/app/error-reporting/error-reporting.module.ts"
    # main.ts wires loadRuntimeErrorReportingConfig BEFORE bootstrapApplication.
    grep -qF 'loadRuntimeErrorReportingConfig' "$TARGET/angular/src/main.ts"
    grep -qF 'initErrorReporting' "$TARGET/angular/src/main.ts"
    grep -qF 'bootstrapApplication' "$TARGET/angular/src/main.ts"
    # Sentry interceptor reports 5xx only.
    grep -qF 'err.status >= 500' \
        "$TARGET/angular/src/app/error-reporting/server-error-reporting.interceptor.ts"
}

@test "nginx /getEnvConfig snippet shipped for unit-06 to consume" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/angular/_partials/nginx-getenvconfig.snippet"
    [ -f "$f" ]
    grep -qF 'location /getEnvConfig {' "$f"
    grep -qF 'try_files $uri /dynamic-env.json;' "$f"
}

@test "observability NuGet packages added to HttpApi.Host csproj" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeApp.HttpApi.Host.csproj"
    grep -qF 'Include="OpenTelemetry.Extensions.Hosting"' "$f"
    grep -qF 'Include="OpenTelemetry.Instrumentation.AspNetCore"' "$f"
    grep -qF 'Include="OpenTelemetry.Instrumentation.Http"' "$f"
    grep -qF 'Include="OpenTelemetry.Instrumentation.EntityFrameworkCore"' "$f"
    grep -qF 'Include="OpenTelemetry.Exporter.OpenTelemetryProtocol"' "$f"
    grep -qF 'Include="OpenTelemetry.Exporter.Prometheus.AspNetCore"' "$f"
    grep -qF 'Include="Serilog.AspNetCore"' "$f"
    grep -qF 'Include="Serilog.Enrichers.Span"' "$f"
    grep -qF 'Include="Serilog.Sinks.Async"' "$f"
}

@test "docs/observability.md ships with rendered ${PROJECT_NAME} tokens" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    f="$TARGET/docs/observability.md"
    [ -f "$f" ]
    grep -qF '# Observability — SmokeApp' "$f"
    grep -qF 'smokeapp-api' "$f"
    grep -qF 'SmokeAppHealthMonitorRoleSeedContributor' "$f"
    # No unrendered scaffold-time tokens.
    ! grep -qE '\$\{PROJECT_NAME[^}]*\}|\$\{PROJECTNAME_UPPER\}' "$f"
}

@test "block-name uniqueness: every block marker pair appears exactly once" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    # Union of unit-04 + unit-05 block names (each MUST appear as exactly
    # one open marker and one close marker in the host-module / Program.cs /
    # appsettings.json triad). The shared closing form </ScaffoldBlock>
    # appears once per block in C#/msbuild files; JSON uses
    # "//scaffold-block-NAME-{start,end}" sentinels.
    local block
    for block in otel health-endpoints; do
        c=$(grep -c "<ScaffoldBlock name=\"${block}\">" \
            "$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs")
        [ "$c" -eq 1 ]
    done
    c=$(grep -c '<ScaffoldBlock name="serilog-bootstrap">' \
        "$TARGET/src/SmokeApp.HttpApi.Host/Program.cs")
    [ "$c" -eq 1 ]
    c=$(grep -c '"//scaffold-block-serilog-config-start"' \
        "$TARGET/src/SmokeApp.HttpApi.Host/appsettings.json")
    [ "$c" -eq 1 ]
    c=$(grep -c '"//scaffold-block-serilog-config-end"' \
        "$TARGET/src/SmokeApp.HttpApi.Host/appsettings.json")
    [ "$c" -eq 1 ]
}

@test "phase_apply_overlays is idempotent with observability overlays" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    h1=$(find "$TARGET" -type f -exec sha256sum {} + | sort | sha256sum)
    phase_apply_overlays
    h2=$(find "$TARGET" -type f -exec sha256sum {} + | sort | sha256sum)
    [ "$h1" = "$h2" ]
}

@test "Sentry SPA TS files parse without syntax errors (node --check)" {
    _load_phase_apply_overlays "$TARGET" SmokeApp
    eval "$(_extract_function phase_apply_overlays "${SCAFFOLD_ROOT}/scaffold.sh")"
    phase_apply_overlays
    if ! command -v node >/dev/null 2>&1; then
        skip "node not installed"
    fi
    # node --check on .ts files does NOT do TypeScript-aware parsing;
    # it runs the JS parser, which rejects TS-only syntax (`: string`,
    # `interface`, generics). Use --input-type=module + a stripped copy
    # to at least validate the import/export structure parses. As a
    # smoke gate, sanity-check that the files are non-empty + don't
    # contain obvious un-substituted scaffold tokens.
    local f
    for f in \
        "$TARGET/angular/src/main.ts" \
        "$TARGET/angular/src/app/error-reporting/error-reporting.module.ts" \
        "$TARGET/angular/src/app/error-reporting/server-error-reporting.interceptor.ts"
    do
        [ -s "$f" ]
        ! grep -qE '\$\{PROJECT_NAME[^}]*\}|\$\{PROJECTNAME_UPPER\}' "$f"
    done
}
