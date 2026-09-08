#!/usr/bin/env python3
"""Validate the separate wallet-free Locus feed without signing or publishing."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

FEED_URL = "https://github.com/nahid-sparktales/locus/releases/latest/download/appcast-locus.xml"
RELEASE_ROOT = "https://github.com/nahid-sparktales/locus/releases/download"
PUBLIC_KEY = "S/F9z1jR20s26+oHOxVjFend/ajDH04OY8Ietw+IDl4="
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
LAST_MANUAL_BUILD = 26
AUTOMATIC_KEYS = (
    "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableAutomaticChecks",
    "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_configuration(info: dict) -> None:
    require(
        info.get("LocusEdition") == "locus"
        and info.get("CFBundleIdentifier") == "io.sparktales.locus"
        and info.get("CFBundleName") == "Locus"
        and info.get("CFBundleExecutable") == "Locus"
        and info.get("LocusUpdateMode") == "automatic",
        "automatic updates require wallet-free Locus with its original identity",
    )
    require(info.get("SUFeedURL") == FEED_URL, "Locus must use its separate appcast-locus.xml feed")
    require(info.get("SUPublicEDKey") == PUBLIC_KEY, "unexpected Locus update public key")
    for key in AUTOMATIC_KEYS:
        require(info.get(key) is True, f"automatic Locus requires {key}=true")
    require(info.get("SUEnableSystemProfiling") is False, "system profiling must remain disabled")
    require(info.get("SUScheduledCheckInterval") == 86400, "Locus must check daily")
    require(info.get("SUScheduledImpatientCheckInterval") == 604800, "Locus must retain its weekly reminder")
    require(
        not any(key.startswith(("LocusWallet", "LocusCanary", "LocusReown", "LocusPhantom")) for key in info),
        "wallet configuration cannot enter the Locus feed",
    )


def release_identity(version: str, build: str) -> None:
    require(bool(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)), "invalid Locus release version")
    require(bool(re.fullmatch(r"[0-9]+", build)), "invalid Locus release build")
    require(int(build) > LAST_MANUAL_BUILD, "automatic Locus releases must exceed build 26")


def plan(info: dict) -> dict:
    validate_configuration(info)
    version, build = str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))
    release_identity(version, build)
    return {
        "channel": "locus", "feedURL": FEED_URL,
        "archiveURL": f"{RELEASE_ROOT}/v{version}/Locus-macOS.zip",
        "version": version, "build": build, "candidate": False,
    }


def verify_feed(path: Path, *, expected: dict | None = None, newer_build: int | None = None) -> None:
    data = path.read_bytes()
    require(0 < len(data) <= 8 * 1024 * 1024, "invalid Locus appcast size")
    require(b"<!DOCTYPE" not in data.upper() and b"<!ENTITY" not in data.upper(), "appcast declarations are unavailable")
    root = ET.fromstring(data)
    require(root.tag == "rss" and len(root.findall("channel")) == 1, "invalid Locus appcast root")
    items = root.findall("channel/item")
    require(0 < len(items) <= 128, "empty or oversized Locus appcast history")
    require(list(root.iter("item")) == items, "appcast contains an item outside its channel")
    require(not list(root.iter(f"{{{SPARKLE}}}channel")), "Locus feed cannot contain wallet or prerelease channels")
    builds: set[int] = set()
    enclosures = []
    for item in items:
        versions = item.findall(f"{{{SPARKLE}}}shortVersionString")
        numbers = item.findall(f"{{{SPARKLE}}}version")
        require(len(versions) == len(numbers) == 1, "ambiguous Locus release identity")
        version, build = versions[0].text or "", numbers[0].text or ""
        release_identity(version, build)
        require(int(build) not in builds, "duplicate Locus release build")
        builds.add(int(build))
        entries = item.findall("enclosure")
        require(len(entries) == 1, "ambiguous Locus archive")
        enclosure = entries[0]
        require(
            enclosure.get("url") == f"{RELEASE_ROOT}/v{version}/Locus-macOS.zip",
            "Locus archive must use its version-pinned release URL",
        )
        length = enclosure.get("length", "")
        require(bool(re.fullmatch(r"[0-9]+", length)) and int(length) > 0, "invalid archive length")
        try:
            signature = base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)
        except (ValueError, binascii.Error) as exc:
            raise ValueError("invalid archive signature") from exc
        require(len(signature) == 64, "missing or invalid archive signature")
        enclosures.append(enclosure)
    require(list(root.iter("enclosure")) == enclosures, "appcast contains an unvalidated archive or delta")
    if newer_build is not None:
        require(newer_build > max(builds), "new Locus build must exceed every published build")
    if expected is not None:
        newest = items[0]
        require(
            newest.findtext(f"{{{SPARKLE}}}version") == expected["build"]
            and newest.findtext(f"{{{SPARKLE}}}shortVersionString") == expected["version"]
            and enclosures[0].get("url") == expected["archiveURL"]
            and int(expected["build"]) == max(builds),
            "generated Locus feed does not lead with the packaged release",
        )


def history_action(http_status: str, initial_channel: str) -> str:
    if http_status == "200":
        return "verify"
    require(http_status == "404" and initial_channel == "locus",
            "Locus history unavailable; initialization requires LOCUS_APPCAST_INITIAL_CHANNEL=locus and HTTP 404")
    return "initialize"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("configuration", "plan"):
        command = commands.add_parser(name)
        command.add_argument("info", type=Path)
    command = commands.add_parser("verify-feed")
    command.add_argument("path", type=Path)
    command.add_argument("--info", type=Path)
    command.add_argument("--newer-build", type=int)
    command = commands.add_parser("history-action")
    command.add_argument("http_status")
    command.add_argument("initial_channel")
    args = parser.parse_args()
    try:
        if args.operation == "history-action":
            print(history_action(args.http_status, args.initial_channel))
        elif args.operation == "verify-feed":
            expected = plan(plistlib.loads(args.info.read_bytes())) if args.info else None
            verify_feed(args.path, expected=expected, newer_build=args.newer_build)
        else:
            info = plistlib.loads(args.info.read_bytes())
            if args.operation == "plan":
                print(json.dumps(plan(info)))
            else:
                validate_configuration(info)
    except (OSError, ValueError, ET.ParseError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
