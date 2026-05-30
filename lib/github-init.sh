#!/usr/bin/env bash
# lib/github-init.sh — unit-10 github-init orchestration helpers.
#
# Sourced by scaffold.sh's `phase_github_repo_init`. Runs AFTER every
# overlay phase + the post-init phase have stamped the tree, so this
# layer can safely git init + commit + create the GitHub remote + apply
# branch protection.
#
# All gh-touching helpers honor DRY_RUN_GITHUB=1 — they print
# 'GH_CMD: <cmd>' lines to stdout and return 0 WITHOUT invoking the
# real gh CLI. git init + commit DO run under --dry-run-github (the
# bats tests want to verify the commit graph).
#
# Public entry-points:
#   github_init_git_repo             <target_real>
#       `git init -b main` + `git add -A` + initial commit. Idempotent
#       skip when <target>/.git already exists.
#
#   github_init_create_remote        <target_real>
#       `gh repo create … --source=. --remote=origin --push`. Visibility
#       from ${GH_VISIBILITY:-private}. HARD failure on rc!=0 (every
#       downstream step depends on the remote existing).
#
#   github_init_branch_protection    <target_real>
#       `gh api -X PUT … /branches/main/protection`. SOFT failure (rc=1
#       returned but caller `|| true`s it). On failure, writes a
#       gh-init-warnings.txt to the target with the remediation cmd.
#
#   github_init_check_workflow_perms <target_real>
#       Read-only `gh api … /actions/permissions/workflow` check.
#       Report-only (never fails the scaffold). Logs the remediation
#       steps when can_approve_pull_request_reviews != true.

if [[ -n "${__LH_GITHUB_INIT_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_GITHUB_INIT_SH_SOURCED=1

if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# github_init_git_repo <target_real>
github_init_git_repo() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "[github-init] target dir missing: ${target}" \
            "github_init_git_repo"
        return 1
    fi
    if [[ -d "${target}/.git" ]]; then
        log_info "[github-init] ${target}/.git already exists; skipping init+commit"
        return 0
    fi
    log_info "[github-init] git init -b main + initial commit"
    local rc=0
    local commit_msg
    commit_msg="Initial commit (scaffold abp-aidlc-template v${SCAFFOLD_VERSION:-0.1.0}; abp ${ABP_VERSION:-unknown})"
    (
        cd "$target" && \
        git init -b main >/dev/null && \
        git add -A && \
        git -c user.email="${GIT_USER_EMAIL:-noreply@scaffold.local}" \
            -c user.name="${GIT_USER_NAME:-Scaffold Tool}" \
            commit -m "$commit_msg" >/dev/null
    ) || rc=$?
    if (( rc != 0 )); then
        log_fail "[step github-init] git init + initial commit failed (rc=${rc})" \
            "git init -b main && git add -A && git commit"
        return 1
    fi
}

# github_init_create_remote <target_real>
#
# Read GH_VISIBILITY (default `private`). Under DRY_RUN_GITHUB=1, emit
# the would-run gh command and return 0 without invoking gh. Otherwise
# run `gh repo create` for real. HARD failure on non-zero rc.
github_init_create_remote() {
    local target="$1"
    if [[ -z "$target" || ! -d "$target" ]]; then
        log_fail "[github-init] target dir missing: ${target}" \
            "github_init_create_remote"
        return 1
    fi
    local visibility="${GH_VISIBILITY:-private}"
    case "$visibility" in
        public|private|internal) ;;
        *)
            log_warn "[github-init] GH_VISIBILITY=${visibility} unrecognized; defaulting to private"
            visibility=private
            ;;
    esac

    local owner="${GITHUB_OWNER}"
    local repo="${PROJECT_NAME_LOWER}"

    if (( ${DRY_RUN_GITHUB:-0} == 1 )); then
        printf 'GH_CMD: gh repo create %s/%s --%s --source=. --remote=origin --push\n' \
            "$owner" "$repo" "$visibility"
        log_info "[github-init] --dry-run-github: emitted gh repo create command"
        return 0
    fi

    log_info "[github-init] gh repo create ${owner}/${repo} --${visibility}"
    local rc=0
    ( cd "$target" && \
      gh repo create "${owner}/${repo}" \
        --"${visibility}" \
        --source=. \
        --remote=origin \
        --push ) || rc=$?
    if (( rc != 0 )); then
        log_fail "[step github-init] gh repo create failed (rc=${rc})" \
            "gh repo create ${owner}/${repo}"
        log_info "[github-init] rollback: 'gh repo delete ${owner}/${repo} --yes' + 'rm -rf ${target}'"
        return 1
    fi
}

# github_init_branch_protection <target_real>
#
# Apply LinkHub's `main` protection rules. SOFT failure — caller
# `|| true`s this so a settings hiccup doesn't kill the whole scaffold.
# Persists a gh-init-warnings.txt file with the remediation command for
# the operator when the API returns non-zero.
github_init_branch_protection() {
    local target="$1"
    local owner="${GITHUB_OWNER}"
    local repo="${PROJECT_NAME_LOWER}"

    if (( ${DRY_RUN_GITHUB:-0} == 1 )); then
        printf 'GH_CMD: gh api -X PUT repos/%s/%s/branches/main/protection\n' \
            "$owner" "$repo"
        return 0
    fi

    log_info "[github-init] applying branch protection on main"
    local rc=0
    gh api -X PUT \
        "repos/${owner}/${repo}/branches/main/protection" \
        -F required_status_checks.strict=true \
        -f 'required_status_checks.contexts[]=CICD' \
        -F enforce_admins=false \
        -F required_pull_request_reviews.required_approving_review_count=1 \
        -F restrictions=null \
        >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        log_warn "[github-init] branch protection PUT returned rc=${rc}"
        log_warn "[github-init] common causes: GitHub Free private repo (paid plan required), or admin perms missing"
        log_warn "[github-init] configure manually: Settings → Branches → Add rule for 'main'"
        # Persist a hint file for the operator.
        {
            printf 'branch-protection-failed: rc=%d\n' "$rc"
            printf 'remediation: gh api -X PUT repos/%s/%s/branches/main/protection ' "$owner" "$repo"
            printf -- '-F required_status_checks.strict=true '
            printf -- "-f required_status_checks.contexts[]=CICD "
            printf -- '-F enforce_admins=false '
            printf -- '-F required_pull_request_reviews.required_approving_review_count=1 '
            printf -- '-F restrictions=null\n'
        } > "${target}/gh-init-warnings.txt"
        return 1   # caller `|| true`s this
    fi
    log_info "[github-init] branch protection applied"
}

# github_init_check_workflow_perms <target_real>
#
# Read-only check of can_approve_pull_request_reviews. Report-only;
# never fails the scaffold.
github_init_check_workflow_perms() {
    local target="$1"
    local owner="${GITHUB_OWNER}"
    local repo="${PROJECT_NAME_LOWER}"

    if (( ${DRY_RUN_GITHUB:-0} == 1 )); then
        printf 'GH_CMD: gh api repos/%s/%s/actions/permissions/workflow\n' \
            "$owner" "$repo"
        return 0
    fi

    local can_approve=""
    can_approve=$(gh api "repos/${owner}/${repo}/actions/permissions/workflow" \
        --jq '.can_approve_pull_request_reviews' 2>/dev/null) || true
    case "$can_approve" in
        true)
            log_info "[github-init] workflow can_approve_pull_request_reviews=true (Dependabot auto-merge OK)"
            ;;
        false|"")
            log_warn "[github-init] workflow can_approve_pull_request_reviews=${can_approve:-<unknown>}"
            log_warn "[github-init] Dependabot auto-merge will FAIL with HTTP 422 until you flip this."
            log_warn "[github-init] Remediation:"
            log_warn "[github-init]   1. Org owner: Settings → Actions → General → Workflow permissions → 'Allow GitHub Actions to create and approve pull requests' = ON"
            log_warn "[github-init]   2. Then repo: same toggle at the repo level"
            log_warn "[github-init]   3. Verify: gh api repos/${owner}/${repo}/actions/permissions/workflow"
            ;;
    esac
    # Silence unused-arg warning when target isn't used in this fn.
    : "${target:-}"
    return 0
}
