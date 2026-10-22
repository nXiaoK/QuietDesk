#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/Capture.swift Sources/QuietDesk/InputSources.swift Sources/QuietDesk/InputSourceContext.swift AppChecks/InputInjectorChecks.swift \
    -o "$build_directory/InputInjectorChecks"
"$build_directory/InputInjectorChecks"

canvas_check_app="$check_root/RemoteCanvasChecks.app"
mkdir -p "$canvas_check_app/Contents/MacOS"
cat > "$canvas_check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.quietdesk.checks.remote-canvas</string>
    <key>CFBundleName</key><string>QuietDesk Canvas Checks (Synthetic State)</string>
    <key>CFBundleExecutable</key><string>RemoteCanvasChecks</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/RemoteCanvas.swift Sources/QuietDesk/FullScreenStatusOverlay.swift Sources/QuietDesk/CapsLockMonitor.swift \
    Sources/QuietDesk/SystemShortcutMonitor.swift AppChecks/RemoteCanvasChecks.swift \
    -o "$canvas_check_app/Contents/MacOS/RemoteCanvasChecks"
"$canvas_check_app/Contents/MacOS/RemoteCanvasChecks"
