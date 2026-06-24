#!/usr/bin/env bash
# 安装开发依赖（其他开发者 clone 后跑一次）。目前只有 SwiftLint 是外部依赖；
# 完整 Xcode 需自行从 App Store / developer.apple.com 安装（脚本无法代装）。幂等：已装则跳过。
set -euo pipefail

if command -v swiftlint >/dev/null 2>&1; then
  echo "✓ swiftlint 已安装：$(swiftlint version)"
else
  if command -v brew >/dev/null 2>&1; then
    echo "安装 swiftlint…"
    brew install swiftlint
  else
    echo "需要 Homebrew 来安装 swiftlint：https://brew.sh （或自行安装 swiftlint）" >&2
    exit 1
  fi
fi

if ! ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
  echo "⚠️  未发现完整 Xcode（/Applications/Xcode*.app）。构建 / 测试 / 运行需要它，请自行安装。" >&2
fi
echo "完成。可用：npm run build / test / dev / lint"
