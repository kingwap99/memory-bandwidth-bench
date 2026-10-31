#!/bin/bash
# 發布新版本：自動累進版號 -> build -> DMG -> git tag/push -> GitHub Release
# 用法：./release.sh [patch|minor|major]（預設 patch：1.0 -> 1.0.1；1.0.1 -> 1.0.2）
# 版號唯一來源是 git tag；首次執行會從最新 tag（或 v1.0）推下一號。
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
  *) echo "BUMP 只能 patch|minor|major"; exit 1 ;;
esac
NEW="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW"
echo "==> 版號：${BASE:-無} -> $TAG"

$PB -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
$PB -c "Set :CFBundleVersion $BUILD" "$PLIST"

./build.sh
./make_dmg.sh
DMG="MemoryBandwidthBench-$NEW.dmg"

git add -A
git -c user.name="${GIT_AUTHOR_NAME:-kingwap99}" -c user.email="${GIT_AUTHOR_EMAIL:-kingwap99@users.noreply.github.com}" commit -m "Release $TAG" || true
git tag "$TAG"
git push origin main "refs/tags/$TAG"

gh release create "$TAG" "$DMG" --title "Memory Bandwidth Bench $TAG" --notes "macOS 記憶體頻寬測試 App。自動偵測語系（繁中/简中/英文）、原廠規格基準線與達原廠%。ad-hoc 簽章，首次開啟請按兩下選打開。" || gh release upload "$TAG" "$DMG" --clobber

echo "==> 發布完成：${TAG}（build ${BUILD}）"
