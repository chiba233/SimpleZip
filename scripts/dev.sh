#!/usr/bin/env bash
# 构建 Debug 版并**前台**运行 SimpleZip-dev.app —— 直接 exec 应用二进制（而非 `open`），
# 这样 npm run dev 自身就是该进程：Ctrl-C / kill 即结束 app，退出码也跟随 app。透传额外参数给 app。
set -euo pipefail
cd "$(dirname "$0")/.."
"$(dirname "$0")/build.sh"
APP=/private/tmp/SimpleZipDerivedData/Build/Products/Debug/SimpleZip-dev.app
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || echo SimpleZip-dev)"
echo "前台运行 $EXE（Ctrl-C 结束）"
exec "$EXE" "$@"
