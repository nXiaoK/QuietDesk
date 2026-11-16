#!/usr/bin/env python3
"""Package the built application as a drag-and-drop DMG, ZIP and source ZIP."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile
import zipfile

from version import ROOT, build_number, parse_version

FIRST_INSTALL_HELPER_NAME = "首次安装信任证书.command"


def require_clean_tree(root):
    if subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=normal"], text=True):
        raise ValueError("Commit or stash changes before packaging source")


def extract_self_signed_certificate(executable_path):
    """Return the embedded PEM certificate if and only if the Mach-O binary is signed with a self-signed certificate."""
    data = Path(executable_path).read_bytes()
    if len(data) < 32:
        return None
    magic = struct.unpack(">I", data[:4])[0]
    if magic == 0xCAFEBABE:
        nfat = struct.unpack(">I", data[4:8])[0]
        if nfat < 1 or len(data) < 28:
            return None
        _, _, offset, size, _ = struct.unpack(">IIIII", data[8:28])
        macho = data[offset:offset + size]
    elif struct.unpack("<I", data[:4])[0] == 0xFEEDFACF:
        macho = data
    else:
        return None

    if len(macho) < 32 or struct.unpack("<I", macho[:4])[0] != 0xFEEDFACF:
        return None
    ncmds = struct.unpack("<I", macho[16:20])[0]
    pos = 32
    sig_offset = sig_size = None
    for _ in range(ncmds):
        if pos + 8 > len(macho):
            return None
        cmd, cmdsize = struct.unpack("<II", macho[pos:pos + 8])
        if cmd == 0x1D and cmdsize >= 16:  # LC_CODE_SIGNATURE
            _, _, sig_offset, sig_size = struct.unpack("<IIII", macho[pos:pos + 16])
            break
        pos += cmdsize
    if sig_offset is None:
        return None

    superblob = macho[sig_offset:sig_offset + sig_size]
    if len(superblob) < 12:
        return None
    sb_magic, _, count = struct.unpack(">III", superblob[:12])
    if sb_magic != 0xFADE0CC0:  # CSMAGIC_EMBEDDED_SIGNATURE
        return None
    cms_der = b""
    for index in range(count):
        idx_pos = 12 + index * 8
        if idx_pos + 8 > len(superblob):
            break
        slot_type, blob_offset = struct.unpack(">II", superblob[idx_pos:idx_pos + 8])
        if slot_type == 0x10000 and blob_offset + 8 <= len(superblob):  # CSSLOT_SIGNATURESLOT
            bw_magic, bw_len = struct.unpack(">II", superblob[blob_offset:blob_offset + 8])
            if bw_magic == 0xFADE0B01 and bw_len > 8:  # CSMAGIC_BLOBWRAPPER
                cms_der = superblob[blob_offset + 8:blob_offset + bw_len]
            break
    if not cms_der:
        return None

    pem_out = subprocess.check_output(
        ["/usr/bin/openssl", "pkcs7", "-inform", "DER", "-print_certs"],
        input=cms_der,
    ).decode("utf-8")
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem_out, re.S)
    if len(blocks) != 1:
        return None
    subject = subprocess.check_output(
        ["/usr/bin/openssl", "x509", "-noout", "-subject"], input=blocks[0], text=True
    ).partition("=")[2].strip()
    issuer = subprocess.check_output(
        ["/usr/bin/openssl", "x509", "-noout", "-issuer"], input=blocks[0], text=True
    ).partition("=")[2].strip()
    if not subject or subject != issuer:
        return None
    return blocks[0].strip() + "\n"


def render_first_install_helper(cert_pem):
    if "PRIVATE KEY" in cert_pem or "-----BEGIN CERTIFICATE-----" not in cert_pem:
        raise ValueError("Invalid public certificate for DMG trust helper")
    return f"""#!/usr/bin/env bash
set -euo pipefail

DMG_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_APP="/Applications/QuietDesk.app"

echo "========================================================"
echo "  QuietDesk 首次安装与代码签名证书信任助手"
echo "  （每台 Mac 仅需首次安装时运行一次，后续升级直接拖入覆盖即可）"
echo "========================================================"
echo ""

if [[ -d "$DMG_DIR/QuietDesk.app" ]]; then
    if pgrep -x QuietDesk >/dev/null 2>&1; then
        echo "提示：检测到 QuietDesk 正在运行，跳过自动复制；将直接信任证书并处理已安装的 $TARGET_APP。"
    elif [[ ! -d "$TARGET_APP" ]]; then
        echo "==> [1/3] 正在将 QuietDesk.app 安装到 /Applications..."
        /usr/bin/ditto "$DMG_DIR/QuietDesk.app" "$TARGET_APP"
    else
        echo "==> [1/3] 检测到已存在 $TARGET_APP，正在同步当前镜像版本..."
        /usr/bin/ditto "$DMG_DIR/QuietDesk.app" "$TARGET_APP"
    fi
else
    echo "==> [1/3] 检查目标应用路径: $TARGET_APP"
fi

TMP_DIR="$(mktemp -d "/tmp/quietdesk-trust.XXXXXX")"
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

CERT_FILE="$TMP_DIR/quietdesk-codesign.crt"
cat > "$CERT_FILE" <<'CERT_EOF'
{cert_pem.rstrip()}
CERT_EOF

if ! /usr/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
    echo "ERROR: 内嵌的代码签名证书已过期或无效。" >&2
    exit 1
fi

SUBJECT="$(/usr/bin/openssl x509 -in "$CERT_FILE" -noout -subject | sed 's/^subject=//')"
SHA1="$(/usr/bin/openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha1 | awk -F= '{{print $2}}')"

echo "==> [2/3] 正在将固定代码签名证书加入本机系统钥匙串信任..."
echo "    证书身份: $SUBJECT"
echo "    SHA-1:    $SHA1"
echo "    （请输入本机管理员密码，并在系统弹窗中确认信任变更）"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \\
    -k /Library/Keychains/System.keychain "$CERT_FILE"

echo "==> [3/3] 正在清除下载隔离属性并校验应用签名..."
if [[ -d "$TARGET_APP" ]]; then
    sudo xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || \\
        xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
    codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
    codesign -d -r- "$TARGET_APP"
fi

echo ""
echo "✅ 首次安装与证书信任已完成！"
echo "   1. 现在可直接打开 /Applications/QuietDesk.app，首次授予录屏与辅助功能权限。"
echo "   2. 今后在这台 Mac 上升级新版本（直接拖入 Applications 覆盖或应用内更新），"
echo "      无需再次运行本脚本，也无需重复授予录屏与辅助功能权限。"
"""


def main():
    output = Path(os.environ.get("QUIETDESK_DIST_DIR", ROOT / "dist"))
    app = output / "QuietDesk.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    parse_version(version)
    build = build_number(info["CFBundleVersion"])
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architectures = set(subprocess.check_output(["xcrun", "lipo", "-archs", str(app / "Contents/MacOS/QuietDesk")], text=True).split())
    if architectures == {"arm64", "x86_64"}:
        architecture = "universal"
    elif architectures in ({"arm64"}, {"x86_64"}):
        architecture = next(iter(architectures))
    else:
        raise ValueError("Unexpected application architectures")
    icon = app / "Contents/Resources" / info["CFBundleIconFile"]
    if icon.read_bytes() != (ROOT / "Resources/QuietDesk.icns").read_bytes():
        raise ValueError("Application icon is missing or differs from its source")
    names = [f"QuietDesk-{version}-macOS-{architecture}.dmg", f"QuietDesk-{version}-macOS-{architecture}.zip", f"QuietDesk-{version}-Source.zip"]
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output) as temporary:
        staging = Path(temporary)
        volume = staging / "volume"
        volume.mkdir()
        subprocess.run(["ditto", str(app), str(volume / app.name)], check=True)
        (volume / "Applications").symlink_to("/Applications", target_is_directory=True)
        self_signed_cert = extract_self_signed_certificate(app / "Contents/MacOS" / info["CFBundleExecutable"])
        if self_signed_cert is not None:
            helper = volume / FIRST_INSTALL_HELPER_NAME
            helper.write_text(render_first_install_helper(self_signed_cert), encoding="utf-8")
            helper.chmod(0o755)
        subprocess.run(["hdiutil", "create", "-volname", "QuietDesk", "-srcfolder", str(volume), "-format", "UDZO", "-ov", str(staging / names[0])], check=True)
        subprocess.run(["hdiutil", "verify", str(staging / names[0])], check=True)
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(staging / names[1])], check=True)
        require_clean_tree(ROOT)
        tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"]).decode().split("\0")
        if "version.json" not in tracked or "Package.swift" not in tracked:
            raise ValueError("Source packaging requires tracked project files")
        with zipfile.ZipFile(staging / names[2], "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name in sorted(filter(None, tracked)):
                if name == "version.json":
                    archive.writestr("QuietDesk/" + name, json.dumps({"version": version, "build": build}, indent=2) + "\n")
                else:
                    archive.write(ROOT / name, "QuietDesk/" + name)
        for name in names[1:]:
            with zipfile.ZipFile(staging / name) as archive:
                if archive.testzip() is not None:
                    raise ValueError("Corrupt package: " + name)
        for name in names:
            (staging / name).replace(output / name)
    checksums = output / f"SHA256SUMS-{version}.txt"
    checksums.write_text("".join(hashlib.sha256((output / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))
    for name in [*names, checksums.name]:
        print(output / name)


if __name__ == "__main__":
    main()
