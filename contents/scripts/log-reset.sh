#!/usr/bin/env bash
# Atomically write a quota-reset event JSON file, mirror latest, and append JSONL.
#
# Usage: log-reset.sh <hist_path> <latest_path_or_-> <jsonl_path_or_-> <payload_path|->
#
# Payload is read from a file path or stdin ("-") so Plasma's executable
# DataSource never has to put the JSON body on process argv alone without
# shell quoting. Never stores tokens — reset events are usage metadata only.
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "usage: log-reset.sh <hist_path> <latest_path_or_-> <jsonl_path_or_-> <payload_path>" >&2
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
JSONL_RAW="$3"
PAYLOAD_ARG="$4"

if [[ -z "$HIST" ]]; then
    echo "log-reset.sh: empty hist path" >&2
    exit 2
fi

PAYLOAD=""
PAYLOAD_FILE=""
if [[ "$PAYLOAD_ARG" == "-" ]]; then
    PAYLOAD="$(cat)"
else
    PAYLOAD_FILE="$(resolve_path "$PAYLOAD_ARG")"
    if [[ -z "$PAYLOAD_FILE" ]]; then
        echo "log-reset.sh: empty payload path" >&2
        exit 2
    fi
    if [[ ! -f "$PAYLOAD_FILE" ]]; then
        echo "log-reset.sh: payload file not found: $PAYLOAD_FILE" >&2
        exit 2
    fi
    PAYLOAD="$(cat -- "$PAYLOAD_FILE")"
fi

if [[ -z "$PAYLOAD" ]]; then
    echo "log-reset.sh: empty payload" >&2
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
    umask 077
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

if [[ -n "$JSONL_RAW" && "$JSONL_RAW" != "-" ]]; then
    JSONL="$(resolve_path "$JSONL_RAW")"
    if [[ -n "$JSONL" ]]; then
        mkdir -p -- "$(dirname -- "$JSONL")"
        umask 077
        # One JSON object per line; payload must already be a single line
        # (JSON.stringify does not emit raw newlines inside strings for our fields).
        printf '%s\n' "$PAYLOAD" >>"$JSONL"
    fi
fi

if [[ -n "$PAYLOAD_FILE" && -f "$PAYLOAD_FILE" ]]; then
    rm -f -- "$PAYLOAD_FILE"
fi
