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

assert_no_request_temps() {
    local temp_files
    shopt -s nullglob
    temp_files=("$RUNTIME_DIR"/.request.tmp.*)
    shopt -u nullglob
    [[ "${#temp_files[@]}" -eq 0 ]] || fail "rejected write left ${#temp_files[@]} temporary file(s)"
}

expect_write_failure() {
    local label="$1"
    local payload_file="$2"
    local bridge_path="${3:-$PATH}"

    if PATH="$bridge_path" "$BRIDGE" write <"$payload_file" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
        fail "$label payload was accepted"
    fi
    [[ ! -e "$RUNTIME_DIR/request.json" ]] || fail "$label payload created a request"
    assert_no_request_temps
    pass "$label payload rejected without temporary files"
}

make_sized_object() {
    local size="$1"
    local output="$2"
    local body_size=$((size - 8))

    {
        printf '%s' '{"v":"'
        head -c "$body_size" /dev/zero | tr '\0' x
        printf '%s' '"}'
    } >"$output"
    [[ "$(wc -c <"$output")" -eq "$size" ]] || fail "could not create $size-byte fixture"
}

make_command_path() {
    local destination="$1"
    shift
    local command_name
    local command_path

    mkdir -p -- "$destination"
    for command_name in "$@"; do
        command_path="$(command -v "$command_name")"
        [[ "$command_path" = /* ]] || fail "required command has no absolute path: $command_name"
        ln -s -- "$command_path" "$destination/$command_name"
    done
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
make_sized_object 65536 "$TMP/exact-limit.json"
make_sized_object 65537 "$TMP/over-limit.json"

expect_write_failure "empty" "$TMP/empty.json"
expect_write_failure "whitespace" "$TMP/whitespace.json"
if command -v python3 >/dev/null 2>&1; then
    expect_write_failure "strict-malformed" "$TMP/malformed.json"
    pass "Python-backed validation is strict"
else
    pass "Python-backed strict validation skipped because python3 is unavailable"
fi
expect_write_failure "non-object" "$TMP/non-object.json"

"$BRIDGE" write <"$TMP/exact-limit.json"
[[ "$(stat -c %s "$RUNTIME_DIR/request.json")" -eq 65536 ]] || fail "65,536-byte request was not preserved"
"$BRIDGE" take >"$TMP/exact-limit-taken.json"
cmp -s "$TMP/exact-limit.json" "$TMP/exact-limit-taken.json" || fail "65,536-byte request round trip mismatch"
pass "65,536-byte input is accepted"
expect_write_failure "65,537-byte" "$TMP/over-limit.json"
pass "65,537-byte input is rejected"

PRESERVED='{"request":"preserve-on-invalid-write"}'
printf '%s' "$PRESERVED" | "$BRIDGE" write
if "$BRIDGE" write <"$TMP/non-object.json" >"$TMP/invalid-replacement.stdout" 2>"$TMP/invalid-replacement.stderr"; then
    fail "invalid replacement write was accepted"
fi
[[ "$(cat "$RUNTIME_DIR/request.json")" = "$PRESERVED" ]] || fail "invalid replacement changed the prior request"
assert_no_request_temps
actual="$($BRIDGE take)"
[[ "$actual" = "$PRESERVED" ]] || fail "prior request was not preserved after invalid replacement"
pass "invalid replacement preserves prior request and leaves no temporary files"

NO_PYTHON_BIN="$TMP/no-python-bin"
make_command_path "$NO_PYTHON_BIN" bash mkdir chmod mktemp head wc tr mv cat rm
if PATH="$NO_PYTHON_BIN" command -v python3 >/dev/null 2>&1; then
    fail "no-Python test PATH unexpectedly exposes python3"
fi
PATH="$NO_PYTHON_BIN" "$BRIDGE" write <"$TMP/malformed.json"
actual="$(PATH="$NO_PYTHON_BIN" "$BRIDGE" take)"
[[ "$actual" = '{not-json}' ]] || fail "no-Python path did not hand object-looking payload to pure consumer"
pass "no-Python fallback publishes object-looking payload"
expect_write_failure "no-python-empty" "$TMP/empty.json" "$NO_PYTHON_BIN"
expect_write_failure "no-python-non-object" "$TMP/non-object.json" "$NO_PYTHON_BIN"
pass "no-Python fallback rejects empty and non-object-looking payloads"

"$BRIDGE" take >"$TMP/missing-take.out"
[[ ! -s "$TMP/missing-take.out" ]] || fail "missing take produced output"
pass "missing take is silent and successful"

[[ ! -e "$XDG_CACHE_HOME/plasma-claude-usage" ]] || fail "runtime bridge used the cache tree despite XDG_RUNTIME_DIR"
[[ ! -e "$PLASMA_CLAUDE_USAGE_CACHE_ROOT" ]] || fail "runtime bridge touched configurable cache root"
pass "runtime bridge is independent of configurable cache root"

FAIL_MV_BIN="$TMP/fail-mv-bin"
mkdir -p -- "$FAIL_MV_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'echo "injected mv failure" >&2' 'exit 73' >"$FAIL_MV_BIN/mv"
chmod +x "$FAIL_MV_BIN/mv"
CLAIM_FAILURE_PAYLOAD='{"request":"preserved-after-claim-failure"}'
printf '%s' "$CLAIM_FAILURE_PAYLOAD" | "$BRIDGE" write
set +e
PATH="$FAIL_MV_BIN:$PATH" "$BRIDGE" take >"$TMP/claim-failure.out" 2>"$TMP/claim-failure.err"
claim_failure_rc=$?
set -e
[[ "$claim_failure_rc" -ne 0 ]] || fail "failed claim was treated as a harmless miss"
[[ -s "$TMP/claim-failure.err" ]] || fail "failed claim emitted no error"
[[ ! -s "$TMP/claim-failure.out" ]] || fail "failed claim produced payload output"
[[ "$(cat "$RUNTIME_DIR/request.json")" = "$CLAIM_FAILURE_PAYLOAD" ]] || fail "failed claim did not preserve request"
actual="$($BRIDGE take)"
[[ "$actual" = "$CLAIM_FAILURE_PAYLOAD" ]] || fail "request was unavailable after injected claim failure"
pass "failed claim reports error and preserves request"

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

PAUSE_CAT_BIN="$TMP/pause-cat-bin"
mkdir -p -- "$PAUSE_CAT_BIN"
printf '%s\n' '#!/usr/bin/env bash' ': >"$CLAIM_PAUSE_MARKER"' 'kill -STOP "$PPID"' 'exec "$REAL_CAT" "$@"' >"$PAUSE_CAT_BIN/cat"
chmod +x "$PAUSE_CAT_BIN/cat"
INTERRUPTED='{"request":"interrupt-after-claim"}'
printf '%s' "$INTERRUPTED" | "$BRIDGE" write
chmod 644 -- "$RUNTIME_DIR/request.json"
CLAIM_PAUSE_MARKER="$TMP/claim-paused" REAL_CAT="$(command -v cat)" PATH="$PAUSE_CAT_BIN:$PATH" \
    "$BRIDGE" take >"$TMP/interrupted-take.out" 2>"$TMP/interrupted-take.err" &
consumer_pid=$!
for ((attempt = 0; attempt < 200; ++attempt)); do
    [[ -e "$TMP/claim-paused" ]] && break
    kill -0 "$consumer_pid" 2>/dev/null || fail "consumer exited before claim inspection"
    sleep 0.01
done
[[ -e "$TMP/claim-paused" ]] || fail "consumer did not reach paused claim state"
shopt -s nullglob
claim_files=("$RUNTIME_DIR"/claim.*)
shopt -u nullglob
[[ "${#claim_files[@]}" -eq 1 ]] || fail "expected one live claim, got ${#claim_files[@]}"
[[ "$(stat -c %a "${claim_files[0]}")" = 600 ]] || fail "live claim mode is not 600"
kill -TERM "$consumer_pid"
kill -CONT "$consumer_pid"
set +e
wait "$consumer_pid"
interrupted_rc=$?
set -e
[[ "$interrupted_rc" -ne 0 ]] || fail "terminated consumer exited successfully"
if compgen -G "$RUNTIME_DIR/claim.*" >/dev/null; then
    fail "terminated consumer left a claim file behind"
fi
pass "live claim is mode 600 and signal cleanup removes it"

XDG_RUNTIME_DIR="" "$BRIDGE" write <<<'{"request":"xdg-cache-fallback"}'
FALLBACK_DIR="$XDG_CACHE_HOME/plasma-claude-usage/runtime"
[[ -f "$FALLBACK_DIR/request.json" ]] || fail "XDG cache runtime fallback request missing"
[[ "$(stat -c %a "$FALLBACK_DIR")" = 700 ]] || fail "XDG cache fallback directory mode is not 700"
[[ "$(stat -c %a "$FALLBACK_DIR/request.json")" = 600 ]] || fail "XDG cache fallback request mode is not 600"
actual="$(XDG_RUNTIME_DIR="" "$BRIDGE" take)"
[[ "$actual" = '{"request":"xdg-cache-fallback"}' ]] || fail "XDG cache runtime fallback round-trip mismatch"
pass "XDG cache runtime fallback"

env -u XDG_CACHE_HOME XDG_RUNTIME_DIR="" "$BRIDGE" write <<<'{"request":"home-cache-fallback"}'
HOME_FALLBACK_DIR="$HOME/.cache/plasma-claude-usage/runtime"
[[ -f "$HOME_FALLBACK_DIR/request.json" ]] || fail "HOME cache runtime fallback request missing"
[[ "$(stat -c %a "$HOME_FALLBACK_DIR")" = 700 ]] || fail "HOME cache fallback directory mode is not 700"
[[ "$(stat -c %a "$HOME_FALLBACK_DIR/request.json")" = 600 ]] || fail "HOME cache fallback request mode is not 600"
actual="$(env -u XDG_CACHE_HOME XDG_RUNTIME_DIR="" "$BRIDGE" take)"
[[ "$actual" = '{"request":"home-cache-fallback"}' ]] || fail "HOME cache runtime fallback round-trip mismatch"
pass "HOME cache runtime fallback"

echo "All test celebration bridge tests passed."
