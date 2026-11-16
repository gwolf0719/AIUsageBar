#!/bin/bash
# 打包發布檔：./release.sh 1.0.0 → build/AIUsageBar-1.0.0.dmg、build/AIUsageBar-1.0.0.zip
# 只產生檔案，不上傳；上傳用 gh release create（見 README）。
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?用法：./release.sh <版本>}"
VERSION="$VERSION" ./build.sh

APP="build/AIUsageBar.app"
ZIP="build/AIUsageBar-$VERSION.zip"
DMG="build/AIUsageBar-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AIUsageBar $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$ZIP" "$DMG"
