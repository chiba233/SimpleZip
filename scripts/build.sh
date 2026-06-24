#!/usr/bin/env bash
# Xcode Debug 构建（app target）。透传额外参数给 xcodebuild。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/_xcode-env.sh
source "$(dirname "$0")/_xcode-env.sh"
exec /usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug \
  -derivedDataPath /private/tmp/SimpleZipDerivedData \
  "$@" \
  build
