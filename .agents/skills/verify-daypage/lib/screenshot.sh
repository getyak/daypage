#!/usr/bin/env bash
# screenshot.sh — 给当前 Simulator 截图，MD5 去重跳过相同帧。
# 用法：screenshot.sh <run-dir> <story-id> <slug>

set -euo pipefail

RUN_DIR="${1:?missing run-dir}"
STORY_ID="${2:?missing story-id}"
SLUG="${3:?missing slug}"

DEVICE_ID=$(jq -r '.deviceId' "$RUN_DIR/env.json")
OUT_DIR="$RUN_DIR/$STORY_ID/screenshots"
mkdir -p "$OUT_DIR"
TS=$(date +%H%M%S)
TMP="$OUT_DIR/.tmp-${TS}-${SLUG}.png"
OUT="$OUT_DIR/${TS}-${SLUG}.png"

xcrun simctl io "$DEVICE_ID" screenshot "$TMP" >/dev/null

# MD5 dedup: skip if identical to the most recent screenshot in this dir
if command -v md5sum >/dev/null 2>&1; then
  NEW_HASH=$(md5sum "$TMP" | awk '{print $1}')
else
  NEW_HASH=$(md5 -q "$TMP")
fi

PREV=$(find "$OUT_DIR" -name "*.png" ! -name ".tmp-*" | sort | tail -1)
if [[ -n "$PREV" ]]; then
  if command -v md5sum >/dev/null 2>&1; then
    PREV_HASH=$(md5sum "$PREV" | awk '{print $1}')
  else
    PREV_HASH=$(md5 -q "$PREV")
  fi
  if [[ "$NEW_HASH" == "$PREV_HASH" ]]; then
    echo "[screenshot] dedupe: $SLUG identical to $(basename "$PREV"), skipping" >&2
    rm -f "$TMP"
    echo "$PREV"
    exit 0
  fi
fi

mv "$TMP" "$OUT"
echo "$OUT"
