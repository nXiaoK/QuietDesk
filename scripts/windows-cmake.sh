#!/bin/bash
# Print the directory of a CMake suitable for the bundled libopus build.
set -euo pipefail

if command -v cmake >/dev/null && cmake --version | awk '
    NR == 1 { split($3, version, "."); ok = version[1] > 3 || (version[1] == 3 && version[2] >= 16) }
    END { exit !ok }
'; then
    cd "$(dirname "$(command -v cmake)")"
    pwd -P
    exit 0
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Install CMake 3.16 or later to build libopus." >&2
    exit 1
fi

version=3.31.10
package="cmake-$version-macos-universal"
digest=be9f3faeeaf7921cc2d77cea711dd5e6f72c63af2810cacd9205b3ce8d1593c9
root="${QUIETDESK_WINDOWS_TOOLCHAIN_DIR:-$PWD/work/toolchains}"
bin="$root/$package/CMake.app/Contents/bin"
if [[ ! -x "$bin/cmake" ]]; then
    mkdir -p "$root"
    staging="$(mktemp -d "$root/cmake.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    curl --fail --silent --show-error --location --retry 2 \
        "https://github.com/Kitware/CMake/releases/download/v$version/$package.tar.gz" -o "$staging/$package.tar.gz"
    echo "$digest  $staging/$package.tar.gz" | shasum -a 256 -c - >/dev/null
    tar -xzf "$staging/$package.tar.gz" -C "$staging"
    # Concurrent native and cross builds may install the same verified distribution.
    mv -n "$staging/$package" "$root/" || test -x "$bin/cmake"
fi
test -x "$bin/cmake"
cd "$bin"
pwd -P
