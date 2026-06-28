#!/usr/bin/env bash
# ios-bulk-sync.sh — bulk-upload iOS DayPage memos to the web backend
#
# Usage:
#   DAYPAGE_API_KEY=<key> ./scripts/ios-bulk-sync.sh <memos.json> [BASE_URL]
#
# memos.json format (array of objects):
#   [
#     {
#       "body": "memo text",
#       "idempotency_key": "ios:abc123",   -- optional, auto-derived if absent
#       "created_at": "2025-01-01T10:00:00Z", -- optional
#       "source_url": "https://...",        -- optional
#       "type": "text"                      -- optional
#     },
#     ...
#   ]

set -euo pipefail

INPUT_FILE="${1:-}"
BASE_URL="${2:-http://localhost:13000}"
ENDPOINT="${BASE_URL}/api/ingest"

# ── Validate inputs ────────────────────────────────────────────────────────────

if [[ -z "$INPUT_FILE" ]]; then
  echo "Error: no input file provided." >&2
  echo "Usage: DAYPAGE_API_KEY=<key> $0 <memos.json> [BASE_URL]" >&2
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: file not found: $INPUT_FILE" >&2
  exit 1
fi

if [[ -z "${DAYPAGE_API_KEY:-}" ]]; then
  echo "Error: DAYPAGE_API_KEY is not set." >&2
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
fi

if ! command -v curl &> /dev/null; then
  echo "Error: curl is required." >&2
  exit 1
fi

# ── Parse memo count ───────────────────────────────────────────────────────────

TOTAL=$(jq 'length' "$INPUT_FILE")
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No memos found in $INPUT_FILE."
  exit 0
fi

echo "Syncing $TOTAL memo(s) from $INPUT_FILE → $ENDPOINT"
echo ""

# ── Upload loop ────────────────────────────────────────────────────────────────

UPLOADED=0
SKIPPED=0
FAILED=0
FAILED_INDICES=""

for i in $(seq 0 $((TOTAL - 1))); do
  MEMO=$(jq ".[$i]" "$INPUT_FILE")
  BODY=$(echo "$MEMO" | jq -r '.body // ""')
  IKEY=$(echo "$MEMO" | jq -r '.idempotency_key // ""')

  # Auto-derive idempotency_key from body hash if not provided.
  # Use python3 for portability — md5sum is GNU coreutils and absent on macOS.
  # (matches the approach used in claude-code-hook.sh)
  if [[ -z "$IKEY" ]]; then
    HASH=$(printf '%s' "$BODY" | python3 -c 'import sys,hashlib; sys.stdout.write(hashlib.md5(sys.stdin.buffer.read()).hexdigest())')
    IKEY="ios_bulk_sync:${HASH}:$i"
  fi

  PAYLOAD=$(jq -n \
    --argjson memo "$MEMO" \
    --arg ikey "$IKEY" \
    '{
      source: "ios_bulk_sync",
      type: "memo",
      payload: {
        body: ($memo.body // ""),
        idempotency_key: $ikey,
        source_url: ($memo.source_url // null),
        device: "ios_bulk_sync"
      }
    }')

  HTTP_CODE=$(curl -s -o /tmp/_daypage_resp.json -w "%{http_code}" \
    -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $DAYPAGE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD") || HTTP_CODE="000"

  PROGRESS=$((i + 1))

  if [[ "$HTTP_CODE" == "201" ]]; then
    UPLOADED=$((UPLOADED + 1))
    echo "[$PROGRESS/$TOTAL] ✓ uploaded (key: $IKEY)"
  elif [[ "$HTTP_CODE" == "200" ]]; then
    # 200 = deduplicated (idempotency hit)
    SKIPPED=$((SKIPPED + 1))
    echo "[$PROGRESS/$TOTAL] ~ skipped duplicate (key: $IKEY)"
  else
    FAILED=$((FAILED + 1))
    FAILED_INDICES="$FAILED_INDICES $i"
    ERR=$(cat /tmp/_daypage_resp.json 2>/dev/null || echo "(no response)")
    echo "[$PROGRESS/$TOTAL] ✗ failed HTTP $HTTP_CODE — $ERR" >&2
  fi
done

echo ""
echo "Done: $UPLOADED uploaded, $SKIPPED skipped (duplicates), $FAILED failed."

if [[ "$FAILED" -gt 0 ]]; then
  echo "Failed memo indices:$FAILED_INDICES" >&2
  exit 1
fi
