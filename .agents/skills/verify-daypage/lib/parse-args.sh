#!/usr/bin/env bash
# parse-args.sh — 解析 verify-daypage 参数
# 输出：把结果写入 $RUN_DIR/args.env（后续脚本 source 它）
#
# 用法：parse-args.sh <run-dir> [args...]

set -euo pipefail

RUN_DIR="${1:?missing run-dir}"
shift

WAVE="all"
SMOKE="1"
MOCK_AI="0"
DRY_RUN_ISSUES="0"
DEVICE=""
KEEP_VAULT="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wave)
      WAVE="$2"; shift 2;;
    --wave=*)
      WAVE="${1#*=}"; shift;;
    --smoke)
      SMOKE="1"; shift;;
    --no-smoke)
      SMOKE="0"; shift;;
    --mock-ai)
      MOCK_AI="1"; shift;;
    --dry-run-issues)
      DRY_RUN_ISSUES="1"; shift;;
    --device)
      DEVICE="$2"; shift 2;;
    --device=*)
      DEVICE="${1#*=}"; shift;;
    --keep-vault)
      KEEP_VAULT="1"; shift;;
    *)
      echo "unknown arg: $1" >&2
      exit 2;;
  esac
done

case "$WAVE" in
  w1|w2|w3|w4|w5|all) ;;
  *) echo "invalid --wave: $WAVE (expected w1..w5 or all)" >&2; exit 2;;
esac

if [[ "$MOCK_AI" == "1" ]]; then
  echo "ERROR: --mock-ai is not implemented in v0. Drop the flag or implement it first." >&2
  exit 3
fi

mkdir -p "$RUN_DIR"
cat > "$RUN_DIR/args.env" <<EOF
WAVE=$WAVE
SMOKE=$SMOKE
MOCK_AI=$MOCK_AI
DRY_RUN_ISSUES=$DRY_RUN_ISSUES
DEVICE="$DEVICE"
KEEP_VAULT=$KEEP_VAULT
EOF

echo "parsed args → $RUN_DIR/args.env"
