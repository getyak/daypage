#!/bin/zsh
set -eu
# Lightweight SDK type checks; no linking, Simulator launch, package download or signing.
# Run through dev-ios-session; pass a registered task artifact directory.
task_artifact=$1
mkdir -p "$task_artifact/ios-modules" "$task_artifact/watch-modules"
task_ios_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
task_watch_sdk=$(xcrun --sdk watchsimulator --show-sdk-path)
swiftc -swift-version 5 -parse-as-library -emit-module -module-name DayPageCapture \
  -target arm64-apple-ios16.1-simulator -sdk "$task_ios_sdk" \
  -emit-module-path "$task_artifact/ios-modules/DayPageCapture.swiftmodule" DayPageCore/Sources/DayPageCapture/*.swift
swiftc -swift-version 5 -parse-as-library -emit-module -module-name DayPageCore \
  -target arm64-apple-ios16.1-simulator -sdk "$task_ios_sdk" -I "$task_artifact/ios-modules" \
  -emit-module-path "$task_artifact/ios-modules/DayPageCore.swiftmodule" DayPageCore/Sources/DayPageCore/*.swift
swiftc -swift-version 5 -typecheck -target arm64-apple-ios16.1-simulator -sdk "$task_ios_sdk" \
  -I "$task_artifact/ios-modules" DayPageLocal/CloudContinuity.swift DayPageLocal/WatchPhoneBridge.swift \
  DayPageLocal/ContinuitySettingsView.swift DayPageLocal/NotebookTheme.swift
swiftc -swift-version 5 -parse-as-library -emit-module -module-name DayPageCapture \
  -target arm64-apple-watchos9.0-simulator -sdk "$task_watch_sdk" \
  -emit-module-path "$task_artifact/watch-modules/DayPageCapture.swiftmodule" DayPageCore/Sources/DayPageCapture/*.swift
swiftc -swift-version 5 -parse-as-library -typecheck -target arm64-apple-watchos9.0-simulator \
  -sdk "$task_watch_sdk" -I "$task_artifact/watch-modules" DayPageLocalWatch/*.swift
