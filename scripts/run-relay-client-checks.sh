#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/relay-client-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export GOCACHE="${QUIETDESK_RELAY_GO_CACHE:-$PWD/work/relay-build/go-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$GOCACHE"
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" AppChecks/RelayInteropChecks.swift -o "$build_directory/RelayInteropChecks"
fixture_directory="$(mktemp -d "$check_root/relay-fixture.XXXXXX")"
fixture_directory="$(cd "$fixture_directory" && pwd)"
blocked=0
private_port=0
if [[ "${1:-}" == "--udp-blocked" ]]; then blocked=1; fi
if [[ "${1:-}" == "--private-udp-port" ]]; then private_port=1; fi
(cd relay && QUIETDESK_RELAY_FIXTURE_DIR="$fixture_directory" QUIETDESK_RELAY_FIXTURE_BLOCK_UDP="$blocked" QUIETDESK_RELAY_FIXTURE_PRIVATE_UDP_PORT="$private_port" go test -run '^TestNativeInteropFixture$' -count=1 -timeout=180s -v .) > "$fixture_directory/node.log" 2>&1 &
fixture_pid=$!
cleanup() { touch "$fixture_directory/finish"; wait "$fixture_pid" || true; }
trap cleanup EXIT
for ((attempt=0; attempt<200; attempt++)); do
    if [[ -f "$fixture_directory/fixture.json" ]]; then break; fi
    if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$fixture_directory/node.log"; exit 1; fi
    sleep 0.1
done
[[ -f "$fixture_directory/fixture.json" ]]
"$build_directory/RelayInteropChecks" "$fixture_directory" "${1:-}"
