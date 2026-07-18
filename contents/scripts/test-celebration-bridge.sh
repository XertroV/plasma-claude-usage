#!/usr/bin/env bash
# Secure transient bridge between the Settings KCM and the running widget.
set -euo pipefail

umask 077

MAX_PAYLOAD_BYTES=65536
TMP_FILE=""
CLAIM_FILE=""

cleanup() {
    [[ -z "$TMP_FILE" ]] || rm -f -- "$TMP_FILE"
    [[ -z "$CLAIM_FILE" ]] || rm -f -- "$CLAIM_FILE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    BRIDGE_DIR="$XDG_RUNTIME_DIR/plasma-claude-usage"
else
    CACHE_HOME="${XDG_CACHE_HOME:-${HOME:-/}/.cache}"
    BRIDGE_DIR="$CACHE_HOME/plasma-claude-usage/runtime"
fi
REQUEST_FILE="$BRIDGE_DIR/request.json"

prepare_bridge_dir() {
    mkdir -p -- "$BRIDGE_DIR"
    chmod 700 -- "$BRIDGE_DIR"
}

validate_payload() {
    local payload_file="$1"
    local compact

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys

def reject_constant(value):
    raise ValueError("non-standard JSON constant: " + value)

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    payload = json.load(stream, parse_constant=reject_constant)
if not isinstance(payload, dict):
    raise SystemExit(1)
' "$payload_file" >/dev/null 2>&1
        return
    fi

    # The pure QML consumer performs full schema validation. Without Python,
    # keep this adapter bounded and require only a non-empty object shape.
    compact="$(LC_ALL=C tr -d '[:space:]' <"$payload_file")"
    [[ "$compact" == \{*\} ]]
}

write_request() {
    local payload_size

    prepare_bridge_dir
    TMP_FILE="$(mktemp --tmpdir="$BRIDGE_DIR" '.request.tmp.XXXXXX')"
    chmod 600 -- "$TMP_FILE"

    head -c $((MAX_PAYLOAD_BYTES + 1)) >"$TMP_FILE"
    payload_size="$(wc -c <"$TMP_FILE")"
    if (( payload_size == 0 || payload_size > MAX_PAYLOAD_BYTES )); then
        echo "test-celebration-bridge.sh: payload must contain 1-$MAX_PAYLOAD_BYTES bytes" >&2
        return 2
    fi
    if ! validate_payload "$TMP_FILE"; then
        echo "test-celebration-bridge.sh: payload must be a valid JSON object" >&2
        return 2
    fi

    mv -f -- "$TMP_FILE" "$REQUEST_FILE"
    TMP_FILE=""
}

take_request() {
    prepare_bridge_dir
    CLAIM_FILE="$BRIDGE_DIR/claim.$$"

    if ! mv -- "$REQUEST_FILE" "$CLAIM_FILE" 2>/dev/null; then
        CLAIM_FILE=""
        return 0
    fi

    cat -- "$CLAIM_FILE"
    rm -f -- "$CLAIM_FILE"
    CLAIM_FILE=""
}

if [[ $# -ne 1 ]]; then
    echo "usage: test-celebration-bridge.sh <write|take>" >&2
    exit 2
fi

case "$1" in
    write)
        write_request
        ;;
    take)
        take_request
        ;;
    *)
        echo "usage: test-celebration-bridge.sh <write|take>" >&2
        exit 2
        ;;
esac
