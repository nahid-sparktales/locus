"""Search or unpack one pinned, offline skill without installing its tools."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--search", help="Words to match against skill names and descriptions")
    action.add_argument("--extract", help="Exact catalog id to unpack")
    parser.add_argument("--limit", type=int, default=15)
    parser.add_argument("--destination", type=Path, help="Writable directory outside the app bundle")
    args = parser.parse_args()
    catalog = json.loads((ROOT / "catalog.json").read_text())
    if args.search is not None:
        words = args.search.lower().split()
        ranked = []
        for item in catalog["skills"]:
            haystack = (item["id"] + " " + item["description"]).lower()
            score = sum(word in haystack for word in words)
            if score or not words:
                ranked.append((score, item))
        ranked.sort(key=lambda pair: (-pair[0], pair[1]["id"]))
        print(json.dumps([item for _, item in ranked[:max(1, args.limit)]], indent=2))
        return

    item = next((item for item in catalog["skills"] if item["id"] == args.extract), None)
    if item is None:
        parser.error("unknown skill id; search the catalog first")
    if not item["bundled"]:
        parser.error("this entry is link-only because its license prohibits redistribution: "
                     + item["url"])
    if args.destination is None:
        parser.error("--extract requires --destination")
    destination = args.destination.resolve()
    if destination == ROOT or ROOT in destination.parents:
        parser.error("destination must be outside the read-only skill bundle")

    archive = ROOT / "library.zip"
    expected = json.loads((ROOT / "SOURCE.json").read_text())["archive_sha256"]
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        parser.error("library archive checksum mismatch")
    prefix = str(PurePosixPath(item["path"]).parent) + "/"
    with zipfile.ZipFile(archive) as bundle:
        members = [member for member in bundle.infolist()
                   if member.filename.startswith(prefix) and not member.is_dir()]
        if not members:
            parser.error("skill is missing from the library archive")
        # Validate all paths before writing any files, including existing symlinks.
        outputs = []
        for member in members:
            relative = PurePosixPath(member.filename)
            target = destination.joinpath(*relative.parts)
            if relative.is_absolute() or ".." in relative.parts \
                    or destination not in target.resolve().parents:
                parser.error("archive path escapes the destination")
            data = bundle.read(member)
            if target.exists() and (not target.is_file() or target.read_bytes() != data):
                parser.error(f"destination contains a modified file: {target}")
            outputs.append((member, target, data))
        for member, target, data in outputs:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            if (member.external_attr >> 16) & 0o111:
                target.chmod(target.stat().st_mode | 0o100)
    license_path = destination / "LIBRARY-LICENSE"
    if not license_path.exists():
        license_path.write_bytes((ROOT / "LICENSE").read_bytes())
    print(destination / item["path"])


if __name__ == "__main__":
    main()
