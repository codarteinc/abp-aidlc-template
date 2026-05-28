#!/usr/bin/env bash
# lib/log.sh — structured operator-visible logging for scaffold.sh.
#
# Source from scaffold.sh and other lib/* files. Idempotent (re-sourcing is
# safe). Sets a global STEP_TOTAL the orchestrator updates and emits
# `[step N/M] <phase>` headers for every phase, plus info/warn/err/fail
# helpers. ANSI colors are enabled only when stdout is a TTY so CI logs
# stay clean.

# Idempotency guard so multiple `source lib/log.sh` calls don't redefine.
if [[ -n "${__LH_LOG_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_LOG_SH_SOURCED=1

# STEP_TOTAL is the denominator in `[step N/M]`. Orchestrator overrides
# at script top. Default to 0 so a stray log_step before init still
# prints something useful instead of crashing.
: "${STEP_TOTAL:=0}"

# Color setup — only when stdout is a TTY.
if [[ -t 1 ]]; then
    __LH_C_RESET=$'\033[0m'
    __LH_C_BOLD=$'\033[1m'
    __LH_C_DIM=$'\033[2m'
    __LH_C_RED=$'\033[31m'
    __LH_C_YELLOW=$'\033[33m'
    __LH_C_GREEN=$'\033[32m'
    __LH_C_CYAN=$'\033[36m'
else
    __LH_C_RESET=""
    __LH_C_BOLD=""
    __LH_C_DIM=""
    __LH_C_RED=""
    __LH_C_YELLOW=""
    __LH_C_GREEN=""
    __LH_C_CYAN=""
fi

# log_step <N> <M> <phase-name>
# Prints a structured header for the start of a phase.
log_step() {
    local n="$1"
    local m="$2"
    local phase="$3"
    printf "%b[step %s/%s]%b %b%s%b\n" \
        "${__LH_C_BOLD}${__LH_C_CYAN}" "$n" "$m" "${__LH_C_RESET}" \
        "${__LH_C_BOLD}" "$phase" "${__LH_C_RESET}"
}

log_info() {
    printf "%b[info]%b %s\n" "${__LH_C_DIM}" "${__LH_C_RESET}" "$*"
}

log_warn() {
    printf "%b[warn]%b %s\n" "${__LH_C_YELLOW}" "${__LH_C_RESET}" "$*" >&2
}

log_err() {
    printf "%b[error]%b %s\n" "${__LH_C_RED}" "${__LH_C_RESET}" "$*" >&2
}

log_ok() {
    printf "%b[ ok ]%b %s\n" "${__LH_C_GREEN}" "${__LH_C_RESET}" "$*"
}

# log_fail "<message>" "<failing-command>"
# Prints a structured failure with the offending phase + command so the
# operator can see exactly what to retry. Does NOT exit (caller decides).
log_fail() {
    local msg="$1"
    local cmd="${2:-<unspecified>}"
    printf "%b[FAIL]%b %s\n" "${__LH_C_BOLD}${__LH_C_RED}" "${__LH_C_RESET}" "$msg" >&2
    printf "       command: %s\n" "$cmd" >&2
    if [[ -n "${CURRENT_PHASE:-}" ]]; then
        printf "       phase:   %s\n" "$CURRENT_PHASE" >&2
    fi
}
