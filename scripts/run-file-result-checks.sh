#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/file-result-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export QUIETDESK_CHECK_ROOT="$check_root/files"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$QUIETDESK_CHECK_ROOT"
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/FileTransferNotice.swift Checks/FileResultChecks.swift \
    Checks/FileApprovalChecks.swift Checks/FileReceptionChecks.swift Checks/ClipboardWindowChecks.swift Checks/ClipboardStorageChecks.swift \
    AppChecks/FileTransferResultChecks.swift -o "$build_directory/FileTransferResultChecks"
"$build_directory/FileTransferResultChecks" "$@"
