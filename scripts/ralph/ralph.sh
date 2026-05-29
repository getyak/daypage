#!/bin/bash
# Ralph - Autonomous AI agent loop for Solo Compass
# Each iteration: fresh Claude Code instance → implement single story → test → commit
# Usage: ./ralph.sh [--tool claude] [--prd <file>] [max_iterations]
#   --prd <file>  Path to the PRD json to run (default: <repo-root>/prd.json).
#                 Relative paths resolve against the repo root, so you can run a
#                 specific PRD without renaming prd.json, e.g.:
#                   ./ralph.sh --prd prd.web-vnext.json 25

set -e
set -o pipefail

TOOL="claude"
MAX_ITERATIONS=10
PRD_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool) TOOL="$2"; shift 2 ;;
    --tool=*) TOOL="${1#*=}"; shift ;;
    --prd) PRD_ARG="$2"; shift 2 ;;
    --prd=*) PRD_ARG="${1#*=}"; shift ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$1"; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"

# PRD is at project root by default; --prd overrides it. Relative --prd paths
# resolve against the repo root (an absolute path is used verbatim).
if [ -n "$PRD_ARG" ]; then
  case "$PRD_ARG" in
    /*) PRD_FILE="$PRD_ARG" ;;
    *)  PRD_FILE="$REPO_ROOT/$PRD_ARG" ;;
  esac
else
  PRD_FILE="$REPO_ROOT/prd.json"
fi

if [ ! -f "$PRD_FILE" ]; then
  echo "❌ PRD file not found: $PRD_FILE"
  exit 1
fi

# Init progress file
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# DayPage — Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PROGRESS_FILE"
  echo "Tool: $TOOL" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "🚀 Ralph starting — Tool: $TOOL, Max iterations: $MAX_ITERATIONS"
echo "📋 PRD: $PRD_FILE"
echo ""

# Cache TARGET_BRANCH at start (NEVER re-read from PRD — Claude Code may overwrite it)
TARGET_BRANCH=$(python3 -c "import json; f=open('$PRD_FILE'); print(json.load(f).get('branchName','main'))")
# Cache project name + description so the per-story prompt reflects THIS PRD
# (not a hard-coded one). PRD_REL is the repo-relative PRD path for the prompt.
PRD_PROJECT=$(python3 -c "import json; f=open('$PRD_FILE'); print(json.load(f).get('project','DayPage'))")
PRD_DESC=$(python3 -c "import json; f=open('$PRD_FILE'); print(json.load(f).get('description',''))")
PRD_REL="${PRD_FILE#$REPO_ROOT/}"
echo "🎯 Target branch: $TARGET_BRANCH"

# Verify we're on the correct branch BEFORE first iteration.
# If the branch does not exist yet, create it from main (per Ralph CLAUDE.md:
# "check it out or create from main").
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  if git rev-parse --verify --quiet "$TARGET_BRANCH" >/dev/null; then
    echo "   ⚠️ Not on target branch ($CURRENT_BRANCH ≠ $TARGET_BRANCH) — switching"
    git checkout "$TARGET_BRANCH"
  else
    echo "   ⚠️ Target branch $TARGET_BRANCH does not exist — creating from main"
    git checkout -b "$TARGET_BRANCH" main
  fi
fi

for i in $(seq 1 $MAX_ITERATIONS); do
  echo "═══════════════════════════════════════════════════════════"
  echo "  Iteration $i / $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════════"

  # Guard: ensure we're on the correct branch (Claude Code may have switched it)
  CURRENT_BRANCH=$(git branch --show-current)
  if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
    echo "   ⚠️ Branch drift: on $CURRENT_BRANCH, expected $TARGET_BRANCH — switching back"
    if git rev-parse --verify --quiet "$TARGET_BRANCH" >/dev/null; then
      git checkout "$TARGET_BRANCH"
    else
      git checkout -b "$TARGET_BRANCH" main
    fi
  fi

  # Find next incomplete story
  STORY=$(python3 -c "
import json, sys
with open('$PRD_FILE') as f:
    prd = json.load(f)
items = prd.get('stories', prd.get('userStories', []))
incomplete = [s for s in items if not s['passes']]
if not incomplete:
    print('ALL_DONE')
    sys.exit(0)
story = incomplete[0]
print(json.dumps(story))
")

  if [ "$STORY" = "ALL_DONE" ]; then
    echo "✅ ALL STORIES COMPLETE!"
    echo "All stories pass: true" >> "$PROGRESS_FILE"
    exit 0
  fi

  STORY_ID=$(echo "$STORY" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  STORY_NAME=$(echo "$STORY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name', d.get('title','')))")
  STORY_DESC=$(echo "$STORY" | python3 -c "import json,sys; print(json.load(sys.stdin)['description'])")
  # acceptanceCriteria is an array — join with newlines for the prompt
  STORY_ACCEPT=$(echo "$STORY" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ac = d.get('acceptance', d.get('acceptanceCriteria', []))
if isinstance(ac, list):
    print('\n'.join(f'- {a}' for a in ac))
else:
    print(ac)
")

  echo "📌 Story #$STORY_ID: $STORY_NAME"
  echo "   Acceptance: $STORY_ACCEPT"

  # Build the Claude Code prompt
  PROMPT="You are implementing a SINGLE user story from the $PRD_PROJECT PRD.

⚠️ CRITICAL: You are working on branch '$TARGET_BRANCH'. NEVER run git checkout, git switch, git branch, or any command that changes the current branch. NEVER push or pull. Only git add and git commit.

PROJECT: $PRD_PROJECT
PRD: $PRD_DESC
Read AGENTS.md (and web/CLAUDE.md for web stories) for repo conventions.
Current machine-readable PRD: $PRD_REL.

STORY #$STORY_ID: $STORY_NAME
DESCRIPTION: $STORY_DESC
ACCEPTANCE CRITERIA:
$STORY_ACCEPT

Implement ONLY this story. Do NOT touch unrelated code. Keep changes focused and minimal.
After implementing:
1. For Web stories: cd web && pnpm run build
2. For iOS stories: xcodebuild -scheme DayPage build CODE_SIGNING_ALLOWED=NO -destination 'generic/platform=iOS Simulator'
3. For both: run both commands above
4. Print a summary of what you changed
5. The acceptance criteria must be satisfied"

  echo "   🤖 Running Claude Code..."

  # Run Claude Code in the repo root
  cd "$REPO_ROOT"
  
  if claude -p "$PROMPT" \
    --allowedTools "Read,Write,Edit,Bash" \
    --max-turns 40 \
    --effort high \
    --output-format json \
    --dangerously-skip-permissions 2>&1 | tee /tmp/ralph-output-$i.json; then
    
    echo "   ✅ Story #$STORY_ID implemented successfully"

    # Mark story as passes: true (BEFORE commit so it's included)
    python3 -c "
import json
with open('$PRD_FILE') as f:
    prd = json.load(f)
for s in prd.get('stories', prd.get('userStories', [])):
    if s['id'] == '$STORY_ID':
        s['passes'] = True
        break
with open('$PRD_FILE', 'w') as f:
    json.dump(prd, f, indent=2)
"
    echo "   ✔️ Story #$STORY_ID marked as passes: true"

    # Log progress
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Story #$STORY_ID: $STORY_NAME — PASSED" >> "$PROGRESS_FILE"

    # Git add + commit (includes PRD mark AND progress)
    cd "$REPO_ROOT"
    if git diff --quiet && git diff --cached --quiet; then
      echo "   ⚠️ No changes to commit"
    else
      git add -A
      git commit -m "fix: story #$STORY_ID — $STORY_NAME

Implemented: $STORY_DESC
Acceptance: $STORY_ACCEPT"
      echo "   📝 Committed: story #$STORY_ID"
    fi

  else
    echo "   ❌ Story #$STORY_ID FAILED"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Story #$STORY_ID: $STORY_NAME — FAILED (iteration $i)" >> "$PROGRESS_FILE"
    
    # Don't exit — continue to next iteration (Claude may fix it in next pass)
  fi

  echo ""
done

echo "🏁 Ralph complete after $MAX_ITERATIONS iterations"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ralph complete after $MAX_ITERATIONS iterations" >> "$PROGRESS_FILE"

# Report remaining incomplete stories
REMAINING=$(python3 -c "
import json
with open('$PRD_FILE') as f:
    prd = json.load(f)
remaining = [s.get('name', s.get('title', '?')) for s in prd.get('stories', prd.get('userStories', [])) if not s['passes']]
if remaining:
    print('Remaining: ' + ', '.join(remaining))
else:
    print('All complete! 🎉')
")
echo "📊 $REMAINING"
