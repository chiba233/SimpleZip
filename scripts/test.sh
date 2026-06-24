#!/usr/bin/env bash
# SwiftPM 核心测试（SimpleZipCore）。透传额外参数给 swift test。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/_xcode-env.sh
source "$(dirname "$0")/_xcode-env.sh"
exec /usr/bin/xcrun swift test \
  --scratch-path /private/tmp/SimpleZipSwiftPM \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache \
  "$@"
