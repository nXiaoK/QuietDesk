#!/usr/bin/env python3
"""Package the built application as a drag-and-drop DMG, ZIP and source ZIP."""

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

from version import ROOT, build_number, parse_version


def main():
    output = ROOT / "dist"
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
        subprocess.run(["hdiutil", "create", "-volname", "QuietDesk", "-srcfolder", str(volume), "-format", "UDZO", "-ov", str(staging / names[0])], check=True)
        subprocess.run(["hdiutil", "verify", str(staging / names[0])], check=True)
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(staging / names[1])], check=True)
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
