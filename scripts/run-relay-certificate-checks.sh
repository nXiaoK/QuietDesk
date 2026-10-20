#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/relay-certificate-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# Match the relay image's certificate generator rather than the runner's OpenSSL 1.1 default.
openssl_binary=openssl
if command -v brew >/dev/null 2>&1; then
    openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [[ -x "$openssl_prefix/bin/openssl" ]]; then openssl_binary="$openssl_prefix/bin/openssl"; fi
fi
openssl_version="$("$openssl_binary" version)"
if [[ ! "$openssl_version" =~ ^OpenSSL\ ([3-9]|[1-9][0-9]+)\. ]]; then
    echo "Relay certificate checks require OpenSSL 3 or newer; found: $openssl_version" >&2
    exit 1
fi
echo "Relay certificate fixture generator: $openssl_version"
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
"$openssl_binary" req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -subj '/CN=QuietDesk synthetic node' \
    -addext 'subjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost' -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$fixture/privkey.pem" -out "$fixture/certificate.pem" 2> "$fixture/openssl.log"
"$openssl_binary" x509 -in "$fixture/certificate.pem" -outform DER -out "$fixture/certificate.der"
"$openssl_binary" x509 -in "$fixture/certificate.pem" -noout -fingerprint -sha256 > "$fixture/fingerprint.txt"
"$openssl_binary" req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 -subj '/CN=QuietDesk synthetic client' \
    -addext 'subjectAltName=IP:127.0.0.1' -addext 'extendedKeyUsage=clientAuth' \
    -keyout "$fixture/client.key" -out "$fixture/client.pem" 2>> "$fixture/openssl.log"
"$openssl_binary" req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj '/CN=QuietDesk synthetic issuer' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign' \
    -keyout "$fixture/issuer.key" -out "$fixture/issuer.pem" 2>> "$fixture/openssl.log"
"$openssl_binary" req -new -sha256 -key "$fixture/privkey.pem" -subj '/CN=QuietDesk synthetic issued node' \
    -out "$fixture/issued.csr" 2>> "$fixture/openssl.log"
cat > "$fixture/issued.ext" <<'EXT'
subjectAltName=IP:127.0.0.1
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
"$openssl_binary" x509 -req -sha256 -days 1 -in "$fixture/issued.csr" -CA "$fixture/issuer.pem" \
    -CAkey "$fixture/issuer.key" -set_serial 2 -extfile "$fixture/issued.ext" -outform DER \
    -out "$fixture/issued.der" 2>> "$fixture/openssl.log"
"$build_directory/RelayCertificateChecks" "$fixture"
