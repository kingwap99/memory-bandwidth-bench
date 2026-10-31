#!/bin/bash
# 將 MemoryBandwidthBench.app 打包成 DMG（拖曳安裝格式）
# 先跑 ./build.sh 更新 binary，再跑本腳本
set -euo pipefail
cd "$(dirname "$0")"

APP="MemoryBandwidthBench.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="MemoryBandwidthBench-$VERSION.dmg"
STAGING=$(mktemp -d /tmp/mbb-dmg.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

echo "==> 準備 staging"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/"
xattr -cr "$STAGING"

echo "==> 重新簽章（清除 Finder 屬性後）"
codesign --force --sign - "$STAGING/$APP"
codesign --verify --verbose=1 "$STAGING/$APP"

echo "==> 產生 $DMG"
hdiutil create -volname "Memory Bandwidth Bench" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "==> 完成：$(pwd)/$DMG"
