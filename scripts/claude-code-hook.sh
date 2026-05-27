#!/usr/bin/env bash
# DayPage Claude Code hook script
# Usage: claude-code-hook.sh <action> [args...]
# Actions: add-memo <content>, search <query>, get-today
# Requires: DAYPAGE_API_KEY env var, DAYPAGE_URL (default: http://localhost:3000)

set -euo pipefail

DAYPAGE_URL="${DAYPAGE_URL:-http://localhost:3000}"
API_KEY="${DAYPAGE_API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: DAYPAGE_API_KEY environment variable is not set" >&2
  exit 1
fi

ACTION="${1:-}"
if [[ -z "$ACTION" ]]; then
  echo "Error: No action specified" >&2
  echo "Usage: $0 <action> [args]" >&2
  echo "Actions: add-memo <content>, search <query>, get-today" >&2
  exit 1
fi

shift

# Helper: POST JSON, print response body, exit non-zero on HTTP error
post_json() {
  local url="$1"
  local body="$2"
  local response
  local http_code

  response=$(curl -s -w "\n%{http_code}" \
    -X POST "$url" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body")

  http_code=$(echo "$response" | tail -n1)
  body_text=$(echo "$response" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "Error: HTTP $http_code from $url" >&2
    echo "$body_text" >&2
    exit 1
  fi

  echo "$body_text"
}

# Helper: GET with optional query params, print response body
get_json() {
  local url="$1"
  local response
  local http_code

  response=$(curl -s -w "\n%{http_code}" \
    -X GET "$url" \
    -H "Authorization: Bearer $API_KEY")

  http_code=$(echo "$response" | tail -n1)
  body_text=$(echo "$response" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "Error: HTTP $http_code from $url" >&2
    echo "$body_text" >&2
    exit 1
  fi

  echo "$body_text"
}

case "$ACTION" in
  add-memo)
    CONTENT="${1:-}"
    if [[ -z "$CONTENT" ]]; then
      echo "Error: add-memo requires <content> argument" >&2
      exit 1
    fi

    # Escape content for JSON
    ESCAPED=$(printf '%s' "$CONTENT" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null \
      || printf '%s' "$CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')

    JSON="{\"source\":\"claude-code\",\"type\":\"memo\",\"payload\":{\"body\":$ESCAPED}}"
    RESULT=$(post_json "$DAYPAGE_URL/api/ingest" "$JSON")

    # Extract id and body for human-readable output
    MEMO_ID=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id','unknown'))" 2>/dev/null || echo "unknown")
    echo "Memo created: $MEMO_ID"
    echo "Content: $CONTENT"
    ;;

  search)
    QUERY="${1:-}"
    if [[ -z "$QUERY" ]]; then
      echo "Error: search requires <query> argument" >&2
      exit 1
    fi

    # URL-encode query
    ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY" 2>/dev/null \
      || echo "$QUERY" | sed 's/ /%20/g; s/&/%26/g')

    MEMOS_RESULT=$(get_json "$DAYPAGE_URL/api/memos?limit=5&q=$(echo "$ENCODED")" 2>/dev/null || echo '{"items":[]}')
    PAGES_RESULT=$(get_json "$DAYPAGE_URL/api/pages?q=$ENCODED&limit=5" 2>/dev/null || echo '{"pages":[]}')

    echo "=== Search results for: $QUERY ==="
    echo ""
    echo "--- Pages ---"
    echo "$PAGES_RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pages = data.get('pages', [])
if not pages:
    print('  (no pages found)')
for p in pages:
    print(f\"  [{p.get('type','?')}] {p.get('title','Untitled')} (slug: {p.get('slug','?')})\")
" 2>/dev/null || echo "$PAGES_RESULT"

    echo ""
    echo "--- Memos ---"
    echo "$MEMOS_RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
    print('  (no memos found)')
for m in items:
    body = m.get('body','')
    preview = body[:120] + '...' if len(body) > 120 else body
    ts = m.get('created_at','')[:10]
    print(f\"  [{ts}] {preview}\")
" 2>/dev/null || echo "$MEMOS_RESULT"
    ;;

  get-today)
    TODAY=$(date +%Y-%m-%d)

    # Try to get today's daily page
    PAGES_RESULT=$(get_json "$DAYPAGE_URL/api/pages?type=daily&limit=10" 2>/dev/null || echo '{"pages":[]}')

    echo "=== DayPage: $TODAY ==="
    echo ""

    DAILY=$(echo "$PAGES_RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pages = data.get('pages', [])
today = '$TODAY'
for p in pages:
    if today in p.get('slug','') or today in p.get('title',''):
        print(json.dumps(p))
        break
" 2>/dev/null || echo "")

    if [[ -n "$DAILY" ]]; then
      echo "--- Compiled Daily Page ---"
      echo "$DAILY" | python3 -c "
import json, sys
p = json.load(sys.stdin)
print(f\"Title: {p.get('title','')}\")
print(f\"Status: {p.get('status','')}\")
print(f\"Sources: {p.get('source_count',0)} memos\")
print(f\"Last compiled: {p.get('last_compiled_at','never')}\")
" 2>/dev/null || echo "$DAILY"
    else
      echo "No compiled daily page for today yet."
    fi

    echo ""
    echo "--- Recent memos (today) ---"
    SINCE="${TODAY}T00:00:00Z"
    MEMOS_RESULT=$(get_json "$DAYPAGE_URL/api/memos?since=$SINCE&limit=20" 2>/dev/null || echo '{"items":[]}')
    echo "$MEMOS_RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', [])
print(f'  Total memos today: {len(items)}')
for m in items:
    body = m.get('body','')
    preview = body[:80] + '...' if len(body) > 80 else body
    ts = m.get('created_at','')[:19].replace('T',' ')
    print(f\"  [{ts}] {preview}\")
" 2>/dev/null || echo "$MEMOS_RESULT"
    ;;

  *)
    echo "Error: Unknown action '$ACTION'" >&2
    echo "Usage: $0 <action> [args]" >&2
    echo "Actions: add-memo <content>, search <query>, get-today" >&2
    exit 1
    ;;
esac
