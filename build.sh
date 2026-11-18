#!/bin/bash
# Compile MemoryBandwidthBench.swift and refresh MemoryBandwidthBench.app (ad-hoc signed for local use).
set -euo pipefail
cd "$(dirname "$0")"

APP="MemoryBandwidthBench.app"

echo "==> Compiling"
# Deployment target must match LSMinimumSystemVersion in Info.plist (macOS 13).
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" MemoryBandwidthBench.swift -o MemoryBandwidthBench

echo "==> Updating app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f MemoryBandwidthBench "$APP/Contents/MacOS/MemoryBandwidthBench"
cp -f Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The source Info.plist carries the App Store identity; the local/DMG build keeps a
# separate bundle id so it never collides with the store-installed copy.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.bench.MemoryBandwidthBench" "$APP/Contents/Info.plist"

echo "==> Ad-hoc signing"
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Run it with: open \"$APP\""
