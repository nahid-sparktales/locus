#!/usr/bin/env python3
"""Hash manifest for the companion wire files shared with the iOS client.

The iOS companion app vendors these files byte-for-byte so both ends of the
mobile protocol decode the same bytes with the same code. Nothing here can
enforce that from the other side, so this is the guard on *this* side: editing a
shared file without regenerating the manifest fails CI, and regenerating it bumps
`protocol_revision`, which makes the protocol change visible in the diff instead
of silent.

    python3 Tools/ProtocolManifest.py            # verify (CI)
    python3 Tools/ProtocolManifest.py --write    # regenerate after a change
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "ProtocolFixtures" / "protocol-manifest.json"

# Files vendored by the iOS client. Keep this list in sync with the vendor
# manifest in that repository.
SHARED = [
    "Locus/CompanionWireTypes.swift",
    "Locus/JSONValue.swift",
    "ProtocolFixtures/companion-v1.json",
]

# The language mode the shared sources are known to compile under, on both
# platforms. CI typechecks them against the iOS SDK at this version.
SWIFT_VERSION = "5.10"


def digest(path: pathlib.Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def render(document: dict) -> str:
    return json.dumps(document, indent=2) + "\n"


def build(previous: dict) -> dict:
    missing = [name for name in SHARED if not (ROOT / name).exists()]
    if missing:
        sys.stderr.write("error: shared protocol file is missing:\n")
        for name in missing:
            sys.stderr.write(f"         {name}\n")
        raise SystemExit(1)
    return {
        "protocol_revision": previous.get("protocol_revision", 0),
        "protocol_version": 1,
        "swift_version": SWIFT_VERSION,
        "files": {name: digest(ROOT / name) for name in SHARED},
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="regenerate the manifest")
    arguments = parser.parse_args()

    previous = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    current = build(previous)

    if arguments.write:
        if current["files"] != previous.get("files"):
            current["protocol_revision"] = previous.get("protocol_revision", 0) + 1
        MANIFEST.parent.mkdir(parents=True, exist_ok=True)
        MANIFEST.write_text(render(current))
        print(f"protocol manifest written (revision {current['protocol_revision']})")
        return 0

    if not MANIFEST.exists():
        sys.stderr.write(
            "error: ProtocolFixtures/protocol-manifest.json does not exist.\n"
            "       Run: python3 Tools/ProtocolManifest.py --write\n"
        )
        return 1

    if render(current) != MANIFEST.read_text():
        changed = [
            name
            for name, checksum in current["files"].items()
            if previous.get("files", {}).get(name) != checksum
        ]
        sys.stderr.write(
            "error: ProtocolFixtures/protocol-manifest.json is stale.\n"
            "       A file shared with the iOS companion changed:\n"
        )
        for name in changed or ["(manifest metadata)"]:
            sys.stderr.write(f"         {name}\n")
        sys.stderr.write(
            "       This is a cross-repo protocol change. Run:\n"
            "         python3 Tools/ProtocolManifest.py --write\n"
            "       then re-vendor in the iOS client in the same change.\n"
        )
        return 1

    print(f"protocol manifest is current (revision {current['protocol_revision']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
