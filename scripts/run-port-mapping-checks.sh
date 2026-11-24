#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/port-mapping-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache"
    --config-path "$check_root/configuration" --security-path "$check_root/security")
if [[ "${1:-}" == --benchmark ]]; then swift_build+=(--configuration release); fi
"${swift_build[@]}" --target QuietDeskCore
bin="$("${swift_build[@]}" --show-bin-path)"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" -I "$bin/Modules" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$bin"/QuietDeskCore.build/*.swift.o \
    Sources/QuietDesk/Capture.swift Sources/QuietDesk/CaptureLifecycle.swift Sources/QuietDesk/InputSources.swift Sources/QuietDesk/InputSourceContext.swift \
    AppChecks/RelayOpaqueProxy.swift AppChecks/PortMappingChecks.swift AppChecks/PortMappingPerformanceChecks.swift \
    -o "$bin/PortMappingChecks"
fixture="$(mktemp -d "$check_root/mapped-file.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
"$bin/PortMappingChecks" "$fixture" "$@"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" -I "$bin/Modules" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$bin"/QuietDeskCore.build/*.swift.o \
    Sources/QuietDesk/PortMappingManager.swift Sources/QuietDesk/PortMappingApprovalPanel.swift \
    Sources/QuietDesk/DeskTheme.swift \
    AppChecks/PortMappingRuleChecks.swift -o "$bin/PortMappingRuleChecks"
"$bin/PortMappingRuleChecks"
