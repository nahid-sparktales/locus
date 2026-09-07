#!/usr/bin/env python3
"""Verify public artifact invariants also required when appcast generation is skipped."""

from __future__ import annotations

import argparse
import plistlib
import subprocess
import sys
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def inspect(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    return result.stdout + result.stderr


def verify(app: Path) -> None:
    require(app.name == "Locus.app", "public archive must contain Locus.app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(
        info.get("CFBundleIdentifier") == "io.sparktales.locus"
        and info.get("CFBundleExecutable") == "Locus"
        and info.get("LocusEdition") == "locus"
        and info.get("LocusUpdateMode") == "manual",
        "public manual artifact must be wallet-free Locus",
    )
    require(not any(app.rglob("*.xctest")), "public archive contains an embedded test bundle")
    inspect(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    signature = inspect(["/usr/bin/codesign", "-d", "--verbose=4", str(app)]).splitlines()
    require(
        "TeamIdentifier=4X4RJA7GMD" in signature
        and "Identifier=io.sparktales.locus" in signature
        and any(line.startswith("Authority=Developer ID Application:") for line in signature),
        "public archive must be signed by the SparkTales Developer ID team",
    )
    architecture = inspect(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/Locus")]).strip()
    require(architecture == "arm64", f"public archive must contain only arm64, found {architecture}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        verify(args.app)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: invalid public manual app: {exc}", file=sys.stderr)
        return 1
    print("Public manual app identity, signature, architecture, and test exclusion verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
