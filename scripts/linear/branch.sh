#!/usr/bin/env bash
# =============================================================================
# linear-branch.sh — Create a git branch from a Linear issue
#
# Usage:
#   bash scripts/linear/branch.sh DAY-42
#   bash scripts/linear/branch.sh DAY-42 --type feat
#   bash scripts/linear/branch.sh DAY-42 --base main
#
# Output:
#   Creates and checks out: feat/DAY-42-issue-title-slug
# =============================================================================

set -euo pipefail

LINEAR_API_KEY="${LINEAR_API_KEY:-}"
LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-6f56b048-0155-4f2f-be96-20aa5dafe0a9}"

# ── Help ──
if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  cat <<EOF
Usage: linear-branch.sh ISSUE_ID [options]

Options:
  --type TYPE    Branch prefix (default: feat). Options: feat, fix, chore, refactor
  --base BRANCH  Base branch (default: main)

Examples:
  linear-branch.sh DAY-42
  linear-branch.sh DAY-42 --type fix
  linear-branch.sh DAY-42 --type feat --base develop

Requires:
  - LINEAR_API_KEY in env
  - curl, git, gh CLI (logged in)
EOF
  exit 0
fi

ISSUE_ID="${1:-}"
[[ -z "$ISSUE_ID" ]] && { echo "❌ Missing issue ID (e.g. DAY-42)"; exit 1; }

# ── Parse options ──
BRANCH_TYPE="feat"
BASE_BRANCH="main"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) BRANCH_TYPE="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Check prerequisites ──
command -v curl >/dev/null 2>&1 || { echo "❌ curl required"; exit 1; }
[[ -z "$LINEAR_API_KEY" ]] && { echo "❌ LINEAR_API_KEY not set"; exit 1; }

# ── Fetch issue details ──
echo "🔍 Fetching $ISSUE_ID from Linear..."

RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ issue(id: \"'"$ISSUE_ID"'\") { id identifier title description state { name type } assignee { name } labels { nodes { name } } url } }"}')

# Check for errors
if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(1 if d.get('errors') else 0)" 2>/dev/null; then
  ERRORS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errors',[]))" 2>/dev/null)
  echo "❌ Linear API error: $ERRORS"
  exit 1
fi

TITLE=$(echo "$RESPONSE" | python3 -c "
import sys,json,re
d=json.load(sys.stdin)
issue=d.get('data',{}).get('issue',{})
print(issue.get('title',''))
")

STATE=$(echo "$RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
issue=d.get('data',{}).get('issue',{})
state=issue.get('state',{})
print(f'{state.get(\"name\",\"?\")} ({state.get(\"type\",\"?\")})')
")

ASSIGNEE=$(echo "$RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
issue=d.get('data',{}).get('issue',{})
a=issue.get('assignee') or {}
print(a.get('name','Unassigned'))
")

LABELS=$(echo "$RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
issue=d.get('data',{}).get('issue',{})
labels=issue.get('labels',{}).get('nodes',[])
print(', '.join(l['name'] for l in labels) if labels else 'none')
")

[[ -z "$TITLE" ]] && { echo "❌ Issue $ISSUE_ID not found"; exit 1; }

echo ""
echo "  📋 $ISSUE_ID: $TITLE"
echo "  📊 Status:  $STATE"
echo "  👤 Assignee: $ASSIGNEE"
echo "  🏷 Labels:   $LABELS"
echo ""

# ── Generate branch name slug ──
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
BRANCH="${BRANCH_TYPE}/${ISSUE_ID,,}-${SLUG}"  # lowercase DAY-42
BRANCH=$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]')

echo "🌿 Branch: $BRANCH"
echo "📌 Base:   $BASE_BRANCH"
echo ""

# ── Confirm ──
read -r -p "Create and checkout this branch? [Y/n] " confirm
[[ "$confirm" =~ ^[Nn] ]] && { echo "Cancelled."; exit 0; }

# ── Create branch ──
git fetch origin "$BASE_BRANCH" 2>/dev/null || true
git checkout -b "$BRANCH" "origin/$BASE_BRANCH" 2>/dev/null || git checkout -b "$BRANCH"

echo ""
echo "✅ Branch created: $BRANCH"
echo ""
echo "Next steps:"
echo "  1. Make your changes"
echo "  2. git commit -m \"feat: $ISSUE_ID — $TITLE\""
echo "  3. git push -u origin $BRANCH"
echo "  4. Create PR: Closes $ISSUE_ID"

# ── Optionally move issue to "In Progress" ──
STATE_IN_PROGRESS="9b3b8f1a-e816-4ffd-b864-1b9b79a5e7ac"

read -r -p "Move $ISSUE_ID to \"In Progress\"? [Y/n] " move
if [[ ! "$move" =~ ^[Nn] ]]; then
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query":"mutation { issueUpdate(id: \"'"$ISSUE_ID"'\", input: { stateId: \"'"$STATE_IN_PROGRESS"'\" }) { success } }"}' > /dev/null
  echo "📊 $ISSUE_ID → In Progress"
fi

# ── Assign to self ──
VIEWER_ID=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id } }"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['viewer']['id'])" 2>/dev/null)

if [ -n "$VIEWER_ID" ] && [ "$ASSIGNEE" = "Unassigned" ]; then
  read -r -p "Assign $ISSUE_ID to yourself? [Y/n] " assign
  if [[ ! "$assign" =~ ^[Nn] ]]; then
    curl -s -X POST https://api.linear.app/graphql \
      -H "Authorization: $LINEAR_API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"query":"mutation { issueUpdate(id: \"'"$ISSUE_ID"'\", input: { assigneeId: \"'"$VIEWER_ID"'\" }) { success } }"}' > /dev/null
    echo "👤 Assigned to you"
  fi
fi
