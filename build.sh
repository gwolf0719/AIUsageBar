#!/bin/bash
# 建置 AIUsageBar.app（只需要 Command Line Tools，不需要 Xcode，也沒有任何第三方依賴）。
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AIUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# 通用版：Apple Silicon 與 Intel 各編一次再合併。
VERSION="${VERSION:-1.0.0}"
TMP="build/obj"; mkdir -p "$TMP"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macosx14.0" -o "$TMP/AIUsageBar-$arch" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/AIUsageBar" "$TMP/AIUsageBar-arm64" "$TMP/AIUsageBar-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.aiusagebar</string>
  <key>CFBundleName</key><string>AIUsageBar</string>
  <key>CFBundleExecutable</key><string>AIUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
cp Resources/*.svg "$APP/Contents/Resources/"

codesign --force --sign - "$APP" >/dev/null 2>&1
"$APP/Contents/MacOS/AIUsageBar" --selftest
echo "建置完成：$APP"

# ./build.sh install：安裝到 ~/Applications 並（重新）啟動。
if [ "${1:-}" = "install" ]; then
  pkill -x AIUsageBar 2>/dev/null || true
  # 等舊程序真的結束，否則 open 會回 -600。
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x AIUsageBar >/dev/null || break; sleep 0.5; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/AIUsageBar.app"
  cp -R "$APP" "$HOME/Applications/"
  # 剛複製完 LaunchServices 偶爾還沒認得新 app，也會回 -600：重試幾次。
  for i in 1 2 3 4 5; do open "$HOME/Applications/AIUsageBar.app" 2>/dev/null && break; [ "$i" = 5 ] && exit 1; sleep 1; done
  echo "已安裝並啟動：~/Applications/AIUsageBar.app"
fi
