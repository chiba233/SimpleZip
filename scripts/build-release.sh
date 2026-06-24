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

# 加速：① 默认增量构建——复用 derived data，不每次清（首次全量，之后只编改动的文件）；想干净全量加 --clean。
#       ② 只编主机一种架构（ONLY_ACTIVE_ARCH=YES，省掉另一半 x86_64/arm64）。本地够用；可分发的通用二进制走 build:signed。
[[ "${1:-}" == "--clean" ]] && rm -rf "$DERIVED"
xcodebuild \
  -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Release \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/SimpleZip.app"
ditto "$APP" "$ROOT/dist/SimpleZip.app"
echo "✓ → dist/SimpleZip.app（未签名）"
