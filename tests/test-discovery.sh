#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$("$ROOT/contents/scripts/discover-profiles.sh")"
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