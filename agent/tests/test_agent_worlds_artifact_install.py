"""Pinned local artifact install through the real manager; no user installation."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys
import zipfile

import pytest

TOOLS = Path(__file__).resolve().parents[2] / "Tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("world_artifact_install", TOOLS / "InstallAgentWorldsArtifact.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def plugin(root: Path, version="0.2.0", protocol=2):
    (root / ".codex-plugin").mkdir(parents=True)
    (root / "ui/static").mkdir(parents=True)
    manifest = {"name": "agent-world", "version": version, "description": "Fixture",
                "interface": {"displayName": "Agent Worlds"},
                "locus": {"screens": [{"id": "agent-world", "title": "Agent Worlds", "version": protocol,
                                       "entrypoint": "ui/index.html", "capabilities": ["agents.read", "agents.interact", "world.preferences"]}]},
                "agentWorlds": {"worlds": ["local-line"], "sdkVersion": 1, "bridgeVersion": protocol, "runtimeVersion": version}}
    (root / ".codex-plugin/plugin.json").write_text(json.dumps(manifest))
    (root / "ui/world.json").write_text(json.dumps({"id": "local-line", "version": version}))
    (root / "ui/index.html").write_text('<html><script src="static/world.js"></script></html>')
    (root / "ui/static/world.js").write_text('"use strict";')
    return root


def zip_plugin(root: Path, path: Path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as package:
        for file in sorted(root.rglob("*")):
            if file.is_file():
                package.write(file, str(file.relative_to(root)))
    return path, hashlib.sha256(path.read_bytes()).hexdigest()


def install_fixture(tmp_path, version="0.2.0", state=None):
    source = plugin(tmp_path / ("source-" + version), version)
    archive, pin = zip_plugin(source, tmp_path / (version + ".zip"))
    report = installer.review(archive, pin)
    state = state or tmp_path / "state"
    installed = installer.install(archive, pin, report["plugin_digest"], state, workspace=str(tmp_path / "workspace"))
    return archive, pin, report, installed, state


def test_review_lists_exact_content_without_creating_extension_state(tmp_path):
    source = plugin(tmp_path / "source")
    archive, pin = zip_plugin(source, tmp_path / "world.zip")
    extracted = tmp_path / "review-files"
    report = installer.review(archive, pin, extracted)
    assert report["installation_id"] == "locus/agent-world"
    assert report["file_count"] == 4
    assert report["files"] == [{"path": str(p.relative_to(source)), "bytes": p.stat().st_size,
                                "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                               for p in sorted(source.rglob("*")) if p.is_file()]
    assert not (tmp_path / "state").exists()
    with pytest.raises(FileExistsError): installer.review(archive, pin, extracted)


def test_install_preserves_identity_existing_marketplaces_and_workspace_scopes(tmp_path):
    archive, pin, report, installed, state = install_fixture(tmp_path)
    assert installed["installation_id"] == "locus/agent-world"
    assert installed["enabled_workspaces"] == [str(tmp_path / "workspace")]
    assert not installed["enabled_global"]
    data = installer.read_state(state)
    data["marketplaces"].append({"id": "locus", "name": "Existing catalog", "catalog": []})
    data["plugins"][0]["disabled_workspaces"] = [str(tmp_path / "private")]
    (state / "state.json").write_text(json.dumps(data))
    again = installer.install(archive, pin, report["plugin_digest"], state, scope="global")
    after = installer.read_state(state)
    assert again["enabled_workspaces"] == installed["enabled_workspaces"]
    assert not again["enabled_global"]
    assert after["marketplaces"] == data["marketplaces"]
    assert after["plugins"][0]["disabled_workspaces"] == data["plugins"][0]["disabled_workspaces"]
    assert len(after["plugins"]) == 1


def test_upgrade_and_reviewed_rollback_use_atomic_manager_versions(tmp_path):
    _, _, first, _, state = install_fixture(tmp_path)
    _, _, second, installed, _ = install_fixture(tmp_path, "0.2.1", state)
    assert installed["previous_versions"] == ["0.2.0"]
    restored = installer.rollback(state, second["plugin_digest"], first["plugin_digest"])
    assert restored["version"] == "0.2.0"
    assert restored["plugin_digest"] == first["plugin_digest"]
    assert restored["enabled_workspaces"] == installed["enabled_workspaces"]
    assert installer._tree_digest(Path(restored["root"])) == first["plugin_digest"]


def test_explicit_legacy_upgrade_keeps_old_cache_and_does_not_touch_domain_state(tmp_path):
    state = tmp_path / "state"
    old = plugin(tmp_path / "legacy", "0.1.1", 1)
    manager = installer.ArtifactManager(str(tmp_path), root=state)
    manager.artifact = old
    old_digest = installer._tree_digest(old)
    manager.install_plugin("locus", "agent-world", scope="workspace", workspace=str(tmp_path), expected_digest=old_digest)
    canonical = tmp_path / "profiles-and-conversations.json"
    canonical.write_text('{"do-not-change":true}')
    source = plugin(tmp_path / "candidate")
    archive, pin = zip_plugin(source, tmp_path / "candidate.zip")
    digest = installer.review(archive, pin)["plugin_digest"]
    before = (state / "state.json").read_bytes()
    with pytest.raises(ValueError, match="upgrade-legacy-v1"):
        installer.install(archive, pin, digest, state, workspace=str(tmp_path))
    assert (state / "state.json").read_bytes() == before
    upgraded = installer.install(archive, pin, digest, state, workspace=str(tmp_path), upgrade_legacy_v1=True)
    assert upgraded["capability_diff"]["requires_renewed_trust"]
    assert upgraded["previous_versions"] == ["0.1.1"]
    installer.rollback(state, digest, old_digest)
    assert canonical.read_text() == '{"do-not-change":true}'


def test_stale_review_or_bad_archive_pin_never_changes_state(tmp_path):
    archive, pin, _, _, state = install_fixture(tmp_path)
    before = (state / "state.json").read_bytes()
    with pytest.raises(ValueError, match="SHA-256"):
        installer.install(archive, "0" * 64, "0" * 64, state, workspace=str(tmp_path))
    with pytest.raises(ValueError, match="after review"):
        installer.install(archive, pin, "0" * 64, state, workspace=str(tmp_path))
    assert (state / "state.json").read_bytes() == before


@pytest.mark.parametrize("name,mode", [("../escape", 0), ("ui/link", stat.S_IFLNK | 0o777), ("ui/outpost/old.js", 0)])
def test_unsafe_zip_content_rejected_before_install(tmp_path, name, mode):
    archive = tmp_path / "bad.zip"
    with zipfile.ZipFile(archive, "w") as package:
        item = zipfile.ZipInfo(name)
        item.external_attr = mode << 16
        package.writestr(item, "bad")
    with pytest.raises(ValueError): installer.review(archive, installer.sha256(archive))


def test_corrupt_state_is_not_replaced_by_degraded_defaults(tmp_path):
    source = plugin(tmp_path / "source")
    archive, pin = zip_plugin(source, tmp_path / "world.zip")
    state = tmp_path / "state"
    state.mkdir()
    (state / "state.json").write_text("corrupt")
    with pytest.raises(ValueError):
        installer.install(archive, pin, installer.review(archive, pin)["plugin_digest"], state, workspace=str(tmp_path))
    assert (state / "state.json").read_text() == "corrupt"


def test_failed_state_commit_leaves_previous_active_version_intact(tmp_path, monkeypatch):
    _, _, first, _, state = install_fixture(tmp_path)
    source = plugin(tmp_path / "source-new", "0.2.1")
    archive, pin = zip_plugin(source, tmp_path / "new.zip")
    digest = installer.review(archive, pin)["plugin_digest"]
    before = (state / "state.json").read_bytes()
    def fail(_): raise OSError("injected state commit failure")
    monkeypatch.setattr(installer.ArtifactManager, "_save", fail)
    with pytest.raises(OSError, match="injected"):
        installer.install(archive, pin, digest, state, workspace=str(tmp_path))
    assert (state / "state.json").read_bytes() == before
    assert installer.read_state(state)["plugins"][0]["digest"] == first["plugin_digest"]


def test_rollback_rejects_changed_current_and_tampered_previous(tmp_path):
    _, _, first, _, state = install_fixture(tmp_path)
    _, _, second, _, _ = install_fixture(tmp_path, "0.2.1", state)
    before = (state / "state.json").read_bytes()
    with pytest.raises(ValueError, match="changed"):
        installer.rollback(state, "0" * 64, first["plugin_digest"])
    previous = installer.read_state(state)["plugins"][0]["previous"][0]
    (Path(previous["root"]) / "ui/static/world.js").write_text("tampered")
    with pytest.raises(ValueError, match="no longer match"):
        installer.rollback(state, second["plugin_digest"], first["plugin_digest"])
    assert (state / "state.json").read_bytes() == before


def test_development_directory_is_explicit_marked_snapshot_with_rereview(tmp_path):
    source = plugin(tmp_path / "development")
    original = (source / ".codex-plugin/plugin.json").read_bytes()
    with pytest.raises(ValueError, match="checksum"):
        installer.review(None, "../untrusted", development_directory=source)
    report = installer.review(None, None, development_directory=source)
    assert report["mode"] == "development" and report["artifact_sha256"] is None
    assert report["manifest"]["interface"]["displayName"] == "Agent Worlds (development)"
    assert report["manifest"]["locus"]["screens"][0]["title"] == "Agent Worlds (development)"
    result = installer.install(None, None, report["plugin_digest"], tmp_path / "state", workspace=str(tmp_path), development_directory=source)
    assert result["mode"] == "development"
    assert (source / ".codex-plugin/plugin.json").read_bytes() == original
    (source / "ui/static/world.js").write_text("new build")
    assert (Path(result["root"]) / "ui/static/world.js").read_text() == '"use strict";'
    with pytest.raises(ValueError, match="after review"):
        installer.install(None, None, report["plugin_digest"], tmp_path / "state", workspace=str(tmp_path), development_directory=source)
    (source / "ui/link").symlink_to(tmp_path)
    with pytest.raises(ValueError, match="symbolic"):
        installer.review(None, None, development_directory=source)


def test_wrong_metadata_shape_fails_before_touching_state(tmp_path):
    source = plugin(tmp_path / "source")
    path = source / ".codex-plugin/plugin.json"
    manifest = json.loads(path.read_text())
    manifest["agentWorlds"] = False
    path.write_text(json.dumps(manifest))
    archive, pin = zip_plugin(source, tmp_path / "wrong-metadata.zip")
    with pytest.raises(ValueError, match="metadata"):
        installer.review(archive, pin)
    manifest["interface"] = False
    path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="development manifest"):
        installer.review(None, None, development_directory=source)
