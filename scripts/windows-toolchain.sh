#!/bin/bash
# Sourced by the Windows build scripts: puts a pinned llvm-mingw cross toolchain on PATH, downloading and
# verifying it on first use, and points Cargo at it for the x86_64 and aarch64 Windows targets.
toolchain_release=20261104
toolchain_archive="llvm-mingw-$toolchain_release-ucrt-macos-universal.tar.xz"
toolchain_sha256=66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c
toolchain_root="${QUIETDESK_WINDOWS_TOOLCHAIN_DIR:-$PWD/work/toolchains}"
toolchain_directory="$toolchain_root/${toolchain_archive%.tar.xz}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "The pinned cross toolchain is the macOS build of llvm-mingw; on Windows build with cargo directly." >&2
    exit 1
fi
if [[ ! -x "$toolchain_directory/bin/x86_64-w64-mingw32-clang" || ! -x "$toolchain_directory/bin/aarch64-w64-mingw32-clang" ]]; then
    mkdir -p "$toolchain_root"
    curl -sSL --fail -o "$toolchain_root/$toolchain_archive.part" \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$toolchain_release/$toolchain_archive"
    echo "$toolchain_sha256  $toolchain_root/$toolchain_archive.part" | shasum -a 256 -c - >/dev/null
    mv "$toolchain_root/$toolchain_archive.part" "$toolchain_root/$toolchain_archive"
    tar -xJf "$toolchain_root/$toolchain_archive" -C "$toolchain_root"
fi
cmake_bin="$(bash scripts/windows-cmake.sh)" || return 1
export PATH="$toolchain_directory/bin:$cmake_bin:$PATH"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER=x86_64-w64-mingw32-clang
export CC_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-clang
export CXX_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-clang++
export AR_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-llvm-ar
export RANLIB_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-llvm-ranlib
export RC_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-windres
export CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER=aarch64-w64-mingw32-clang
export CC_aarch64_pc_windows_gnullvm=aarch64-w64-mingw32-clang
export CXX_aarch64_pc_windows_gnullvm=aarch64-w64-mingw32-clang++
export AR_aarch64_pc_windows_gnullvm=aarch64-w64-mingw32-llvm-ar
export RANLIB_aarch64_pc_windows_gnullvm=aarch64-w64-mingw32-llvm-ranlib
export RC_aarch64_pc_windows_gnullvm=aarch64-w64-mingw32-windres
# libopus 1.6.1 guards NEON prototype declarations behind OPUS_ARM_MAY_HAVE_NEON_INTR even when OPUS_PRESUME_NEON is on without RTCD.
export CFLAGS_aarch64_pc_windows_gnullvm="-DOPUS_ARM_MAY_HAVE_NEON_INTR -DOPUS_ARM_MAY_HAVE_NEON"
export CARGO_TARGET_DIR="${QUIETDESK_WINDOWS_TARGET_DIR:-$PWD/work/windows-build/target}"
mkdir -p "$CARGO_TARGET_DIR"
rust_channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' windows/rust-toolchain.toml)"
installed_targets="$(rustup target list --installed --toolchain "$rust_channel" 2>/dev/null || true)"
for rust_target in x86_64-pc-windows-gnullvm aarch64-pc-windows-gnullvm; do
    if ! grep -qx "$rust_target" <<< "$installed_targets"; then
        rustup target add --toolchain "$rust_channel" "$rust_target" >/dev/null 2>&1
    fi
done
if [[ "${QUIETDESK_SKIP_ARM64_OPENSSL:-0}" != "1" ]]; then
    openssl_arm64_dir="$(bash scripts/windows-openssl-arm64.sh)" || return 1
    export AARCH64_PC_WINDOWS_GNULLVM_OPENSSL_NO_VENDOR=1
    export AARCH64_PC_WINDOWS_GNULLVM_OPENSSL_STATIC=1
    export AARCH64_PC_WINDOWS_GNULLVM_OPENSSL_DIR="$openssl_arm64_dir"
fi
