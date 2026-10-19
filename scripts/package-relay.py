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


def package_docker(root, output, version, revision, dirty, include_source=True):
    name = f"QuietDesk-Relay-{version}-Docker" + ("" if include_source else "-Deploy")
    public = {"compose.image.yaml", "deploy.sh", "README.md"}
    if include_source:
        public |= {"Dockerfile", ".dockerignore", "compose.yaml", "docker/provision.sh", "go.mod"}
    tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--", "relay"], text=True).split("\0")
    sources = {}
    for item in filter(None, tracked):
        relative = Path(item).relative_to("relay").as_posix()
        if relative in public or (include_source and relative.endswith(".go")):
            source = root / item
            if source.is_symlink() or not source.is_file():
                raise ValueError("Docker source must be a regular file: " + item)
            sources[relative] = source
    required = public | ({"cmd/quietdesk-relay/main.go", "server.go", "privatefile.go", "protocol.go"} if include_source else set())
    if not required.issubset(sources):
        raise ValueError("Docker deployment files must be tracked before packaging")
    sources["LICENSE"] = root / "LICENSE"
    archive = output / f"{name}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="relay-docker-package-", dir=root / "work") as temporary:
        folder = Path(temporary) / name
        folder.mkdir()
        for relative, source in sources.items():
            target = folder / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            target.chmod(0o755 if relative.endswith(".sh") else 0o644)
        manifest = {
            "version": version, "protocol": 1, "revision": revision, "workingTreeDirty": dirty,
            "platforms": ["linux/amd64", "linux/arm64"],
            "sha256": {relative: hashlib.sha256(source.read_bytes()).hexdigest() for relative, source in sorted(sources.items())},
        }
        (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(folder, arcname=name)
        with tarfile.open(archive) as bundle:
            expected_files = {f"{name}/{relative}" for relative in [*sources, "manifest.json"]}
            if {member.name for member in bundle.getmembers() if member.isfile()} != expected_files:
                raise ValueError("Unexpected Docker package contents")
            if any(not (member.isdir() or member.isfile()) for member in bundle.getmembers()):
                raise ValueError("Unexpected Docker package link")
    return archive.name


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
    names.append(package_docker(ROOT, output, version, revision, dirty))
    names.append(package_docker(ROOT, output, version, revision, dirty, include_source=False))
    (output / "SHA256SUMS.txt").write_text("".join(hashlib.sha256((output / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))
    for name in [*names, "SHA256SUMS.txt"]:
        print(output / name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    package(arguments.output.resolve(), os.environ.get("QUIETDESK_VERSION", current()["version"]))
