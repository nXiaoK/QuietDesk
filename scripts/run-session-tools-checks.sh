#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/session-tools-checks}"
mkdir -p "$check_root/ModuleCache"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$check_root/ModuleCache" \
    Sources/QuietDesk/SessionToolsView.swift AppChecks/SessionToolsChecks.swift \
    -o "$check_root/SessionToolsChecks"
"$check_root/SessionToolsChecks"
