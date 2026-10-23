#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/all-checks}"
export QUIETDESK_CHECK_BUILD_DIR="$check_root"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --product QuietDesk
"${swift_build[@]}" --product QuietDeskChecks
build_directory="$("${swift_build[@]}" --show-bin-path)"
"$build_directory/QuietDeskChecks"
for script in app input caps-lock video cursor privacy-cursor session-data session-termination remote-desktop-actions session-effects unlock traffic log credential permission media-transport media-session media-blackhole update; do
    "./scripts/run-$script-checks.sh"
done
./scripts/run-update-controller-checks.sh
./scripts/run-relay-server-checks.sh
./scripts/run-relay-certificate-checks.sh
./scripts/run-relay-connection-checks.sh
for relay_mode in normal --udp-blocked --private-udp-port --mixed --mixed-blocked; do
    if [[ "$relay_mode" == normal ]]; then ./scripts/run-relay-client-checks.sh
    else ./scripts/run-relay-client-checks.sh "$relay_mode"; fi
done
