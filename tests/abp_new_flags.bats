#!/usr/bin/env bats
# tests/abp_new_flags.bats — phase_abp_new flag-composition matrix.
# Uses --dry-run-abp-new to capture the assembled flag array without
# invoking the real `abp new` binary.

load _helper

@test "LinkHub baseline composes the LinkHub-known-good flags" {
    run run_scaffold_dry_abp_new
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^ABP_NEW_FLAG: SmokeApp$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: app$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: angular$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: ef$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: postgresql$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: leptonx-lite$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --skip-migration$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --skip-migrator$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --without-cms-kit$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --dont-run-install-libs$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --dont-run-bundling$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --no-multi-tenancy$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: --no-social-logins$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-gdpr$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-openiddict-admin-ui$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-audit-logging$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-file-management$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-language-management$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-text-template-management$'
    # --separate-tenant-schema MUST NOT appear in the baseline.
    ! echo "$output" | grep -q '^ABP_NEW_FLAG: --separate-tenant-schema$'
    # --tiered MUST NOT appear in the baseline.
    ! echo "$output" | grep -q '^ABP_NEW_FLAG: --tiered$'
}

@test "multi-tenancy ON + ef -> --separate-tenant-schema present" {
    run run_scaffold_dry_abp_new abp_multi_tenancy=true
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^ABP_NEW_FLAG: --separate-tenant-schema$'
    ! echo "$output" | grep -q '^ABP_NEW_FLAG: --no-multi-tenancy$'
}

@test "multi-tenancy ON + mongodb -> --separate-tenant-schema ABSENT (and --no-multi-tenancy ABSENT)" {
    run run_scaffold_dry_abp_new abp_multi_tenancy=true abp_db_provider=mongodb
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q '^ABP_NEW_FLAG: --separate-tenant-schema$'
    ! echo "$output" | grep -q '^ABP_NEW_FLAG: --no-multi-tenancy$'
}

@test "optional_modules=[file-management] -> -no-file-management ABSENT, others PRESENT" {
    run run_scaffold_dry_abp_new "abp_optional_modules=[file-management]"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q '^ABP_NEW_FLAG: -no-file-management$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-language-management$'
    echo "$output" | grep -q '^ABP_NEW_FLAG: -no-text-template-management$'
}

@test "tiered=true -> --tiered flag present" {
    run run_scaffold_dry_abp_new abp_tiered=true
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^ABP_NEW_FLAG: --tiered$'
}

@test "ABP version auto-detect picks up local abp --version" {
    # Skip when abp CLI isn't installed (CI's fast-tier bats job has no
    # Volo.Abp.Studio.Cli by design — only the slow smoke job does).
    command -v abp >/dev/null 2>&1 || skip "abp CLI not installed"
    detected="$(abp --version 2>/dev/null | head -1 | awk '{print $NF}')"
    [ -n "$detected" ]
    # Force auto-detect by unsetting the helper's ABP_VERSION default.
    unset ABP_VERSION
    run run_scaffold_dry_abp_new
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "abp version: ${detected}"
}

@test "--abp-version override wins over auto-detect" {
    tmpdir="$(mktemp -d -t scaffold-bats.XXXXXX)"
    cp "${SCAFFOLD_ROOT}/scaffold-config.example.yml" "${tmpdir}/c.yml"
    run bash "${SCAFFOLD_ROOT}/scaffold.sh" \
        --config "${tmpdir}/c.yml" \
        --target "${tmpdir}/SampleApp" \
        --abp-version 10.3.5 \
        --dry-run-abp-new
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'abp version: 10.3.5'
    echo "$output" | grep -q '^ABP_NEW_FLAG: 10.3.5$'
}
