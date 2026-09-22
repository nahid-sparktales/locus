"""The requested community skills ship offline and remain explicitly selected."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

from ollama_code.extensions import BUILTIN_SKILLS_ROOT, ExtensionManager
from ollama_code.tool_registry import ToolRegistry

REQUESTED = {
    "using-superpowers": "obra/superpowers",
    "ponytail": "DietrichGebert/ponytail",
    "graphify": "Graphify-Labs/graphify",
    "caveman": "JuliusBrussee/caveman",
    "understand-anything": "Egonex-AI/Understand-Anything",
    "last30days": "mvanhorn/last30days-skill",
    "i-have-adhd": "ayghri/i-have-adhd",
    "agentic-awesome-skills": "sickn33/agentic-awesome-skills",
    "scientific-agent-skills": "K-Dense-AI/scientific-agent-skills",
    "diagram-design": "cathrynlavery/diagram-design",
}
LIBRARIES = ["agentic-awesome-skills", "scientific-agent-skills"]


def test_requested_skills_are_discoverable_and_explicit(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    skills = {item["id"]: item for item in manager.skills()}
    assert not [item for item in skills.values() if item.get("error")]
    assert manager.startup_skills() == []
    registry = ToolRegistry(manager)
    registry.begin_turn("Help with this project", str(tmp_path))
    assert registry.explicit_skill_context == ""
    for name, repo in REQUESTED.items():
        record = skills[f"builtin:{name}"]
        assert record["enabled"]
        assert record["activation"] == "explicit"
        assert not record["allow_implicit_invocation"]
        assert record["provenance"]["repository"] == f"https://github.com/{repo}"
        assert len(record["provenance"]["commit"]) == 40
        assert (Path(record["root"]) / "LICENSE").is_file()
        registry.begin_turn(f"Use ${name} for this task", str(tmp_path))
        assert f"Explicitly activated skill $builtin:{name}" in registry.explicit_skill_context


@pytest.mark.parametrize("name", LIBRARIES)
def test_library_catalog_matches_offline_archive(name):
    root = BUILTIN_SKILLS_ROOT / name
    source = json.loads((root / "SOURCE.json").read_text())
    catalog = json.loads((root / "catalog.json").read_text())
    assert catalog["commit"] == source["commit"]
    assert len(catalog["skills"]) == source["catalog_skill_count"]
    assert sum(item["bundled"] for item in catalog["skills"]) == source["bundled_skill_count"]
    assert hashlib.sha256((root / "library.zip").read_bytes()).hexdigest() == source["archive_sha256"]
    assert len({item["id"] for item in catalog["skills"]}) == len(catalog["skills"])
    with zipfile.ZipFile(root / "library.zip") as archive:
        files = set(archive.namelist())
        assert archive.testzip() is None
        for item in catalog["skills"]:
            if item["bundled"]:
                assert item["path"] in files
            else:
                assert item["id"] in source["excluded_skills"]
                prefix = str(Path(item["path"]).parent) + "/"
                assert not any(path.startswith(prefix) for path in files)


def _library(name, *args):
    return subprocess.run(
        [sys.executable, str(BUILTIN_SKILLS_ROOT / name / "scripts/library.py"), *args],
        capture_output=True, text=True, check=False,
    )


@pytest.mark.parametrize("name,query,chosen,restricted", [
    ("agentic-awesome-skills", "frontend design", "frontend-design", "docx-official"),
    ("scientific-agent-skills", "astronomy", "astropy", "docx"),
])
def test_library_search_extract_and_no_overwrite(tmp_path, name, query, chosen, restricted):
    result = _library(name, "--search", query)
    assert result.returncode == 0, result.stderr
    assert chosen in {item["id"] for item in json.loads(result.stdout)}
    destination = tmp_path / "library"
    result = _library(name, "--extract", chosen, "--destination", str(destination))
    assert result.returncode == 0, result.stderr
    skill = Path(result.stdout.strip())
    assert skill.is_file()
    assert (destination / "LIBRARY-LICENSE").is_file()
    assert {path.name for path in (destination / "skills").iterdir()} == {chosen}
    with zipfile.ZipFile(BUILTIN_SKILLS_ROOT / name / "library.zip") as archive:
        assert skill.read_bytes() == archive.read(f"skills/{chosen}/SKILL.md")
    # Reusing an unchanged extraction works, but local edits must survive.
    assert _library(name, "--extract", chosen, "--destination", str(destination)).returncode == 0
    skill.write_text("user customization")
    assert _library(name, "--extract", chosen, "--destination", str(destination)).returncode != 0
    assert skill.read_text() == "user customization"
    assert _library(name, "--extract", restricted, "--destination", str(destination)).returncode != 0
    assert not (destination / "skills" / restricted).exists()


def test_library_rejects_symlink_escape(tmp_path):
    destination = tmp_path / "library"
    destination.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (destination / "skills").symlink_to(outside, target_is_directory=True)
    result = _library("scientific-agent-skills", "--extract", "astropy",
                      "--destination", str(destination))
    assert result.returncode != 0
    assert list(outside.iterdir()) == []


def test_supporting_resources_are_readable_through_locus(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    for name, resource in [
        ("graphify", "references/query.md"),
        ("understand-anything", "upstream/skills/understand/SKILL.md"),
        ("last30days", "UPSTREAM_SKILL.md"),
        ("diagram-design", "references/style-guide.md"),
        ("agentic-awesome-skills", "catalog.json"),
        ("scientific-agent-skills", "catalog.json"),
    ]:
        assert manager.read_skill_file(f"builtin:{name}", resource)
