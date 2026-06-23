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

# 独立 AI 进程改造:dev 专属 LaunchAgent plist(`*.dev.aiagent*.plist`:Mach 探针 `.dev.aiagent.plist` +
# 周期索引 `.dev.aiagent.index.plist`)只服务本地自签 dev 版(Debug bundle id 带 .dev),发布产物**绝不该**带它
# → glob 剔除(覆盖现有两个 + 将来新增的 dev plist,免漏)。再断言发布产物 bundle id 是正式的(防 Debug 的 .dev
# 误入发布;正常 Release 配置本就正式,这是兜底闸)。
LAUNCHAGENTS_DIR="$APP_PATH/Contents/Library/LaunchAgents"
for DEV_LAUNCHAGENT in "$LAUNCHAGENTS_DIR/"*.dev.aiagent*.plist; do
  [[ -f "$DEV_LAUNCHAGENT" ]] || continue
  echo "Removing dev-only LaunchAgent from release bundle: ${DEV_LAUNCHAGENT#"$APP_PATH"/}"
  rm -f "$DEV_LAUNCHAGENT"
done
RELEASE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")"
if [[ "$RELEASE_BUNDLE_ID" != "yumeka.SimpleZip-in-mac" ]]; then
  echo "ERROR: release bundle id is '$RELEASE_BUNDLE_ID', expected 'yumeka.SimpleZip-in-mac'." >&2
  echo "       The dev-only '.dev' bundle id must never ship. Build with the Release configuration." >&2
  exit 1
fi

# 独立 AI 进程改造:内嵌前台 XPC Service 同样按构建配置隔离 dev/prod —— Release 只产正式 `.aixpc`
# (`.dev.aixpc` 只存在于本地 Debug 构建,不进 Release 产物)。断言它的 bundle id 是正式的,兜底防 dev 的
# .xpc 误入发布(对照上面对 app bundle id / dev LaunchAgent plist 的处理)。XPC Service 是构建产物,Release
# 配置本就只产 .aixpc 一个,所以这里只需断言、无需像 dev plist 那样 rm。
# App Intents 扩展(ExtensionKit,在 Contents/Extensions —— **非** `--deep` 覆盖的标准嵌套位置,必须显式签,
# 否则它保持 build 期的 ad-hoc 签名 → 公证 Invalid → staple 找不到票,见 1.0.1-beta.4 实测)。
INTENTS_EXTENSION_BUNDLE="$APP_PATH/Contents/Extensions/SimpleZipIntentsExtension.appex"
XPC_SERVICE_BUNDLE="$APP_PATH/Contents/XPCServices/SimpleZipAIXPCService.xpc"
if [[ -d "$XPC_SERVICE_BUNDLE" ]]; then
  XPC_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$XPC_SERVICE_BUNDLE/Contents/Info.plist")"
  if [[ "$XPC_BUNDLE_ID" != "yumeka.SimpleZip-in-mac.aixpc" ]]; then
    echo "ERROR: embedded XPC service bundle id is '$XPC_BUNDLE_ID', expected 'yumeka.SimpleZip-in-mac.aixpc'." >&2
    echo "       The dev-only '.dev.aixpc' service must never ship. Build with the Release configuration." >&2
    exit 1
  fi
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

  # 独立 AI 进程改造:SimpleZipAIAgent helper 可执行在 Contents/MacOS(非 Resources、非标准嵌套 bundle),
  # `--deep` 不保证签到 → 必须像 7zz/rar 一样**先逐个签**(--options runtime + --timestamp),否则公证因
  # 「未签名 / 未 hardened」直接拒(SMAppService 还要求它和 App 同 Developer ID 身份 → 这里用同一 $SIGN_IDENTITY)。
  AGENT_BIN="$APP_PATH/Contents/MacOS/SimpleZipAIAgent"
  if [[ -f "$AGENT_BIN" ]]; then
    echo "  signing embedded AI agent: ${AGENT_BIN#"$APP_PATH"/}"
    # helper 是裸 Mach-O(无 Info.plist bundle)→ codesign 默认拿**产品名** `SimpleZipAIAgent` 当签名 identifier,
    # 与 app(`yumeka.SimpleZip-in-mac`)/ XPC Service(`…aixpc`)的命名空间不一致。显式 `--identifier` 钉成同
    # 命名空间的 `…aiagent`(= LaunchAgent plist 的 Label / MachServices 名),命名统一、且将来要上严格 XPC peer
    # 签名校验时 identifier 是确定的。发布恒正式 bundle id(脚本前面已断言 app 是无 `.dev` 的正式 id)。
    codesign --force --options runtime --timestamp \
      --identifier yumeka.SimpleZip-in-mac.aiagent \
      --sign "$SIGN_IDENTITY" "$AGENT_BIN"
  fi

  # 独立 AI 进程改造:前台 XPC Service 在 Contents/XPCServices(--deep 的标准嵌套位置),但同样**先显式逐个签**
  # (--options runtime + --timestamp + 同 $SIGN_IDENTITY),不依赖 --deep 是否给嵌套 bundle 应用 hardened
  # runtime;随后 147 行的 `--deep --options runtime` 会再覆盖一次,双保险。XPC Service 与 App 同 Developer ID
  # 身份(App 按 serviceName 拉起内嵌 .xpc,签名身份需一致)。
  if [[ -d "$XPC_SERVICE_BUNDLE" ]]; then
    echo "  signing embedded AI XPC service: ${XPC_SERVICE_BUNDLE#"$APP_PATH"/}"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$XPC_SERVICE_BUNDLE"
  fi

  # App Intents 扩展:`Contents/Extensions/*.appex` 不在 `--deep` 的标准嵌套位置,**必须先显式签**
  # (--options runtime + --timestamp,同 Developer ID),否则保持 ad-hoc 签名 → 公证 Invalid。
  # 嵌套必须先于外层 app 签(下面的 --deep 签 app),故放在这里。
  if [[ -d "$INTENTS_EXTENSION_BUNDLE" ]]; then
    echo "  signing embedded App Intents extension: ${INTENTS_EXTENSION_BUNDLE#"$APP_PATH"/}"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$INTENTS_EXTENSION_BUNDLE"
  fi

  # --deep 处理 Sparkle.framework 及其内部 XPC / Autoupdate / Updater.app 等嵌套代码。
  codesign --force --options runtime --timestamp --deep --sign "$SIGN_IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  # 明确确认 hardened runtime 已生效（notary 的硬性要求；缺了要到公证失败才暴露，提前在这截断）。
  # App 主体 + 内嵌 AI agent + 内嵌前台 XPC Service 都要查 —— agent 在 Contents/MacOS(非标准嵌套位置),
  # `--deep` 不保证重签到它;XPC Service 在标准位置但一并复核。**故意放在最终 --deep 之后复核**:断言的是
  # 真正装船的产物状态,而非签名中途的中间态(对 .xpc bundle,--display 查的是其主可执行的 flags)。
  for signed_bin in "$APP_PATH" "$AGENT_BIN" "$XPC_SERVICE_BUNDLE" "$INTENTS_EXTENSION_BUNDLE"; do
    [[ -e "$signed_bin" ]] || continue
    if ! codesign --display --verbose=4 "$signed_bin" 2>&1 | grep -Eq 'flags=.*runtime'; then
      echo "ERROR: hardened runtime flag missing after signing $signed_bin" >&2
      exit 1
    fi
  done
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
