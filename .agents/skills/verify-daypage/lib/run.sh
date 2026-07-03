#!/usr/bin/env bash
# run.sh — verify-daypage 主入口。串起所有步骤，带 trap 兜底还原 vault。
#
# 用法（从仓库根调用）：
#   bash .claude/skills/verify-daypage/lib/run.sh [args...]
#
# Claude 在 skill 里调这个脚本。参数同 SKILL.md 中的约定。

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$SKILL_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
echo "[run] run-id=$RUN_ID"
echo "[run] run-dir=$RUN_DIR"

# 1. 解析参数
bash "$SKILL_DIR/lib/parse-args.sh" "$RUN_DIR" "$@"
# shellcheck disable=SC1091
source "$RUN_DIR/args.env"

# 2. 预检
bash "$SKILL_DIR/lib/preflight.sh"

# 3. build + boot（先于 vault-isolate，因为 vault-isolate 需要 sandbox 路径）
bash "$SKILL_DIR/lib/build-and-boot.sh" "$RUN_DIR" "$DEVICE"

# 4. 隔离 vault，注册 trap
RESTORED=0
restore_vault() {
  if [[ "$RESTORED" == "1" ]]; then return; fi
  if [[ "$KEEP_VAULT" == "1" ]]; then
    echo "[run] --keep-vault：不还原，备份在 /tmp/daypage-vault-backup-$RUN_ID"
    RESTORED=1
    return
  fi
  echo "[run] trap：还原真实 vault"
  bash "$SKILL_DIR/lib/vault-isolate.sh" restore "$RUN_DIR" || true
  RESTORED=1
}
trap restore_vault EXIT INT TERM

bash "$SKILL_DIR/lib/vault-isolate.sh" backup "$RUN_DIR"

# 5. 挑选 story
REGISTRY="$SKILL_DIR/stories/_registry.tsv"
STORIES=()
while IFS=$'\t' read -r sid w smoke title script; do
  [[ "$sid" == "story-id" ]] && continue
  if [[ "$WAVE" != "all" && "$w" != "$WAVE" ]]; then continue; fi
  if [[ "$SMOKE" == "1" && "$smoke" != "1" ]]; then continue; fi
  STORIES+=("$sid|$w|$title|$script")
done < "$REGISTRY"

if [[ ${#STORIES[@]} -eq 0 ]]; then
  echo "[run] 没挑到任何 story，检查参数 WAVE=$WAVE SMOKE=$SMOKE" >&2
  exit 1
fi

echo "[run] 将跑 ${#STORIES[@]} 个 story："
for s in "${STORIES[@]}"; do echo "  - ${s%%|*}"; done

# 6. 逐条跑 + 建 issue
PASS=0; FAIL=0; SKIP=0
for s in "${STORIES[@]}"; do
  IFS='|' read -r sid w title script <<< "$s"
  echo ""
  echo "================================================================"
  echo "[$sid] $title"
  echo "================================================================"
  mkdir -p "$RUN_DIR/$sid"
  set +e
  bash "$SKILL_DIR/$script" "$RUN_DIR" "$sid" "$w" "$title"
  rc=$?
  set -e
  case $rc in
    0) echo "[$sid] ✓ pass"; PASS=$((PASS+1));;
    1)
      echo "[$sid] ✗ fail"; FAIL=$((FAIL+1))
      if [[ "$DRY_RUN_ISSUES" == "1" ]]; then
        bash "$SKILL_DIR/lib/issue-create.sh" "$RUN_DIR" "$sid" --dry-run
      else
        bash "$SKILL_DIR/lib/issue-create.sh" "$RUN_DIR" "$sid"
      fi;;
    2) echo "[$sid] ⊘ skip"; SKIP=$((SKIP+1));;
    *) echo "[$sid] ⚠ unexpected rc=$rc，计 fail"; FAIL=$((FAIL+1));;
  esac
done

# 7. 汇总
REPORT="$RUN_DIR/report.md"
{
  echo "# verify-daypage run \`$RUN_ID\`"
  echo ""
  echo "- WAVE=$WAVE  SMOKE=$SMOKE  DRY_RUN_ISSUES=$DRY_RUN_ISSUES"
  echo "- **pass=$PASS  fail=$FAIL  skip=$SKIP**"
  echo ""
  echo "| story | wave | status | issue |"
  echo "|---|---|---|---|"
  for s in "${STORIES[@]}"; do
    IFS='|' read -r sid w title script <<< "$s"
    if [[ -f "$RUN_DIR/$sid/result.json" ]]; then
      st=$(jq -r '.status' "$RUN_DIR/$sid/result.json")
    else
      st="?"
    fi
    url=""
    [[ -f "$RUN_DIR/$sid/issue-url.txt" ]] && url=$(cat "$RUN_DIR/$sid/issue-url.txt")
    [[ -f "$RUN_DIR/$sid/issue-number.txt" ]] && url="#$(cat "$RUN_DIR/$sid/issue-number.txt")"
    echo "| $sid | $w | $st | $url |"
  done
} > "$REPORT"

echo ""
echo "[run] 报告：$REPORT"
echo "[run] 汇总：pass=$PASS  fail=$FAIL  skip=$SKIP"

# EXIT trap 会还原 vault
exit 0
