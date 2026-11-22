#!/usr/bin/env python3
"""Fails when a registry package in a Cargo.lock was published less than a minimum number of days ago.

New releases have not been vetted yet, and a compromised release is usually yanked within days, so the
Windows client only locks versions that have been public for a week. Pin an older version with
`cargo update -p <name> --precise <version>` when this reports a package.
"""
import argparse
import datetime
import json
import re
import sys
import urllib.request


def published(name: str, version: str) -> datetime.datetime:
    request = urllib.request.Request(
        f"https://crates.io/api/v1/crates/{name}/{version}",
        headers={"User-Agent": "quietdesk-lock-age-check (https://github.com/nXiaoK/QuietDesk)"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        created = json.load(response)["version"]["created_at"]
    return datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("lock", nargs="?", default="windows/Cargo.lock")
    parser.add_argument("--days", type=int, default=7)
    arguments = parser.parse_args()
    text = open(arguments.lock, encoding="utf-8").read()
    packages = re.findall(r'\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"\nsource = "registry', text)
    now = datetime.datetime.now(datetime.timezone.utc)
    young = [(name, version, (now - published(name, version)).days) for name, version in packages]
    young = [entry for entry in young if entry[2] < arguments.days]
    print(f"{len(packages)} registry packages in {arguments.lock}")
    for name, version, days in young:
        print(f"TOO NEW {name} {version}: published {days} days ago")
    return 1 if young else 0


if __name__ == "__main__":
    sys.exit(main())
