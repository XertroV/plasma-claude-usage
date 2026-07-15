#!/usr/bin/env bash
# Atomically write a provider response envelope to a historical path and
# optionally overwrite a latest convenience copy.
# Usage: cache-response.sh <hist_path> <latest_path_or_-> <json_payload>
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: cache-response.sh <hist_path> <latest_path_or_-> <json_payload>" >&2
    exit 2
fi

HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}"
HOME="${HOME:-/}"

resolve_path() {
    local p="$1"
    if [[ "$p" == \$HOME/* ]]; then
        p="${HOME}/${p#\$HOME/}"
    elif [[ "$p" == \${HOME}/* ]]; then
        p="${HOME}/${p#\${HOME}/}"
    elif [[ "$p" == ~/* ]]; then
        p="${HOME}/${p#\~/}"
    fi
    printf '%s' "$p"
}

HIST="$(resolve_path "$1")"
LATEST_RAW="$2"
PAYLOAD="$3"

if [[ -z "$HIST" ]]; then
    echo "cache-response.sh: empty hist path" >&2
    exit 2
fi

write_atomic() {
    local dest="$1"
    local dir tmp
    dir="$(dirname -- "$dest")"
    mkdir -p -- "$dir"
    tmp="$(mktemp --tmpdir="$dir" ".tmp.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -f -- "$tmp"' RETURN
    printf '%s' "$PAYLOAD" >"$tmp"
    mv -f -- "$tmp" "$dest"
    trap - RETURN
}

write_atomic "$HIST"

if [[ -n "$LATEST_RAW" && "$LATEST_RAW" != "-" ]]; then
    LATEST="$(resolve_path "$LATEST_RAW")"
    if [[ -n "$LATEST" ]]; then
        write_atomic "$LATEST"
    fi
fi
