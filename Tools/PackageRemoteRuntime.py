#!/usr/bin/env python3
"""Reproducible remote runtime archives; no credentials or host paths in manifests."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import subprocess
import tarfile
import tempfile
from pathlib import Path

TARGETS = ("linux-x86_64", "linux-arm64", "macos-arm64")
CODEX_VERSION = "0.147.0"


def host_target() -> str:
    system = {"Darwin": "macos", "Linux": "linux"}.get(platform.system(), "unsupported")
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64"}.get(platform.machine(), "unsupported")
    return f"{system}-{arch}"


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()


def runtime_files(runtime: Path) -> dict[str, Path]:
    runtime = runtime.resolve(strict=True)
    files = {}
    for path in sorted(runtime.rglob("*")):
        if "__pycache__" in path.parts or path.suffix == ".pyc" or path.name == ".DS_Store" or path.name.startswith("._"):
            continue
        if path.is_symlink():
            resolved = path.resolve(strict=True)
            if runtime not in resolved.parents or resolved.is_dir():
                raise ValueError("Runtime links must reference files inside the prepared runtime")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("Runtime contains a non-regular file")
        name = path.relative_to(runtime).as_posix()
        if name.split("/")[0] not in {"python", "source", "site-packages", "licenses", "provenance.json"}:
            raise ValueError("Unexpected file in prepared runtime: " + name)
        files[name] = path
    for name in ("python/bin/python3", "source/ollama_code/runtime.py"):
        if name not in files:
            raise ValueError("The portable runtime layout is incomplete: " + name)
    return files


def check_runtime(runtime: Path, helper: Path) -> None:
    result = subprocess.run([str(helper.resolve()), "--version"], capture_output=True, text=True, timeout=20, check=False)
    if result.returncode or result.stdout.strip() != "codex-cli " + CODEX_VERSION:
        raise ValueError("The ChatGPT helper must be pinned to version " + CODEX_VERSION)
    with tempfile.TemporaryDirectory(prefix="locus-package-check-") as temporary:
        environment = {**os.environ, "PYTHONPATH": str(runtime / "source") + os.pathsep + str(runtime / "site-packages"),
                       "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                       "OLLAMA_CODE_HOME": str(Path(temporary) / "profile"), "LOCUS_CODEX_HOME": str(Path(temporary) / "accounts")}
        result = subprocess.run([str(runtime / "python/bin/python3"), "-s", "-c",
                                 "import ssl, sqlite3, ollama_code.runtime; import fastapi, uvicorn; print('ready')"],
                                env=environment, cwd=temporary, capture_output=True, timeout=40, check=False)
        if result.returncode or result.stdout.strip() != b"ready":
            raise ValueError("The prepared Python runtime cannot import its dependencies in isolation")


def package_runtime(runtime: Path, helper: Path, code_host: Path, target: str, output: Path) -> str:
    if target not in TARGETS or host_target() != target:
        raise ValueError("Build and validate this package on its target operating system and architecture")
    runtime = runtime.resolve(strict=True)
    output = output.resolve()
    if output == runtime or runtime in output.parents:
        raise ValueError("The package output must be outside the prepared runtime")
    files = runtime_files(runtime)
    for path in (helper, code_host):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError("Both pinned ChatGPT helper executables are required")
    check_runtime(runtime, helper)
    files.update({"codex-app-server": helper, "codex-code-mode-host": code_host})
    hashes = {name: digest(path) for name, path in sorted(files.items())}
    manifest = {"version": 1, "protocol_version": 1, "target": target, "codex_version": CODEX_VERSION, "files": hashes}
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".package-", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name, path in sorted(files.items()):
                item = tarfile.TarInfo(name)
                item.mode = 0o700 if path.stat().st_mode & 0o111 else 0o600
                item.size = path.stat().st_size
                with path.open("rb") as stream:
                    archive.addfile(item, stream)
                if digest(path) != hashes[name]:
                    raise ValueError("A runtime file changed while it was being packaged: " + name)
            data = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
            item = tarfile.TarInfo("manifest.json")
            item.size, item.mode = len(data), 0o600
            archive.addfile(item, io.BytesIO(data))
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)
    checksum = digest(output)
    output.with_suffix(output.suffix + ".sha256").write_text(checksum + "\n")
    return checksum


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--codex-helper", type=Path, required=True)
    parser.add_argument("--codex-code-mode-host", type=Path, required=True)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    checksum = package_runtime(args.runtime, args.codex_helper, args.codex_code_mode_host, args.target, args.output)
    print(json.dumps({"target": args.target, "package": args.output.name, "sha256": checksum}))


if __name__ == "__main__":
    main()
