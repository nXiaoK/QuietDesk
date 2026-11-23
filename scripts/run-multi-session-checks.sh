#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/multi-session-checks}"
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
    "${core_objects[@]}" \
    Sources/QuietDesk/AppDataLocation.swift \
    Sources/QuietDesk/PortMappingManager.swift \
    Sources/QuietDesk/PortMappingApprovalPanel.swift \
    Sources/QuietDesk/CapsLockMonitor.swift \
    Sources/QuietDesk/ClipboardSync.swift \
    Sources/QuietDesk/FinderClipboardPaste.swift \
    Sources/QuietDesk/ClipboardPrivacy.swift \
    AppChecks/MultiSessionRuntimeChecks.swift \
    -o "$build_directory/MultiSessionRuntimeChecks"
"$build_directory/MultiSessionRuntimeChecks"
