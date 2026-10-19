#!/usr/bin/env python3
"""Package the standalone Linux relay and public deployment files."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

from version import ROOT, current, parse_version


def package(output, version):
    parse_version(version)
    revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=normal"], text=True))
    toolchain = subprocess.check_output(["go", "version"], text=True).strip()
    names = []
    (ROOT / "work").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="relay-package-", dir=ROOT / "work") as temporary:
        staging = Path(temporary)
        for architecture in ("amd64", "arm64"):
            name = f"QuietDesk-Relay-{version}-linux-{architecture}"
            folder = staging / name
            folder.mkdir()
            binary = folder / "quietdesk-relay"
            binary.write_bytes((output / f"quietdesk-relay-linux-{architecture}").read_bytes())
            binary.chmod(0o755)
            for source in (ROOT / "relay/README.md", ROOT / "relay/quietdesk-relay.service", ROOT / "LICENSE"):
                (folder / source.name).write_bytes(source.read_bytes())
            manifest = {
                "version": version, "protocol": 1, "os": "linux", "architecture": architecture,
                "revision": revision, "workingTreeDirty": dirty, "toolchain": toolchain,
                "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            }
            (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            archive = output / f"{name}.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(folder, arcname=name)
            with tarfile.open(archive) as bundle:
                expected = {name, *(f"{name}/{item}" for item in ("quietdesk-relay", "README.md", "quietdesk-relay.service", "LICENSE", "manifest.json"))}
                if set(bundle.getnames()) != expected:
                    raise ValueError("Unexpected relay package contents")
                for member in bundle.getmembers():
                    if not (member.isdir() or member.isfile()):
                        raise ValueError("Unexpected relay package link")
            names.append(archive.name)
    (output / "SHA256SUMS.txt").write_text("".join(hashlib.sha256((output / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))
    for name in [*names, "SHA256SUMS.txt"]:
        print(output / name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    package(arguments.output.resolve(), os.environ.get("QUIETDESK_VERSION", current()["version"]))
