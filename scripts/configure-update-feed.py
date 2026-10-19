#!/usr/bin/env python3
"""Validate build-time update configuration and insert it into Info.plist."""

import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
from urllib.parse import urlsplit

PRODUCTION_BUNDLE_ID = "local.quietdesk.app"


def configuration(config, bundle_identifier, environment):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_identifier):
        raise ValueError("Invalid bundle identifier")
    value = json.loads(Path(config).read_text())
    overrides = {name for name in ("QUIETDESK_UPDATE_FEED_URL", "QUIETDESK_UPDATE_PUBLIC_KEYS") if name in environment}
    if bundle_identifier == PRODUCTION_BUNDLE_ID:
        if overrides:
            raise ValueError("Update feed overrides require a non-production bundle identifier")
    else:
        value = {"feedURL": "", "publicKeys": []}
    if "QUIETDESK_UPDATE_FEED_URL" in overrides:
        value["feedURL"] = environment["QUIETDESK_UPDATE_FEED_URL"]
    if "QUIETDESK_UPDATE_PUBLIC_KEYS" in overrides:
        raw_keys = environment["QUIETDESK_UPDATE_PUBLIC_KEYS"]
        value["publicKeys"] = json.loads(raw_keys) if raw_keys else []
    feed, keys = value.get("feedURL"), value.get("publicKeys")
    if not isinstance(feed, str) or not isinstance(keys, list):
        raise ValueError("Update feed URL and public key table have invalid types")
    identifiers = set()
    for item in keys:
        if not isinstance(item, dict) or set(item) != {"id", "key"}:
            raise ValueError("Each update public key requires id and key")
        if not isinstance(item["id"], str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", item["id"]) or item["id"] in identifiers:
            raise ValueError("Invalid or duplicate update key ID")
        try:
            decoded = base64.b64decode(item["key"], validate=True)
        except (ValueError, TypeError):
            raise ValueError("Invalid update public key") from None
        if len(decoded) != 32:
            raise ValueError("Update public keys must contain 32 bytes")
        identifiers.add(item["id"])
    if feed:
        url = urlsplit(feed)
        loopback = bundle_identifier != PRODUCTION_BUNDLE_ID and url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost"}
        github = url.scheme == "https" and url.hostname == "github.com" and url.port is None and re.fullmatch(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/latest/download/QuietDesk-update\.json", url.path)
        if url.username is not None or url.password is not None or url.query or url.fragment or not (github or loopback):
            raise ValueError("Update feed must use a GitHub release or an independent preview loopback source")
    if keys and not feed:
        raise ValueError("An enabled update key table requires a feed URL")
    return {"feedURL": feed, "publicKeys": keys}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="Resources/update-feed.json")
    parser.add_argument("--plist", required=True)
    args = parser.parse_args()
    try:
        path = Path(args.plist)
        metadata = plistlib.loads(path.read_bytes())
        bundle_identifier = os.environ.get("QUIETDESK_BUNDLE_IDENTIFIER", metadata["CFBundleIdentifier"])
        value = configuration(args.config, bundle_identifier, os.environ)
        subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", bundle_identifier, str(path)], check=True)
        for key, kind, item in (("QuietDeskUpdateFeedURL", "-string", value["feedURL"]),
                                ("QuietDeskUpdatePublicKeys", "-json", json.dumps(value["publicKeys"], separators=(",", ":")))):
            if key in metadata:
                subprocess.run(["plutil", "-remove", key, str(path)], check=True)
            subprocess.run(["plutil", "-insert", key, kind, item, str(path)], check=True)
        subprocess.run(["plutil", "-lint", str(path)], check=True)
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Update configuration failed: {error}\n")


if __name__ == "__main__":
    main()
