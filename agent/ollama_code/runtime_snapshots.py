"""Reviewed, immutable project snapshots and explicit conflict-checked returns."""
from __future__ import annotations

import hashlib
import io
import json
import os
import re
import subprocess
import tarfile
from pathlib import Path, PurePosixPath

MAX_FILE = 32 * 1024 * 1024
MAX_SNAPSHOT = 512 * 1024 * 1024
SECRET_NAME = re.compile(r"(^|/)(\.env(?:\..*)?|credentials(?:\..*)?|auth\.json|id_(?:rsa|ed25519)|.*\.(?:pem|p12|pfx|key))$", re.I)
SECRET_CONTENT = re.compile(rb"-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----|(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,})|(?:AKIA[0-9A-Z]{16})|(?:gh[pousr]_[A-Za-z0-9]{30,})")
OMIT = {".git", ".venv", "node_modules", "__pycache__", ".DS_Store", ".codex-app-server", "build", ".build", ".cache"}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def relative(value: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value or "\x00" in value or str(path) != value:
        raise ValueError("Invalid snapshot path")
    return value


def contained(root: Path, name: str) -> Path:
    path = root / relative(name)
    if path.is_symlink() or root not in path.resolve().parents:
        raise ValueError("Snapshot path escapes its workspace")
    return path


def preview(root: Path, selected: list[str] | None = None) -> dict:
    root = root.resolve(strict=True)
    candidates, excluded = [], []
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in list(folders):
            path = Path(directory) / name
            if name in OMIT or path.is_symlink():
                excluded.append({"path": path.relative_to(root).as_posix() + "/", "reason": "cache, repository metadata, or symbolic link"})
                folders.remove(name)
        for name in files:
            candidates.append((Path(directory) / name).relative_to(root).as_posix())
    ignored = set()
    result = subprocess.run(["git", "-C", str(root), "check-ignore", "--no-index", "-z", "--stdin"],
                            input="\0".join(candidates).encode(), capture_output=True, check=False)
    if result.returncode in {0, 1}:
        ignored = set(result.stdout.decode().split("\0"))
    requested = set(selected) if selected is not None else None
    if requested is not None and not requested.issubset(candidates):
        raise ValueError("A selected file is missing, a symbolic link, or excluded repository metadata")
    files, total = [], 0
    for name in sorted(candidates):
        path = root / name
        reason = ""
        if path.is_symlink() or not path.is_file():
            reason = "symbolic link or special file"
        elif SECRET_NAME.search(name):
            reason = "credential file"
        elif path.stat().st_size > MAX_FILE:
            reason = "file exceeds 32 MiB"
        elif requested is not None and name not in requested:
            reason = "not selected"
        elif name in ignored and requested is None:
            reason = "ignored by project"
        elif any(part in OMIT for part in Path(name).parts):
            reason = "cache or repository metadata"
        if reason:
            excluded.append({"path": name, "reason": reason})
            continue
        data = path.read_bytes()
        if SECRET_CONTENT.search(data):
            excluded.append({"path": name, "reason": "detected secret"})
            continue
        total += len(data)
        if total > MAX_SNAPSHOT:
            raise ValueError("Snapshot exceeds 512 MiB; narrow the selected files")
        files.append({"path": name, "sha256": digest(data), "size": len(data), "executable": bool(path.stat().st_mode & 0o111)})
    manifest = {"version": 1, "files": files}
    return {**manifest, "fingerprint": digest(json.dumps(manifest, sort_keys=True).encode()), "total_bytes": total,
            "workspace": str(root), "exclusions": excluded}


def archive(review: dict) -> bytes:
    root = Path(review["workspace"])
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as tar:
        for entry in review["files"]:
            path = contained(root, entry["path"])
            data = path.read_bytes()
            if digest(data) != entry["sha256"] or len(data) != entry["size"]:
                raise ValueError("A reviewed file changed; review the snapshot again")
            item = tarfile.TarInfo(entry["path"])
            item.size, item.mode = len(data), 0o700 if entry.get("executable") else 0o600
            tar.addfile(item, io.BytesIO(data))
    return output.getvalue()


def unpack(data: bytes, destination: Path, files: list[dict]) -> None:
    expected = {relative(item["path"]): item for item in files}
    if len(expected) != len(files):
        raise ValueError("Duplicate snapshot file")
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    seen, total = set(), 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for item in tar:
            name = relative(item.name)
            if not item.isfile() or name not in expected or name in seen or item.size > MAX_FILE:
                raise ValueError("Invalid snapshot archive")
            total += item.size
            if total > MAX_SNAPSHOT:
                raise ValueError("Snapshot exceeds size limit")
            content = tar.extractfile(item).read(MAX_FILE + 1)
            if digest(content) != expected[name]["sha256"] or len(content) != expected[name]["size"]:
                raise ValueError("Snapshot integrity check failed")
            target = contained(destination, name)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as stream:
                stream.write(content)
            target.chmod(0o700 if expected[name].get("executable") else 0o600)
            seen.add(name)
    if seen != set(expected):
        raise ValueError("Snapshot is incomplete")


def changes(baseline: dict, returned: dict) -> list[dict]:
    before = {item["path"]: item for item in baseline["files"]}
    after = {item["path"]: item for item in returned["files"]}
    excluded = {item["path"] for item in returned.get("exclusions", [])}
    return [{"path": name, "state": "added" if name not in before else "deleted" if name not in after else "modified",
             "baseline": before.get(name), "result": after.get(name)}
            for name in sorted(before.keys() | after.keys()) if name not in excluded and before.get(name) != after.get(name)]


def apply_changes(baseline: dict, returned: dict, result_root: Path, selected: list[str]) -> list[str]:
    """The caller explicitly selects changes after retrieval; reject local edits."""
    root = Path(baseline["workspace"]).resolve()
    available = {item["path"]: item for item in changes(baseline, returned)}
    if len(set(selected)) != len(selected) or not set(selected).issubset(available):
        raise ValueError("Select changes from the reviewed result")
    prepared = []
    for name in selected:
        item, target = available[name], contained(root, name)
        expected = item["baseline"]
        if (expected and (not target.is_file() or digest(target.read_bytes()) != expected["sha256"])) or (not expected and target.exists()):
            raise ValueError(f"Local edits conflict with returned change: {name}")
        data = contained(result_root, name).read_bytes() if item["result"] else None
        if data is not None and digest(data) != item["result"]["sha256"]:
            raise ValueError("The returned file changed after review")
        prepared.append((target, data, item))
    for target, data, item in prepared:
        if data is None:
            target.unlink()
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".locus-return")
            with temporary.open("xb") as stream:
                stream.write(data)
            temporary.chmod(0o700 if item["result"].get("executable") else 0o600)
            os.replace(temporary, target)
    return selected
