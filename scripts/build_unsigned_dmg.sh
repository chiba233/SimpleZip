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

if [[ -n "$RELEASE_VERSION" && ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "RELEASE_VERSION must look like 0.1.0 or 1.2" >&2
  exit 1
fi

if [[ -n "$RELEASE_VERSION" ]]; then
  DMG_PATH="$ARTIFACTS_DIR/$APP_NAME-$RELEASE_VERSION-unsigned.dmg"
else
  DMG_PATH="$ARTIFACTS_DIR/$APP_NAME-$CONFIGURATION-unsigned.dmg"
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
  # 把 MARKETING_VERSION 和 CURRENT_PROJECT_VERSION 都设成 RELEASE_VERSION ——
  # Sparkle 的 SUStandardVersionComparator 实际比较的是 sparkle:version vs app 的 CFBundleVersion
  # (= CURRENT_PROJECT_VERSION)，不是 CFBundleShortVersionString。如果二者不一致
  # (e.g. CFBundleVersion="47" GITHUB_RUN_NUMBER 而 sparkle:version="0.1.7")，
  # Sparkle 解析成 [47] vs [0,1,7] → 永远觉得本地比远端新 → 「已是最新版」
  # 同时 Sparkle UI 又用 shortVersionString 给用户显示「0.1.7 可用 / 你在 0.1.6」
  # → 两个对话框互相矛盾的「Sparkle 坑」。
  # 让 CFBundleVersion 跟 sparkle:version 都用 marketing version (e.g. "0.1.7") 就消除歧义。
  xcodebuild_args+=(
    "MARKETING_VERSION=$RELEASE_VERSION"
    "CURRENT_PROJECT_VERSION=$RELEASE_VERSION"
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

codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Created $DMG_PATH"
