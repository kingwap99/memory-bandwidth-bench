#!/bin/bash
# Package MemoryBandwidthBench.app into a drag-to-install DMG.
# Run ./build.sh first to refresh the binary, then this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="MemoryBandwidthBench.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="MemoryBandwidthBench-${VERSION}.dmg"
STAGING=$(mktemp -d /tmp/mbb-dmg.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

echo "==> Preparing staging"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/"
xattr -cr "$STAGING"

echo "==> Re-signing (after clearing Finder attributes)"
codesign --force --sign - "$STAGING/$APP"
codesign --verify --verbose=1 "$STAGING/$APP"

echo "==> Creating $DMG"
hdiutil create -volname "Memory Bandwidth Bench" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "==> Done: $(pwd)/$DMG"
