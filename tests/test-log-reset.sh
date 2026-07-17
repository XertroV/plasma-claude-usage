#!/usr/bin/env bash
# Smoke test for log-reset.sh: hist, latest, jsonl, $HOME expansion, stdin payload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/contents/scripts/log-reset.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

chmod +x "$SCRIPT"

PAYLOAD='{"observedAtMs":1,"provider":"claude","windowId":"5h","kind":"natural"}'
HIST="$TMP/resets/2026/07/18/120000-001-claude-p-5h.json"
LATEST="$TMP/resets/latest/claude-p-5h.json"
JSONL="$TMP/resets/events.jsonl"

printf '%s' "$PAYLOAD" | bash "$SCRIPT" "$HIST" "$LATEST" "$JSONL" -

test -f "$HIST"
test -f "$LATEST"
test -f "$JSONL"
grep -q '"kind":"natural"' "$HIST"
grep -q '"kind":"natural"' "$LATEST"
# jsonl has trailing newline
test "$(wc -l < "$JSONL")" -eq 1
grep -q '"windowId":"5h"' "$JSONL"

# Second append grows jsonl
printf '%s' '{"kind":"early"}' | bash "$SCRIPT" \
    "$TMP/resets/2026/07/18/120001-002-claude-p-5h.json" \
    "$LATEST" "$JSONL" -
test "$(wc -l < "$JSONL")" -eq 2

# $HOME expansion
export HOME="$TMP/home"
mkdir -p "$HOME"
printf '%s' '{"ok":true}' | bash "$SCRIPT" \
    '$HOME/cache/resets/a.json' \
    '$HOME/cache/resets/latest/a.json' \
    '$HOME/cache/resets/events.jsonl' -
test -f "$HOME/cache/resets/a.json"
test -f "$HOME/cache/resets/latest/a.json"

echo "All log-reset.sh tests passed."
