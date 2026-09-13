#!/usr/bin/env python3
"""Verify the Direct Locus runtime launcher's distribution signature before notarization."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def inspect(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    return result.stdout + result.stderr


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify(app: Path) -> None:
    helper = app / "Contents/Helpers/LocusRuntime"
    require(helper.is_file() and os.access(helper, os.X_OK), "LocusRuntime executable is missing")
    host = inspect(["/usr/bin/codesign", "-d", "--verbose=4", str(app)])
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", host, re.MULTILINE)
    require(team is not None, "containing app has no valid signing team")
    assert team is not None

    # Deep verification alone accepts a valid ad-hoc or development signature.
    # Check distribution metadata for every slice as well as the cryptographic seal.
    inspect(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(helper)])
    architectures = inspect(["/usr/bin/lipo", "-archs", str(helper)]).split()
    require(bool(architectures), "LocusRuntime has no Mach-O architectures")
    for architecture in architectures:
        signature = inspect([
            "/usr/bin/codesign", "-d", "--verbose=4", "--arch", architecture, str(helper),
        ])
        lines = signature.splitlines()
        require(
            any(line.startswith("Authority=Developer ID Application:") for line in lines),
            f"LocusRuntime ({architecture}) requires a Developer ID Application signature",
        )
        require(
            f"TeamIdentifier={team.group(1)}" in lines,
            f"LocusRuntime ({architecture}) signing team differs from its containing app",
        )
        require(
            any(line.startswith("Timestamp=") and line.removeprefix("Timestamp=").strip()
                and line.removeprefix("Timestamp=").strip().lower() != "none" for line in lines),
            f"LocusRuntime ({architecture}) signature requires a secure timestamp",
        )
        flags = re.search(r"^CodeDirectory .*\bflags=0x([0-9a-fA-F]+)\b", signature, re.MULTILINE)
        require(
            flags is not None and bool(int(flags.group(1), 16) & 0x10000),
            f"LocusRuntime ({architecture}) signature requires hardened runtime",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        verify(args.app)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: invalid runtime helper: {exc}", file=sys.stderr)
        return 1
    print("LocusRuntime Developer ID, team, secure timestamp, and hardened runtime verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
