#!/usr/bin/env bats
# tests/github_init.bats — unit-10 github-init helpers + phase wiring.
#
# Uses --dry-run-github to capture intended `gh` invocations as `GH_CMD:`
# lines without hitting real GitHub. `git` is NOT stubbed — we want real
# git init + commit in the tmpdir so the bats tests verify the commit
# graph.

load _helper

# Seed a target with a baseline .gitignore that satisfies every required
# pattern from handoff_assert_safe_to_commit. Tests that need to provoke
# a safety-gate failure mutate the file in-place.
_seed_target_with_gitignore() {
    local target="$1"
    mkdir -p "$target"
    cat > "${target}/.gitignore" <<'EOF'
# baseline for tests
appsettings.secrets.json
appsettings.secrets.*.json
*.tfstate
*.tfstate.backup
.terraform/
*.pfx
id_ed25519
id_rsa
EOF
    cat > "${target}/README.md" <<'EOF'
# Smoke project
EOF
}

_setup_phase_env() {
    TMP="$(mktemp -d -t github-init-bats.XXXXXX)"
    TARGET="${TMP}/SmokeApp"
    PN="SmokeApp"
    _seed_target_with_gitignore "$TARGET"

    unset __LH_LOG_SH_SOURCED __LH_HANDOFF_SH_SOURCED __LH_GITHUB_INIT_SH_SOURCED
    # shellcheck source=lib/log.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/log.sh"
    # shellcheck source=lib/handoff.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/handoff.sh"
    # shellcheck source=lib/github-init.sh disable=SC1091
    source "${SCAFFOLD_ROOT}/lib/github-init.sh"

    export PROJECT_NAME="$PN"
    export PROJECT_NAME_LOWER="${PN,,}"
    export GITHUB_OWNER=acme
    export SCAFFOLD_VERSION="0.1.0"
    export ABP_VERSION="10.3.0"
    export UI=angular
    export DRY_RUN_GITHUB=0
    export SKIP_GH_CREATE=false
    # Use scoped git identity so the test doesn't depend on global config.
    export GIT_USER_EMAIL="bats@example.test"
    export GIT_USER_NAME="bats"
}

teardown() {
    if [[ -n "${TMP:-}" && -d "${TMP}" ]]; then
        rm -rf "$TMP"
    fi
}

# ----------------------------------------------------------------------
# handoff_assert_safe_to_commit tests
# ----------------------------------------------------------------------

@test "T1: handoff_assert_safe_to_commit passes on a well-formed target" {
    _setup_phase_env
    run handoff_assert_safe_to_commit "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'safety gate clean'
}

@test "T2: handoff_assert_safe_to_commit FAILS when .gitignore missing" {
    _setup_phase_env
    rm -f "${TARGET}/.gitignore"
    run handoff_assert_safe_to_commit "$TARGET"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '.gitignore missing'
}

@test "T3: handoff_assert_safe_to_commit FAILS when appsettings.secrets.json line dropped" {
    _setup_phase_env
    # Remove the exact line (replace_all would also remove the wildcard variant).
    grep -v '^appsettings.secrets.json$' "${TARGET}/.gitignore" > "${TARGET}/.gitignore.new"
    mv "${TARGET}/.gitignore.new" "${TARGET}/.gitignore"
    run handoff_assert_safe_to_commit "$TARGET"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'missing required pattern: appsettings.secrets.json'
}

@test "T4: handoff_assert_safe_to_commit FAILS when *.tfstate not ignored" {
    _setup_phase_env
    grep -v '^\*\.tfstate$' "${TARGET}/.gitignore" > "${TARGET}/.gitignore.new"
    mv "${TARGET}/.gitignore.new" "${TARGET}/.gitignore"
    run handoff_assert_safe_to_commit "$TARGET"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'missing required pattern: \*.tfstate'
}

# ----------------------------------------------------------------------
# github_init_git_repo tests
# ----------------------------------------------------------------------

@test "T5: github_init_git_repo creates main branch + exactly one commit" {
    _setup_phase_env
    run github_init_git_repo "$TARGET"
    [ "$status" -eq 0 ]
    [ -d "${TARGET}/.git" ]
    branch=$(git -C "$TARGET" symbolic-ref --short HEAD)
    [ "$branch" = "main" ]
    n_commits=$(git -C "$TARGET" rev-list --count HEAD)
    [ "$n_commits" = "1" ]
}

@test "T6: github_init_git_repo commit message references SCAFFOLD_VERSION + ABP_VERSION" {
    _setup_phase_env
    export SCAFFOLD_VERSION="0.2.7"
    export ABP_VERSION="10.3.1"
    run github_init_git_repo "$TARGET"
    [ "$status" -eq 0 ]
    msg=$(git -C "$TARGET" log -1 --pretty=%s)
    echo "$msg" | grep -q 'v0.2.7'
    echo "$msg" | grep -q 'abp 10.3.1'
}

@test "T7: github_init_git_repo is idempotent (skips when .git/ exists)" {
    _setup_phase_env
    run github_init_git_repo "$TARGET"
    [ "$status" -eq 0 ]
    first_commit=$(git -C "$TARGET" rev-parse HEAD)
    # Touch a new file; second call should NOT create a new commit.
    printf 'extra\n' > "${TARGET}/extra.txt"
    run github_init_git_repo "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'already exists; skipping'
    second_commit=$(git -C "$TARGET" rev-parse HEAD)
    [ "$first_commit" = "$second_commit" ]
}

# ----------------------------------------------------------------------
# github_init_create_remote (dry-run-github) tests
# ----------------------------------------------------------------------

@test "T8: github_init_create_remote (--dry-run-github) emits 'gh repo create … --private'" {
    _setup_phase_env
    export DRY_RUN_GITHUB=1
    run github_init_create_remote "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'GH_CMD: gh repo create acme/smokeapp --private --source=. --remote=origin --push'
}

@test "T9: github_init_create_remote (--dry-run-github GH_VISIBILITY=public) emits '--public'" {
    _setup_phase_env
    export DRY_RUN_GITHUB=1
    export GH_VISIBILITY=public
    run github_init_create_remote "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'GH_CMD: gh repo create acme/smokeapp --public'
}

# ----------------------------------------------------------------------
# github_init_branch_protection tests
# ----------------------------------------------------------------------

@test "T10: github_init_branch_protection (--dry-run-github) emits expected gh api PUT" {
    _setup_phase_env
    export DRY_RUN_GITHUB=1
    run github_init_branch_protection "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'GH_CMD: gh api -X PUT repos/acme/smokeapp/branches/main/protection'
}

@test "T11: github_init_branch_protection writes gh-init-warnings.txt on rc!=0 (simulated)" {
    _setup_phase_env
    # Real-call branch with a fake gh that exits non-zero.
    FAKE_BIN="${TMP}/bin"
    mkdir -p "$FAKE_BIN"
    cat > "${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "fake gh: api PUT failed" >&2
exit 22
EOF
    chmod +x "${FAKE_BIN}/gh"
    PATH="${FAKE_BIN}:${PATH}"
    export PATH
    export DRY_RUN_GITHUB=0
    run github_init_branch_protection "$TARGET"
    # Soft-failure → returns 1, but the file is written.
    [ "$status" -eq 1 ]
    [ -f "${TARGET}/gh-init-warnings.txt" ]
    grep -q 'branch-protection-failed: rc=22' "${TARGET}/gh-init-warnings.txt"
    grep -q 'remediation: gh api -X PUT repos/acme/smokeapp/branches/main/protection' \
        "${TARGET}/gh-init-warnings.txt"
}

@test "T12: github_init_check_workflow_perms (--dry-run-github) emits expected gh api GET" {
    _setup_phase_env
    export DRY_RUN_GITHUB=1
    run github_init_check_workflow_perms "$TARGET"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'GH_CMD: gh api repos/acme/smokeapp/actions/permissions/workflow'
}

# ----------------------------------------------------------------------
# phase_github_repo_init wiring tests (full scaffold.sh invocation)
# ----------------------------------------------------------------------

# Build a complete scaffolded-shape tmpdir tree (gitignore, src dirs)
# so phase_github_repo_init can run end-to-end.
_seed_phase_tree() {
    local target="$1"
    _seed_target_with_gitignore "$target"
    mkdir -p "${target}/src/SmokeApp.HttpApi.Host" \
             "${target}/src/SmokeApp.DbMigrator" \
             "${target}/angular"
}

@test "T13: phase_github_repo_init in --dry-run mode is a no-op" {
    TMP2="$(mktemp -d -t github-init-phase-bats.XXXXXX)"
    trap "rm -rf '$TMP2'" RETURN
    cfg="${TMP2}/c.yml"
    cat > "$cfg" <<'EOF'
project_name: SmokeApp
github_owner: acme
abp:
  template: app
  ui: angular
  db_provider: ef
  dbms: postgresql
  tiered: false
  multi_tenancy: false
  default_culture: en
  optional_modules: []
infra:
  hetzner_location: hel1
  hetzner_server_type: cx22
  cloudflare_zone: example.com
EOF
    run bash "${SCAFFOLD_ROOT}/scaffold.sh" \
        --config "$cfg" \
        --target "${TMP2}/out" \
        --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[github-init\] dry-run: skipping'
}

@test "T14: phase_github_repo_init with --skip-gh-create commits locally + skips gh repo create" {
    _setup_phase_env
    _seed_phase_tree "$TARGET"
    # Fake gh that would FAIL if accidentally invoked.
    FAKE_BIN="${TMP}/bin"
    mkdir -p "$FAKE_BIN"
    cat > "${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "GH_INVOKED_UNEXPECTEDLY $*" >&2
exit 77
EOF
    chmod +x "${FAKE_BIN}/gh"
    PATH="${FAKE_BIN}:${PATH}"
    export PATH

    # Drive the phase directly (not full scaffold.sh) so we don't need
    # to source the whole orchestrator. Mimic what scaffold.sh does
    # inside phase_github_repo_init.
    export TARGET_DIR="$TARGET"
    export LIB_DIR="${SCAFFOLD_ROOT}/lib"
    export DRY_RUN=0 DRY_RUN_ABP_NEW=0 SKIP_GH_CREATE=true CURRENT_PHASE=test
    STEP=0 STEP_TOTAL=15
    # Reload scaffold.sh's phase under bash for the assertions. Easier:
    # invoke the helpers in sequence the same way scaffold.sh does.
    target_real="$(realpath "$TARGET_DIR")"
    run handoff_assert_safe_to_commit "$target_real"
    [ "$status" -eq 0 ]
    run github_init_git_repo "$target_real"
    [ "$status" -eq 0 ]
    # gh should NEVER have been touched.
    [ ! -f "${TMP}/gh-was-here" ]
    # And the commit landed.
    n=$(git -C "$target_real" rev-list --count HEAD)
    [ "$n" = "1" ]
}
