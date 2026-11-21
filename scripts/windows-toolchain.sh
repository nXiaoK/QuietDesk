#!/bin/bash
# Sourced by the Windows build scripts: puts a pinned llvm-mingw cross toolchain on PATH, downloading and
# verifying it on first use, and points Cargo at it for the x86_64 Windows target.
toolchain_release=20261104
toolchain_archive="llvm-mingw-$toolchain_release-ucrt-macos-universal.tar.xz"
toolchain_sha256=66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c
toolchain_root="${QUIETDESK_WINDOWS_TOOLCHAIN_DIR:-$PWD/work/toolchains}"
toolchain_directory="$toolchain_root/${toolchain_archive%.tar.xz}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "The pinned cross toolchain is the macOS build of llvm-mingw; on Windows build with cargo directly." >&2
    exit 1
fi
if [[ ! -x "$toolchain_directory/bin/x86_64-w64-mingw32-clang" ]]; then
    mkdir -p "$toolchain_root"
    curl -sSL --fail -o "$toolchain_root/$toolchain_archive.part" \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$toolchain_release/$toolchain_archive"
    echo "$toolchain_sha256  $toolchain_root/$toolchain_archive.part" | shasum -a 256 -c - >/dev/null
    mv "$toolchain_root/$toolchain_archive.part" "$toolchain_root/$toolchain_archive"
    tar -xJf "$toolchain_root/$toolchain_archive" -C "$toolchain_root"
fi
export PATH="$toolchain_directory/bin:$PATH"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER=x86_64-w64-mingw32-clang
export CC_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-clang
export AR_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-llvm-ar
export RANLIB_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-llvm-ranlib
export CARGO_TARGET_DIR="${QUIETDESK_WINDOWS_TARGET_DIR:-$PWD/work/windows-build/target}"
rustup target add --toolchain "$(sed -n 's/^channel = "\(.*\)"/\1/p' windows/rust-toolchain.toml)" x86_64-pc-windows-gnullvm >/dev/null 2>&1
