#!/usr/bin/env python3
"""Verify a pinned Agent Worlds candidate through Locus's isolated real installer.

This rehearses installation and optional v1-to-v2 upgrade/rollback using disposable
state. It never modifies the user's installed plugins or treats native UI as tested.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import zipfile


def extract_candidate(archive: Path, expected_sha256: str, destination: Path) -> None:
    if archive.stat().st_size > 260 * 1024 * 1024:
        raise ValueError("Artifact exceeds the bounded ZIP size")
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if len(expected_sha256) != 64 or actual != expected_sha256.lower():
        raise ValueError("Artifact SHA-256 does not match the pin")
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if len(entries) > 5_000 or sum(item.file_size for item in entries) > 250 * 1024 * 1024:
            raise ValueError("Archive exceeds Locus package limits")
        seen: set[str] = set()
        for item in entries:
            name = item.filename
            parts = PurePosixPath(name).parts
            if not name or name.startswith("/") or "\\" in name or ":" in name or "%" in name \
                    or any(part in {"", ".", ".."} for part in name.split("/")) or name in seen \
                    or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError(f"Unsafe or duplicate archive entry: {name}")
            seen.add(name)
            if any(part in {".git", "node_modules", "outpost"} for part in parts):
                raise ValueError(f"Forbidden artifact content: {name}")
            target = destination.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.open(item) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output)


def verify(archive: Path, expected_sha256: str, previous: Path | None) -> dict:
    with tempfile.TemporaryDirectory(prefix="locus-agent-worlds-artifact-") as temp:
        root = Path(temp)
        # Set isolation before importing any application module.
        os.environ["OLLAMA_CODE_HOME"] = str(root / "app-state")
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
        from ollama_code.extensions import ExtensionError, ExtensionManager, _tree_digest, parse_plugin

        candidate = root / "candidate"
        extract_candidate(archive, expected_sha256, candidate)
        parsed = parse_plugin(candidate)
        assert parsed["name"] == "agent-world" and parsed["version"] == "0.2.0"
        assert len(parsed["screens"]) == 1 and parsed["screens"][0]["version"] == 2
        assert parsed["screens"][0]["id"] == "agent-world"
        assert parsed["screens"][0]["capabilities"] == ["agents.interact", "agents.read", "world.preferences"]
        assert not parsed["skills"] and not parsed["mcp_servers"] and not parsed["unsupported"]
        market = root / "market"
        active = market / "plugins/agent-world"
        active.parent.mkdir(parents=True)
        shutil.copytree(previous or candidate, active)
        (market / ".agents/plugins").mkdir(parents=True)
        (market / ".agents/plugins/marketplace.json").write_text(json.dumps({
            "name": "locus", "plugins": [{"name": "agent-world", "source": {
                "source": "local", "path": "./plugins/agent-world",
            }}],
        }))
        manager = ExtensionManager(str(root), root=root / "extension-state")
        source = manager.add_marketplace(str(market), name="locus")
        first = manager.inspect_catalog_plugin(source["id"], "agent-world")
        installed = manager.install_plugin(source["id"], "agent-world", scope="workspace", workspace=str(root), expected_digest=first["digest"])
        assert installed["id"] == "locus/agent-world"
        expected_scope = installed["enabled_workspaces"]
        rollback_verified = False
        if previous:
            shutil.rmtree(active)
            shutil.copytree(candidate, active)
            next_review = manager.inspect_catalog_plugin(source["id"], "agent-world")
            if first["plugin"]["screens"] != next_review["plugin"]["screens"]:
                assert next_review["capability_diff"]["requires_renewed_trust"]
            try:
                manager.update_plugin(installed["id"], expected_digest=first["digest"])
            except ExtensionError as error:
                assert "changed after trust review" in str(error)
            else:
                raise AssertionError("Upgrade accepted the stale trust digest")
            installed = manager.update_plugin(installed["id"], expected_digest=next_review["digest"])
            assert installed["version"] == "0.2.0" and installed["enabled_workspaces"] == expected_scope
            assert _tree_digest(Path(installed["root"])) == _tree_digest(candidate)
            rolled_back = manager.rollback_plugin(installed["id"])
            assert rolled_back["digest"] == first["digest"] and rolled_back["enabled_workspaces"] == expected_scope
            rollback_verified = True
            installed = manager.update_plugin(installed["id"], expected_digest=next_review["digest"])
        assert installed["screens"][0]["version"] == 2
        assert _tree_digest(Path(installed["root"])) == _tree_digest(candidate)
        disabled = manager.set_plugin_enabled(installed["id"], False, scope="workspace", workspace=str(root))
        assert str(root.resolve()) in disabled["disabled_workspaces"]
        manager.uninstall_plugin(installed["id"])
        assert not manager.snapshot()["plugins"]
        return {"artifact_sha256": expected_sha256, "plugin_digest": _tree_digest(candidate), "installation_id": "locus/agent-world", "version": "0.2.0", "protocol": 2,
                "install": "passed", "disable_uninstall": "passed", "upgrade_rollback": "passed" if rollback_verified else "not-requested",
                "native_integration": "not-tested"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--previous-plugin", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.artifact.resolve(), args.sha256, args.previous_plugin.resolve() if args.previous_plugin else None), indent=2))


if __name__ == "__main__":
    main()
