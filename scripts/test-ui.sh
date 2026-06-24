#!/usr/bin/env bash
# 运行 XCUITest 启动冒烟测试（SimpleZipUITests，走 SimpleZip scheme 的 Test action）。
# 会构建并启动 SimpleZip-dev.app —— 需要图形会话（非 headless）和本机签名身份。透传额外参数给 xcodebuild。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/_xcode-env.sh
source "$(dirname "$0")/_xcode-env.sh"
exec /usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug \
  -derivedDataPath /private/tmp/SimpleZipDerivedData \
  -destination 'platform=macOS' \
  "$@" \
  test
