#!/bin/bash
# Hawky をビルドして Hawky.app を作る。Xcode 本体は不要
set -euo pipefail

cd "$(dirname "$0")"

APP="Hawky.app"
TARGET="arm64-apple-macos14.0"
VERSION="${HAWKY_VERSION:-0.0.0}"

# 暫定署名だとビルドのたびに同一性が変わり、アクセシビリティの許可が毎回外れる。
# 証明書があればそれを使う
SIGN_IDENTITY="${HAWKY_SIGN_IDENTITY:-Okigae Dev}"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "警告: 証明書「${SIGN_IDENTITY}」が見つかりません。暫定署名にします（許可が外れます）" >&2
  SIGN_IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -target "$TARGET" \
  -swift-version 6 \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -o "$APP/Contents/MacOS/Hawky" \
  Sources/Paths.swift Sources/Store.swift Sources/Focus.swift Sources/Strings.swift Sources/main.swift

# アイコンは scripts/build-icons.py で書き出したもの
cp Resources/AppIcon.icns Resources/StatusIcon.png Resources/StatusIcon@2x.png "$APP/Contents/Resources/"

# ダウンロードした人がリポジトリなしでフックを登録できるよう、アプリに同梱する。
# install.mjs は自分の置き場所の隣にある hawky-hook.mjs を登録する
mkdir -p "$APP/Contents/Resources/hook"
cp hook/hawky-hook.mjs hook/install.mjs "$APP/Contents/Resources/hook/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hawky</string>
  <key>CFBundleDisplayName</key><string>Hawky</string>
  <key>CFBundleExecutable</key><string>Hawky</string>
  <key>CFBundleIdentifier</key><string>io.kkweb.hawky</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
