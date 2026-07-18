#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/contents/scripts/test-celebration-bridge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

expect_write_failure() {
    local label="$1"
    local payload_file="$2"

    if "$BRIDGE" write <"$payload_file" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
        fail "$label payload was accepted"
    fi
    [[ ! -e "$RUNTIME_DIR/request.json" ]] || fail "$label payload created a request"
    pass "$label payload rejected"
}

[[ -x "$BRIDGE" ]] || fail "missing executable $BRIDGE"

export HOME="$TMP/home"
export XDG_RUNTIME_DIR="$TMP/runtime"
export XDG_CACHE_HOME="$TMP/xdg-cache"
export PLASMA_CLAUDE_USAGE_CACHE_ROOT="$TMP/configured-response-cache"
mkdir -p -- "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
RUNTIME_DIR="$XDG_RUNTIME_DIR/plasma-claude-usage"

PAYLOAD='{"version":1,"type":"test-celebration","createdAtMs":1784354254000,"nonce":"round-trip"}'
printf '%s' "$PAYLOAD" | "$BRIDGE" write
[[ -f "$RUNTIME_DIR/request.json" ]] || fail "write did not create request.json"
[[ "$(stat -c %a "$RUNTIME_DIR")" = 700 ]] || fail "runtime directory mode is not 700"
[[ "$(stat -c %a "$RUNTIME_DIR/request.json")" = 600 ]] || fail "request file mode is not 600"
actual="$($BRIDGE take)"
[[ "$actual" = "$PAYLOAD" ]] || fail "round-trip payload mismatch"
[[ ! -e "$RUNTIME_DIR/request.json" ]] || fail "take did not remove request"
pass "round trip and secure modes"

FIRST='{"request":"first"}'
SECOND='{"request":"second"}'
printf '%s' "$FIRST" | "$BRIDGE" write
printf '%s' "$SECOND" | "$BRIDGE" write
actual="$($BRIDGE take)"
[[ "$actual" = "$SECOND" ]] || fail "second write did not replace first request"
pass "second write replaces pending request"

: >"$TMP/empty.json"
printf '   \n\t' >"$TMP/whitespace.json"
printf '%s' '{not-json}' >"$TMP/malformed.json"
printf '%s' '[{"object":false}]' >"$TMP/non-object.json"
python3 -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write("{\"value\":\"" + "x" * 65536 + "\"}")' "$TMP/oversized.json"
expect_write_failure "empty" "$TMP/empty.json"
expect_write_failure "whitespace" "$TMP/whitespace.json"
expect_write_failure "malformed" "$TMP/malformed.json"
expect_write_failure "non-object" "$TMP/non-object.json"
expect_write_failure "oversized" "$TMP/oversized.json"

"$BRIDGE" take >"$TMP/missing-take.out"
[[ ! -s "$TMP/missing-take.out" ]] || fail "missing take produced output"
pass "missing take is silent and successful"

[[ ! -e "$XDG_CACHE_HOME/plasma-claude-usage" ]] || fail "runtime bridge used the cache tree despite XDG_RUNTIME_DIR"
[[ ! -e "$PLASMA_CLAUDE_USAGE_CACHE_ROOT" ]] || fail "runtime bridge touched configurable cache root"
pass "runtime bridge is independent of configurable cache root"

CONCURRENT='{"request":"one-consumer"}'
printf '%s' "$CONCURRENT" | "$BRIDGE" write
"$BRIDGE" take >"$TMP/take-1.out" &
pid1=$!
"$BRIDGE" take >"$TMP/take-2.out" &
pid2=$!
wait "$pid1"
wait "$pid2"
nonempty=0
[[ -s "$TMP/take-1.out" ]] && nonempty=$((nonempty + 1))
[[ -s "$TMP/take-2.out" ]] && nonempty=$((nonempty + 1))
[[ "$nonempty" -eq 1 ]] || fail "expected exactly one concurrent take output, got $nonempty"
combined="$(cat "$TMP/take-1.out" "$TMP/take-2.out")"
[[ "$combined" = "$CONCURRENT" ]] || fail "concurrent take output mismatch"
if compgen -G "$RUNTIME_DIR/claim.*" >/dev/null; then
    fail "take left a claim file behind"
fi
pass "concurrent take has exactly one consumer"

XDG_RUNTIME_DIR="" "$BRIDGE" write <<<'{"request":"fallback"}'
FALLBACK_DIR="$XDG_CACHE_HOME/plasma-claude-usage/runtime"
[[ -f "$FALLBACK_DIR/request.json" ]] || fail "cache runtime fallback request missing"
[[ "$(stat -c %a "$FALLBACK_DIR")" = 700 ]] || fail "fallback runtime directory mode is not 700"
[[ "$(stat -c %a "$FALLBACK_DIR/request.json")" = 600 ]] || fail "fallback request file mode is not 600"
actual="$(XDG_RUNTIME_DIR="" "$BRIDGE" take)"
[[ "$actual" = '{"request":"fallback"}' ]] || fail "cache runtime fallback round-trip mismatch"
pass "XDG cache runtime fallback"

echo "All test celebration bridge tests passed."
