#!/usr/bin/env bash
set -euo pipefail
set +x

usage() {
    cat <<'EOF'
用法:
  ./scripts/export-ci-cert.sh [--upload] [--repo <owner/repo>] [--out-dir <目录>]

说明:
  从本机登录钥匙串导出当前固定代码签名身份（自动识别 QuietDesk Self-Signed Code Signing
  或 RDesk Self-Signed Code Signing，也可用 SIGNING_IDENTITY 指定），重新封装为只含该单本身分的
  加密 PKCS#12，用于配置 GitHub Actions 自动打包签名（保持与本机一致的 Designated Requirement）。

选项:
  --upload            直接通过已登录的 gh CLI 设置仓库 Secrets（推荐：私钥与密码不落盘、不打印）
  --repo <owner/repo> 指定 GitHub 仓库（默认自动从 git remote origin 推断）
  --out-dir <目录>    未加 --upload 时保存导出文件的仓库外私有目录（默认 ~/.config/QuietDesk）
EOF
}

UPLOAD=0
REPO=""
OUT_DIR="${HOME}/.config/QuietDesk"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload)
            UPLOAD=1
            shift
            ;;
        --repo)
            [[ $# -ge 2 ]] || { echo "ERROR: --repo 缺少参数" >&2; exit 1; }
            REPO="$2"
            shift 2
            ;;
        --out-dir)
            [[ $# -ge 2 ]] || { echo "ERROR: --out-dir 缺少参数" >&2; exit 1; }
            OUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: 未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

check_outside_git() {
    local target="$1"
    python3 - "$target" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1]).expanduser().resolve()
for candidate in [p, *p.parents]:
    if (candidate / ".git").exists():
        sys.stderr.write(f"ERROR: 拒绝将签名材料写入 Git 仓库目录内: {p}\n")
        sys.exit(1)
PY
}

check_outside_git "$OUT_DIR"

LOGIN_KEYCHAIN="${QUIETDESK_LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"

TARGET_SHA1=""
TARGET_NAME=""
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    if [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        TARGET_SHA1="$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')"
        TARGET_NAME="$(printf '%s\n' "$IDENTITIES" | awk -v sha="$TARGET_SHA1" 'toupper($2) == sha { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit }')"
    else
        TARGET_SHA1="$(printf '%s\n' "$IDENTITIES" | awk -v name="\"$SIGNING_IDENTITY\"" '$0 ~ name { print toupper($2); exit }')"
        TARGET_NAME="$SIGNING_IDENTITY"
    fi
else
    for candidate in "QuietDesk Self-Signed Code Signing" "RDesk Self-Signed Code Signing"; do
        match="$(printf '%s\n' "$IDENTITIES" | awk -v name="\"$candidate\"" '$0 ~ name { print toupper($2); exit }')"
        if [[ -n "$match" ]]; then
            TARGET_SHA1="$match"
            TARGET_NAME="$candidate"
            break
        fi
    done
fi

if [[ -z "$TARGET_SHA1" ]]; then
    echo "ERROR: 未在本机钥匙串中找到可用的固定代码签名证书。" >&2
    echo "请先运行 ./scripts/setup-cert.sh 生成证书，或通过 SIGNING_IDENTITY 指定已有身份。" >&2
    exit 1
fi

if [[ "$UPLOAD" == "1" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: 未找到 gh CLI；请先安装 GitHub CLI (brew install gh && gh auth login)，或省略 --upload 导出到仓库外目录。" >&2
        exit 1
    fi
    if [[ -z "$REPO" ]]; then
        REMOTE_URL="$(git config --get remote.origin.url || true)"
        REPO="$(printf '%s' "$REMOTE_URL" | sed -E 's#^.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
    fi
    if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "ERROR: 无法推断 GitHub 仓库名，请使用 --repo <owner/repo> 显式指定。" >&2
        exit 1
    fi
fi

TMP_DIR="$(mktemp -d "/tmp/quietdesk-export-ci.XXXXXX")"
chmod 700 "$TMP_DIR"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

RAW_PASS="$(/usr/bin/openssl rand -hex 24)"
EXPORT_PASS="$(/usr/bin/openssl rand -hex 24)"
export RAW_PASS EXPORT_PASS TARGET_SHA1

echo "==> [1/3] 正在从登录钥匙串导出证书 '$TARGET_NAME' (SHA-1: $TARGET_SHA1)..."
echo "    （若弹出 macOS 钥匙串授权窗口，请输入本机登录密码点击“允许”）"
security export \
    -k "$LOGIN_KEYCHAIN" \
    -t identities \
    -f pkcs12 \
    -P "$RAW_PASS" \
    -o "$TMP_DIR/raw.p12"

echo "==> [2/3] 正在筛选并重新封装单一签名身份（剔除钥匙串中其他无关证书）..."
/usr/bin/openssl pkcs12 -in "$TMP_DIR/raw.p12" -passin env:RAW_PASS -clcerts -nokeys -out "$TMP_DIR/all-certs.pem"
/usr/bin/openssl pkcs12 -in "$TMP_DIR/raw.p12" -passin env:RAW_PASS -nocerts -nodes -out "$TMP_DIR/all-keys.pem"
rm -f "$TMP_DIR/raw.p12"

python3 - "$TMP_DIR" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys

tmp = Path(sys.argv[1])
target_sha1 = os.environ["TARGET_SHA1"].upper()

certs_pem = (tmp / "all-certs.pem").read_text()
keys_pem = (tmp / "all-keys.pem").read_text()
cert_blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certs_pem, re.S)
key_blocks = re.findall(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", keys_pem, re.S)

matched_cert = None
matched_pub = None
for block in cert_blocks:
    fp = subprocess.check_output(
        ["/usr/bin/openssl", "x509", "-noout", "-fingerprint", "-sha1"],
        input=block, text=True
    )
    sha1 = fp.split("=", 1)[1].replace(":", "").strip().upper()
    if sha1 == target_sha1:
        matched_cert = block
        matched_pub = subprocess.check_output(
            ["/usr/bin/openssl", "x509", "-noout", "-pubkey"],
            input=block, text=True
        ).strip()
        break

if not matched_cert or not matched_pub:
    sys.stderr.write(f"ERROR: 在登录钥匙串导出的证书中未找到目标 SHA-1 ({target_sha1})。\n")
    sys.exit(1)

matched_key = None
for block in key_blocks:
    pub = subprocess.check_output(
        ["/usr/bin/openssl", "pkey", "-pubout"],
        input=block, text=True
    ).strip()
    if pub == matched_pub:
        matched_key = block
        break

if not matched_key:
    sys.stderr.write("ERROR: 未找到与目标证书配对的私钥。\n")
    sys.exit(1)

(tmp / "matched.crt").write_text(matched_cert + "\n")
(tmp / "matched.key").write_text(matched_key + "\n")
os.chmod(tmp / "matched.key", 0o600)
PY

rm -f "$TMP_DIR/all-certs.pem" "$TMP_DIR/all-keys.pem"

/usr/bin/openssl pkcs12 -export \
    -out "$TMP_DIR/clean.p12" \
    -inkey "$TMP_DIR/matched.key" \
    -in "$TMP_DIR/matched.crt" \
    -passout env:EXPORT_PASS
rm -f "$TMP_DIR/matched.key"

install -d -m 700 "$OUT_DIR"
PUBLIC_CRT="$OUT_DIR/quietdesk-codesign.crt"
cp -f "$TMP_DIR/matched.crt" "$PUBLIC_CRT"
chmod 644 "$PUBLIC_CRT"

P12_B64="$(base64 < "$TMP_DIR/clean.p12" | tr -d '\n')"

if [[ "$UPLOAD" == "1" ]]; then
    echo "==> [3/3] 正在通过 gh secret set 配置仓库 $REPO 的签名 Secrets..."
    printf '%s' "$P12_B64" | gh secret set QUIETDESK_CODESIGN_P12_BASE64 --repo "$REPO"
    printf '%s' "$EXPORT_PASS" | gh secret set QUIETDESK_CODESIGN_P12_PASSWORD --repo "$REPO"
    printf '%s' "$TARGET_SHA1" | gh secret set QUIETDESK_SIGNING_LEAF_SHA1 --repo "$REPO"
    echo "✅ 已完成 GitHub Actions 签名配置（仓库: $REPO, 证书 SHA-1: $TARGET_SHA1）。"
    echo "   公开证书已保存至（不含私钥，可拷给其他需安装此 DMG 的 Mac 信任一次）："
    echo "   $PUBLIC_CRT"
else
    B64_FILE="$OUT_DIR/ci-codesign.p12.b64"
    PASS_FILE="$OUT_DIR/ci-codesign.pass"
    umask 077
    printf '%s\n' "$P12_B64" > "$B64_FILE"
    printf '%s\n' "$EXPORT_PASS" > "$PASS_FILE"
    chmod 600 "$B64_FILE" "$PASS_FILE"
    echo "==> [3/3] 已导出到仓库外私有目录: $OUT_DIR"
    echo "    - 公开证书（可拷给其他 Mac 执行 ./scripts/trust-cert.sh）：$PUBLIC_CRT"
    echo "    - CI P12 Base64（0600 私有）：$B64_FILE"
    echo "    - CI P12 密码（0600 私有）：$PASS_FILE"
    echo ""
    echo "可执行以下命令写入 GitHub Actions Secrets（替换 <owner/repo>）："
    echo "  gh secret set QUIETDESK_CODESIGN_P12_BASE64 --repo <owner/repo> < \"$B64_FILE\""
    echo "  gh secret set QUIETDESK_CODESIGN_P12_PASSWORD --repo <owner/repo> < \"$PASS_FILE\""
    echo "  printf '%s' '$TARGET_SHA1' | gh secret set QUIETDESK_SIGNING_LEAF_SHA1 --repo <owner/repo>"
fi
