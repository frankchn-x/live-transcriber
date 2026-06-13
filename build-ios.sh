#!/bin/bash
# 生成并构建 iOS 应用。
#   ./build-ios.sh sim              — 在 iPhone 模拟器上编译验证（无需签名）
#   ./build-ios.sh device <TEAMID>  — 构建并安装到已连接的真机（需 Apple ID 签名）
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate

MODE="${1:-sim}"

if [ "$MODE" = "sim" ]; then
  xcodebuild -project LiveTranscriberiOS.xcodeproj -scheme LiveTranscriber \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
elif [ "$MODE" = "device" ]; then
  TEAM="${2:?用法: ./build-ios.sh device <DEVELOPMENT_TEAM_ID>}"
  xcodebuild -project LiveTranscriberiOS.xcodeproj -scheme LiveTranscriber \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    build
  echo "构建完成。用 Xcode 或 'xcrun devicectl device install app' 安装到 iPhone。"
else
  echo "用法: ./build-ios.sh [sim | device <TEAMID>]"; exit 1
fi
