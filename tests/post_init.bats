#!/usr/bin/env bats
# tests/post_init.bats — unit-10 post-init helpers.
#
# Uses a fixture-tree approach: pre-build a minimal "scaffolded"-shape
# directory and invoke post_init_* helpers directly (NOT scaffold.sh
# end-to-end). dotnet / abp / yarn invocations are stubbed via a
# PATH-prepended fake-bin dir that emits the expected files for the
# smoke checks and exits with a configurable code.

load _helper

# Stand up an isolated tmpdir tree shaped like the post-scaffold state:
#   <root>/<ProjectName>/src/<ProjectName>.EntityFrameworkCore/
#   <root>/<ProjectName>/src/<ProjectName>.DbMigrator/
#   <root>/<ProjectName>/angular/
#   <root>/<ProjectName>/<ProjectName>.slnx
# Plus a fake-bin/ dir on PATH carrying stub dotnet/abp/yarn binaries.
_setup_post_init_env() {
    TMP="$(mktemp -d -t post-init-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    PN="SmokeApp"
    mkdir -p "$TARGET/src/${PN}.EntityFrameworkCore" \
             "$TARGET/src/${PN}.DbMigrator" \
             "$TARGET/angular"
    # Top-level solution so the smoke build has something to point at.
    cat > "${TARGET}/${PN}.slnx" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Solution />
EOF

    # Fake-bin dir. Stub dotnet/abp/yarn writes a marker file the test
    # asserts on, and exits with an env-controlled exit code.
    FAKE_BIN="${TMP}/bin"
    mkdir -p "$FAKE_BIN"
    cat > "${FAKE_BIN}/dotnet" <<'EOF'
#!/usr/bin/env bash
# Stub: dotnet ef migrations add Initial  →  writes Initial.cs
#       dotnet build <sln>                →  no-op (just an exit code)
case "$1 $2" in
    "ef migrations")
        # Locate the EF project from the -p flag and drop an Initial.cs in.
        ef_proj=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "-p" ]]; then
                ef_proj="$2"
                shift 2
                continue
            fi
            shift
        done
        # ef_proj is relative; resolve against PWD.
        mkdir -p "${ef_proj}/Migrations"
        if (( ${DOTNET_EF_WRITE_INITIAL:-1} == 1 )); then
            printf 'public partial class Initial { }\n' > "${ef_proj}/Migrations/00000000000000_Initial.cs"
        fi
        printf 'CALLED: dotnet ef migrations add Initial\n' > "${DOTNET_TRACE_FILE:-/dev/null}"
        exit "${DOTNET_EF_EXIT_CODE:-0}"
        ;;
    "build "*)
        printf 'CALLED: dotnet build %s\n' "$2" > "${DOTNET_TRACE_FILE:-/dev/null}"
        exit "${DOTNET_BUILD_EXIT_CODE:-0}"
        ;;
esac
exit 0
EOF
    chmod +x "${FAKE_BIN}/dotnet"

    cat > "${FAKE_BIN}/abp" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    install-libs)
        printf 'CALLED: abp install-libs (cwd=%s)\n' "$PWD" > "${ABP_TRACE_FILE:-/dev/null}"
        exit "${ABP_INSTALL_LIBS_EXIT_CODE:-0}"
        ;;
esac
exit 0
EOF
    chmod +x "${FAKE_BIN}/abp"

    cat > "${FAKE_BIN}/yarn" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    install)
        printf 'CALLED: yarn install (cwd=%s)\n' "$PWD" > "${YARN_TRACE_FILE:-/dev/null}"
        exit "${YARN_INSTALL_EXIT_CODE:-0}"
        ;;
esac
exit 0
EOF
    chmod +x "${FAKE_BIN}/yarn"

    PATH="${FAKE_BIN}:${PATH}"
    export PATH PN

    unset __LH_LOG_SH_SOURCED __LH_POST_INIT_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/post-init.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/post-init.sh"

    export PROJECT_NAME="$PN"
    export PROJECT_NAME_LOWER="${PN,,}"
    export ABP_TEMPLATE=app
    export ABP_DB_PROVIDER=ef
    export UI=angular
}

teardown() {
    if [[ -n "${TMP:-}" && -d "${TMP}" ]]; then
        rm -rf "$TMP"
    fi
}

# ----------------------------------------------------------------------
# post_init_run_ef_migration tests
# ----------------------------------------------------------------------

@test "T1: post_init_run_ef_migration is a no-op when db_provider=mongodb" {
    _setup_post_init_env
    export ABP_DB_PROVIDER=mongodb
    run post_init_run_ef_migration "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'skipping EF initial migration: db_provider=mongodb'
    # No Initial.cs landed.
    [ ! -f "$TARGET/src/${PN}.EntityFrameworkCore/Migrations/00000000000000_Initial.cs" ]
}

@test "T2: post_init_run_ef_migration is a no-op when template=app-nolayers" {
    _setup_post_init_env
    export ABP_TEMPLATE=app-nolayers
    run post_init_run_ef_migration "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'skipping EF initial migration: template=app-nolayers'
}

@test "T3: post_init_run_ef_migration is a no-op when EF Core proj missing" {
    _setup_post_init_env
    rm -rf "$TARGET/src/${PN}.EntityFrameworkCore"
    run post_init_run_ef_migration "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "skipping EF migration"
    # Target dir preserved (no rollback for this case).
    [ -d "$TARGET" ]
}

@test "T4: post_init_run_ef_migration calls dotnet ef + verifies Initial.cs" {
    _setup_post_init_env
    export DOTNET_TRACE_FILE="${TMP}/dotnet-trace.log"
    run post_init_run_ef_migration "$TARGET"
    [ "$status" -eq 0 ]
    # Initial.cs landed on disk.
    ls "$TARGET/src/${PN}.EntityFrameworkCore/Migrations/" | grep -q 'Initial.cs'
    # The stub was actually called.
    grep -q 'CALLED: dotnet ef migrations add Initial' "$DOTNET_TRACE_FILE"
}

@test "T5: post_init_run_ef_migration HARD-fails (rm -rf target) when dotnet ef fails" {
    _setup_post_init_env
    export DOTNET_EF_EXIT_CODE=1
    run post_init_run_ef_migration "$TARGET"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'dotnet ef migrations add Initial failed'
    # Target dir was nuked.
    [ ! -d "$TARGET" ]
}

@test "T6: post_init_run_ef_migration HARD-fails when dotnet ef succeeds but no Initial.cs" {
    _setup_post_init_env
    export DOTNET_EF_WRITE_INITIAL=0
    run post_init_run_ef_migration "$TARGET"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'dotnet ef succeeded but no \*Initial.cs found'
    [ ! -d "$TARGET" ]
}

# ----------------------------------------------------------------------
# post_init_install_libs tests
# ----------------------------------------------------------------------

@test "T7: post_init_install_libs runs abp install-libs for UI=mvc" {
    _setup_post_init_env
    export UI=mvc
    export ABP_TRACE_FILE="${TMP}/abp-trace.log"
    run post_init_install_libs "$TARGET"
    [ "$status" -eq 0 ]
    grep -q 'CALLED: abp install-libs' "$ABP_TRACE_FILE"
}

@test "T8: post_init_install_libs runs yarn install for UI=angular" {
    _setup_post_init_env
    export UI=angular
    export YARN_TRACE_FILE="${TMP}/yarn-trace.log"
    run post_init_install_libs "$TARGET"
    [ "$status" -eq 0 ]
    grep -q 'CALLED: yarn install' "$YARN_TRACE_FILE"
    grep -q "cwd=${TARGET}/angular" "$YARN_TRACE_FILE"
}

@test "T9: post_init_install_libs is no-op for UI=blazor-server" {
    _setup_post_init_env
    export UI=blazor-server
    export YARN_TRACE_FILE="${TMP}/yarn-trace.log"
    export ABP_TRACE_FILE="${TMP}/abp-trace.log"
    run post_init_install_libs "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'nothing to install'
    [ ! -f "$YARN_TRACE_FILE" ]
    [ ! -f "$ABP_TRACE_FILE" ]
}

@test "T10: post_init_install_libs soft-fails (log_warn, rc=0) on network failure" {
    _setup_post_init_env
    export UI=angular
    export YARN_INSTALL_EXIT_CODE=1
    run post_init_install_libs "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'yarn install failed'
    echo "$output" | grep -q 'operator can retry post-handoff'
    # Target dir is preserved on soft-fail.
    [ -d "$TARGET" ]
}

# ----------------------------------------------------------------------
# post_init_smoke_dotnet_build tests
# ----------------------------------------------------------------------

@test "T11: post_init_smoke_dotnet_build calls dotnet build on the .slnx" {
    _setup_post_init_env
    export DOTNET_TRACE_FILE="${TMP}/dotnet-trace.log"
    run post_init_smoke_dotnet_build "$TARGET"
    [ "$status" -eq 0 ]
    grep -q 'CALLED: dotnet build SmokeApp.slnx' "$DOTNET_TRACE_FILE"
}

@test "T12: post_init_smoke_dotnet_build HARD-fails (rm -rf target) on build failure" {
    _setup_post_init_env
    export DOTNET_BUILD_EXIT_CODE=1
    run post_init_smoke_dotnet_build "$TARGET"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'dotnet build smoke failed'
    [ ! -d "$TARGET" ]
}
