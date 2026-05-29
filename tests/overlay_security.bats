#!/usr/bin/env bats
# tests/overlay_security.bats — end-to-end test of unit-05 security overlay.
#
# Stands up a minimal abp-new-like tree, runs phase_apply_overlays followed
# by phase_apply_security_overlay, then asserts every plan §14
# success-criterion.

load _helper

# Seed a small target tree matching what abp-new produces (post unit-03
# overlay). PROJECT_NAME = $2.
_seed_fake_target() {
    local root="$1" pn="$2"
    mkdir -p "$root/src/${pn}.HttpApi.Host" "$root/src/${pn}.DbMigrator" \
        "$root/src/${pn}.Domain/Data" "$root/etc"

    # Host module shaped like ABP-default (after unit-03 RootNamespace overlay).
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
using System.Linq;
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

    # DbMigrationService at one of the two candidate paths.
    cat > "$root/src/${pn}.DbMigrator/${pn}DbMigrationService.cs" <<EOF
using System;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;

namespace ${pn}.Data;

public class ${pn}DbMigrationService
{
    private readonly IConfiguration _configuration;

    public ${pn}DbMigrationService(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    private async Task SeedDataAsync()
    {
        await Task.CompletedTask;
    }
}
EOF

    # Minimal .gitignore (post-unit-03 shape).
    cat > "$root/.gitignore" <<'EOF'
*.pfx
appsettings.secrets.json
appsettings.Development.local.json
EOF
}

# Source the security overlay helpers + drive phase_apply_security_overlay.
# Uses the SAME pattern as overlay_dotnet_application.bats.
_setup_phase_env() {
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
    unset __LH_LOG_SH_SOURCED __LH_SUBSTITUTE_SH_SOURCED \
          __LH_DOTNET_OVERLAY_SH_SOURCED __LH_SECURITY_OVERLAY_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/substitute.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/substitute.sh"
    # shellcheck source=lib/dotnet-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/dotnet-overlay.sh"
    # shellcheck source=lib/security-overlay.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/security-overlay.sh"
    LIB_DIR="${SCAFFOLD_ROOT}/lib"
    TEMPLATE_DIR="${SCAFFOLD_ROOT}/template"
    DRY_RUN=0
    DRY_RUN_ABP_NEW=0
    CURRENT_PHASE=""
    STEP_TOTAL=1
    STEP=0
    _phase_start() {
        CURRENT_PHASE="$1"
        STEP=$((STEP + 1))
        log_step "$STEP" "$STEP_TOTAL" "$CURRENT_PHASE"
    }
}

# Inject the empty marker pairs into a freshly-seeded target by re-using
# the merge_markers_into_existing helper against the .markers files that
# ship under template/. Mirrors what phase_apply_overlays does.
_inject_template_markers() {
    local target="$1" pn="$2"
    local host_mod_markers="${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.HttpApi.Host/${pn}HttpApiHostModule.cs.markers.tmp"
    # Render the markers file with {{PROJECTNAME}} -> $pn (mirrors phase_apply_overlays).
    sed "s/{{PROJECTNAME}}/${pn}/g" \
        "${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.HttpApi.Host/{{PROJECTNAME}}HttpApiHostModule.cs.markers" \
        > "$host_mod_markers"
    merge_markers_into_existing \
        "$target/src/${pn}.HttpApi.Host/${pn}HttpApiHostModule.cs" \
        "$host_mod_markers"
    rm -f "$host_mod_markers"

    merge_markers_into_existing \
        "$target/src/${pn}.HttpApi.Host/Program.cs" \
        "${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.HttpApi.Host/Program.cs.markers"

    merge_markers_into_existing \
        "$target/src/${pn}.HttpApi.Host/appsettings.json" \
        "${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.HttpApi.Host/appsettings.json.markers"
}

setup() {
    TMP="$(mktemp -d -t overlay-sec-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    _seed_fake_target "$TARGET" SmokeApp
}

teardown() {
    rm -rf "$TMP"
}

# --- Tests ----------------------------------------------------------------

@test "Program.cs rendered contains the production-fail-fast block body" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    f="$TARGET/src/SmokeApp.HttpApi.Host/Program.cs"
    grep -q 'Missing required configuration keys in Production' "$f"
    grep -q 'App:SelfUrl' "$f"
    grep -q 'App:AngularUrl' "$f"
    grep -q 'App:CorsOrigins' "$f"
    grep -q 'App:RedirectAllowedUrls' "$f"
    grep -q 'AuthServer:Authority' "$f"
    grep -q 'HostAbortedException' "$f"
    grep -q '\[SmokeApp.Config\]' "$f"
}

@test "Program.cs gets using System.Linq for the Where(...) in fail-fast block" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    f="$TARGET/src/SmokeApp.HttpApi.Host/Program.cs"
    grep -qxF 'using System.Linq;' "$f"
}

@test "appsettings.json carries csp-defaults block with Mode='report-only'" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    f="$TARGET/src/SmokeApp.HttpApi.Host/appsettings.json"
    grep -q 'report-only' "$f"
    grep -q '"Csp"' "$f"
    grep -q '"Mode"' "$f"
    grep -q '"ReportUri"' "$f"
}

@test "security overlay block insertion is idempotent (byte-identical second run)" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    h1=$(find "$TARGET" -type f -exec sha256sum {} + | sort | sha256sum)
    security_overlay_insert_blocks "$TARGET"
    h2=$(find "$TARGET" -type f -exec sha256sum {} + | sort | sha256sum)
    [ "$h1" = "$h2" ]
}

@test "host module CSP middleware block lands inside OnApplicationInitialization" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs"
    grep -q 'ContentSecurityPolicyMiddleware' "$f"
    grep -q 'UseCookiePolicy' "$f"
}

@test "openiddict-cert block lands inside PreConfigureServices not OnApplicationInitialization" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    f="$TARGET/src/SmokeApp.HttpApi.Host/SmokeAppHttpApiHostModule.cs"
    # PreConfigureServices body — from its open line to next "    }" line.
    awk '/public override void PreConfigureServices/{p=1} p{print} p && /^[[:space:]]*}[[:space:]]*$/ {exit}' \
        "$f" | grep -q 'openiddict-cert'
    # OnApplicationInitialization body — must NOT contain openiddict-cert.
    body=$(awk '/public override void OnApplicationInitialization/{p=1} p{print} p && /^[[:space:]]*}[[:space:]]*$/ {exit}' "$f")
    ! echo "$body" | grep -q 'openiddict-cert'
}

@test "admin-password fail-fast block contains all three SHA-256 hashes and the throw" {
    _setup_phase_env "$TARGET" SmokeApp
    security_overlay_merge_dbmigrator_markers "$TARGET"
    f="$TARGET/src/SmokeApp.DbMigrator/SmokeAppDbMigrationService.cs"
    [ -f "$f" ]
    # The three known-leaked SHA-256(UTF-8) hashes (1q2w3E*, Admin123!, ABP123!).
    grep -qF '60ee4b4d6802ab8c4b33b164be9a3319f08941908bfaf85c7c1ad7aedc03b822' "$f"
    grep -qF '49ca938a16af564567b77f93c6990a5d6094f15be9977f2a80dc64d965e3ad25' "$f"
    grep -qF '3eb3fe66b31e3b4d10fa70b5cad49c7112294af6ae4e476a1c405155d45aa121' "$f"
    grep -q 'Missing required configuration .App:AdminPassword.' "$f"
    grep -q 'known-leaked admin password' "$f"
    grep -q 'throw new System.InvalidOperationException' "$f"
}

@test "admin-password fail-fast block falls back to Domain/Data/ path if DbMigrator empty" {
    _setup_phase_env "$TARGET" SmokeApp
    rm "$TARGET/src/SmokeApp.DbMigrator/SmokeAppDbMigrationService.cs"
    # Drop the same file under the fallback path (per LinkHub canonical).
    cat > "$TARGET/src/SmokeApp.Domain/Data/SmokeAppDbMigrationService.cs" <<EOF
using System;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
namespace SmokeApp.Data;
public class SmokeAppDbMigrationService
{
    private readonly IConfiguration _configuration;
    public SmokeAppDbMigrationService(IConfiguration configuration) { _configuration = configuration; }
    private async Task SeedDataAsync()
    {
        await Task.CompletedTask;
    }
}
EOF
    security_overlay_merge_dbmigrator_markers "$TARGET"
    f="$TARGET/src/SmokeApp.Domain/Data/SmokeAppDbMigrationService.cs"
    grep -q 'known-leaked admin password' "$f"
}

@test "nginx security-headers fragment contains all 6 required directives" {
    fragment="${SCAFFOLD_ROOT}/overlay-blocks/unit-05/nginx-security-headers.conf"
    [ -f "$fragment" ]
    grep -q 'Content-Security-Policy-Report-Only' "$fragment"
    grep -q 'Strict-Transport-Security "max-age=2592000"' "$fragment"
    grep -q 'X-Frame-Options "DENY"' "$fragment"
    grep -q 'X-Content-Type-Options "nosniff"' "$fragment"
    grep -q 'Referrer-Policy "strict-origin-when-cross-origin"' "$fragment"
    grep -q 'location = /csp-report' "$fragment"
    # HSTS directive line must NOT include includeSubDomains or preload
    # (30-day ramp — comments about preload are fine, the directive must
    # not opt in).
    hsts_line=$(grep '^add_header Strict-Transport-Security' "$fragment")
    ! echo "$hsts_line" | grep -q 'includeSubDomains'
    ! echo "$hsts_line" | grep -q 'preload'
}

@test "generate-dev-openiddict-cert.sh ships in template/etc/ and is shellcheck clean" {
    f="${SCAFFOLD_ROOT}/template/etc/generate-dev-openiddict-cert.sh"
    [ -f "$f" ]
    if command -v shellcheck >/dev/null; then
        shellcheck -s bash "$f"
    fi
}

@test "generate-dev-openiddict-cert.sh runs end-to-end against a tmp tree" {
    if ! command -v dotnet >/dev/null; then
        skip "dotnet sdk not available"
    fi
    work="$(mktemp -d -t cert-script-bats.XXXXXX)"
    mkdir -p "$work/src/TestApp.HttpApi.Host" "$work/etc"
    # Render the template via envsubst (PROJECT_NAME-only).
    PROJECT_NAME=TestApp envsubst '${PROJECT_NAME}' \
        < "${SCAFFOLD_ROOT}/template/etc/generate-dev-openiddict-cert.sh" \
        > "$work/etc/generate-dev-openiddict-cert.sh"
    chmod +x "$work/etc/generate-dev-openiddict-cert.sh"
    OPENIDDICT_DEV_CERT_PASS=test PROJECT_NAME=TestApp \
        bash "$work/etc/generate-dev-openiddict-cert.sh"
    [ -s "$work/src/TestApp.HttpApi.Host/openiddict.pfx" ]
    rm -rf "$work"
}

@test "all 4 dev secrets templates ship and use REPLACE_ME placeholders" {
    files=(
        "${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.HttpApi.Host/appsettings.secrets.json.template"
        "${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.DbMigrator/appsettings.secrets.json.template"
        "${SCAFFOLD_ROOT}/template/src/{{PROJECTNAME}}.HttpApi.Host/appsettings.Development.local.json.template"
        "${SCAFFOLD_ROOT}/template/angular/src/environments/environment.local.ts.template"
    )
    for f in "${files[@]}"; do
        [ -f "$f" ]
        grep -q 'REPLACE_ME' "$f"
    done
}

@test "both staging-secrets templates exist with STAGING_* envsubst targets" {
    files=(
        "${SCAFFOLD_ROOT}/overlay-blocks/unit-05/staging/appsettings.secrets.staging.json.template"
        "${SCAFFOLD_ROOT}/overlay-blocks/unit-05/staging/dbmigrator.appsettings.secrets.staging.json.template"
    )
    for f in "${files[@]}"; do
        [ -f "$f" ]
        grep -q 'STAGING_' "$f"
    done
}

@test "NO plaintext leaked passwords appear in template/ or overlay-blocks/" {
    # We ship SHA-256 hashes ONLY — the plaintexts must never appear.
    ! grep -RIn -e '1q2w3E\*' -e 'Admin123!' -e 'ABP123!' \
        "${SCAFFOLD_ROOT}/template" "${SCAFFOLD_ROOT}/overlay-blocks" 2>/dev/null
}

@test "security overlay append_gitignore inserts the staging-secrets stanza idempotently" {
    _setup_phase_env "$TARGET" SmokeApp
    gi="$TARGET/.gitignore"
    security_overlay_append_gitignore "$gi"
    grep -qF 'appsettings.secrets.*.json' "$gi"
    grep -qF '!appsettings.secrets.json.template' "$gi"
    grep -qF '!appsettings.secrets.staging.json.template' "$gi"
    h1=$(sha256sum "$gi")
    security_overlay_append_gitignore "$gi"
    h2=$(sha256sum "$gi")
    [ "$h1" = "$h2" ]
}

@test "appsettings.json with csp-defaults inserted is well-formed JSON" {
    _setup_phase_env "$TARGET" SmokeApp
    _inject_template_markers "$TARGET" SmokeApp
    security_overlay_insert_blocks "$TARGET"
    f="$TARGET/src/SmokeApp.HttpApi.Host/appsettings.json"
    # Strip the sentinel-key lines (they're not valid JSON in isolation but
    # ASP.NET Core's IConfiguration tolerates them). Verify the rest is still
    # valid by removing sentinel-keyed lines.
    if command -v python3 >/dev/null; then
        # ASP.NET Core tolerates extra string keys with "//" prefix; jq/python
        # JSON parsers do too — they're just string keys. Run a strict
        # parse to confirm overall validity.
        python3 -c "import json,sys; json.load(open('$f'))"
    fi
}

@test "phase_apply_security_overlay ordering: runs AFTER phase_apply_overlays in main()" {
    out=$(awk '/^main\(\)/,/^\}/' "${SCAFFOLD_ROOT}/scaffold.sh")
    apply_line=$(echo "$out" | grep -n 'phase_apply_overlays$' | head -1 | cut -d: -f1)
    security_line=$(echo "$out" | grep -n 'phase_apply_security_overlay' | head -1 | cut -d: -f1)
    [ -n "$apply_line" ] && [ -n "$security_line" ]
    [ "$security_line" -gt "$apply_line" ]
}
