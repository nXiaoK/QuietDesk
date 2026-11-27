#!/usr/bin/env python3
"""Package Windows Setup.exe installers (x64 and/or arm64) using Inno Setup 6."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile

from version import ROOT, build_number, current, parse_version

IMAGE_FILE_MACHINE_I386 = 0x014C
IMAGE_FILE_MACHINE_AMD64 = 0x8664
IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMAGE_SUBSYSTEM_WINDOWS_GUI = 2
MAX_INSTALLER_BYTES = 64 * 1024 * 1024

EXPECTED_EXE_MACHINE = {
    "x64": IMAGE_FILE_MACHINE_AMD64,
    "arm64": IMAGE_FILE_MACHINE_ARM64,
}


def inspect_pe(path: Path):
    """Return (machine, subsystem, pe32_plus) for a Windows PE image, or raise ValueError."""
    data = Path(path).read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise ValueError(f"{path}: missing MZ header")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_offset < 0x40 or pe_offset + 24 + 70 > len(data):
        raise ValueError(f"{path}: invalid PE header offset")
    if data[pe_offset:pe_offset + 4] != b"PE\x00\x00":
        raise ValueError(f"{path}: missing PE signature")
    machine, _, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", data, pe_offset + 4)
    optional_offset = pe_offset + 24
    if optional_size < 70 or optional_offset + optional_size > len(data):
        raise ValueError(f"{path}: truncated PE optional header")
    magic = struct.unpack_from("<H", data, optional_offset)[0]
    if magic not in (0x10B, 0x20B):
        raise ValueError(f"{path}: unexpected PE optional magic 0x{magic:04x}")
    subsystem = struct.unpack_from("<H", data, optional_offset + 68)[0]
    return machine, subsystem, magic == 0x20B


def validate_app_executable(path: Path, arch: str):
    machine, subsystem, pe32_plus = inspect_pe(path)
    expected = EXPECTED_EXE_MACHINE[arch]
    if not pe32_plus or machine != expected:
        raise ValueError(f"{path}: expected PE32+ machine 0x{expected:04x} for {arch}, got 0x{machine:04x}")
    if subsystem != IMAGE_SUBSYSTEM_WINDOWS_GUI:
        raise ValueError(f"{path}: expected Windows GUI subsystem (2), got {subsystem}")


def validate_installer_executable(path: Path):
    size = path.stat().st_size
    if size <= 0 or size > MAX_INSTALLER_BYTES:
        raise ValueError(f"{path}: invalid installer size {size}")
    machine, subsystem, _ = inspect_pe(path)
    if machine not in (IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_ARM64):
        raise ValueError(f"{path}: unexpected installer PE machine 0x{machine:04x}")
    if subsystem != IMAGE_SUBSYSTEM_WINDOWS_GUI:
        raise ValueError(f"{path}: expected Windows GUI subsystem (2), got {subsystem}")


def find_iscc(explicit=None):
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    env_iscc = os.environ.get("ISCC_PATH")
    if env_iscc:
        candidates.append(Path(env_iscc))
    for name in ("ISCC", "iscc", "ISCC.exe"):
        found = shutil.which(name)
        if found:
            candidates.append(Path(found))
    for win_root in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles"), r"C:\Program Files (x86)", r"C:\Program Files"):
        if win_root:
            candidates.append(Path(win_root) / "Inno Setup 6" / "ISCC.exe")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("Inno Setup 6 compiler (ISCC.exe) not found; set --iscc or ISCC_PATH")


def write_checksums(output_dir: Path, version: str):
    names = sorted(
        p.name
        for p in output_dir.iterdir()
        if p.is_file()
        and p.name.startswith(f"QuietDesk-{version}-Windows-")
        and (p.name.endswith(".zip") or p.name.endswith("-Setup.exe"))
    )
    if not names:
        raise ValueError(f"No Windows packages found in {output_dir} for version {version}")
    lines = [
        hashlib.sha256((output_dir / name).read_bytes()).hexdigest() + "  " + name + "\n"
        for name in names
    ]
    checksum_path = output_dir / f"SHA256SUMS-{version}-Windows.txt"
    # Keep LF line endings on Windows for shasum verification on macOS.
    checksum_path.write_bytes("".join(lines).encode("utf-8"))
    return checksum_path


def build_installers(
    *,
    root: Path = ROOT,
    dist_dir: Path,
    version: str,
    build: int,
    arches=("x64", "arm64"),
    iscc_path=None,
):
    parse_version(version)
    build = build_number(build)
    iss_path = root / "windows" / "installer" / "QuietDesk.iss"
    if not iss_path.read_bytes().startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"{iss_path} must start with UTF-8 BOM for Inno Setup Unicode parsing")
    compiler = find_iscc(iscc_path)
    dist_dir.mkdir(parents=True, exist_ok=True)
    created = []
    with tempfile.TemporaryDirectory(prefix="quietdesk-inno-") as temp_root:
        staging_root = Path(temp_root)
        for arch in arches:
            if arch not in EXPECTED_EXE_MACHINE:
                raise ValueError(f"Unsupported Windows architecture: {arch}")
            zip_path = dist_dir / f"QuietDesk-{version}-Windows-{arch}.zip"
            if not zip_path.is_file():
                raise FileNotFoundError(f"Missing portable archive required to build installer: {zip_path}")
            arch_dir = staging_root / arch
            arch_dir.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zip_path, "r") as archive:
                if archive.testzip() is not None:
                    raise ValueError(f"Corrupt ZIP archive: {zip_path}")
                if "QuietDesk.exe" not in archive.namelist():
                    raise ValueError(f"QuietDesk.exe missing from {zip_path}")
                exe_bytes = archive.read("QuietDesk.exe")
                (arch_dir / "LICENSE").write_bytes(archive.read("LICENSE"))
            exe_path = arch_dir / "QuietDesk.exe"
            exe_path.write_bytes(exe_bytes)
            validate_app_executable(exe_path, arch)
            out_stage = staging_root / f"out-{arch}"
            out_stage.mkdir(parents=True, exist_ok=True)
            cmd = [
                str(compiler),
                "/Q",
                f"/DMyAppVersion={version}",
                f"/DMyAppBuild={build}",
                f"/DTargetArch={arch}",
                f"/DBinaryPath={exe_path}",
                f"/DOutputDir={out_stage}",
                f"/DRepoRoot={root}",
                str(iss_path),
            ]
            subprocess.run(cmd, check=True)
            installer_name = f"QuietDesk-{version}-Windows-{arch}-Setup.exe"
            built_installer = out_stage / installer_name
            if not built_installer.is_file():
                raise FileNotFoundError(f"ISCC did not produce expected output: {built_installer}")
            validate_installer_executable(built_installer)
            destination = dist_dir / installer_name
            shutil.move(str(built_installer), str(destination))
            created.append(destination)
    checksum_file = write_checksums(dist_dir, version)
    return created, checksum_file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist-dir", type=Path, default=Path(os.environ.get("QUIETDESK_WINDOWS_DIST_DIR", ROOT / "outputs" / "windows")))
    parser.add_argument("--version", default=None)
    parser.add_argument("--build", default=None)
    parser.add_argument("--arch", choices=["all", "x64", "arm64"], default="all")
    parser.add_argument("--iscc", type=Path, default=None)
    args = parser.parse_args()

    resolved = current(ROOT)
    version = args.version or resolved["version"]
    build = int(args.build) if args.build is not None else resolved["build"]
    arches = ("x64", "arm64") if args.arch == "all" else (args.arch,)
    try:
        installers, checksum_file = build_installers(
            root=ROOT,
            dist_dir=args.dist_dir.resolve(),
            version=version,
            build=build,
            arches=arches,
            iscc_path=args.iscc,
        )
        for path in [*installers, checksum_file]:
            print(path)
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Windows installer packaging failed: {error}\n")


if __name__ == "__main__":
    main()
