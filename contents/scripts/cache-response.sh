#!/usr/bin/env bash
# Atomically write a provider response envelope to a historical path and
# optionally overwrite a latest convenience copy.
#
# Usage: cache-response.sh <hist_path> <latest_path_or_-> <payload_path>
#
# Payload is read from a file path (not argv) so the Plasma executable
# DataSource never has to put the JSON body on process argv (B023).
# The payload file is removed only after hist/latest writes succeed
# (so a failed run can be retried). Pass "-" to read JSON from stdin.
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: cache-response.sh <hist_path> <latest_path_or_-> <payload_path>" >&2
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
PAYLOAD_ARG="$3"

if [[ -z "$HIST" ]]; then
    echo "cache-response.sh: empty hist path" >&2
    exit 2
fi

PAYLOAD=""
PAYLOAD_FILE=""
if [[ "$PAYLOAD_ARG" == "-" ]]; then
    PAYLOAD="$(cat)"
else
    PAYLOAD_FILE="$(resolve_path "$PAYLOAD_ARG")"
    if [[ -z "$PAYLOAD_FILE" ]]; then
        echo "cache-response.sh: empty payload path" >&2
        exit 2
    fi
    if [[ ! -f "$PAYLOAD_FILE" ]]; then
        echo "cache-response.sh: payload file not found: $PAYLOAD_FILE" >&2
        exit 2
    fi
    # Keep the file until hist/latest writes succeed so a failed run can retry.
    PAYLOAD="$(cat -- "$PAYLOAD_FILE")"
fi

write_atomic() {
    local dest="$1"
    local dir tmp
    dir="$(dirname -- "$dest")"
    mkdir -p -- "$dir"
    tmp="$(mktemp --tmpdir="$dir" ".tmp.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -f -- "$tmp"' RETURN
    # Restrictive mode: envelopes may include provider response bodies
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

# Unlink staged payload only after successful writes (B023)
if [[ -n "$PAYLOAD_FILE" ]]; then
    rm -f -- "$PAYLOAD_FILE"
fi
