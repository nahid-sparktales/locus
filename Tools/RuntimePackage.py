#!/usr/bin/env python3
"""Verify the vendored runtime wheel and stage the Locus host registration.

Build tool only (Python 3.11+); product and runtime wheels support Python 3.10+.
Reads committed build inputs, never an installed runtime or production profile.
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import json
import re
import subprocess
import zipfile
from email.parser import Parser
from pathlib import Path, PurePosixPath

import tomllib

HOST_GROUP = "locus_runtime.host"
HOST_ENTRY = "ollama_code.runtime_host:main"


def runtime_release(agent: Path) -> dict:
    """Validate the immutable build input before pip, including cache reuse."""
    folder = agent / "vendor/wheels"
    release = json.loads((folder / "runtime-release.json").read_text())
    if release.get("distribution") != "locus-runtime":
        raise ValueError("Unexpected runtime distribution")
    version = release.get("version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Runtime version must be an exact release version")
    filename = f"locus_runtime-{version}-py3-none-any.whl"
    if release.get("artifact") != filename:
        raise ValueError("Unexpected runtime wheel filename")
    wheel = folder / filename
    if wheel.is_symlink() or not wheel.is_file():
        raise ValueError("Runtime wheel must be a regular vendored file")
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != release.get("sha256"):
        raise ValueError("Runtime wheel integrity check failed")
    if not re.fullmatch(r"[0-9a-f]{40}", release.get("source_revision", "")):
        raise ValueError("Runtime source revision must identify a committed source")
    if not release.get("source_repository"):
        raise ValueError("Runtime source provenance is missing")
    with zipfile.ZipFile(wheel) as archive:
        metadata = Parser().parsestr(archive.read(f"locus_runtime-{version}.dist-info/METADATA").decode())
        if metadata["Name"] != "locus-runtime" or metadata["Version"] != version:
            raise ValueError("Runtime wheel metadata does not match its pin")
        entrypoints = archive.read(f"locus_runtime-{version}.dist-info/entry_points.txt").decode()
        if not re.search(r"^locus-runtime\s*=\s*locus_runtime\.cli:main\s*$", entrypoints, re.MULTILINE):
            raise ValueError("Runtime wheel must own the locus-runtime console script")
    project = tomllib.loads((agent / "pyproject.toml").read_text())["project"]
    if f"locus-runtime=={version}" not in project["dependencies"]:
        raise ValueError("Locus and the vendored runtime must be pinned as a compatible pair")
    return release


def stage_host_metadata(agent: Path, destination: Path) -> Path:
    """Represent the staged product source as its canonical host distribution.

    Desktop staging selects an edition before this runs. Metadata comes from the
    same pyproject as a normal wheel; no extra backend or dynamic plugin is copied.
    """
    project = tomllib.loads((agent / "pyproject.toml").read_text())["project"]
    hosts = project.get("entry-points", {}).get(HOST_GROUP, {})
    if project["name"] != "ollama-code" or hosts != {"locus": HOST_ENTRY}:
        raise ValueError("Only the canonical Locus host registration may be staged")
    if "locus-runtime" in project.get("scripts", {}):
        raise ValueError("The runtime wheel must be the sole locus-runtime console owner")
    version = project["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Unexpected Locus distribution version")
    if not (destination / "ollama_code/runtime_host.py").is_file():
        raise ValueError("The staged Locus host adapter is missing")
    metadata = destination / f"ollama_code-{version}.dist-info"
    if metadata.is_symlink() or any(path != metadata for path in destination.glob("ollama_code-*.dist-info")):
        raise ValueError("Ambiguous Locus host distribution metadata")
    metadata.mkdir(parents=True, exist_ok=True)
    lines = ["Metadata-Version: 2.1", "Name: ollama-code", f"Version: {version}",
             f"Requires-Python: {project['requires-python']}"]
    lines.extend(f"Requires-Dist: {dependency}" for dependency in project["dependencies"])
    (metadata / "METADATA").write_text("\n".join(lines) + "\n\n")
    (metadata / "INSTALLER").write_text("Locus source assembly\n")
    groups = {"console_scripts": project.get("scripts", {}), HOST_GROUP: hosts}
    entries = "\n".join(f"[{group}]\n" + "\n".join(f"{key} = {value}" for key, value in sorted(values.items())) + "\n"
                        for group, values in groups.items())
    (metadata / "entry_points.txt").write_text(entries)
    record = io.StringIO(newline="")
    writer = csv.writer(record)
    for path in sorted(metadata.iterdir()):
        if path.name == "RECORD":
            continue
        data = path.read_bytes()
        checksum = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        writer.writerow((path.relative_to(destination).as_posix(), f"sha256={checksum}", len(data)))
    writer.writerow(((metadata / "RECORD").relative_to(destination).as_posix(), "", ""))
    (metadata / "RECORD").write_text(record.getvalue())
    return metadata


def verify_installed_runtime(agent: Path, site_packages: Path) -> dict:
    """Require the composed package's code to match the reviewed wheel exactly."""
    release = runtime_release(agent)
    with zipfile.ZipFile(agent / "vendor/wheels" / release["artifact"]) as archive:
        for member in archive.infolist():
            name = PurePosixPath(member.filename)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError("Unsafe runtime wheel member")
            if member.is_dir() or name.name == "RECORD":
                continue
            path = site_packages / member.filename
            if path.is_symlink() or not path.is_file() or path.read_bytes() != archive.read(member):
                raise ValueError("Installed runtime differs from the reviewed wheel: " + member.filename)
    return release


def composed_provenance(agent: Path) -> dict:
    release = runtime_release(agent)
    repo = agent.parent
    revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(repo), "status", "--porcelain"], text=True))
    return {"format": "locus-runtime-composition/1", "product_repository": "https://github.com/nahid-sparktales/locus",
            "product_revision": revision, "product_dirty": dirty,
            "runtime": release,
            "dependency_lock_sha256": hashlib.sha256((agent / "requirements-runtime.lock").read_bytes()).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "verify-installed", "stage-host", "provenance"))
    parser.add_argument("--agent", type=Path, required=True)
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        print(json.dumps(runtime_release(args.agent), sort_keys=True))
    elif args.destination is None:
        parser.error("--destination is required for installed verification, staging and provenance")
    elif args.action == "verify-installed":
        print(json.dumps(verify_installed_runtime(args.agent, args.destination), sort_keys=True))
    elif args.action == "stage-host":
        stage_host_metadata(args.agent, args.destination)
    else:
        args.destination.write_text(json.dumps(composed_provenance(args.agent), sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
