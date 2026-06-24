#!/usr/bin/env bash
#
# Release 构建 → dist/SimpleZip.app。给其他开发者本机构建用：什么都不签（无 Developer ID、无 ad-hoc、不碰 Sparkle）。
# 需要可分发的签名版见 `npm run build:signed`（用维护者的证书，脚本在 secrets/，不进 git）。
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_xcode-env.sh
source "$ROOT/scripts/_xcode-env.sh"

DERIVED="/private/tmp/SimpleZipRelease"
APP="$DERIVED/Build/Products/Release/SimpleZip.app"

rm -rf "$DERIVED"
xcodebuild \
  -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/SimpleZip.app"
ditto "$APP" "$ROOT/dist/SimpleZip.app"
echo "✓ → dist/SimpleZip.app（未签名）"
