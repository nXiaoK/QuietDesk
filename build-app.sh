#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

ARCH="${1:-universal}"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" && "$ARCH" != "universal" ]]; then
  print -u2 "用法: ./build-app.sh [universal|arm64|x86_64]"
  exit 1
fi

VERSION_INFO=("${(@f)$(python3 scripts/version.py current)}")
APP_VERSION="${VERSION_INFO[1]}"
APP_BUILD="${VERSION_INFO[2]}"
BUILD_ROOT="${QUIETDESK_BUILD_DIR:-$PWD/.build}"
DIST_ROOT="${QUIETDESK_DIST_DIR:-$PWD/dist}"
BUILD_REVISION=""
if [[ -z "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  BUILD_REVISION="$(git rev-parse --verify HEAD 2>/dev/null || true)"
fi
if [[ ! "$BUILD_REVISION" =~ '^[0-9a-f]{40}$' ]]; then BUILD_REVISION=""; fi

mkdir -p "$BUILD_ROOT/module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/module-cache"
if [[ "$ARCH" == "universal" ]]; then
  ARCHES=(arm64 x86_64)
else
  ARCHES=("$ARCH")
fi
BINARIES=()
for TARGET_ARCH in "${ARCHES[@]}"; do
  swift build --product QuietDesk -c release --arch "$TARGET_ARCH" --scratch-path "$BUILD_ROOT" --disable-sandbox \
    --cache-path "$BUILD_ROOT/cache" --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security"
  BIN_DIR="$(swift build -c release --arch "$TARGET_ARCH" --show-bin-path --scratch-path "$BUILD_ROOT" --disable-sandbox \
    --cache-path "$BUILD_ROOT/cache" --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security")"
  BINARIES+=("$BIN_DIR/QuietDesk")
done
APP="$DIST_ROOT/QuietDesk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PWD/Resources/QuietDesk.icns" "$APP/Contents/Resources/QuietDesk.icns"
if [[ "${#BINARIES[@]}" == "2" ]]; then
  xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/QuietDesk.building"
else
  cp "${BINARIES[1]}" "$APP/Contents/MacOS/QuietDesk.building"
fi
mv -f "$APP/Contents/MacOS/QuietDesk.building" "$APP/Contents/MacOS/QuietDesk"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.quietdesk.app</string>
  <key>CFBundleName</key><string>QuietDesk</string>
  <key>CFBundleDisplayName</key><string>QuietDesk</string>
  <key>CFBundleExecutable</key><string>QuietDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>QuietDesk.icns</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>QuietDeskBuildRevision</key><string>$BUILD_REVISION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>用于将这台 Mac 的屏幕传输到你自己的另一台 Mac。</string>
  <key>NSLocalNetworkUsageDescription</key><string>用于与你自己的另一台 Mac 建立远程桌面连接。</string>
  <key>NSInputMonitoringUsageDescription</key><string>仅在远程画面聚焦时处理 Caps Lock，并在全屏控制时转发系统快捷键。</string>
</dict></plist>
PLIST
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
print "已生成: $APP ($ARCH · $APP_VERSION · build $APP_BUILD)"
