# tests/smoke/_smoke_helper.bash — shared setup/teardown for the smoke tier.
#
# Gated behind RUN_SMOKE_TESTS=1 so the suite stays opt-in. Each combo
# requires `abp`, `dotnet`, plus `node`/`yarn` (angular combos) or
# nothing-extra (mvc/none). Missing tools → bats `skip` with a clear
# message rather than fail; CI installs the missing tools before flipping
# the env var.

# shellcheck disable=SC2034  # used by tests sourcing this helper.
SCAFFOLD_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

smoke_setup() {
    [ "${RUN_SMOKE_TESTS:-0}" = "1" ] || skip "set RUN_SMOKE_TESTS=1 to run smoke tier"
    command -v abp     >/dev/null 2>&1 || skip "abp CLI not installed"
    command -v dotnet  >/dev/null 2>&1 || skip "dotnet not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    TMP="$(mktemp -d -t smoke-bats.XXXXXX)"
    export TARGET_PARENT="$TMP"
}

smoke_teardown() {
    if [ -n "${TMP:-}" ]; then
        rm -rf "$TMP"
    fi
    return 0
}

# Run scaffold.sh from a fixture; sets $PROJECT and $TARGET vars on
# success. The two --skip-* flags are operator-visible escape hatches
# wired in unit-10:
#   --skip-gh-create suppresses `gh repo create` (no real GH auth on CI)
#   --skip-post-init suppresses migration + install-libs + dotnet build
#       so the bats body controls those explicitly.
smoke_scaffold() {
    local fixture="$1"
    PROJECT=$(yq -r '.project_name' "$BATS_TEST_DIRNAME/../fixtures/smoke/$fixture")
    TARGET="$TARGET_PARENT/$PROJECT"
    bash "$SCAFFOLD_ROOT/scaffold.sh" \
        --config "$BATS_TEST_DIRNAME/../fixtures/smoke/$fixture" \
        --target "$TARGET" \
        --skip-gh-create \
        --skip-post-init
}
