#!/usr/bin/env python3
"""Exercise update publishing with disposable keys and synthetic metadata only."""

import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile


def check(tool, work):
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="quietdesk-update-key-") as keys_directory, tempfile.TemporaryDirectory(prefix="fixtures-", dir=work) as fixture_directory:
        keys = Path(keys_directory)
        fixture = Path(fixture_directory)
        known_secrets = []

        def run(*arguments, secret=None, succeeds=True):
            environment = dict(os.environ)
            environment.pop("QUIETDESK_UPDATE_SIGNING_KEY", None)
            if secret is not None:
                environment["QUIETDESK_UPDATE_SIGNING_KEY"] = secret
            result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, env=environment)
            output = result.stdout + result.stderr
            if any(value in output for value in known_secrets):
                raise AssertionError("Tool exposed a signing key")
            if (result.returncode == 0) != succeeds:
                raise AssertionError(f"Unexpected exit status for {arguments[0]}: {output}")
            return result.stdout

        public_keys = []
        for name in ("signing", "wrong"):
            path = keys / name
            output = run("generate-key", "--out", path)
            public_keys.append(json.loads(output))
            if stat.S_IMODE(path.stat().st_mode) != 0o600:
                raise AssertionError("Generated private key permissions are not 0600")
            known_secrets.append(path.read_text().strip())
            if known_secrets[-1] in output or set(public_keys[-1]) != {"id", "key"}:
                raise AssertionError("Key generation output was not limited to the public key and ID")
        root = Path(__file__).resolve().parents[1]
        rejected_path = root / "work" / "rejected-update-key"
        run("generate-key", "--out", rejected_path, succeeds=False)
        if rejected_path.exists():
            raise AssertionError("Generated a private key inside the repository")
        config = fixture / "feed.json"
        config.write_text(json.dumps({"publicKeys": []}))
        run("check-key", "--config", config)
        config.write_text(json.dumps({"publicKeys": [public_keys[0]]}))
        run("check-key", "--config", config, succeeds=False)
        run("check-key", "--config", config, secret=known_secrets[1], succeeds=False)
        run("check-key", "--config", config, secret=known_secrets[0])
        app = fixture / "QuietDesk.app"
        (app / "Contents").mkdir(parents=True)
        metadata = {"CFBundleIdentifier": "local.quietdesk.checks.updater", "CFBundleShortVersionString": "0.8.0",
                    "CFBundleVersion": "31", "LSMinimumSystemVersion": "14.0", "QuietDeskBuildRevision": "",
                    "QuietDeskUpdateFeedURL": "http://127.0.0.1:1/QuietDesk-update.json", "QuietDeskUpdatePublicKeys": [public_keys[0]]}
        plist = app / "Contents/Info.plist"
        plist.write_bytes(plistlib.dumps(metadata))
        archive = fixture / "QuietDesk-0.8.0-macOS-universal.zip"
        archive.write_bytes(b"Synthetic archive bytes for release-signing checks\n")
        notes = fixture / "notes.txt"
        notes.write_text("说" * 4_100)
        manifest = fixture / "QuietDesk-update.json"
        run("sign", "--app", app, "--archive", archive, "--tag", "v0.8.0", "--repository", "nXiaoK/QuietDesk",
            "--notes-file", notes, "--out", manifest, secret=known_secrets[0])
        verify_arguments = ("verify", "--app", app, "--archive", archive, "--manifest", manifest)
        run(*verify_arguments)
        original = manifest.read_bytes()
        envelope = json.loads(original)
        payload = json.loads(base64.b64decode(envelope["payload"]))
        if len(payload["notes"]) != 4_000:
            raise AssertionError("Release notes were not limited to 4000 characters")
        payload["build"] += 1
        envelope["payload"] = base64.b64encode(json.dumps(payload).encode()).decode()
        manifest.write_text(json.dumps(envelope))
        run(*verify_arguments, succeeds=False)
        manifest.write_bytes(original)
        archive.write_bytes(archive.read_bytes() + b"tampered")
        run(*verify_arguments, succeeds=False)
        archive.write_bytes(b"Synthetic archive bytes for release-signing checks\n")
        metadata["CFBundleVersion"] = "32"
        plist.write_bytes(plistlib.dumps(metadata))
        run(*verify_arguments, succeeds=False)
    print("Update publishing checks passed (temporary keys, synthetic metadata).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    arguments = parser.parse_args()
    check(arguments.tool.resolve(), arguments.work.resolve())


if __name__ == "__main__":
    main()
