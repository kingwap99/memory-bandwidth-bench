#!/bin/bash
# Release a new version: auto-increment version -> build -> DMG -> git tag/push -> GitHub Release.
# Usage: ./release.sh [patch|minor|major] (default patch: 1.0 -> 1.0.1; 1.0.1 -> 1.0.2)
# The git tag is the single source of truth; first run derives from the latest tag (or v1.0).
set -euo pipefail
cd "$(dirname "$0")"

BUMP=${1:-patch}
PB=/usr/libexec/PlistBuddy
PLIST=Info.plist

LAST=$(git tag --sort=-v:refname | grep -E "^v[0-9]+(\.[0-9]+){1,2}$" | head -1 || true)
if [ -z "$LAST" ]; then
  MAJOR=1; MINOR=0; PATCH=0; BASE="v1.0"
else
  VER=${LAST#v}
  MAJOR=$(echo "$VER" | cut -d. -f1)
  MINOR=$(echo "$VER" | cut -d. -f2)
  PATCH=$(echo "$VER" | cut -s -d. -f3); PATCH=${PATCH:-0}
  BASE="$LAST"
fi

case "$BUMP" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
  *) echo "BUMP must be patch|minor|major"; exit 1 ;;
esac
NEW="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW"
echo "==> Version: ${BASE:-none} -> $TAG"

$PB -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
$PB -c "Set :CFBundleVersion $BUILD" "$PLIST"

./build.sh
./make_dmg.sh
DMG="MemoryBandwidthBench-$NEW.dmg"

git add -A
git -c user.name="${GIT_AUTHOR_NAME:-kingwap99}" -c user.email="${GIT_AUTHOR_EMAIL:-kingwap99@users.noreply.github.com}" commit -m "Release $TAG" || true
git push origin main "refs/tags/$TAG"

gh release create "$TAG" "$DMG" --title "Memory Bandwidth Bench $TAG" --notes "macOS memory bandwidth benchmark. Auto UI language (zh-Hant/zh-Hans/en), official-spec baseline with % of official, GPU-core-count config detection. Ad-hoc signed: right-click > Open on first launch." || gh release upload "$TAG" "$DMG" --clobber

echo "==> Released: $TAG (build $BUILD)"
