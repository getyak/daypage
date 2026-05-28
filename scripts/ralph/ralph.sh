#!/bin/bash
# Ralph - Autonomous AI agent loop for Solo Compass
# Each iteration: fresh Claude Code instance → implement single story → test → commit
# Usage: ./ralph.sh [--tool claude] [max_iterations]

set -e
set -o pipefail

TOOL="claude"
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool) TOOL="$2"; shift 2 ;;
    --tool=*) TOOL="${1#*=}"; shift ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$1"; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PRD is at project root, progress is in scripts/ralph/
PRD_FILE="$SCRIPT_DIR/../../prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
echo "🎯 Target branch: $TARGET_BRANCH"

# Verify we're on the correct branch BEFORE first iteration
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  echo "   ⚠️ Not on target branch ($CURRENT_BRANCH ≠ $TARGET_BRANCH) — switching"
  git checkout "$TARGET_BRANCH"
fi

for i in $(seq 1 $MAX_ITERATIONS); do
  echo "═══════════════════════════════════════════════════════════"
  echo "  Iteration $i / $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════════"

  # Guard: ensure we're on the correct branch (Claude Code may have switched it)
  CURRENT_BRANCH=$(git branch --show-current)
  if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
    echo "   ⚠️ Branch drift: on $CURRENT_BRANCH, expected $TARGET_BRANCH — switching back"
    git checkout "$TARGET_BRANCH"
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
  PROMPT="You are implementing a SINGLE user story from the DayPage v8 Museum Aesthetic redesign PRD.

⚠️ CRITICAL: You are working on branch '$TARGET_BRANCH'. NEVER run git checkout, git switch, git branch, or any command that changes the current branch. NEVER push or pull. Only git add and git commit.

PROJECT: DayPage — museum-aesthetic personal logging tool (iOS + Web)
Primary target: both web/ (Next.js App Router, TypeScript strict, Tailwind, pnpm) and iOS (SwiftUI, Xcode). Read AGENTS.md for repo conventions.
PRD source: tasks/prd-daypage-v8-museum-aesthetic.md. Current machine-readable PRD: prd.json.

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
