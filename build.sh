#!/bin/bash
# Hawky をビルドして Hawky.app を作る。Xcode 本体は不要（Command Line Tools のみで動く）。
set -euo pipefail

cd "$(dirname "$0")"

APP="Hawky.app"
TARGET="arm64-apple-macos14.0"
# リリース時は release.sh から渡される。手元のビルドでは 0.0.0 のままでよい
VERSION="${HAWKY_VERSION:-0.0.0}"
SPARKLE_VERSION="2.9.5"

# 暫定署名だとビルドのたびに同一性が変わり、アクセシビリティの許可が毎回外れる。
# 証明書があればそれを使う。CI には無いので暫定署名に落ちる
SIGN_IDENTITY="${HAWKY_SIGN_IDENTITY:-Okigae Dev}"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "警告: 証明書「${SIGN_IDENTITY}」が見つかりません。暫定署名にします（許可が外れます）" >&2
  SIGN_IDENTITY="-"
fi

# 自動更新に Sparkle を使う。framework は大きいのでリポジトリに置かず、
# 無ければ取ってくる（Vendor/ は git の管理外）
if [ ! -d "Vendor/Sparkle.framework" ]; then
  echo "Sparkle $SPARKLE_VERSION を取得します…"
  mkdir -p Vendor
  TMP="$(mktemp -d)"
  curl -sL -o "$TMP/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar xf "$TMP/sparkle.tar.xz" -C "$TMP"
  cp -R "$TMP/Sparkle.framework" Vendor/
  cp -R "$TMP/bin" Vendor/
  rm -rf "$TMP"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp -R Vendor/Sparkle.framework "$APP/Contents/Frameworks/"

swiftc \
  -target "$TARGET" \
  -swift-version 6 \
  -O \
  -F Vendor \
  -framework AppKit \
  -framework ApplicationServices \
  -framework ServiceManagement \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Hawky" \
  Sources/Paths.swift Sources/Store.swift Sources/Focus.swift Sources/Strings.swift \
  Sources/Updater.swift Sources/SelfTest.swift Sources/main.swift

# アイコンは Tools/make-icon.py で書き出したもの
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.kkweb.hawky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Dock に出さず、メニューバーだけに常駐させる -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>

  <!-- 自動更新（Sparkle）。確認は起動時に1回だけ行い、見つかったときだけ画面を出す。
       この2つを false にしておかないと、初回起動で「自動で確認していいか」を尋ねる画面が出る -->
  <key>SUFeedURL</key><string>https://github.com/piro0919/hawky/releases/latest/download/appcast.xml</string>
  <!-- 更新の署名を確かめる公開鍵。Konechi・Gocci・Nonja・Okigae と同じ鍵で、
       対になる秘密鍵はログインキーチェーンにある。これを失うと更新を配れなくなる -->
  <key>SUPublicEDKey</key><string>qYQq1iewXYNDhhkJJak1nXUXmFkZ0jAF6Gr+pjB4Bxo=</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
</dict>
</plist>
PLIST

# framework は中から署名する。先にアプリを署名すると、後から中身が変わって壊れる
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
  codesign --force --sign "$SIGN_IDENTITY" "$SPARKLE/$part" 2>/dev/null || true
done
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "できました: $(pwd)/$APP"
