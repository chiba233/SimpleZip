#!/usr/bin/env bash
# 构建 Debug 版并启动 SimpleZip-dev.app。
set -euo pipefail
cd "$(dirname "$0")/.."
"$(dirname "$0")/build.sh"
APP=/private/tmp/SimpleZipDerivedData/Build/Products/Debug/SimpleZip-dev.app
echo "启动 $APP"
open "$APP"
