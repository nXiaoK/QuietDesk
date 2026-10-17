#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path

source = Path("Sources/QuietDesk/DeskModel.swift").read_text()
for api in ("CGRequestScreenCaptureAccess", "AXIsProcessTrustedWithOptions", "IOHIDRequestAccess"):
    if api in source:
        raise SystemExit(f"Permission settings entry points must not trigger a system prompt: {api}")
print("PASS Permission settings entry points do not call system prompt APIs")
PY
check_root="${QUIETDESK_PERMISSION_CHECK_BUILD_DIR:-$PWD/work/permission-checks}"
check_app="$check_root/PermissionGuideChecks.app"
mkdir -p "$check_root/ModuleCache" "$check_app/Contents/MacOS"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.quietdesk.checks.permission-guide</string>
    <key>CFBundleName</key><string>QuietDesk Permission Checks (Synthetic State)</string>
    <key>CFBundleExecutable</key><string>PermissionGuideChecks</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$check_root/ModuleCache" \
    Sources/QuietDesk/PermissionGuide.swift AppChecks/PermissionGuideChecks.swift \
    -o "$check_app/Contents/MacOS/PermissionGuideChecks"
"$check_app/Contents/MacOS/PermissionGuideChecks"
