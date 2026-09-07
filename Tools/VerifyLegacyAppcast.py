#!/usr/bin/env python3
"""Read-only gate for retaining an old signed feed beside a manual Locus release.

Old installed apps still request releases/latest/download/appcast.xml. Every
enclosure must remain pinned to an earlier release, never the new latest ZIP.
The existing Sparkle tools verify the original bytes; no feed is generated.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PUBLIC_KEY = "S/F9z1jR20s26+oHOxVjFend/ajDH04OY8Ietw+IDl4="
KEY_ACCOUNT = "io.sparktales"
RELEASE_ROOT = "https://github.com/nahid-sparktales/locus/releases/download"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def version_tuple(value: str) -> tuple[int, ...]:
    require(bool(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value)), "invalid release version")
    return tuple(int(part) for part in value.split("."))


def validate(feed: bytes, info: dict) -> None:
    require(
        info.get("LocusEdition") == "locus"
        and info.get("LocusUpdateMode") == "manual"
        and info.get("CFBundleIdentifier") == "io.sparktales.locus",
        "preserving the legacy feed is limited to wallet-free manual Locus",
    )
    current_version = version_tuple(str(info.get("CFBundleShortVersionString", "")))
    current_build = str(info.get("CFBundleVersion", ""))
    require(current_build.isascii() and current_build.isdecimal(), "invalid release build")
    require(len(feed) <= 5_000_000, "legacy appcast is oversized")
    root = ET.fromstring(feed)
    require(root.tag == "rss", "legacy appcast must be an RSS feed")
    items = root.findall("./channel/item")
    require(bool(items), "legacy appcast has no previous releases")
    validated_enclosures = []
    for item in items:
        version = item.findtext(f"{{{SPARKLE}}}shortVersionString", "")
        build = item.findtext(f"{{{SPARKLE}}}version", "")
        require(version_tuple(version) < current_version, "legacy feed must contain only prior versions")
        require(
            build.isascii() and build.isdecimal() and int(build) < int(current_build),
            "legacy feed must contain only prior builds",
        )
        enclosures = list(item.iter("enclosure"))
        require(bool(enclosures), "legacy release has no enclosure")
        for enclosure in enclosures:
            require(
                enclosure.get("url") == f"{RELEASE_ROOT}/v{version}/Locus-macOS.zip",
                "legacy enclosure must point to its version-pinned prior release archive",
            )
            require(bool(enclosure.get(f"{{{SPARKLE}}}edSignature")), "legacy enclosure lacks signature")
        validated_enclosures.extend(enclosures)
    require(
        list(root.iter("enclosure")) == validated_enclosures,
        "legacy appcast contains an enclosure outside a validated release",
    )


def verify(feed_path: Path, info: dict, tools_path: Path) -> str:
    feed = feed_path.read_bytes()
    validate(feed, info)
    keys = tools_path / "bin/generate_keys"
    signer = tools_path / "bin/sign_update"
    require(
        keys.is_file() and signer.is_file(),
        "pinned Sparkle 2.9.6 tools are missing; set LOCUS_SPARKLE_TOOLS_DIR to the verified tools",
    )
    key = subprocess.run(
        [str(keys), "--account", KEY_ACCOUNT, "-p"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    require(key == PUBLIC_KEY, "Keychain Sparkle key differs from the legacy public key")
    subprocess.run(
        [str(signer), "--account", KEY_ACCOUNT, "--verify", str(feed_path)],
        capture_output=True, text=True, check=True,
    )
    require(feed_path.read_bytes() == feed, "legacy appcast changed during verification")
    return hashlib.sha256(feed).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("info_plist", type=Path)
    args = parser.parse_args()
    tools = Path(os.environ.get(
        "LOCUS_SPARKLE_TOOLS_DIR",
        str(Path(__file__).resolve().parents[1] / ".release-tools/Sparkle-2.9.6"),
    ))
    try:
        info = plistlib.loads(args.info_plist.read_bytes())
        print(verify(args.appcast, info, tools))
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f"error: cannot preserve legacy appcast: {exc}", file=sys.stderr)
        return 1
    print("Legacy appcast signature and prior-release archive URLs verified.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
