"""Candidate ZIP rejection boundaries before the ordinary plugin trust review."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import stat
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parents[2] / "Tools/VerifyAgentWorldsArtifact.py"
spec = importlib.util.spec_from_file_location("verify_agent_worlds_artifact", SOURCE)
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def package(tmp_path, names=("ui/index.html",), *, symlink=False):
    archive = tmp_path / "candidate.zip"
    with zipfile.ZipFile(archive, "w") as output:
        for name in names:
            info = zipfile.ZipInfo(name)
            if symlink:
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(info, "fixture")
    return archive, hashlib.sha256(archive.read_bytes()).hexdigest()


@pytest.mark.parametrize("path", ["../escape", "/escape", "ui/../../escape", "ui\\escape", "ui/%2e%2e/escape", "ui/./escape", "ui//escape", "ui/outpost/model.glb", ".git/config"])
def test_artifact_rejects_unsafe_paths(tmp_path, path):
    archive, digest = package(tmp_path, [path])
    with pytest.raises(ValueError):
        artifact.extract_candidate(archive, digest, tmp_path / "output")
    assert not (tmp_path / "escape").exists()


def test_artifact_rejects_symlink_and_wrong_pin(tmp_path):
    archive, digest = package(tmp_path, symlink=True)
    with pytest.raises(ValueError, match="SHA-256"):
        artifact.extract_candidate(archive, "0" * 64, tmp_path / "wrong-pin")
    with pytest.raises(ValueError, match="Unsafe"):
        artifact.extract_candidate(archive, digest, tmp_path / "linked")


def test_artifact_rejects_duplicate_members(tmp_path):
    with pytest.warns(UserWarning, match="Duplicate name"):
        archive, digest = package(tmp_path, ["ui/index.html", "ui/index.html"])
    with pytest.raises(ValueError, match="duplicate"):
        artifact.extract_candidate(archive, digest, tmp_path / "output")


def test_artifact_rejects_file_count_before_extraction(tmp_path):
    archive, digest = package(tmp_path, [f"f{i}" for i in range(5001)])
    with pytest.raises(ValueError, match="limits"):
        artifact.extract_candidate(archive, digest, tmp_path / "output")
    assert not (tmp_path / "output").exists()


def test_artifact_rejects_declared_expansion_limit_before_extraction(tmp_path):
    archive, _ = package(tmp_path)
    data = bytearray(archive.read_bytes())
    central = data.index(b"PK\x01\x02")
    struct.pack_into("<I", data, central + 24, 251 * 1024 * 1024)
    archive.write_bytes(data)
    with pytest.raises(ValueError, match="limits"):
        artifact.extract_candidate(archive, hashlib.sha256(data).hexdigest(), tmp_path / "output")
    assert not (tmp_path / "output").exists()


def test_artifact_extracts_verified_bytes_without_links(tmp_path):
    archive, digest = package(tmp_path)
    output = tmp_path / "output"
    artifact.extract_candidate(archive, digest, output)
    assert (output / "ui/index.html").read_bytes() == b"fixture"


@pytest.mark.parametrize("manifest", ["{invalid", json.dumps({
    "name": "agent-world", "version": "0.2.0", "locus": {"screens": [{
        "id": "agent-world", "title": "Agent Worlds", "entrypoint": "ui/index.html",
        "version": 3, "capabilities": ["agents.read"],
    }]},
})])
def test_artifact_rejects_invalid_manifest_before_install(tmp_path, manifest):
    archive = tmp_path / "candidate.zip"
    with zipfile.ZipFile(archive, "w") as output:
        output.writestr(".codex-plugin/plugin.json", manifest)
        output.writestr("ui/index.html", "<!doctype html><title>fixture</title>")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    result = subprocess.run([sys.executable, str(SOURCE), "--artifact", str(archive), "--sha256", digest],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode != 0
    assert "ExtensionError" in result.stderr
    assert '"install": "passed"' not in result.stdout
