#!/bin/bash
# 版を付けてビルドし、配布用の zip を dist/ に作る。GitHub Release への上げ方は CLAUDE.md
#   scripts/release.sh 0.1.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?版を渡してください（例: scripts/release.sh 0.1.0）}"

HAWKY_VERSION="$VERSION" ./build.sh

mkdir -p dist
ZIP="dist/Hawky-${VERSION}.zip"
rm -f "$ZIP"
# Finder の「圧縮」と同じ形。拡張属性と署名を壊さずに固める
ditto -c -k --sequesterRsrc --keepParent Hawky.app "$ZIP"

shasum -a 256 "$ZIP"
