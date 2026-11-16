#!/usr/bin/env bash
set -euo pipefail
set +x

PREFLIGHT=0
if [[ "${1:-}" == "--preflight" ]]; then
    PREFLIGHT=1
fi

P12_B64="${QUIETDESK_CODESIGN_P12_BASE64:-}"
P12_PASS="${QUIETDESK_CODESIGN_P12_PASSWORD:-}"
PINNED_SHA1="${QUIETDESK_SIGNING_LEAF_SHA1:-}"
REQUESTED_IDENTITY="${QUIETDESK_SIGNING_IDENTITY:-${SIGNING_IDENTITY:-}}"

if [[ -z "${P12_B64//[[:space:]]/}" ]]; then
    if [[ "$PREFLIGHT" == "1" ]]; then
        echo "::warning::未配置 QUIETDESK_CODESIGN_P12_BASE64，本次构建使用临时签名（ad-hoc）；覆盖安装后需重新授予录屏与辅助功能权限。"
    fi
    exit 0
fi

if [[ -z "$P12_PASS" ]]; then
    echo "::error::已配置 QUIETDESK_CODESIGN_P12_BASE64，但缺少 QUIETDESK_CODESIGN_P12_PASSWORD。" >&2
    exit 1
fi

BASE_TMP="${RUNNER_TEMP:-/tmp}"
STATE_DIR="$(mktemp -d "$BASE_TMP/quietdesk-ci-signing.XXXXXX")"
chmod 700 "$STATE_DIR"

P12_FILE="$STATE_DIR/codesign.p12"
CERT_PEM="$STATE_DIR/codesign-certs.pem"
KEYCHAIN_PATH="$STATE_DIR/quietdesk-signing.keychain-db"

cleanup_on_failure() {
    local code=$?
    rm -f "$P12_FILE"
    if [[ $code -ne 0 ]]; then
        if [[ -f "$STATE_DIR/previous-keychains.txt" ]]; then
            local prev=()
            while IFS= read -r item; do
                [[ -n "$item" ]] && prev+=("$item")
            done < "$STATE_DIR/previous-keychains.txt"
            if [[ ${#prev[@]} -gt 0 ]]; then
                security list-keychains -d user -s "${prev[@]}" >/dev/null 2>&1 || true
            fi
        fi
        security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
        rm -rf "$STATE_DIR"
    fi
}
trap cleanup_on_failure EXIT INT TERM

python3 - "$P12_FILE" <<'PY'
import base64
import os
from pathlib import Path
import sys

raw = os.environ.get("QUIETDESK_CODESIGN_P12_BASE64", "").strip()
try:
    decoded = base64.b64decode(raw, validate=False)
except Exception as exc:
    sys.stderr.write("ERROR: QUIETDESK_CODESIGN_P12_BASE64 不是有效的 Base64 编码。\n")
    sys.exit(1)
if len(decoded) < 64:
    sys.stderr.write("ERROR: 解码后的 PKCS#12 数据长度异常，请检查 QUIETDESK_CODESIGN_P12_BASE64。\n")
    sys.exit(1)
out = Path(sys.argv[1])
out.write_bytes(decoded)
os.chmod(out, 0o600)
PY

# 先在导入钥匙串前用本机 LibreSSL 校验密码、证书有效期与私钥存在性
if ! /usr/bin/openssl pkcs12 -in "$P12_FILE" -passin env:QUIETDESK_CODESIGN_P12_PASSWORD -clcerts -nokeys -out "$CERT_PEM" >/dev/null 2>&1; then
    echo "::error::无法使用 QUIETDESK_CODESIGN_P12_PASSWORD 解析 PKCS#12 证书（密码错误或文件损坏）。" >&2
    exit 1
fi
chmod 600 "$CERT_PEM"

if ! grep -q "BEGIN CERTIFICATE" "$CERT_PEM"; then
    echo "::error::PKCS#12 中未找到代码签名证书。" >&2
    exit 1
fi

if ! /usr/bin/openssl x509 -in "$CERT_PEM" -noout -checkend 0 >/dev/null 2>&1; then
    echo "::error::代码签名证书已过期，请更新证书后重试。" >&2
    exit 1
fi

KEY_COUNT="$(/usr/bin/openssl pkcs12 -in "$P12_FILE" -passin env:QUIETDESK_CODESIGN_P12_PASSWORD -nocerts -nodes 2>/dev/null | grep -c "PRIVATE KEY" || true)"
if [[ "$KEY_COUNT" -lt 1 ]]; then
    echo "::error::PKCS#12 中未包含私钥，无法用于代码签名。" >&2
    exit 1
fi

SUBJECT="$(/usr/bin/openssl x509 -in "$CERT_PEM" -noout -subject | sed 's/^subject=//')"
ISSUER="$(/usr/bin/openssl x509 -in "$CERT_PEM" -noout -issuer | sed 's/^issuer=//')"
LEAF_SHA1="$(/usr/bin/openssl x509 -in "$CERT_PEM" -noout -fingerprint -sha1 | awk -F= '{gsub(/:/, "", $2); print toupper($2)}')"
END_DATE="$(/usr/bin/openssl x509 -in "$CERT_PEM" -noout -enddate | sed 's/^notAfter=//')"

if [[ -n "$PINNED_SHA1" ]]; then
    EXPECTED="$(printf '%s' "$PINNED_SHA1" | tr -d ': ' | tr '[:lower:]' '[:upper:]')"
    if [[ "$LEAF_SHA1" != "$EXPECTED" ]]; then
        echo "::error::导入证书的 SHA-1 ($LEAF_SHA1) 与 QUIETDESK_SIGNING_LEAF_SHA1 ($EXPECTED) 不一致。" >&2
        exit 1
    fi
fi

if [[ "$PREFLIGHT" == "1" ]]; then
    rm -rf "$STATE_DIR"
    echo "==> 代码签名证书预检通过: $SUBJECT (SHA-1: $LEAF_SHA1, 有效期至: $END_DATE)"
    exit 0
fi

KEYCHAIN_PASS="$(/usr/bin/openssl rand -hex 24)"

EXISTING_KEYCHAINS=()
while IFS= read -r line; do
    cleaned="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
    [[ -n "$cleaned" ]] && EXISTING_KEYCHAINS+=("$cleaned")
done < <(security list-keychains -d user)
printf '%s\n' "${EXISTING_KEYCHAINS[@]}" > "$STATE_DIR/previous-keychains.txt"

security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" "${EXISTING_KEYCHAINS[@]}"

security import "$P12_FILE" \
    -k "$KEYCHAIN_PATH" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/productsign \
    -f pkcs12 >/dev/null
rm -f "$P12_FILE"

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null

# 在临时 CI 运行器上，自签名证书需加入 System.keychain 代码签名信任，codesign --verify --strict 才能通过
if [[ "$SUBJECT" == "$ISSUER" ]] && [[ "${GITHUB_ACTIONS:-}" == "true" || "${QUIETDESK_TRUST_CI_CERT:-0}" == "1" ]]; then
    LEAF_CERT="$STATE_DIR/leaf-cert.crt"
    /usr/bin/openssl x509 -in "$CERT_PEM" -out "$LEAF_CERT"
    sudo security add-trusted-cert -d -r trustRoot -p codeSign \
        -k /Library/Keychains/System.keychain "$LEAF_CERT"
fi

VALID_IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null || true)"
SELECTED_IDENTITY=""
if [[ -n "$REQUESTED_IDENTITY" ]]; then
    SELECTED_IDENTITY="$REQUESTED_IDENTITY"
elif printf '%s\n' "$VALID_IDENTITIES" | grep -qi "$LEAF_SHA1"; then
    SELECTED_IDENTITY="$LEAF_SHA1"
else
    SELECTED_IDENTITY="$(printf '%s\n' "$VALID_IDENTITIES" | awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')"
fi

if [[ -z "$SELECTED_IDENTITY" ]]; then
    echo "::error::导入钥匙串后未找到有效的代码签名身份，请检查证书是否包含 codeSigning 扩展用途。" >&2
    exit 1
fi

echo "==> 已导入固定代码签名证书: $SUBJECT (SHA-1: $LEAF_SHA1, 有效期至: $END_DATE)"

if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        echo "SIGNING_IDENTITY=$SELECTED_IDENTITY"
        echo "QUIETDESK_REQUIRE_CERT=1"
        echo "QUIETDESK_SIGNING_LEAF_SHA1=$LEAF_SHA1"
        echo "QUIETDESK_CI_KEYCHAIN=$KEYCHAIN_PATH"
        echo "QUIETDESK_CI_CERT_STATE=$STATE_DIR"
    } >> "$GITHUB_ENV"
fi
