#!/usr/bin/env bash
# build-and-boot.sh — build DayPage Debug，boot Simulator，install，launch。
# 输出 env.json 到 $RUN_DIR（含 sandbox data 路径、device-id、app-bundle-id）。
#
# 用法：build-and-boot.sh <run-dir> [device-name]

set -euo pipefail

RUN_DIR="${1:?missing run-dir}"
DEVICE_NAME="${2:-}"
BUNDLE_ID="com.daypage.app"
SCHEME="DayPage"

mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/build.log"

# 1. 解析 device id
if [[ -z "$DEVICE_NAME" ]]; then
  # 优先已 Booted 的设备
  DEVICE_ID=$(xcrun simctl list devices -j | jq -r '
    [.devices[][] | select(.state == "Booted") | .udid] | .[0] // empty
  ')
  if [[ -z "$DEVICE_ID" ]]; then
    # 再退回第一个可用 iPhone 15
    DEVICE_ID=$(xcrun simctl list devices -j | jq -r '
      [.devices[][] | select(.isAvailable == true and (.name | test("iPhone 1[5-9]"))) | .udid] | .[0] // empty
    ')
  fi
else
  DEVICE_ID=$(xcrun simctl list devices -j | jq -r --arg name "$DEVICE_NAME" '
    [.devices[][] | select(.name == $name and .isAvailable == true) | .udid] | .[0] // empty
  ')
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "[boot] 没找到可用设备（name=$DEVICE_NAME）" >&2
  exit 1
fi
echo "[boot] device-id=$DEVICE_ID"

# 2. boot（已 Booted 会报错，忽略）
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$DEVICE_ID" || true

# 3. build
echo "[build] xcodebuild Debug → $LOG"
APP_PATH_LOG="$RUN_DIR/build-settings.log"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$RUN_DIR/DerivedData" \
  build >"$LOG" 2>&1

APP_PATH=$(find "$RUN_DIR/DerivedData/Build/Products/Debug-iphonesimulator" -name "*.app" -maxdepth 2 | head -1)
if [[ -z "$APP_PATH" ]]; then
  echo "[build] 没找到 .app 产物，看 $LOG" >&2
  exit 1
fi
echo "[build] app-path=$APP_PATH"

# 4. install + launch
xcrun simctl install "$DEVICE_ID" "$APP_PATH"
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" >/dev/null

# 5. 解析 sandbox data 路径（用于 vault 隔离 + 读日志）
SANDBOX_DATA=$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)
echo "[boot] sandbox-data=$SANDBOX_DATA"

cat > "$RUN_DIR/env.json" <<EOF
{
  "deviceId": "$DEVICE_ID",
  "bundleId": "$BUNDLE_ID",
  "appPath": "$APP_PATH",
  "sandboxData": "$SANDBOX_DATA",
  "runDir": "$RUN_DIR"
}
EOF
echo "[boot] → $RUN_DIR/env.json"
