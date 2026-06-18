#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/SimpleZip.xcodeproj"
SCHEME="SimpleZip"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-dmg}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ALLOW_BUNDLED_RAR="${ALLOW_BUNDLED_RAR:-0}"
APP_NAME="SimpleZip"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
STAGING_DIR="$DERIVED_DATA_PATH/dmg-staging"

if [[ -n "$RELEASE_VERSION" && ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}(-(beta|rc)\.[0-9]+)?$ ]]; then
  echo "RELEASE_VERSION must look like 0.1.0, 1.2, or 0.1.0-beta.1" >&2
  exit 1
fi

# 发布构建（SIGN_IDENTITY 非空）不加后缀；非发布构建加 "-unsigned" 后缀以示区分。
# appcast 的 enclosure url 取 DMG basename，这里改名后 appcast 自动跟随，保持一致。
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  DMG_SUFFIX=""
else
  DMG_SUFFIX="-unsigned"
fi

if [[ -n "$RELEASE_VERSION" ]]; then
  DMG_PATH="$ARTIFACTS_DIR/$APP_NAME-$RELEASE_VERSION$DMG_SUFFIX.dmg"
else
  DMG_PATH="$ARTIFACTS_DIR/$APP_NAME-$CONFIGURATION$DMG_SUFFIX.dmg"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$ARTIFACTS_DIR"
rm -rf "$DERIVED_DATA_PATH" "$STAGING_DIR" "$DMG_PATH"

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -destination "generic/platform=macOS"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
  CODE_SIGNING_ALLOWED=YES
)

if [[ -n "$RELEASE_VERSION" ]]; then
  # **CFBundleVersion 必须单调递增整数** —— Sparkle `SUStandardVersionComparator` 比的就是它（vs feed
  # `sparkle:version`），不是 `CFBundleShortVersionString`。
  #
  # 历史教训：0.1.8 release 一度把两边都设成 marketing string（`CURRENT_PROJECT_VERSION=$RELEASE_VERSION`），
  # 想消除「整数 vs marketing 字符串」歧义。结果反而 break：0.1.7 user 的 CFBundleVersion 是 build_number
  # （小整数），feed 的 `sparkle:version` 是 "0.1.8"，比较解析成 [1] vs [0,1,8]：1 > 0 → Sparkle 以为本地更新
  # → 0.1.7 user 永远收不到 0.1.8 更新提示。
  #
  # 正解：CFBundleVersion = BUILD_NUMBER（GITHUB_RUN_NUMBER，单调递增整数），appcast 的 sparkle:version 也
  # 写同一个整数，sparkle:shortVersionString 才用 marketing 字符串做 UI 显示。这样 Sparkle 比较的两边都是单
  # 整数，永远清晰。
  xcodebuild_args+=(
    "MARKETING_VERSION=$RELEASE_VERSION"
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  )
fi

xcodebuild "${xcodebuild_args[@]}" build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced at $APP_PATH" >&2
  exit 1
fi

if [[ -n "$RELEASE_VERSION" ]]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
  if [[ "$APP_VERSION" != "$RELEASE_VERSION" ]]; then
    echo "Expected app version $RELEASE_VERSION but built $APP_VERSION" >&2
    exit 1
  fi
fi

if [[ "$ALLOW_BUNDLED_RAR" != "1" ]]; then
  BUNDLED_RAR_PATH="$APP_PATH/Contents/Resources/rar"
  BUNDLED_RAR_TOOLS_PATH="$APP_PATH/Contents/Resources/Tools/rar"
  if [[ -e "$BUNDLED_RAR_PATH" || -e "$BUNDLED_RAR_TOOLS_PATH" ]]; then
    echo "Refusing to package app bundle containing RARLAB rar." >&2
    echo "Found $BUNDLED_RAR_PATH or $BUNDLED_RAR_TOOLS_PATH." >&2
    exit 1
  fi
else
  BUNDLED_RAR_PATH="$APP_PATH/Contents/Resources/rar"
  if [[ ! -x "$BUNDLED_RAR_PATH" ]]; then
    echo "Expected bundled RAR backend was not copied to $BUNDLED_RAR_PATH" >&2
    exit 1
  fi
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # —— Developer ID 签名（公证前置条件）——
  # notarization 硬性要求：链上每个可执行文件都启用 hardened runtime(--options runtime)
  # + 安全时间戳(--timestamp) + 有效 Developer ID 签名，且不带 get-task-allow。
  #
  # 关键坑：`codesign --deep` 只签「标准位置的嵌套代码」(Frameworks/、XPCServices/…)，
  # **不会**签放在 Contents/Resources 里的 7zz / rar。这俩不签 → notary 直接拒
  # （"not signed with a valid Developer ID" / "not hardened"）。所以先逐个签 Resources
  # 下的 Mach-O 可执行文件，再 --deep 签整个 app（app 签名会把已签的工具一并封进去）。
  echo "Signing with Developer ID: $SIGN_IDENTITY"
  while IFS= read -r -d '' bin; do
    if file "$bin" | grep -q "Mach-O"; then
      echo "  signing bundled binary: ${bin#"$APP_PATH"/}"
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bin"
    fi
  done < <(find "$APP_PATH/Contents/Resources" -type f -perm -u+x -print0)

  # --deep 处理 Sparkle.framework 及其内部 XPC / Autoupdate / Updater.app 等嵌套代码。
  codesign --force --options runtime --timestamp --deep --sign "$SIGN_IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  # 明确确认 hardened runtime 已生效（notary 的硬性要求；缺了要到公证失败才暴露，提前在这截断）。
  if ! codesign --display --verbose=4 "$APP_PATH" 2>&1 | grep -Eq 'flags=.*runtime'; then
    echo "ERROR: hardened runtime flag missing after signing $APP_PATH" >&2
    exit 1
  fi
else
  # 本地 / PR 构建：ad-hoc 签名，产物为 unsigned DMG（沿用历史行为）。
  codesign --force --deep --sign - "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Signing DMG with Developer ID: $SIGN_IDENTITY"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

echo "Created $DMG_PATH"
