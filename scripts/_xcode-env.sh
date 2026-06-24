#!/usr/bin/env bash
# 被其它脚本 source：把 DEVELOPER_DIR 指向一个完整 Xcode（默认取 /Applications 下最新的 Xcode*.app，
# 可用环境变量 DEVELOPER_DIR 覆盖）。仅 Command Line Tools 无法构建 app，故必须是完整 Xcode。
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  _xc="$(ls -d /Applications/Xcode*.app 2>/dev/null | tail -1)"
  if [[ -z "$_xc" ]]; then
    echo "未找到 /Applications/Xcode*.app。请安装完整 Xcode，或自行 export DEVELOPER_DIR。" >&2
    exit 1
  fi
  export DEVELOPER_DIR="$_xc/Contents/Developer"
fi
