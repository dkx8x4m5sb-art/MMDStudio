#!/usr/bin/env bash
# 把 MMDStudio 工程打成未签名 IPA（TrollStore / AltStore / 侧载用）。
# 设置 ADHOC_SIGN=1 可追加 ad-hoc 签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-MMDStudio}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
ARCHIVE_PATH="$BUILD_DIR/MMDStudio.xcarchive"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGE_DIR="$BUILD_DIR/ipa-stage"
LOG_PATH="$BUILD_DIR/xcodebuild.log"
ADHOC_SIGN="${ADHOC_SIGN:-0}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：找不到 xcodebuild。本脚本必须在 macOS + Xcode 环境运行。" >&2
  exit 1
fi

PROJECT_PATH="$ROOT/MMDStudio.xcodeproj"
if [ ! -d "$PROJECT_PATH" ]; then
  echo "错误：找不到 MMDStudio.xcodeproj。请在仓库根目录运行。" >&2
  exit 1
fi

# 版本号直接从工程读取，避免在 CI 配置里维护第二份副本。
read_setting() {
  local key="$1"
  xcodebuild -project "$PROJECT_PATH" -target "$SCHEME" -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' -v k="$key" '$1 ~ k"$" { print $2; exit }'
}

VERSION="$(read_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_setting CURRENT_PROJECT_VERSION)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/  */ /g')"

echo "Project:   $PROJECT_PATH"
echo "Scheme:    $SCHEME ($CONFIGURATION)"
echo "Version:   ${VERSION:-?} (${BUILD_NUMBER:-?})"
echo "SDK:       iphoneos ${SDK_VERSION}"
echo "Xcode:     ${XCODE_VERSION}"
echo ""

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$DERIVED_DATA" "$STAGE_DIR"

set +e
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean archive 2>&1 | tee "$LOG_PATH"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "xcodebuild 失败，完整日志：$LOG_PATH" >&2
  grep -E "error:|warning: .*deprecated" "$LOG_PATH" | head -40 >&2 || true
  exit "$STATUS"
fi

APP="$ARCHIVE_PATH/Products/Applications/MMDStudio.app"
if [ ! -d "$APP" ]; then
  echo "错误：archive 中找不到 MMDStudio.app：$APP" >&2
  exit 1
fi

if [ "$ADHOC_SIGN" = "1" ] || [ "$ADHOC_SIGN" = "true" ]; then
  echo "执行 ad-hoc 签名 ..."
  codesign --force --deep --sign - "$APP"
  IPA_PATH="$BUILD_DIR/MMDStudio-adhoc-${VERSION:-dev}.ipa"
else
  IPA_PATH="$BUILD_DIR/MMDStudio-unsigned-${VERSION:-dev}.ipa"
fi

mkdir -p "$STAGE_DIR/Payload"
if command -v ditto >/dev/null 2>&1; then
  ditto "$APP" "$STAGE_DIR/Payload/MMDStudio.app"
else
  cp -R "$APP" "$STAGE_DIR/Payload/MMDStudio.app"
fi

rm -f "$IPA_PATH"
(cd "$STAGE_DIR" && zip -qry "$IPA_PATH" Payload)

echo ""
echo "IPA 已生成：$IPA_PATH"
echo "大小：$(du -h "$IPA_PATH" | cut -f1)"
echo "二进制架构：$(lipo -archs "$APP/MMDStudio" 2>/dev/null || echo unknown)"
