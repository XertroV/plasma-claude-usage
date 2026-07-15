#!/usr/bin/env bash
# B023: cache-response.sh reads payload from a file path (not argv) and unlinks it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/contents/scripts/cache-response.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || fail "missing $SCRIPT"

# --- file-path payload: writes hist + latest, removes payload ---
PAYLOAD="$TMP/payload.json"
printf '%s' '{"hello":"world","n":42}' >"$PAYLOAD"
HIST="$TMP/hist/a.json"
LATEST="$TMP/latest/a.json"
bash "$SCRIPT" "$HIST" "$LATEST" "$PAYLOAD"
[[ -f "$HIST" ]] || fail "hist not written"
[[ -f "$LATEST" ]] || fail "latest not written"
[[ ! -e "$PAYLOAD" ]] || fail "payload file should be removed after read"
grep -q '"hello":"world"' "$HIST" || fail "hist content mismatch"
grep -q '"n":42' "$LATEST" || fail "latest content mismatch"
pass "file payload → hist+latest, payload unlinked"

# --- latest disabled with "-" ---
PAYLOAD2="$TMP/payload2.json"
printf '%s' '{"only":"hist"}' >"$PAYLOAD2"
HIST2="$TMP/hist/b.json"
LATEST2="$TMP/latest/b.json"
bash "$SCRIPT" "$HIST2" "-" "$PAYLOAD2"
[[ -f "$HIST2" ]] || fail "hist2 not written"
[[ ! -e "$LATEST2" ]] || fail "latest should not be created when arg is -"
[[ ! -e "$PAYLOAD2" ]] || fail "payload2 should be removed"
pass "latest='-' skips latest copy"

# --- stdin payload via "-" ---
HIST3="$TMP/hist/c.json"
printf '%s' '{"via":"stdin"}' | bash "$SCRIPT" "$HIST3" "-" "-"
[[ -f "$HIST3" ]] || fail "stdin hist not written"
grep -q '"via":"stdin"' "$HIST3" || fail "stdin content mismatch"
pass "payload_path='-' reads stdin"

# --- missing payload file exits non-zero ---
set +e
bash "$SCRIPT" "$TMP/hist/missing.json" "-" "$TMP/does-not-exist.json" 2>/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "expected non-zero exit for missing payload"
pass "missing payload file fails"

# --- $HOME token expansion in paths ---
HOME_DIR="$TMP/fakehome"
mkdir -p "$HOME_DIR"
PAYLOAD_H="$HOME_DIR/pay.json"
printf '%s' '{"home":true}' >"$PAYLOAD_H"
HOME="$HOME_DIR" bash "$SCRIPT" '$HOME/cache/h.json' '$HOME/cache/l.json' '$HOME/pay.json'
[[ -f "$HOME_DIR/cache/h.json" ]] || fail "\$HOME hist not written"
[[ -f "$HOME_DIR/cache/l.json" ]] || fail "\$HOME latest not written"
[[ ! -e "$PAYLOAD_H" ]] || fail "\$HOME payload should be removed"
grep -q '"home":true' "$HOME_DIR/cache/h.json" || fail "\$HOME content mismatch"
pass "\$HOME path tokens resolve"

# --- large-ish payload (chunking stand-in; script itself reads whole file) ---
PAYLOAD_L="$TMP/large.json"
python3 - <<PY
import json
from pathlib import Path
body = {"raw": "x" * 50000, "ok": True}
Path("$PAYLOAD_L").write_text(json.dumps(body), encoding="utf-8")
PY
HIST_L="$TMP/hist/large.json"
bash "$SCRIPT" "$HIST_L" "-" "$PAYLOAD_L"
[[ -f "$HIST_L" ]] || fail "large hist not written"
[[ ! -e "$PAYLOAD_L" ]] || fail "large payload should be removed"
python3 - <<PY
import json
from pathlib import Path
d = json.loads(Path("$HIST_L").read_text(encoding="utf-8"))
assert d.get("ok") is True and len(d.get("raw","")) == 50000, d
print("large payload round-trip ok")
PY
pass "large payload file round-trip"

# --- simulate QML chunked staging then cache-response (B023 path) ---
PENDING_DIR="$TMP/pending"
mkdir -p "$PENDING_DIR"
PENDING="$PENDING_DIR/p-chunked.json"
FULL='{"savedAt":"t","body":{"k":"v"},"note":"chunk-me-please-with-quotes-and-'"'"'s"}'
# 8-byte chunks to force many appends
CHUNK=8
: >"$PENDING"
# recreate with first write semantics
rm -f "$PENDING"
offset=0
len=${#FULL}
first=1
while (( offset < len )); do
    chunk="${FULL:offset:CHUNK}"
    if (( first )); then
        mkdir -p -- "$PENDING_DIR"
        printf %s "$chunk" >"$PENDING"
        first=0
    else
        printf %s "$chunk" >>"$PENDING"
    fi
    offset=$((offset + CHUNK))
done
[[ "$(cat "$PENDING")" == "$FULL" ]] || fail "chunked stage mismatch"
HIST_C="$TMP/hist/chunked.json"
bash "$SCRIPT" "$HIST_C" "-" "$PENDING"
[[ "$(cat "$HIST_C")" == "$FULL" ]] || fail "chunked cache content mismatch"
[[ ! -e "$PENDING" ]] || fail "chunked pending should be removed"
pass "chunked stage + cache-response matches full payload"

# --- argv of cache-response must not include JSON body (best-effort) ---
PAYLOAD_A="$TMP/argv-payload.json"
printf '%s' '{"secret_marker_B023_SHOULD_NOT_BE_ON_ARGV":true}' >"$PAYLOAD_A"
HIST_A="$TMP/hist/argv.json"
# Body lives only in the payload file; argv is path-only and short.
cmd=(bash "$SCRIPT" "$HIST_A" "-" "$PAYLOAD_A")
argv_len=0
for a in "${cmd[@]}"; do
    argv_len=$((argv_len + ${#a} + 1))
done
[[ "$argv_len" -lt 2000 ]] || fail "cache-response argv unexpectedly large ($argv_len)"
# Ensure none of the argv strings contain the secret marker
for a in "${cmd[@]}"; do
    [[ "$a" != *secret_marker_B023* ]] || fail "payload marker leaked into argv element: $a"
done
"${cmd[@]}"
grep -q 'secret_marker_B023' "$HIST_A" || fail "argv-test hist missing body"
pass "cache-response argv is path-only (short)"

echo "All cache-response tests passed."
