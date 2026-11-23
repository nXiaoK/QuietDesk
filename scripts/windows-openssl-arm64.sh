#!/bin/bash
# Builds static OpenSSL (mingwarm64) from the Cargo-locked openssl-src crate for aarch64-pc-windows-gnullvm,
# because openssl-src 300.6.1 does not map the aarch64-pc-windows-gnullvm triple in its target table yet.
set -euo pipefail

cd "$(dirname "$0")/.."

read -r openssl_version openssl_source_dir < <(
    {
        cargo metadata --manifest-path windows/Cargo.toml --format-version 1 --locked --offline --filter-platform aarch64-pc-windows-gnullvm 2>/dev/null \
        || cargo metadata --manifest-path windows/Cargo.toml --format-version 1 --locked --filter-platform aarch64-pc-windows-gnullvm
    } | python3 -c '
import json, pathlib, sys
meta = json.load(sys.stdin)
pkg = next(p for p in meta["packages"] if p["name"] == "openssl-src")
src = pathlib.Path(pkg["manifest_path"]).resolve().parent / "openssl"
if not (src / "Configure").is_file():
    raise SystemExit(f"Bundled OpenSSL source not found at {src}")
print(pkg["version"], src)
'
)

build_root="${QUIETDESK_WINDOWS_TARGET_DIR:-$PWD/work/windows-build/target}"
prefix="$(cd "$(dirname "$build_root")" 2>/dev/null && pwd -P || echo "$(dirname "$build_root")")/openssl-mingwarm64-$openssl_version"
if [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" && -f "$prefix/include/openssl/ssl.h" ]]; then
    echo "$prefix"
    exit 0
fi

mkdir -p "$(dirname "$prefix")"
staging="$(mktemp -d "$(dirname "$prefix")/.openssl-arm64.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

cp -R "$openssl_source_dir" "$staging/src"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
(
    cd "$staging/src"
    CC=aarch64-w64-mingw32-clang \
    CXX=aarch64-w64-mingw32-clang++ \
    AR=aarch64-w64-mingw32-llvm-ar \
    RANLIB=aarch64-w64-mingw32-llvm-ranlib \
    RC=aarch64-w64-mingw32-windres \
    WINDRES=aarch64-w64-mingw32-windres \
    perl ./Configure mingwarm64 \
        no-shared no-dso no-module no-tests no-comp no-zlib no-zlib-dynamic \
        no-legacy no-ssl3 no-md2 no-rc5 no-weak-ssl-ciphers \
        no-camellia no-idea no-seed no-capieng no-apps no-docs \
        --libdir=lib "--prefix=$staging/install" >/dev/null
    make -j"$jobs" build_libs >/dev/null
    make install_dev >/dev/null
)

test -f "$staging/install/lib/libssl.a"
test -f "$staging/install/lib/libcrypto.a"
test -f "$staging/install/include/openssl/ssl.h"
rm -rf "$prefix"
mv "$staging/install" "$prefix"
echo "$prefix"
