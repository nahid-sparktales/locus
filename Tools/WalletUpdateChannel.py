#!/usr/bin/env python3
"""Validate sealed update routing and channel-specific appcast contents.

Read-only: this never rewrites a signed app/feed, accesses a signing key, or
publishes an artifact. Candidate URLs are public release configuration.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

STABLE_FEED = (
    "https://github.com/nahid-sparktales/locus/releases/latest/download/appcast.xml"
)
RELEASE_ROOT = "https://github.com/nahid-sparktales/locus/releases/download"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def https_url(value: object) -> str:
    require(
        isinstance(value, str) and 0 < len(value) <= 2048,
        "missing or oversized sealed update URL",
    )
    require(
        value.isascii() and not re.search(r"[\s\\\x00-\x1f\x7f]", value),
        "noncanonical sealed update URL",
    )
    parsed = urlsplit(value)
    require(
        parsed.scheme == "https"
        and bool(parsed.hostname)
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment,
        "sealed update URLs must be HTTPS without credentials, query, or fragment",
    )
    require(
        parsed.port in (None, 443) and parsed.hostname == parsed.hostname.lower(),
        "invalid sealed update authority",
    )
    require(not re.search(r"%(?![0-9A-Fa-f]{2})", value), "invalid update URL encoding")
    return value


def plan(info: dict, channel: str, *, require_candidate: bool = False) -> dict:
    require(
        channel in {"canary", "stable"},
        "explicit canary or stable update channel is required",
    )
    require(info.get("SUFeedURL") == STABLE_FEED, "sealed stable update feed differs")
    version, build = (
        str(info.get("CFBundleShortVersionString", "")),
        str(info.get("CFBundleVersion", "")),
    )
    require(
        bool(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version))
        and bool(re.fullmatch(r"[0-9]+", build)),
        "invalid sealed update version",
    )
    canary = info.get("LocusCanaryUpdateFeedURL", "")
    archive = info.get("LocusWalletCandidateArchiveURL", "")
    candidate = bool(canary or archive or info.get("LocusWalletReviewCeilingBase64"))
    if require_candidate or candidate or channel == "canary":
        canary, archive = https_url(canary), https_url(archive)
        require(
            canary != STABLE_FEED and "/latest/" not in urlsplit(canary).path,
            "canary must have a distinct non-latest feed",
        )
        require(
            urlsplit(canary).path.endswith("/appcast.xml"),
            "canary feed must end in appcast.xml",
        )
        require(
            urlsplit(archive).path.endswith("/Locus-macOS.zip")
            and "/latest/" not in urlsplit(archive).path,
            "candidate archive must have an immutable non-latest release URL",
        )
        require(
            archive not in {canary, STABLE_FEED}, "archive and feed URLs must differ"
        )
    else:
        archive = f"{RELEASE_ROOT}/v{version}/Locus-macOS.zip"
    return {
        "channel": channel,
        "feedURL": canary if channel == "canary" else STABLE_FEED,
        "archiveURL": archive,
        "version": version,
        "build": build,
        "candidate": candidate or require_candidate,
    }


def verify_feed(path: Path, channel: str, *, expected: dict | None = None) -> None:
    require(channel in {"canary", "stable"}, "explicit update channel is required")
    data = path.read_bytes()
    require(0 < len(data) <= 8 * 1024 * 1024, "appcast size is invalid")
    require(
        b"<!DOCTYPE" not in data.upper() and b"<!ENTITY" not in data.upper(),
        "appcast declarations are unavailable",
    )
    root = ET.fromstring(data)
    require(
        root.tag == "rss" and len(root.findall("channel")) == 1, "invalid appcast root"
    )
    items = root.findall("channel/item")
    require(0 < len(items) <= 128, "empty or oversized appcast history")
    seen: set[str] = set()
    for item in items:
        labels = item.findall(f"{{{SPARKLE}}}channel")
        require(
            len(labels) == (1 if channel == "canary" else 0)
            and (not labels or labels[0].text == "canary"),
            "appcast contains another update channel",
        )
        versions = item.findall(f"{{{SPARKLE}}}version")
        require(
            len(versions) == 1
            and bool(re.fullmatch(r"[0-9]+", versions[0].text or "")),
            "invalid appcast build",
        )
        build = versions[0].text
        require(build not in seen, "duplicate appcast build")
        seen.add(build)
        enclosures = item.findall("enclosure")
        require(len(enclosures) == 1, "ambiguous appcast enclosure")
        https_url(enclosures[0].get("url"))
    if expected is not None:
        newest = items[0]
        require(
            newest.findtext(f"{{{SPARKLE}}}version") == expected["build"]
            and newest.findtext(f"{{{SPARKLE}}}shortVersionString")
            == expected["version"]
            and newest.find("enclosure").get("url") == expected["archiveURL"],
            "appcast does not reference the exact sealed candidate",
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["plan", "verify-feed"])
    parser.add_argument("path", type=Path)
    parser.add_argument("channel", choices=["canary", "stable"])
    parser.add_argument("--require-candidate", action="store_true")
    parser.add_argument("--info", type=Path)
    args = parser.parse_args()
    if args.operation == "plan":
        result = plan(
            plistlib.loads(args.path.read_bytes()),
            args.channel,
            require_candidate=args.require_candidate,
        )
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        expected = (
            plan(plistlib.loads(args.info.read_bytes()), args.channel)
            if args.info
            else None
        )
        verify_feed(args.path, args.channel, expected=expected)
        print("Update channel isolation verified.")


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        KeyError,
        OSError,
        ET.ParseError,
        plistlib.InvalidFileException,
    ) as error:
        raise SystemExit(f"error: {error}") from None
