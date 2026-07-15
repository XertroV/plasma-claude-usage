#!/usr/bin/env bash
# Discover AI provider auth profiles under $HOME and emit a JSON array to stdout.
set -uo pipefail

HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}"
HOME="${HOME:-/}"

# Record: inode|prefer_real_dir(0/1)|path_len|provider|profileKey|configDir|credPath|isFlatFile
CANDIDATES=()

cred_inode() {
    local path="$1"
    stat -c '%d:%i' "$path" 2>/dev/null || echo ""
}

canonical_path() {
    readlink -f "$1" 2>/dev/null || echo "$1"
}

dir_is_symlink() {
    [[ -L "$1" ]]
}

add_candidate() {
    local provider="$1"
    local config_dir="$2"
    local cred_path="$3"
    local is_flat="$4"
    local profile_key="$5"

    [[ -f "$cred_path" ]] || return 0

    local canon_cred
    canon_cred="$(canonical_path "$cred_path")"
    [[ -n "$canon_cred" && -f "$canon_cred" ]] || return 0

    local inode prefer_real path_len
    inode="$(cred_inode "$canon_cred")"
    [[ -n "$inode" ]] || return 0

    if dir_is_symlink "$config_dir"; then
        prefer_real=0
    else
        prefer_real=1
    fi
    path_len=${#canon_cred}

    CANDIDATES+=("${inode}|${prefer_real}|${path_len}|${provider}|${profile_key}|${config_dir}|${canon_cred}|${is_flat}")
}

extract_dir_profile_key() {
    local base="$1"
    local dirname="$2"

    local dotbase=".${base}"
    if [[ "$dirname" == "$dotbase" ]]; then
        echo ""
    elif [[ "$dirname" == "${dotbase}-"* ]]; then
        echo "${dirname#${dotbase}-}"
    else
        echo "${dirname#.}"
    fi
}

scan_provider_dirs() {
    local provider="$1"
    local base="$2"
    local cred_rel="$3"

    local suffix dir dirname cred
    for suffix in "" "-p" "-w" "-1" "-2"; do
        dirname=".${base}${suffix}"
        dir="${HOME}/${dirname}"
        cred="${dir}/${cred_rel}"
        if [[ -e "$dir" || -L "$dir" ]]; then
            add_candidate "$provider" "$dir" "$cred" "false" "$(extract_dir_profile_key "$base" "$dirname")"
        fi
    done
}

scan_flat_file() {
    local provider="$1"
    local rel_path="$2"
    local path="${HOME}/${rel_path}"
    add_candidate "$provider" "$path" "$path" "true" ""
}

scan_opencode_file() {
    local cred_path="$1"
    local profile_key="$2"
    local config_dir
    config_dir="$(dirname "$cred_path")"
    add_candidate "opencode" "$config_dir" "$cred_path" "false" "$profile_key"
}

# --- collect candidates ------------------------------------------------------

scan_provider_dirs "claude" "claude" ".credentials.json"
scan_provider_dirs "codex" "codex" "auth.json"
scan_provider_dirs "grok" "grok" "auth.json"
scan_provider_dirs "minimax" "mmx" "config.json"

scan_flat_file "minimax" ".minimax"
scan_flat_file "zai" ".api-zai"
scan_flat_file "kimi" ".kimi-for-coding"

if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    add_candidate "claude" "$CLAUDE_CONFIG_DIR" "${CLAUDE_CONFIG_DIR}/.credentials.json" "false" "$(basename "$CLAUDE_CONFIG_DIR")"
fi

if [[ -n "${GROK_HOME:-}" ]]; then
    add_candidate "grok" "$GROK_HOME" "${GROK_HOME}/auth.json" "false" "$(basename "$GROK_HOME")"
fi

scan_opencode_file "${HOME}/.local/share/opencode/auth.json" "local-share"

if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    scan_opencode_file "${XDG_DATA_HOME}/opencode/auth.json" "xdg-data"
fi

scan_opencode_file "${HOME}/.config/opencode/auth.json" "config"
scan_opencode_file "${HOME}/.config/opencode/anthropic-accounts.json" "anthropic-accounts"

# --- deduplicate by cred inode -----------------------------------------------

declare -A BEST=()

for entry in "${CANDIDATES[@]}"; do
    IFS='|' read -r inode prefer_real path_len provider profile_key config_dir cred_path is_flat <<<"$entry"

    if [[ -z "${BEST[$inode]:-}" ]]; then
        BEST[$inode]="$entry"
        continue
    fi

    IFS='|' read -r _ best_prefer best_len _ _ _ best_cred _ <<<"${BEST[$inode]}"

    replace=0
    if (( prefer_real > best_prefer )); then
        replace=1
    elif (( prefer_real == best_prefer )); then
        if (( path_len < best_len )); then
            replace=1
        elif (( path_len == best_len )) && [[ "$cred_path" < "$best_cred" ]]; then
            replace=1
        fi
    fi

    if (( replace )); then
        BEST[$inode]="$entry"
    fi
done

# --- build stable ids --------------------------------------------------------

declare -A ID_COUNT=()
RESULTS=()

for inode in "${!BEST[@]}"; do
    IFS='|' read -r _ _ _ provider profile_key config_dir cred_path is_flat <<<"${BEST[$inode]}"

    if [[ -z "$profile_key" ]]; then
        id="${provider}-default"
    else
        id="${provider}-${profile_key}"
    fi

    ID_COUNT[$id]=$((${ID_COUNT[$id]:-0} + 1))
    RESULTS+=("${id}|${provider}|${profile_key}|${config_dir}|${cred_path}|${inode}|${is_flat}")
done

FINAL=()
for row in "${RESULTS[@]}"; do
    IFS='|' read -r id provider profile_key config_dir cred_path inode is_flat <<<"$row"
    if (( ID_COUNT[$id] > 1 )); then
        id="${id}-${inode#*:}"
    fi
    FINAL+=("$id|$provider|$profile_key|$config_dir|$cred_path|$inode|$is_flat")
done

# --- emit JSON (pure bash; no external JSON tools) ---------------------------

json_escape() {
    # Escape a string for inclusion inside a JSON double-quoted value.
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

if ((${#FINAL[@]} == 0)); then
    printf '%s\n' '[]'
    exit 0
fi

IFS=$'\n' SORTED=($(printf '%s\n' "${FINAL[@]}" | sort -t'|' -k2,2 -k1,1))

printf '[\n'
first=1
for row in "${SORTED[@]}"; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r id provider profile_key config_dir cred_path inode is_flat <<<"$row"
    flat_json=false
    [[ "$is_flat" == "true" ]] && flat_json=true
    if ((first)); then
        first=0
    else
        printf ',\n'
    fi
    printf '  {"id":"%s","provider":"%s","profileKey":"%s","configDir":"%s","credPath":"%s","credInode":"%s","isFlatFile":%s}' \
        "$(json_escape "$id")" \
        "$(json_escape "$provider")" \
        "$(json_escape "$profile_key")" \
        "$(json_escape "$config_dir")" \
        "$(json_escape "$cred_path")" \
        "$(json_escape "$inode")" \
        "$flat_json"
done
printf '\n]\n'