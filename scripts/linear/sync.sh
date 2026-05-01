#!/usr/bin/env bash
# =============================================================================
# linear-sync.sh — General-purpose Linear ↔ GitHub sync utilities
#
# Commands:
#   status DAY-42              Show issue status/details
#   move  DAY-42 in-progress   Move issue to a state
#   comment DAY-42 "text"      Add a comment
#   link-pr DAY-42             Link current branch PR to Linear
#   create "Title" "Body"      Create a new Linear issue
#   list [filter]              List issues
#   close DAY-42               Mark issue as Done
# =============================================================================

set -euo pipefail

LINEAR_API_KEY="${LINEAR_API_KEY:-}"

STATE_TODO="ef0366f3-edde-4889-a633-b908c6be8ae2"
STATE_IN_PROGRESS="9b3b8f1a-e816-4ffd-b864-1b9b79a5e7ac"
STATE_IN_REVIEW="e7a1b7ef-bed6-4167-9331-24d867443b81"
STATE_DONE="0ccb1b40-6513-486f-9b03-1903b166b669"
STATE_CANCELED="b4749b49-f3e9-4814-999c-e7bddfa10e77"
STATE_BACKLOG="3745a8d5-2f7a-4a88-b9f3-3c0f11fff869"

TEAM_ID="6f56b048-0155-4f2f-be96-20aa5dafe0a9"

# ── State mapping ──
state_to_id() {
  case "${1,,}" in
    todo|unstarted)       echo "$STATE_TODO" ;;
    in-progress|started)  echo "$STATE_IN_PROGRESS" ;;
    in-review|review)     echo "$STATE_IN_REVIEW" ;;
    done|completed)       echo "$STATE_DONE" ;;
    canceled|cancelled)   echo "$STATE_CANCELED" ;;
    backlog|backlog)      echo "$STATE_BACKLOG" ;;
    *) echo "unknown" ;;
  esac
}

# ── API helpers ──
linear_query() {
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$1"
}

# ── Commands ──
cmd_status() {
  local issue_id="$1"
  local response
  response=$(linear_query '{"query":"{ issue(id: \"'"$issue_id"'\") { identifier title description priority state { name type } assignee { name } labels { nodes { name } } url createdAt updatedAt } }"}')

  echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
i = d.get('data', {}).get('issue', {})
if not i:
    print('Issue not found')
    sys.exit(1)

labels = ', '.join(l['name'] for l in i.get('labels', {}).get('nodes', [])) or 'none'
assignee = (i.get('assignee') or {}).get('name', 'Unassigned')
state = i.get('state', {})

print(f'''
{'='*60}
  {i['identifier']}: {i['title']}
{'='*60}
  Status:    {state.get('name', '?')} ({state.get('type', '?')})
  Priority:  {i.get('priority', '?')}
  Assignee:  {assignee}
  Labels:    {labels}
  Created:   {i.get('createdAt', '?')}
  Updated:   {i.get('updatedAt', '?')}
  URL:       {i.get('url', '?')}
{'='*60}
''')
"
}

cmd_move() {
  local issue_id="$1"
  local target_state="$2"
  local state_id
  state_id=$(state_to_id "$target_state")

  if [ "$state_id" = "unknown" ]; then
    echo "❌ Unknown state: $target_state"
    echo "   Valid: todo, in-progress, in-review, done, canceled, backlog"
    exit 1
  fi

  local response
  response=$(linear_query '{"query":"mutation { issueUpdate(id: \"'"$issue_id"'\", input: { stateId: \"'"$state_id"'\" }) { success issue { identifier state { name } } } }"}')

  echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('data', {}).get('issueUpdate', {}).get('success'):
    i = d['data']['issueUpdate']['issue']
    print(f'✅ {i[\"identifier\"]} → {i[\"state\"][\"name\"]}')
else:
    print(f'❌ Failed: {d.get(\"errors\", \"unknown\")}')
"
}

cmd_comment() {
  local issue_id="$1"
  local body="$2"

  # Use Python for the full call to handle JSON escaping properly
  python3 -c "
import json, os, sys, urllib.request, ssl

body = sys.argv[1]
issue_id = sys.argv[2]
api_key = os.environ.get('LINEAR_API_KEY', '')

payload = {
    'query': 'mutation { commentCreate(input: { issueId: \"%s\", body: %s }) { success } }' % (issue_id, json.dumps(body))
}

# Simple SSL context
ctx = ssl.create_default_context()

req = urllib.request.Request(
    'https://api.linear.app/graphql',
    data=json.dumps(payload).encode('utf-8'),
    headers={'Authorization': api_key, 'Content-Type': 'application/json'},
    method='POST'
)

resp = urllib.request.urlopen(req, timeout=10, context=ctx)
data = json.loads(resp.read())
print('✅ Comment added' if data.get('data', {}).get('commentCreate', {}).get('success') else '❌ Failed')
" "$body" "$issue_id" 2>&1
}

cmd_create() {
  local title="$1"
  local description="${2:-}"
  local title_esc desc_esc
  title_esc=$(echo "$title" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
  desc_esc=$(echo "$description" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

  local response
  response=$(linear_query '{"query":"mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }","variables":{"input":{"teamId":"'"$TEAM_ID"'","title":'"$title_esc"',"description":'"$desc_esc"',"priority":3}}}')

  echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('data', {}).get('issueCreate', {}).get('success'):
    i = d['data']['issueCreate']['issue']
    print(f'✅ Created: {i[\"identifier\"]} — {i[\"url\"]}')
else:
    print(f'❌ Failed: {d.get(\"errors\", \"unknown\")}')
"
}

cmd_list() {
  local filter="${1:-}"
  local query

  if [ -n "$filter" ]; then
    query='{"query":"{ issueSearch(query: \"'"$filter"'\", first: 20) { nodes { identifier title state { name } priority assignee { name } url } } }"}'
  else
    query='{"query":"{ issues(first: 20, filter: { team: { id: { eq: \"'"$TEAM_ID"'\" } } }) { nodes { identifier title state { name type } priority assignee { name } url } } }"}'
  fi

  local response
  response=$(linear_query "$query")

  echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)

# Try issueSearch first, then issues
nodes = []
if 'issueSearch' in d.get('data', {}):
    nodes = d['data']['issueSearch'].get('nodes', [])
elif 'issues' in d.get('data', {}):
    nodes = d['data']['issues'].get('nodes', [])

if not nodes:
    print('No issues found')
    sys.exit(0)

print(f'\\n{\"ID\":<12} {\"Priority\":<8} {\"Status\":<16} {\"Assignee\":<14} Title')
print('-' * 90)
for i in nodes:
    state = (i.get('state') or {}).get('name', '?')
    assignee = (i.get('assignee') or {}).get('name', 'Unassigned')
    prio = ['','Urgent','High','Medium','Low'][i.get('priority', 3)] if i.get('priority', 0) > 0 else 'None'
    print(f'{i[\"identifier\"]:<12} {prio:<8} {state:<16} {assignee:<14} {i[\"title\"][:50]}')
print()
"
}

cmd_close() {
  local issue_id="$1"
  cmd_move "$issue_id" "done"
}

cmd_link_pr() {
  local issue_id="$1"
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "")

  if [ -z "$branch" ]; then
    echo "❌ Not in a git repository or no current branch"
    exit 1
  fi

  # Check if branch already has a PR
  local pr_number
  pr_number=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")

  if [ -z "$pr_number" ]; then
    echo "📝 Creating PR for $branch..."

    ISSUE_DETAILS=$(linear_query '{"query":"{ issue(id: \"'"$issue_id"'\") { title description } }"}')
    ISSUE_TITLE=$(echo "$ISSUE_DETAILS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['issue']['title'])" 2>/dev/null)

    PR_TITLE="feat: $issue_id — ${ISSUE_TITLE:-Update}"
    PR_BODY="Closes $issue_id\n\n<!-- Linear: https://linear.app/daypage/issue/$issue_id -->"

    gh pr create \
      --title "$PR_TITLE" \
      --body "$(printf '%b' "$PR_BODY")" \
      --base main

    echo "✅ PR created and linked to $issue_id"
  else
    echo "PR #$pr_number already exists for this branch"
    echo "Linking to $issue_id..."
    cmd_comment "$issue_id" "🔗 PR: https://github.com/getyak/daypage/pull/$pr_number"
  fi
}

# ── Main ──
main() {
  [[ -z "$LINEAR_API_KEY" ]] && { echo "❌ LINEAR_API_KEY not set"; exit 1; }

  local cmd="${1:-help}"

  case "$cmd" in
    status|show|info)
      [[ -z "${2:-}" ]] && { echo "Usage: $0 status DAY-42"; exit 1; }
      cmd_status "$2"
      ;;
    move|transition)
      [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: $0 move DAY-42 in-progress"; exit 1; }
      cmd_move "$2" "$3"
      ;;
    comment|note)
      [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: $0 comment DAY-42 'text'"; exit 1; }
      cmd_comment "$2" "$3"
      ;;
    create|new)
      [[ -z "${2:-}" ]] && { echo "Usage: $0 create 'Title' ['Body']"; exit 1; }
      cmd_create "$2" "${3:-}"
      ;;
    list|ls)
      cmd_list "${2:-}"
      ;;
    close|complete|finish)
      [[ -z "${2:-}" ]] && { echo "Usage: $0 close DAY-42"; exit 1; }
      cmd_close "$2"
      ;;
    link-pr|pr)
      [[ -z "${2:-}" ]] && { echo "Usage: $0 link-pr DAY-42"; exit 1; }
      cmd_link_pr "$2"
      ;;
    help|-h|--help|*)
      cat <<EOF
Usage: linear-sync.sh COMMAND [ARGS]

Commands:
  status  ID        Show issue details
  move    ID STATE  Move issue to state (todo|in-progress|in-review|done|canceled)
  comment ID TEXT   Add a comment
  create  TITLE [BODY]  Create a new issue
  list    [FILTER]  List team issues
  close   ID        Mark issue as Done
  link-pr ID        Create PR and link to Linear issue

Examples:
  linear-sync.sh status DAY-42
  linear-sync.sh move DAY-42 in-progress
  linear-sync.sh comment DAY-42 "Working on this now"
  linear-sync.sh create "Fix login bug" "Users cannot login with SSO"
  linear-sync.sh list "status:in-progress"
  linear-sync.sh link-pr DAY-42

Requires: LINEAR_API_KEY env var
EOF
      ;;
  esac
}

main "$@"
