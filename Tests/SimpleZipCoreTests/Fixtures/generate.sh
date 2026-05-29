#!/bin/bash
#
# 重新生成 SimpleZipCoreTests 的预录 fixtures。
#
# 这些 fixtures 是给单元测试用的预先打好的压缩包，避免「测试自己用 ArchiveService
# 现场造压缩包再读」式的自证。脚本只在改动 fixture 内容（或 macOS 工具产出格式变化）
# 时手工跑，平时跑测试不需要重新生成。
#
# 用法：
#   ./Tests/SimpleZipCoreTests/Fixtures/generate.sh
#
# 工具依赖：
#   - /usr/bin/zip / unzip                （macOS 自带）
#   - /usr/bin/tar                         （macOS 自带）
#   - SimpleZip/Tools/7zz                  （仓库内）
#   - python3                              （macOS 自带 / Homebrew）
#
# 每个 fixture 头注释里写了「这是什么 + 用来覆盖什么测试场景」。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SEVEN_ZIP="$REPO_ROOT/SimpleZip/Tools/7zz"

if [[ ! -x "$SEVEN_ZIP" ]]; then
  echo "未找到可执行的 bundled 7zz: $SEVEN_ZIP" >&2
  exit 1
fi

PASSWORD="fixture-pw"
WORK_DIR="$(mktemp -d -t simplezip-fixture-XXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "→ 准备 payload 在 $WORK_DIR"
mkdir -p "$WORK_DIR/payload/nested"
mkdir -p "$WORK_DIR/payload/empty_dir"
# 故意用中文文件名 —— 测试输出解析时的 UTF-8 / 转义路径处理。
printf '根条目内容\n' > "$WORK_DIR/payload/根条目.txt"
printf '嵌套条目内容\n' > "$WORK_DIR/payload/nested/嵌套.txt"

cd "$WORK_DIR"

echo "→ plain_unicode.zip（用 /usr/bin/zip，覆盖原生 zip 列表解析路径）"
rm -f "$SCRIPT_DIR/plain_unicode.zip"
/usr/bin/zip -qr "$SCRIPT_DIR/plain_unicode.zip" payload

echo "→ plain_unicode.7z（用 bundled 7zz）"
rm -f "$SCRIPT_DIR/plain_unicode.7z"
"$SEVEN_ZIP" a -bd -bso0 -bsp0 "$SCRIPT_DIR/plain_unicode.7z" payload >/dev/null

echo "→ plain_unicode.tar（覆盖 tar 列表解析路径）"
rm -f "$SCRIPT_DIR/plain_unicode.tar"
/usr/bin/tar -cf "$SCRIPT_DIR/plain_unicode.tar" payload

echo "→ aes256_password.zip（AES-256，header 不加密 —— ZIP 标准不支持文件头加密）"
rm -f "$SCRIPT_DIR/aes256_password.zip"
"$SEVEN_ZIP" a -bd -bso0 -bsp0 -tzip -p"$PASSWORD" -mem=AES256 \
  "$SCRIPT_DIR/aes256_password.zip" payload >/dev/null

echo "→ aes256_password.7z（AES + 文件名加密 = 列表也必须密码）"
rm -f "$SCRIPT_DIR/aes256_password.7z"
"$SEVEN_ZIP" a -bd -bso0 -bsp0 -t7z -p"$PASSWORD" -mhe=on \
  "$SCRIPT_DIR/aes256_password.7z" payload >/dev/null

echo "→ path_traversal.zip（条目名带 ../，覆盖 ArchiveSafety）"
rm -f "$SCRIPT_DIR/path_traversal.zip"
python3 - "$SCRIPT_DIR/path_traversal.zip" <<'PY'
import sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    # 正常文件
    z.writestr('payload/normal.txt', 'normal content\n')
    # 用 ".." 在条目名里逃出解压目录 —— SimpleZip 的 ArchiveSafety 应识别为不安全
    z.writestr('../escape.txt', 'this entry should be flagged\n')
PY

echo "→ 生成完成。Fixtures 列表："
cd "$SCRIPT_DIR"
ls -lh *.zip *.7z *.tar 2>/dev/null | awk '{ printf "    %s  %s\n", $5, $NF }'
