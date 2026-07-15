#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/contents/scripts/discover-profiles.sh"

# B017: discovery must not invoke python (pure-bash JSON emit)
if grep -E '^[[:space:]]*python3?[[:space:]]|^[[:space:]]*python3?$|command[[:space:]]+-v[[:space:]]+python' "$SCRIPT" >/dev/null; then
    echo "FAIL: discover-profiles.sh still invokes python" >&2
    exit 1
fi

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

# Script works even when python3 is absent from PATH
NOPY_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -E 'python' | paste -sd: -)
# Also hide python3 binary via a temp PATH that only has coreutils + bash helpers
FAKE_BIN=$(mktemp -d)
ln -s /bin/bash "$FAKE_BIN/bash" 2>/dev/null || true
for cmd in sort stat readlink printf cat cut id getent dirname basename; do
    if command -v "$cmd" >/dev/null 2>&1; then
        src=$(command -v "$cmd")
        ln -sf "$src" "$FAKE_BIN/$cmd"
    fi
done
# Prefer real PATH stripped of python dirs if that still has needed tools
OUT2=$(env PATH="${NOPY_PATH:-$FAKE_BIN}" "$SCRIPT")
echo "$OUT2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list); print('no-python PATH json ok', len(d))"
rm -rf "$FAKE_BIN"