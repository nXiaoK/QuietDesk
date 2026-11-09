#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/connection-recovery-checks}"
mkdir -p "$check_root/ModuleCache"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$check_root/ModuleCache" \
    Sources/QuietDesk/ConnectionRecoveryView.swift AppChecks/ConnectionRecoveryChecks.swift \
    -o "$check_root/ConnectionRecoveryChecks"
"$check_root/ConnectionRecoveryChecks"
