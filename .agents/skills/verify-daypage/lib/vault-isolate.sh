#!/usr/bin/env bash
# vault-isolate.sh — 护栏 1：备份 / 还原真实 vault，避免验证污染用户真实日记。
#
# 用法：
#   vault-isolate.sh backup  <run-dir>
#   vault-isolate.sh restore <run-dir>
#   vault-isolate.sh status  <run-dir>
#
# 备份位置：/tmp/daypage-vault-backup-<run-id>/
# 状态文件：$RUN_DIR/vault.state（备份成功后写 "backed-up"，还原后写 "restored"）

set -euo pipefail

MODE="${1:?mode: backup|restore|status}"
RUN_DIR="${2:?missing run-dir}"
RUN_ID=$(basename "$RUN_DIR")
BACKUP_DIR="/tmp/daypage-vault-backup-${RUN_ID}"

ENV_JSON="$RUN_DIR/env.json"
if [[ ! -f "$ENV_JSON" ]]; then
  echo "[vault] 找不到 $ENV_JSON，先跑 build-and-boot.sh" >&2
  exit 1
fi
SANDBOX_DATA=$(jq -r '.sandboxData' "$ENV_JSON")
VAULT="$SANDBOX_DATA/Documents/vault"

case "$MODE" in
  backup)
    if [[ -e "$BACKUP_DIR" ]]; then
      echo "[vault] 已存在备份 $BACKUP_DIR（上次没还原？）" >&2
      exit 1
    fi
    if [[ -d "$VAULT" ]]; then
      echo "[vault] backup: $VAULT → $BACKUP_DIR"
      mv "$VAULT" "$BACKUP_DIR"
    else
      echo "[vault] 没有真实 vault（首次启动），只做标记"
      mkdir -p "$BACKUP_DIR"
      touch "$BACKUP_DIR/.empty"
    fi
    echo "backed-up" > "$RUN_DIR/vault.state"
    ;;

  restore)
    if [[ ! -e "$BACKUP_DIR" ]]; then
      echo "[vault] 没有待还原的备份 $BACKUP_DIR，跳过" >&2
      exit 0
    fi
    # 删掉验证产生的 vault-verify（其实就是 vault 目录本身，因为 v0 直接复用真实路径）
    if [[ -d "$VAULT" ]]; then
      rm -rf "$VAULT"
    fi
    if [[ -f "$BACKUP_DIR/.empty" ]]; then
      echo "[vault] 原本就没 vault，不还原"
      rm -rf "$BACKUP_DIR"
    else
      echo "[vault] restore: $BACKUP_DIR → $VAULT"
      mv "$BACKUP_DIR" "$VAULT"
    fi
    echo "restored" > "$RUN_DIR/vault.state"
    ;;

  status)
    if [[ -f "$RUN_DIR/vault.state" ]]; then
      cat "$RUN_DIR/vault.state"
    else
      echo "unknown"
    fi
    ;;

  *)
    echo "unknown mode: $MODE" >&2
    exit 2;;
esac
