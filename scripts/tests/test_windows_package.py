import hashlib
import importlib.util
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SCRIPT = ROOT / "scripts" / "package-windows-installer.py"
spec = importlib.util.spec_from_file_location("package_windows_installer", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def synthetic_pe(machine: int, subsystem: int = 2, pe32_plus: bool = True) -> bytes:
    mz = bytearray(0x80)
    mz[:2] = b"MZ"
    struct.pack_into("<I", mz, 0x3C, 0x80)
    coff = struct.pack("<HHIIIHH", machine, 1, 0, 0, 0, 0xF0 if pe32_plus else 0xE0, 0x0022)
    opt = bytearray(0xF0 if pe32_plus else 0xE0)
    struct.pack_into("<H", opt, 0, 0x20B if pe32_plus else 0x10B)
    struct.pack_into("<H", opt, 68, subsystem)
    return bytes(mz) + b"PE\x00\x00" + coff + bytes(opt) + b"\x00" * 64


class WindowsInstallerPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.work = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def make_portable_zip(self, dist_dir: Path, version: str, arch: str, exe_bytes: bytes):
        dist_dir.mkdir(parents=True, exist_ok=True)
        zip_path = dist_dir / f"QuietDesk-{version}-Windows-{arch}.zip"
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("QuietDesk.exe", exe_bytes)
            archive.writestr("LICENSE", "MIT\n")
            archive.writestr("THIRD-PARTY-OPUS.txt", "Opus\n")
        return zip_path

    def make_fake_iscc(self, stub_machine: int = 0x014C) -> Path:
        script = self.work / "fake-iscc.py"
        stub_hex = synthetic_pe(stub_machine, subsystem=2, pe32_plus=False).hex()
        script.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib, sys\n"
            "defines = {}\n"
            "for arg in sys.argv[1:]:\n"
            "    if arg.startswith('/D') and '=' in arg:\n"
            "        k, v = arg[2:].split('=', 1)\n"
            "        defines[k] = v\n"
            "assert pathlib.Path(defines['BinaryPath']).is_file()\n"
            "out = pathlib.Path(defines['OutputDir']) / f\"QuietDesk-{defines['MyAppVersion']}-Windows-{defines['TargetArch']}-Setup.exe\"\n"
            f"out.write_bytes(bytes.fromhex('{stub_hex}'))\n",
            encoding="utf-8",
        )
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        return script

    def test_inno_script_has_utf8_bom_and_both_architectures(self):
        iss = ROOT / "windows" / "installer" / "QuietDesk.iss"
        raw = iss.read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))
        text = raw.decode("utf-8-sig")
        self.assertIn('TargetArch == "arm64"', text)
        self.assertIn("ArchitecturesInstallIn64BitMode=arm64", text)
        self.assertIn("ArchitecturesInstallIn64BitMode=x64compatible", text)
        self.assertIn("PrivilegesRequired=lowest", text)
        self.assertIn('Name: "desktopicon"', text)
        self.assertIn('Name: "autostart"', text)
        self.assertIn("skipifsilent", text)

    def test_packages_x64_and_arm64_installers_and_checksums(self):
        dist = self.work / "dist"
        self.make_portable_zip(dist, "0.8.0", "x64", synthetic_pe(0x8664))
        self.make_portable_zip(dist, "0.8.0", "arm64", synthetic_pe(0xAA64))
        fake_iscc = self.make_fake_iscc()

        def write_windows_text(path, data, *, encoding):
            with path.open("w", encoding=encoding, newline="\r\n") as stream:
                return stream.write(data)

        with patch.object(Path, "write_text", write_windows_text):
            installers, checksum_file = module.build_installers(
                root=ROOT,
                dist_dir=dist,
                version="0.8.0",
                build=31,
                arches=("x64", "arm64"),
                iscc_path=fake_iscc,
            )
        self.assertEqual(
            [p.name for p in installers],
            ["QuietDesk-0.8.0-Windows-x64-Setup.exe", "QuietDesk-0.8.0-Windows-arm64-Setup.exe"],
        )
        checksum_bytes = checksum_file.read_bytes()
        self.assertNotIn(b"\r", checksum_bytes)
        self.assertTrue(checksum_bytes.endswith(b"\n"))
        lines = checksum_bytes.decode("utf-8").splitlines()
        self.assertEqual(len(lines), 4)
        recorded = {}
        for line in lines:
            digest, name = line.split("  ")
            recorded[name] = digest
            self.assertEqual(digest, hashlib.sha256((dist / name).read_bytes()).hexdigest())
        self.assertEqual(
            set(recorded),
            {
                "QuietDesk-0.8.0-Windows-arm64-Setup.exe",
                "QuietDesk-0.8.0-Windows-arm64.zip",
                "QuietDesk-0.8.0-Windows-x64-Setup.exe",
                "QuietDesk-0.8.0-Windows-x64.zip",
            },
        )

    def test_rejects_mismatched_pe_architecture_or_console_subsystem(self):
        dist = self.work / "bad"
        self.make_portable_zip(dist, "0.8.0", "arm64", synthetic_pe(0x8664))
        fake_iscc = self.make_fake_iscc()
        with self.assertRaisesRegex(ValueError, "0xaa64"):
            module.build_installers(
                root=ROOT,
                dist_dir=dist,
                version="0.8.0",
                build=31,
                arches=("arm64",),
                iscc_path=fake_iscc,
            )
        console_exe = self.work / "console.exe"
        console_exe.write_bytes(synthetic_pe(0x8664, subsystem=3))
        with self.assertRaisesRegex(ValueError, "GUI subsystem"):
            module.validate_app_executable(console_exe, "x64")


if __name__ == "__main__":
    unittest.main()
