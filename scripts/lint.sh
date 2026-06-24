#!/usr/bin/env bash
#
# SwiftLint 本地入口。配置见 ../.swiftlint.yml；仓库现有违规已记入 swiftlint-baseline.json，
# 故只报**新增**违规（与 CI 的 SwiftLint 步骤等价，便于提交前自查）。
#
#   scripts/lint.sh                 检查新增违规（--strict：有新增即非零退出，与 CI 一致）
#   scripts/lint.sh fix             swiftlint --fix 自动修可修项（不改 baseline）
#   scripts/lint.sh regen-baseline  重建基线（谨慎：会把当前全部违规重新纳入基线）
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "未找到 swiftlint。安装：brew install swiftlint" >&2
  exit 127
fi

case "${1:-lint}" in
  lint)
    exec swiftlint lint --strict
    ;;
  fix)
    exec swiftlint --fix
    ;;
  regen-baseline)
    exec swiftlint lint --write-baseline swiftlint-baseline.json
    ;;
  *)
    echo "用法: scripts/lint.sh [lint|fix|regen-baseline]" >&2
    exit 2
    ;;
esac
