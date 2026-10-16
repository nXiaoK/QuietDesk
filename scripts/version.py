#!/usr/bin/env python3
"""Resolve local build metadata and allocate serial GitHub release versions."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def parse_version(value):
    if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
        raise ValueError("Version must contain three non-negative integers, e.g. 0.5.0")
    return tuple(map(int, value.split(".")))


def build_number(value):
    if not re.fullmatch(r"[1-9][0-9]*", str(value)):
        raise ValueError("Build number must be a positive integer")
    return int(value)


def configuration(root):
    value = json.loads((root / "version.json").read_text())
    parse_version(value["version"])
    value["build"] = build_number(value["build"])
    return value


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True, stderr=subprocess.DEVNULL).strip()


def version_tags(root, points_at=None):
    arguments = ["tag", "--list", "v*"]
    if points_at:
        arguments += ["--points-at", points_at]
    try:
        names = git(root, *arguments).splitlines()
    except subprocess.CalledProcessError:
        return []
    return [name for name in names if VERSION_PATTERN.fullmatch(name[1:])]


def annotation(root, tag):
    content = git(root, "for-each-ref", "--format=%(objecttype)%00%(contents)", "refs/tags/" + tag)
    kind, _, message = content.partition("\0")
    return message if kind == "tag" else ""


def current(root=ROOT, environment=None):
    environment = os.environ if environment is None else environment
    result = configuration(root)
    exact = version_tags(root, "HEAD")
    if exact:
        tag = max(exact, key=lambda item: parse_version(item[1:]))
        if parse_version(tag[1:]) >= parse_version(result["version"]):
            result["version"] = tag[1:]
            match = re.search(r"^Build-Number: ([1-9][0-9]*)$", annotation(root, tag), re.MULTILINE)
            if match:
                result["build"] = build_number(match[1])
    result["version"] = environment.get("QUIETDESK_VERSION", result["version"])
    result["build"] = build_number(environment.get("QUIETDESK_BUILD_NUMBER", result["build"]))
    parse_version(result["version"])
    return result


def next_version(base, tags, increment="auto"):
    if increment not in {"auto", "patch", "minor", "major"}:
        raise ValueError("Unsupported version increment")
    floor = parse_version(base)
    previous = max((parse_version(tag[1:]) for tag in tags), default=None)
    if increment == "auto" and (previous is None or previous < floor):
        return base
    major, minor, patch = max(floor, previous or floor)
    if increment == "major":
        major, minor, patch = major + 1, 0, 0
    elif increment == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f"{major}.{minor}.{patch}"


def plan_release(root, increment, run_id, run_number):
    if not re.fullmatch(r"[0-9]+", run_id):
        raise ValueError("Missing or invalid GitHub run ID")
    config = configuration(root)
    git(root, "rev-parse", "HEAD")
    tags = version_tags(root)
    for tag in sorted(version_tags(root, "HEAD"), key=lambda item: parse_version(item[1:]), reverse=True):
        message = annotation(root, tag)
        if f"Workflow-Run: {run_id}" in message.splitlines():
            match = re.search(r"^Build-Number: ([1-9][0-9]*)$", message, re.MULTILINE)
            if not match:
                raise ValueError("Existing release tag has no build number")
            return {"version": tag[1:], "build": build_number(match[1]), "tag": tag, "reused": True,
                    "latest": parse_version(tag[1:]) >= max(parse_version(item[1:]) for item in tags)}
    version = next_version(config["version"], tags, increment)
    return {"version": version, "build": config["build"] + build_number(run_number),
            "tag": "v" + version, "reused": False, "latest": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("current")
    release = commands.add_parser("next")
    release.add_argument("--increment", choices=["auto", "patch", "minor", "major"], default="auto")
    release.add_argument("--github-output", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "current":
            value = current()
            print(value["version"])
            print(value["build"])
        else:
            value = plan_release(ROOT, args.increment, os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("GITHUB_RUN_NUMBER", ""))
            if args.github_output:
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    for key, item in value.items():
                        output.write(f"{key}={str(item).lower() if isinstance(item, bool) else item}\n")
            print(json.dumps(value))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Version configuration failed: {error}\n")


if __name__ == "__main__":
    main()
