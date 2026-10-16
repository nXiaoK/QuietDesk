#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift_build=(swift build --disable-sandbox --cache-path "$PWD/.build/cache" \
    --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security")
"${swift_build[@]}" --product QuietDeskChecks
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/ClipboardSync.swift AppChecks/ClipboardFocusChecks.swift \
    -o "$build_directory/ClipboardFocusChecks"
"$build_directory/ClipboardFocusChecks"
