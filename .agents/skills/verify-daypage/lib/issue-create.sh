#!/usr/bin/env bash
# issue-create.sh — fail 的 story 自动建 GitHub issue，带去重。
#
# 用法：issue-create.sh <run-dir> <story-id> [--dry-run]
#
# 去重逻辑：
#   1. gh issue list --label verify-daypage --search "[<story-id>]" --state open
#   2. 找到 → 追加评论（附截图）
#   3. 没找到 → gh issue create，title 带 [<story-id>] 前缀，打 label

set -euo pipefail

RUN_DIR="${1:?missing run-dir}"
STORY_ID="${2:?missing story-id}"
DRY_RUN="${3:-}"

RESULT="$RUN_DIR/$STORY_ID/result.json"
if [[ ! -f "$RESULT" ]]; then
  echo "[issue] 没找到 $RESULT" >&2
  exit 1
fi

STATUS=$(jq -r '.status' "$RESULT")
if [[ "$STATUS" != "fail" ]]; then
  echo "[issue] story $STORY_ID status=$STATUS，跳过建 issue"
  exit 0
fi

TITLE_CORE=$(jq -r '.storyTitle' "$RESULT")
WAVE=$(jq -r '.wave' "$RESULT")
TITLE="[$STORY_ID] $TITLE_CORE"

# 渲染 body
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/issue-body.md"
RUN_ID=$(basename "$RUN_DIR")
BODY=$(
  awk -v run_id="$RUN_ID" \
      -v story_id="$STORY_ID" \
      -v wave="$WAVE" \
      -v result_path="$RESULT" \
      '
      {
        gsub(/\{\{RUN_ID\}\}/, run_id)
        gsub(/\{\{STORY_ID\}\}/, story_id)
        gsub(/\{\{WAVE\}\}/, wave)
        print
      }
      ' "$TEMPLATE"
  echo
  echo "## result.json"
  echo '```json'
  cat "$RESULT"
  echo '```'
)

# 去重：搜同前缀 + open 状态
EXISTING=$(gh issue list \
  --label verify-daypage \
  --search "in:title \"[$STORY_ID]\"" \
  --state open \
  --json number,title \
  --limit 5 \
  2>/dev/null | jq -r '.[0].number // empty')

if [[ "$DRY_RUN" == "--dry-run" || "${DRY_RUN_ISSUES:-0}" == "1" ]]; then
  DRAFT="$RUN_DIR/$STORY_ID/issue-draft.md"
  {
    echo "# [DRY-RUN] $TITLE"
    echo
    echo "$BODY"
  } > "$DRAFT"
  echo "[issue] dry-run → $DRAFT"
  if [[ -n "$EXISTING" ]]; then
    echo "[issue] （注：真跑时会追加到 #$EXISTING）"
  fi
  exit 0
fi

if [[ -n "$EXISTING" ]]; then
  echo "[issue] 追加评论到 #$EXISTING"
  COMMENT=$(
    echo "### 🔁 Re-verification failure — run \`$RUN_ID\`"
    echo
    echo "$BODY"
  )
  gh issue comment "$EXISTING" --body "$COMMENT"
  echo "$EXISTING" > "$RUN_DIR/$STORY_ID/issue-number.txt"
else
  echo "[issue] 新建 issue"
  URL=$(gh issue create \
    --title "$TITLE" \
    --body "$BODY" \
    --label "verify-daypage" \
    --label "wave-$WAVE" \
    --label "auto-generated" \
    --label "story-$STORY_ID")
  echo "[issue] $URL"
  echo "$URL" > "$RUN_DIR/$STORY_ID/issue-url.txt"
fi
