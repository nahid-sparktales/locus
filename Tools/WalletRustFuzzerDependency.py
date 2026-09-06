#!/usr/bin/env python3
"""Verify the exact test-only libFuzzer archive, patch, tree and license inputs."""

import difflib
import json
import os
import tarfile
from pathlib import Path

from WalletFuzzEvidence import ROOT, directory_digest, sha256

VENDOR = ROOT / "WalletSignerCore/fuzz/vendor"
VERSION = "0.4.13"
ARCHIVE_SHA256 = "a9fd2f41a1cba099f79a0b6b6c35656cf7c03351a7bae8ff0f28f25270f929d2"
COMMIT = "719e4efb9b8857ebaa782ae59376c8cbb78fed0f"
PATCHED_FILE = "libfuzzer/FuzzerDriver.cpp"


def verify(vendor: Path = VENDOR, environment=None) -> dict:
    environment = os.environ if environment is None else environment
    if any(key.startswith("CUSTOM_LIBFUZZER") for key in environment):
        raise ValueError("Unreviewed custom libFuzzer override is unavailable")
    manifest_path = vendor / "provenance.json"
    manifest = json.loads(manifest_path.read_text())
    if (manifest["schemaVersion"] != 1 or manifest["version"] != VERSION
            or manifest["upstreamCommit"] != COMMIT
            or manifest["archiveSHA256"] != ARCHIVE_SHA256):
        raise ValueError("Rust fuzzer upstream identity mismatch")
    archive = vendor / "upstream/libfuzzer-sys-0.4.13.crate"
    if archive.is_symlink() or sha256(archive) != ARCHIVE_SHA256:
        raise ValueError("Rust fuzzer archive digest mismatch")
    crate = vendor / "libfuzzer-sys-0.4.13"
    patch = vendor / "patches/rss-monitor-shutdown.patch"
    if patch.is_symlink() or sha256(patch) != manifest["patchSHA256"]:
        raise ValueError("Rust fuzzer patch digest mismatch")
    if crate.is_symlink() or directory_digest(crate) != manifest["patchedTreeSHA256"]:
        raise ValueError("Rust fuzzer patched tree mismatch")
    originals = {}
    prefix = "libfuzzer-sys-0.4.13/"
    with tarfile.open(archive, "r:gz") as stream:
        members = stream.getmembers()
        if len(members) > 256 or sum(item.size for item in members) > 4 * 1024 * 1024:
            raise ValueError("Rust fuzzer archive exceeds reviewed bounds")
        for member in members:
            if not member.name.startswith(prefix) or ".." in Path(member.name).parts:
                raise ValueError("Unexpected archive path")
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("Unexpected archive entry type")
            name = member.name[len(prefix):]
            if not name or name in originals:
                raise ValueError("Duplicate archive entry")
            originals[name] = stream.extractfile(member).read()
    actual = {path.relative_to(crate).as_posix() for path in crate.rglob("*") if path.is_file()}
    if actual != set(originals):
        raise ValueError("Rust fuzzer archive/tree inventory mismatch")
    for name, original in originals.items():
        current = (crate / name).read_bytes()
        if name == PATCHED_FILE:
            expected_patch = "".join(difflib.unified_diff(
                original.decode().splitlines(keepends=True),
                current.decode().splitlines(keepends=True),
                fromfile="a/" + name, tofile="b/" + name,
            ))
            if patch.read_text() != expected_patch:
                raise ValueError("Rust fuzzer source does not reproduce its exact patch")
        elif current != original:
            raise ValueError("Unexpected Rust fuzzer source modification")
    vcs = json.loads(originals[".cargo_vcs_info.json"])
    if vcs["git"]["sha1"] != COMMIT:
        raise ValueError("Rust fuzzer archive commit mismatch")
    for license in manifest["licenses"]:
        path = vendor / license["path"]
        if path.is_symlink() or sha256(path) != license["sha256"]:
            raise ValueError("Rust fuzzer license digest mismatch")
    return {
        "version": VERSION,
        "upstreamCommit": COMMIT,
        "archiveSHA256": ARCHIVE_SHA256,
        "patchSHA256": manifest["patchSHA256"],
        "patchedTreeSHA256": manifest["patchedTreeSHA256"],
        "provenanceSHA256": sha256(manifest_path),
        "licenses": manifest["licenses"],
    }


if __name__ == "__main__":
    print(json.dumps(verify(), sort_keys=True))
