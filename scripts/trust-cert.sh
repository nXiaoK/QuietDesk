#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
用法:
  ./scripts/trust-cert.sh <公开证书.crt> [--app /Applications/QuietDesk.app]
  ./scripts/trust-cert.sh --unquarantine [/Applications/QuietDesk.app]

说明:
  1. 在另一台需要安装 GitHub Actions DMG 的 Mac 上，只需导入一次公开证书（.crt，不含私钥）
     并设为系统代码签名信任，之后每次覆盖更新同一证书签名的版本均可保持稳定的指定要求。
  2. 对浏览器直接下载的未公证 DMG 安装后的应用，可用 --unquarantine 清除浏览器附加的隔离属性。
EOF
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

UNQUARANTINE_ONLY=0
CERT_PATH=""
APP_PATH="/Applications/QuietDesk.app"
CLEAR_APP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unquarantine)
            UNQUARANTINE_ONLY=1
            CLEAR_APP=1
            if [[ $# -ge 2 && ! "$2" =~ ^-- ]]; then
                APP_PATH="$2"
                shift 2
            else
                shift
            fi
            ;;
        --app)
            [[ $# -ge 2 ]] || { echo "ERROR: --app 缺少路径参数" >&2; exit 1; }
            APP_PATH="$2"
            CLEAR_APP=1
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$CERT_PATH" ]]; then
                CERT_PATH="$1"
                shift
            else
                echo "ERROR: 未知参数: $1" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [[ "$UNQUARANTINE_ONLY" == "0" ]]; then
    if [[ -z "$CERT_PATH" || ! -f "$CERT_PATH" ]]; then
        echo "ERROR: 找不到证书文件: ${CERT_PATH:-<未指定>}" >&2
        exit 1
    fi
    if grep -q "PRIVATE KEY" "$CERT_PATH"; then
        echo "ERROR: 拒绝导入包含私钥的文件；其他设备只需导入公开证书 (.crt)。" >&2
        exit 1
    fi
    if ! /usr/bin/openssl x509 -in "$CERT_PATH" -noout -checkend 0 >/dev/null 2>&1; then
        echo "ERROR: 指定的文件不是有效的未过期 X.509 证书: $CERT_PATH" >&2
        exit 1
    fi
    SUBJECT="$(/usr/bin/openssl x509 -in "$CERT_PATH" -noout -subject | sed 's/^subject=//')"
    SHA1="$(/usr/bin/openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha1 | awk -F= '{print $2}')"
    echo "==> 正在将公开证书加入系统钥匙串代码签名信任..."
    echo "    Subject: $SUBJECT"
    echo "    SHA-1:   $SHA1"
    sudo security add-trusted-cert -d -r trustRoot -p codeSign \
        -k /Library/Keychains/System.keychain "$CERT_PATH"
    echo "✅ 已信任该代码签名证书。"
fi

if [[ "$CLEAR_APP" == "1" ]]; then
    if [[ ! -d "$APP_PATH" ]]; then
        echo "ERROR: 找不到应用路径: $APP_PATH" >&2
        exit 1
    fi
    xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    codesign -d -r- "$APP_PATH"
    echo "✅ 已移除隔离属性并校验签名通过: $APP_PATH"
fi
