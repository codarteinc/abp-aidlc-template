#!/usr/bin/env bats
# tests/standalone_phases.bats — assert that phase_recommend and
# phase_confirm log their no-op markers when scaffold.sh runs in
# standalone (config-file) mode.

load _helper

@test "phase_recommend is a no-op in standalone mode" {
    run run_scaffold_dry_abp_new
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'standalone mode — recommendation engine skipped'
}

@test "phase_confirm is a no-op in standalone mode" {
    run run_scaffold_dry_abp_new
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'standalone mode — confirmation prompts handled by /scaffold-app skill'
}
