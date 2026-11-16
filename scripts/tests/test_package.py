import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-app.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("package_app", SCRIPT)
package_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_module)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "source.swift").write_text("source\n")
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", "source.swift")
        self.git("commit", "-m", "Fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True, stderr=subprocess.DEVNULL)

    def test_clean_tree_can_be_packaged(self):
        package_module.require_clean_tree(self.root)

    def test_modified_tree_is_rejected(self):
        (self.root / "source.swift").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "Commit or stash changes before packaging source"):
            package_module.require_clean_tree(self.root)

    def test_untracked_source_is_rejected(self):
        (self.root / "new.swift").write_text("new source\n")
        with self.assertRaisesRegex(ValueError, "Commit or stash changes before packaging source"):
            package_module.require_clean_tree(self.root)

    def _build_synthetic_macho_with_cms(self, cms_der: bytes) -> Path:
        import struct

        # Construct a minimal 64-bit Mach-O header with a single LC_CODE_SIGNATURE command
        # pointing to a CS_SuperBlob containing CSSLOT_SIGNATURESLOT (0x10000).
        if cms_der:
            blob_wrapper = struct.pack(">II", 0xFADE0B01, 8 + len(cms_der)) + cms_der
            superblob = struct.pack(">III", 0xFADE0CC0, 12 + 8 + len(blob_wrapper), 1)
            superblob += struct.pack(">II", 0x10000, 20) + blob_wrapper
        else:
            superblob = struct.pack(">III", 0xFADE0CC0, 12, 0)

        header_size = 32
        lc_size = 16
        sig_offset = header_size + lc_size
        macho_header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, lc_size, 0, 0)
        lc_codesig = struct.pack("<IIII", 0x1D, lc_size, sig_offset, len(superblob))
        exe = self.root / "QuietDeskSynthetic"
        exe.write_bytes(macho_header + lc_codesig + superblob)
        return exe

    def test_extracts_only_self_signed_certificate_and_renders_valid_helper(self):
        # 1. Ad-hoc (empty CMS signature slot) -> None
        adhoc_exe = self._build_synthetic_macho_with_cms(b"")
        self.assertIsNone(package_module.extract_self_signed_certificate(adhoc_exe))

        # 2. Self-signed certificate -> returns PEM and renders valid bash helper
        key = self.root / "self.key"
        crt = self.root / "self.crt"
        cms = self.root / "self.der"
        payload = self.root / "payload.bin"
        payload.write_bytes(b"signed-cd")
        subprocess.run(
            ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(key), "-out", str(crt), "-days", "2", "-subj", "/CN=QuietDesk Self-Signed Test"],
            check=True, capture_output=True
        )
        subprocess.run(
            ["/usr/bin/openssl", "smime", "-sign", "-binary", "-in", str(payload),
             "-signer", str(crt), "-inkey", str(key), "-outform", "DER", "-out", str(cms), "-nodetach"],
            check=True, capture_output=True
        )
        self_exe = self._build_synthetic_macho_with_cms(cms.read_bytes())
        extracted = package_module.extract_self_signed_certificate(self_exe)
        self.assertIsNotNone(extracted)
        self.assertIn("-----BEGIN CERTIFICATE-----", extracted)
        self.assertNotIn("PRIVATE KEY", extracted)

        helper_text = package_module.render_first_install_helper(extracted)
        helper_path = self.root / package_module.FIRST_INSTALL_HELPER_NAME
        helper_path.write_text(helper_text, encoding="utf-8")
        syntax = subprocess.run(["bash", "-n", str(helper_path)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

        with self.assertRaisesRegex(ValueError, "Invalid public certificate"):
            package_module.render_first_install_helper(extracted + "\n-----BEGIN PRIVATE KEY-----\n")

        # 3. CA-issued leaf certificate (subject != issuer) -> None (e.g. Developer ID)
        ca_key = self.root / "ca.key"
        ca_crt = self.root / "ca.crt"
        leaf_key = self.root / "leaf.key"
        leaf_csr = self.root / "leaf.csr"
        leaf_crt = self.root / "leaf.crt"
        ca_cms = self.root / "ca.der"
        subprocess.run(
            ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(ca_key), "-out", str(ca_crt), "-days", "2", "-subj", "/CN=Synthetic Root CA"],
            check=True, capture_output=True
        )
        subprocess.run(
            ["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(leaf_key), "-out", str(leaf_csr), "-subj", "/CN=Developer ID Application: Example"],
            check=True, capture_output=True
        )
        subprocess.run(
            ["/usr/bin/openssl", "x509", "-req", "-in", str(leaf_csr), "-CA", str(ca_crt),
             "-CAkey", str(ca_key), "-CAcreateserial", "-out", str(leaf_crt), "-days", "2"],
            check=True, capture_output=True
        )
        subprocess.run(
            ["/usr/bin/openssl", "smime", "-sign", "-binary", "-in", str(payload),
             "-signer", str(leaf_crt), "-inkey", str(leaf_key), "-certfile", str(ca_crt),
             "-outform", "DER", "-out", str(ca_cms), "-nodetach"],
            check=True, capture_output=True
        )
        ca_exe = self._build_synthetic_macho_with_cms(ca_cms.read_bytes())
        self.assertIsNone(package_module.extract_self_signed_certificate(ca_exe))


if __name__ == "__main__":
    unittest.main()
