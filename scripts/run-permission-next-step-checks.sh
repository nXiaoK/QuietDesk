#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/permission-next-step-checks}"
mkdir -p "$check_root/ModuleCache"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$check_root/ModuleCache" \
    Sources/QuietDesk/PermissionNextStepView.swift AppChecks/PermissionNextStepChecks.swift \
    -o "$check_root/PermissionNextStepChecks"
"$check_root/PermissionNextStepChecks"
