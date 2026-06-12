#!/bin/bash
# 构建并打包 实时转录.app 到 dist/
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | tail -5

APP="dist/实时转录.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiveTranscriber "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
