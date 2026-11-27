#!/bin/bash
# Cross-builds QuietDesk for Windows (x64 and/or arm64) on macOS and packages portable ZIP archives.
# Usage: ./scripts/build-windows.sh [all|x64|arm64] [--build-only]
set -euo pipefail
cd "$(dirname "$0")/.."

arch_selection=""
build_only=false
for arg in "$@"; do
    case "$arg" in
        all|x64|arm64)
            if [[ -n "$arch_selection" ]]; then
                echo "用法: ./scripts/build-windows.sh [all|x64|arm64] [--build-only]" >&2
                exit 1
            fi
            arch_selection="$arg"
            ;;
        --build-only)
            build_only=true
            ;;
        *)
            echo "用法: ./scripts/build-windows.sh [all|x64|arm64] [--build-only]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$arch_selection" ]]; then
    if [[ "$build_only" == true ]]; then
        arch_selection=x64
    else
        arch_selection=all
    fi
fi

if [[ "$arch_selection" == all ]]; then
    arches=(x64 arm64)
else
    arches=("$arch_selection")
fi

source scripts/windows-toolchain.sh
version="${QUIETDESK_VERSION:-$(python3 scripts/version.py current | head -1)}"
output="${QUIETDESK_WINDOWS_DIST_DIR:-$PWD/outputs/windows}"

for arch in "${arches[@]}"; do
    case "$arch" in
        x64)
            rust_target=x86_64-pc-windows-gnullvm
            objdump_bin=x86_64-w64-mingw32-objdump
            pe_pattern='PE32+ executable (GUI) x86-64'
            ;;
        arm64)
            rust_target=aarch64-pc-windows-gnullvm
            objdump_bin=aarch64-w64-mingw32-objdump
            pe_pattern='PE32+ executable (GUI) Aarch64'
            ;;
    esac

    (cd windows && cargo build --locked --release --target "$rust_target" -p quietdesk-app)
    built="$CARGO_TARGET_DIR/$rust_target/release"
    if [[ "$build_only" == true ]]; then
        continue
    fi

    # The executable may depend only on libraries that are part of Windows 10 and later.
    imports="$("$objdump_bin" -p "$built/QuietDesk.exe" | sed -n 's/.*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)"
    unexpected="$(grep -Ev '^(advapi32|bcrypt|bcryptprimitives|cfgmgr32|combase|comctl32|crypt32|d2d1|d3d11|dxgi|gdi32|kernel32|mf|mfplat|ntdll|ole32|oleaut32|shell32|user32|userenv|winhttp|ws2_32|api-ms-win-[a-z0-9-]+)\.dll$' <<< "$imports" || true)"
    if [[ -n "$unexpected" ]]; then
        echo "QuietDesk.exe ($arch) depends on libraries Windows does not ship: $unexpected" >&2
        exit 1
    fi
    file "$built/QuietDesk.exe" | grep -q "$pe_pattern"

    archive="$output/QuietDesk-$version-Windows-$arch.zip"
    staging="$(mktemp -d)"
    mkdir -p "$output"
    cp "$built/QuietDesk.exe" windows/licenses/THIRD-PARTY-OPUS.txt "$staging/"
    cat LICENSE Resources/Tailnet-Licenses.txt > "$staging/LICENSE"
    rm -f "$archive"
    (cd "$staging" && zip -q -X "$archive" QuietDesk.exe LICENSE THIRD-PARTY-OPUS.txt)
    rm -rf "$staging"
    unzip -tq "$archive" >/dev/null
done

if [[ "$build_only" == true ]]; then
    exit 0
fi

(
    cd "$output"
    shopt -s nullglob
    packages=(QuietDesk-"$version"-Windows-*.zip QuietDesk-"$version"-Windows-*-Setup.exe)
    if [[ "${#packages[@]}" -eq 0 ]]; then
        echo "No packaged Windows artifacts found for version $version" >&2
        exit 1
    fi
    shasum -a 256 "${packages[@]}" | tee "SHA256SUMS-$version-Windows.txt"
)
