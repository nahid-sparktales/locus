#!/usr/bin/env python3
"""Build a complete remote package on its target host from reviewed, pinned inputs."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

from PackageRemoteRuntime import TARGETS, digest, host_target, package_runtime

ROOT = Path(__file__).resolve().parents[1]
PINS = Path(__file__).with_name("RemoteRuntimeArtifacts.json")
MAX_DOWNLOAD = 512 * 1024 * 1024
MAX_EXPANDED = 2 * 1024 * 1024 * 1024


def wheel_platforms(target: str) -> list[str]:
    if target == "macos-arm64":
        return ["macosx_14_0_arm64"]
    architecture = "aarch64" if target == "linux-arm64" else "x86_64"
    return [f"manylinux_2_{minor}_{architecture}" for minor in (28, 27, 24, 17)] + ["manylinux2014_" + architecture]


def download(component: dict, cache: Path) -> Path:
    """Every cache reuse is verified; partial downloads never become cache entries."""
    checksum = component["sha256"]
    if len(checksum) != 64 or any(c not in "0123456789abcdef" for c in checksum):
        raise ValueError("Invalid pinned artifact checksum")
    if not component["url"].startswith("https://github.com/"):
        raise ValueError("Artifact inputs must use reviewed HTTPS release URLs")
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / (checksum + ".tar.gz")
    if destination.is_symlink():
        raise ValueError("Artifact cache entries cannot be symlinks")
    if destination.is_file() and digest(destination) == checksum:
        return destination
    fd, temporary = tempfile.mkstemp(prefix=".download-", dir=cache)
    try:
        request = urllib.request.Request(component["url"], headers={"User-Agent": "LocusRuntimeBuilder/1"})
        with os.fdopen(fd, "wb") as output, urllib.request.urlopen(request, timeout=60) as response:
            if not response.geturl().startswith("https://"):
                raise ValueError("Artifact download redirected outside HTTPS")
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_DOWNLOAD:
                    raise ValueError("Artifact download exceeds the size limit")
                output.write(chunk)
        if digest(Path(temporary)) != checksum:
            raise ValueError("Pinned artifact integrity check failed")
        if component.get("size") is not None and size != component["size"]:
            raise ValueError("Pinned artifact size changed")
        os.replace(temporary, destination)
        return destination
    finally:
        Path(temporary).unlink(missing_ok=True)


def extract(archive_path: Path, destination: Path) -> None:
    """Extract reviewed inputs without allowing archive paths to escape staging."""
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    links, seen, total = [], set(), 0
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or str(name) in seen:
                raise ValueError("Unsafe artifact archive path")
            seen.add(str(name))
            path = root / str(name)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.issym():
                links.append((path, member.linkname))
            elif member.isfile():
                total += member.size
                if total > MAX_EXPANDED:
                    raise ValueError("Artifact archive exceeds the expanded size limit")
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("xb") as output:
                    shutil.copyfileobj(archive.extractfile(member), output)
                path.chmod(0o755 if member.mode & 0o111 else 0o644)
            else:
                raise ValueError("Unsupported artifact archive entry")
    for path, value in links:
        if Path(value).is_absolute() or root not in (path.parent / value).resolve().parents:
            raise ValueError("Artifact link escapes staging")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(value)
    for path, _ in links:
        if root not in path.resolve(strict=True).parents:
            raise ValueError("Artifact link escapes staging")


def copy_source(repo: Path, output: Path) -> str:
    """Only tracked agent files belong in a release, including their current edits."""
    names = subprocess.check_output(["git", "-C", str(repo), "ls-files", "-z", "agent/ollama_code"], text=True).split("\0")
    source = repo / "agent/ollama_code"
    for name in filter(None, names):
        path = repo / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("Agent source must contain regular tracked files")
        target = output / "source/ollama_code" / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    return subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()


def prune_python(root: Path) -> None:
    """Apply the desktop runtime's unused GPL/Tk and development-file exclusions."""
    for library in (root / "python/lib").glob("python3.*"):
        for name in ("dbm", "tkinter", "test", "idlelib", "turtledemo", "ensurepip", "site-packages"):
            shutil.rmtree(library / name, ignore_errors=True)
        for pattern in ("lib-dynload/_dbm*.so", "lib-dynload/_gdbm*.so", "lib-dynload/_tkinter*.so"):
            for path in library.glob(pattern):
                path.unlink()
    for path in (root / "python/bin").iterdir():
        if not path.name.startswith("python3"):
            path.unlink()
    for directory in (root / "python/include", root / "python/share"):
        shutil.rmtree(directory, ignore_errors=True)
    for pattern in ("tcl*", "tk*", "itcl*", "libtcl*", "libtk*", "Tix*", "thread*"):
        for path in (root / "python/lib").glob(pattern):
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
    shutil.rmtree(root / "site-packages/bin", ignore_errors=True)


def prepare(target: str, cache: Path, output: Path, *, require_clean: bool = False) -> dict:
    if target != host_target():
        raise ValueError("Build on the selected target operating system and architecture")
    pins = json.loads(PINS.read_text())
    dirty = bool(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"], text=True))
    if require_clean and dirty:
        raise ValueError("Release builds require a clean committed checkout")
    components = {**pins["targets"][target], "codex_source": pins["codex_source"]}
    archives = {}
    for name, component in components.items():
        print("Verifying pinned " + name, flush=True)
        archives[name] = download(component, cache)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".runtime-build-", dir=output.parent) as temporary:
        work = Path(temporary)
        runtime = work / "runtime"
        extract(archives["python"], runtime)
        python = runtime / "python/bin/python3"
        if not python.is_file():
            raise ValueError("Unexpected standalone Python layout")
        lock = ROOT / "agent/requirements-runtime.lock"
        platforms = [argument for value in wheel_platforms(target) for argument in ("--platform", value)]
        subprocess.run([str(python), "-s", "-m", "pip", "--isolated", "install", "--disable-pip-version-check", *platforms,
                        "--require-hashes", "--only-binary=:all:", "--no-compile", "--target", str(runtime / "site-packages"),
                        "--requirement", str(lock)], check=True, timeout=900)
        revision = copy_source(ROOT, runtime)
        helper_paths = {}
        for name in ("codex", "code_mode_host"):
            folder = work / name
            extract(archives[name], folder)
            binaries = [p for p in folder.rglob("*") if p.is_file() and p.stat().st_mode & 0o111]
            if len(binaries) != 1:
                raise ValueError("Unexpected pinned helper archive layout")
            helper_paths[name] = binaries[0]
        licenses = runtime / "licenses"
        shutil.copytree(ROOT / "Locus/Resources/ThirdPartyLicenses", licenses)
        shutil.copyfile(ROOT / "Locus/Resources/ThirdPartyNotices.md", licenses / "ThirdPartyNotices.md")
        shutil.copyfile(ROOT / "LICENSE", licenses / "Locus-LICENSE")
        helper_licenses = licenses / ("openai-codex-" + pins["codex_version"])
        helper_licenses.mkdir()
        with tarfile.open(archives["codex_source"], "r:gz") as archive:
            for name in ("LICENSE", "NOTICE"):
                matches = [m for m in archive.getmembers() if len(PurePosixPath(m.name).parts) == 2 and PurePosixPath(m.name).name == name and m.isfile()]
                if len(matches) != 1:
                    raise ValueError("Pinned helper source is missing its license notices")
                (helper_licenses / name).write_bytes(archive.extractfile(matches[0]).read())
        prune_python(runtime)
        provenance = {"version": 1, "target": target, "source_revision": revision, "source_dirty": dirty,
                      "dependency_lock_sha256": digest(lock), "artifact_pins_sha256": digest(PINS),
                      "python_version": pins["python_version"], "codex_version": pins["codex_version"],
                      "wheel_platforms": wheel_platforms(target),
                      "minimum_os": "macOS 14" if target == "macos-arm64" else "Linux with glibc 2.28 and systemd",
                      "components": components, "helper_delivery": "verified-upstream-release"}
        (runtime / "provenance.json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
        checksum = package_runtime(runtime, helper_paths["codex"], helper_paths["code_mode_host"], target, output)
    report = {"target": target, "package": output.name, "sha256": checksum, "provenance": provenance}
    output.with_suffix(output.suffix + ".build.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, default=host_target())
    parser.add_argument("--cache", type=Path, default=ROOT / "build/runtime-downloads")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    print(json.dumps(prepare(args.target, args.cache, args.output, require_clean=args.require_clean)))


if __name__ == "__main__":
    main()
