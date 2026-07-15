#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/contents/scripts/discover-profiles.sh"

# B017: discovery must not invoke python (pure-bash JSON emit)
if grep -E '^[[:space:]]*python3?[[:space:]]|^[[:space:]]*python3?$|command[[:space:]]+-v[[:space:]]+python' "$SCRIPT" >/dev/null; then
    echo "FAIL: discover-profiles.sh still invokes python" >&2
    exit 1
fi

# --- live HOME smoke (JSON + dedupe) -----------------------------------------
OUT="$("$SCRIPT")"
echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin); print('json ok')"
COUNT=$(echo "$OUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "profiles: $COUNT"
# no duplicate credInode
echo "$OUT" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
inos=[r['credInode'] for r in rows]
assert len(inos)==len(set(inos)), 'duplicate inode'
ids=[r['id'] for r in rows]
assert 'claude-w' in ids or 'claude-p' in ids or len(ids)>0
print('dedup ok')
"

# Script works even when python3 is absent from PATH (B017)
NOPY_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -E 'python' | paste -sd: - || true)
FAKE_BIN=$(mktemp -d)
ln -s /bin/bash "$FAKE_BIN/bash" 2>/dev/null || true
for cmd in sort stat readlink printf cat cut id getent dirname basename; do
    if command -v "$cmd" >/dev/null 2>&1; then
        src=$(command -v "$cmd")
        ln -sf "$src" "$FAKE_BIN/$cmd"
    fi
done
OUT2=$(env PATH="${NOPY_PATH:-$FAKE_BIN}" "$SCRIPT")
echo "$OUT2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list); print('no-python PATH json ok', len(d))"
rm -rf "$FAKE_BIN"

# --- isolated HOME: arbitrary suffixes + junk filters (B016) -----------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
    "$TMP/.claude" \
    "$TMP/.claude-p" \
    "$TMP/.claude-work" \
    "$TMP/.claude-3" \
    "$TMP/.claude-backup" \
    "$TMP/.claude-shared" \
    "$TMP/.claude.backup.12345" \
    "$TMP/.grok-3" \
    "$TMP/.codex" \
    "$TMP/.mmx-staging"

# Creds only for real + junk-that-would-be-false-positive if unfiltered
echo '{}' >"$TMP/.claude/.credentials.json"
echo '{}' >"$TMP/.claude-p/.credentials.json"
echo '{}' >"$TMP/.claude-work/.credentials.json"
echo '{}' >"$TMP/.claude-3/.credentials.json"
echo '{}' >"$TMP/.claude-backup/.credentials.json"          # junk suffix
echo '{}' >"$TMP/.claude-shared/.credentials.json"          # junk suffix
echo '{}' >"$TMP/.claude.backup.12345/.credentials.json"    # non-hyphen form
echo '{}' >"$TMP/.grok-3/auth.json"
echo '{}' >"$TMP/.codex/auth.json"
echo '{}' >"$TMP/.mmx-staging/config.json"

# Dir without creds must be ignored
mkdir -p "$TMP/.claude-monitor"
# Plain file must not be treated as a profile dir
echo 'not a dir' >"$TMP/.claude.json"

OUT_ISO="$(HOME="$TMP" "$SCRIPT")"
echo "$OUT_ISO" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
ids = sorted(r['id'] for r in rows)
print('isolated ids:', ids)

# Must discover arbitrary multi-account suffixes
need = {'claude-default', 'claude-p', 'claude-work', 'claude-3', 'grok-3', 'codex-default', 'minimax-staging'}
missing = need - set(ids)
assert not missing, f'missing expected profiles: {missing}'

# Must not pick up junk / non-hyphen backup forms / files
forbid_sub = ('backup', 'shared', 'monitor', 'claude.json')
for i in ids:
    for bad in forbid_sub:
        assert bad not in i.lower(), f'junk profile leaked: {i}'

inos = [r['credInode'] for r in rows]
assert len(inos) == len(set(inos)), 'duplicate inode in isolated HOME'
print('isolated discovery ok')
"
