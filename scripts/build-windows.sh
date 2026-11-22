#!/bin/bash
# Cross-builds QuietDesk for Windows (x64) on macOS and packages it as a ZIP.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/windows-toolchain.sh
version="${QUIETDESK_VERSION:-$(python3 scripts/version.py current | head -1)}"
(cd windows && cargo build --locked --release --target x86_64-pc-windows-gnullvm -p quietdesk-app)
built="$CARGO_TARGET_DIR/x86_64-pc-windows-gnullvm/release"
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi

# The executable may depend only on libraries that are part of Windows 10 and later.
imports="$(x86_64-w64-mingw32-objdump -p "$built/QuietDesk.exe" | sed -n 's/.*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)"
unexpected="$(grep -Ev '^(advapi32|bcrypt|bcryptprimitives|cfgmgr32|combase|comctl32|crypt32|d2d1|d3d11|dxgi|gdi32|kernel32|mf|mfplat|ntdll|ole32|oleaut32|shell32|user32|userenv|ws2_32|api-ms-win-[a-z0-9-]+)\.dll$' <<< "$imports" || true)"
if [[ -n "$unexpected" ]]; then
    echo "QuietDesk.exe depends on libraries Windows does not ship: $unexpected" >&2
    exit 1
fi
file "$built/QuietDesk.exe" | grep -q 'PE32+ executable (GUI) x86-64'

output="${QUIETDESK_WINDOWS_DIST_DIR:-$PWD/outputs/windows}"
archive="$output/QuietDesk-$version-Windows-x64.zip"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$output"
cp "$built/QuietDesk.exe" LICENSE "$staging/"
rm -f "$archive"
(cd "$staging" && zip -q -X "$archive" QuietDesk.exe LICENSE)
unzip -tq "$archive" >/dev/null
(cd "$output" && shasum -a 256 "$(basename "$archive")" | tee "SHA256SUMS-$version-Windows.txt")
