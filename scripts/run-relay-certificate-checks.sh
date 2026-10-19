#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/relay-certificate-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/RelayCertificateStore.swift AppChecks/RelayCertificateChecks.swift \
    -o "$build_directory/RelayCertificateChecks"
fixture="$(mktemp -d "$check_root/certificate-fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
umask 077
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -subj '/CN=QuietDesk synthetic node' \
    -addext 'subjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost' -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$fixture/privkey.pem" -out "$fixture/certificate.pem" 2> "$fixture/openssl.log"
openssl x509 -in "$fixture/certificate.pem" -outform DER -out "$fixture/certificate.der"
openssl x509 -in "$fixture/certificate.pem" -noout -fingerprint -sha256 > "$fixture/fingerprint.txt"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 -subj '/CN=QuietDesk synthetic client' \
    -addext 'subjectAltName=IP:127.0.0.1' -addext 'extendedKeyUsage=clientAuth' \
    -keyout "$fixture/client.key" -out "$fixture/client.pem" 2>> "$fixture/openssl.log"
"$build_directory/RelayCertificateChecks" "$fixture"
