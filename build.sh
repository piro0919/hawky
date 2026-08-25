#!/bin/bash
# Machiban をビルドして Machiban.app を作る。Xcode 本体は不要
set -euo pipefail

cd "$(dirname "$0")"

APP="Machiban.app"
TARGET="arm64-apple-macos14.0"
VERSION="${MACHIBAN_VERSION:-0.0.0}"

# 暫定署名だとビルドのたびに同一性が変わり、アクセシビリティの許可が毎回外れる。
# 証明書があればそれを使う
SIGN_IDENTITY="${MACHIBAN_SIGN_IDENTITY:-Okigae Dev}"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "警告: 証明書「${SIGN_IDENTITY}」が見つかりません。暫定署名にします（許可が外れます）" >&2
  SIGN_IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -target "$TARGET" \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -o "$APP/Contents/MacOS/Machiban" \
  Sources/Paths.swift Sources/Store.swift Sources/Focus.swift Sources/main.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Machiban</string>
  <key>CFBundleDisplayName</key><string>Machiban</string>
  <key>CFBundleExecutable</key><string>Machiban</string>
  <key>CFBundleIdentifier</key><string>io.kkweb.machiban</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Dock に出さず、メニューバーだけに常駐させる -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "できました: $APP"
