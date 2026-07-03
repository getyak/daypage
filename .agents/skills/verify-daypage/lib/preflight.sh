#!/usr/bin/env bash
# preflight.sh — 环境预检。缺啥就报啥。

set -euo pipefail

FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name" >&2
    FAIL=1
  fi
}

echo "[preflight] 检查依赖…"
check "xcodebuild"        xcodebuild -version
check "xcrun simctl"      xcrun simctl help
check "gh (GitHub CLI)"   gh --version
check "gh auth"           gh auth status
check "jq"                jq --version
check "plutil"            plutil -help

# DashScope key 在 Config/GeneratedSecrets.swift 里，编译时嵌入。
# 只有在 --mock-ai 时才允许它为空，其他情况需要 scripts/generate_secrets.sh 已跑过。
SECRETS="DayPage/Config/GeneratedSecrets.swift"
if [[ ! -f "$SECRETS" ]]; then
  echo "  ✗ $SECRETS 不存在，跑 scripts/generate_secrets.sh" >&2
  FAIL=1
else
  if grep -q 'dashScopeApiKey = ""' "$SECRETS" 2>/dev/null; then
    echo "  ✗ DashScope key 为空，跑 scripts/generate_secrets.sh" >&2
    FAIL=1
  else
    echo "  ✓ GeneratedSecrets.swift 就绪"
  fi
fi

if [[ "$FAIL" == "1" ]]; then
  echo "[preflight] ✗ 失败，修完再跑" >&2
  exit 1
fi
echo "[preflight] ✓ 全部就绪"
