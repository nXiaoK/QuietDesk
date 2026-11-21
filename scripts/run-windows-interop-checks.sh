#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/windows-interop-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export CARGO_TARGET_DIR="${QUIETDESK_WINDOWS_TARGET_DIR:-$PWD/work/windows-build/target}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$CARGO_TARGET_DIR"

# The Windows client's portable code: its own tests, then the headless probe built from the same crate.
(cd windows && cargo test --locked -p quietdesk-core && cargo build --locked -p quietdesk-probe)
if [[ "${1:-}" == "--rust-only" ]]; then exit 0; fi

swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/Capture.swift Sources/QuietDesk/CaptureLifecycle.swift Sources/QuietDesk/InputSources.swift Sources/QuietDesk/InputSourceContext.swift \
    AppChecks/WindowsInteropChecks.swift -o "$build_directory/WindowsInteropChecks"
fixture_directory="$(mktemp -d "$check_root/fixture.XXXXXX")"
trap 'rm -rf "$fixture_directory"' EXIT
"$build_directory/WindowsInteropChecks" "$CARGO_TARGET_DIR/debug/quietdesk-probe" "$fixture_directory"
