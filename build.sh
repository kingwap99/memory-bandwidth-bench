#!/bin/bash
# 編譯 main.swift 並更新 MemoryBandwidthBench.app（ad-hoc 簽章，供本機執行）
set -euo pipefail
cd "$(dirname "$0")"

APP="MemoryBandwidthBench.app"

echo "==> 編譯"
swiftc -O -parse-as-library main.swift -o MemoryBandwidthBench

echo "==> 更新 App bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f MemoryBandwidthBench "$APP/Contents/MacOS/MemoryBandwidthBench"
cp -f Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc 簽章"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> 完成：$(pwd)/$APP"
echo "    直接執行：open \"$APP\""
