#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CERT_NAME="${QUIETDESK_CERT_NAME:-QuietDesk Self-Signed Code Signing}"
CERT_ORG="${QUIETDESK_CERT_ORG:-QuietDesk}"
FORCE_CREATE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE_CREATE=1
fi

if [[ "$FORCE_CREATE" != "1" ]]; then
    EXISTING="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if printf '%s\n' "$EXISTING" | grep -q "\"$CERT_NAME\""; then
        echo "==> 钥匙串中已存在有效的 '$CERT_NAME' 代码签名证书："
        printf '%s\n' "$EXISTING" | grep "\"$CERT_NAME\""
        exit 0
    fi
    if printf '%s\n' "$EXISTING" | grep -q '"RDesk Self-Signed Code Signing"'; then
        echo "==> 钥匙串中已存在可复用的 'RDesk Self-Signed Code Signing' 代码签名证书："
        printf '%s\n' "$EXISTING" | grep '"RDesk Self-Signed Code Signing"'
        echo "提示：scripts/sign.sh 与 build-app.sh 会自动识别并复用该证书；如需单独创建 '$CERT_NAME'，请运行 ./scripts/setup-cert.sh --force"
        exit 0
    fi
fi

TMP_DIR="$(mktemp -d "/tmp/quietdesk-cert.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

PASS="$(/usr/bin/openssl rand -hex 16)"

echo "==> [1/3] 使用 /usr/bin/openssl 生成 '$CERT_NAME' 自签名代码签名证书..."
cat > "$TMP_DIR/cert.conf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no

[ req_dn ]
CN = $CERT_NAME
O  = $CERT_ORG

[ codesign_ext ]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/codesign.key" \
    -out "$TMP_DIR/codesign.crt" \
    -days 3650 -config "$TMP_DIR/cert.conf"

/usr/bin/openssl pkcs12 -export \
    -out "$TMP_DIR/codesign.p12" \
    -inkey "$TMP_DIR/codesign.key" \
    -in "$TMP_DIR/codesign.crt" \
    -passout "pass:$PASS"

echo "==> [2/3] 导入证书到登录钥匙串并设为系统代码签名信任..."
security import "$TMP_DIR/codesign.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign -T /usr/bin/productsign -f pkcs12 || true

sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP_DIR/codesign.crt"

echo "==> [3/3] 校验本机可用代码签名身份..."
security find-identity -v -p codesigning
echo "✅ 证书准备完成，后续运行 ./build-app.sh 或 ./scripts/sign.sh 将自动使用该固定证书签名。"
