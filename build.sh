#!/bin/bash
# Compile main.swift and refresh MemoryBandwidthBench.app (ad-hoc signed for local use).
set -euo pipefail
cd "$(dirname "$0")"

APP="MemoryBandwidthBench.app"

echo "==> Compiling"
swiftc -O -parse-as-library main.swift -o MemoryBandwidthBench

echo "==> Updating app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f MemoryBandwidthBench "$APP/Contents/MacOS/MemoryBandwidthBench"
cp -f Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Run it with: open \"$APP\""
