#!/usr/bin/env bash
# lib/prompt.sh — interactive prompt helpers.
#
# Each helper writes ONLY the chosen value to stdout. Status / prompt text
# goes to stderr so callers can do `name=$(prompt_text "Name?" "Default")`.
#
# Helpers prefer `gum` when installed (https://github.com/charmbracelet/gum)
# for a nicer UX, and fall back to plain `read -p` otherwise. The fallback
# path is the contract; `gum` is purely cosmetic.

if [[ -n "${__LH_PROMPT_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_PROMPT_SH_SOURCED=1

_has_gum() {
    command -v gum >/dev/null 2>&1
}

# prompt_text "<question>" [default]
prompt_text() {
    local q="$1"
    local default="${2:-}"
    local answer
    if _has_gum; then
        if [[ -n "$default" ]]; then
            answer=$(gum input --prompt "$q > " --placeholder "$default" --value "$default")
        else
            answer=$(gum input --prompt "$q > ")
        fi
    else
        if [[ -n "$default" ]]; then
            read -r -p "$q [$default]: " answer </dev/tty
            answer="${answer:-$default}"
        else
            read -r -p "$q: " answer </dev/tty
        fi
    fi
    printf '%s\n' "$answer"
}

# prompt_choice "<question>" <opt1> <opt2> ...
prompt_choice() {
    local q="$1"
    shift
    local answer
    if _has_gum; then
        printf '%s\n' "$q" >&2
        answer=$(gum choose "$@")
    else
        printf '%s\n' "$q" >&2
        local i=1
        for opt in "$@"; do
            printf '  %d) %s\n' "$i" "$opt" >&2
            i=$((i + 1))
        done
        local pick
        while true; do
            read -r -p "Pick [1-$#]: " pick </dev/tty
            if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= $# )); then
                answer="${!pick}"
                break
            fi
            printf '  invalid selection — try again.\n' >&2
        done
    fi
    printf '%s\n' "$answer"
}

# prompt_yesno "<question>" [default y|n]
# Emits "yes" or "no" to stdout.
prompt_yesno() {
    local q="$1"
    local default="${2:-n}"
    local answer
    if _has_gum; then
        if gum confirm "$q"; then
            answer=yes
        else
            answer=no
        fi
    else
        local hint
        case "$default" in
            y|Y|yes) hint="[Y/n]" ;;
            *)       hint="[y/N]" ;;
        esac
        local reply
        read -r -p "$q $hint: " reply </dev/tty
        reply="${reply:-$default}"
        case "$reply" in
            y|Y|yes|YES) answer=yes ;;
            *)           answer=no  ;;
        esac
    fi
    printf '%s\n' "$answer"
}

# prompt_multiselect "<question>" <opt1> <opt2> ...
# Emits one selected option per line. Empty (no selection) prints nothing.
prompt_multiselect() {
    local q="$1"
    shift
    if _has_gum; then
        printf '%s\n' "$q" >&2
        gum choose --no-limit "$@"
        return
    fi
    printf '%s\n' "$q" >&2
    printf '  (enter comma-separated indices, blank for none)\n' >&2
    local i=1
    for opt in "$@"; do
        printf '  %d) %s\n' "$i" "$opt" >&2
        i=$((i + 1))
    done
    local picks
    read -r -p "Picks: " picks </dev/tty
    if [[ -z "$picks" ]]; then
        return
    fi
    IFS=',' read -r -a indices <<< "$picks"
    for idx in "${indices[@]}"; do
        # Trim whitespace.
        idx="${idx// /}"
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= $# )); then
            printf '%s\n' "${!idx}"
        fi
    done
}
