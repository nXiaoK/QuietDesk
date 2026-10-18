#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/caps-lock-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift_build=(swift build --jobs 2 --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/CapsLockMonitor.swift AppChecks/CapsLockMonitorChecks.swift \
    -o "$build_directory/CapsLockMonitorChecks"
"$build_directory/CapsLockMonitorChecks"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/Capture.swift Sources/QuietDesk/InputSources.swift AppChecks/InputSourcesChecks.swift \
    -o "$build_directory/InputSourcesChecks"
"$build_directory/InputSourcesChecks"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/Capture.swift Sources/QuietDesk/InputSources.swift \
    Sources/QuietDesk/CapsLockMonitor.swift AppChecks/InputSourceOrderingChecks.swift \
    -o "$build_directory/InputSourceOrderingChecks"
"$build_directory/InputSourceOrderingChecks"
