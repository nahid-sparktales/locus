#!/usr/bin/env python3
"""Validate the distributable Agent World plugin without starting Locus or Meshy."""
from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo / "agent"))
    from ollama_code.extensions import _tree_digest, parse_plugin

    root = repo / "plugins/agent-world"
    plugin = parse_plugin(root)
    assert plugin["name"] == "agent-world"
    assert len(plugin["screens"]) == 1
    assert not plugin["skills"] and not plugin["mcp_servers"]
    assert not plugin["unsupported"]
    theme_root = root / "ui/themes/outpost"
    theme = json.loads((theme_root / "theme.json").read_text())
    assert theme["version"] == 1 and theme["id"] == "outpost"
    provenance = json.loads((theme_root / "provenance.json").read_text())
    assert provenance["reserved_credits"] < 1000
    assert provenance["reported_credits"] <= provenance["reserved_credits"]
    tasks = provenance["tasks"]
    assert tasks and all(task["status"] == "SUCCEEDED" for task in tasks), "Unfinished asset generation"
    assert len({task["id"] for task in tasks}) == len(tasks), "Duplicated paid task in credit accounting"
    assert sum(max(task["reserved_credits"], task.get("consumed_credits", 0)) for task in tasks) == provenance["reserved_credits"]
    assert sum(task.get("consumed_credits", 0) for task in tasks) == provenance["reported_credits"]
    if campaigns := provenance.get("campaigns"):
        assert sum(campaign["reserved_credits"] for campaign in campaigns) == provenance["reserved_credits"]
        assert sum(campaign["reported_credits"] for campaign in campaigns) == provenance["reported_credits"]
    for name, relative in theme["assets"].items():
        path = (theme_root / relative).resolve()
        assert path.is_relative_to(theme_root.resolve())
        data = path.read_bytes()
        magic, version, length = struct.unpack_from("<4sII", data)
        assert magic == b"glTF" and version == 2 and length == len(data), path
        chunk_length, chunk_type = struct.unpack_from("<I4s", data, 12)
        assert chunk_type == b"JSON"
        gltf = json.loads(data[20:20 + chunk_length])
        assert gltf.get("meshes"), path
        assert not set(gltf.get("extensionsRequired", [])) & {"KHR_draco_mesh_compression", "KHR_texture_basisu", "EXT_meshopt_compression"}, "External decoder would be required"
        assert all(not item.get("uri") for item in gltf.get("buffers", [])), "GLB must embed buffers"
        assert all(not item.get("uri") for item in gltf.get("images", [])), "GLB must embed textures"
        assert hashlib.sha256(data).hexdigest() == provenance["assets"][name]["sha256"]
        if name == "resident" or name.startswith("resident_"):
            assert gltf.get("skins"), f"Missing rig: {name}"
            clips = [a.get("name", "").lower() for a in gltf.get("animations", [])]
            assert any("idle" in clip for clip in clips), f"Missing idle animation: {name}"
            assert any("walk" in clip for clip in clips), f"Missing walk animation: {name}"
        print(f"{name}: {len(data) / 1_000_000:.2f} MB, {len(gltf['meshes'])} meshes")
    html = (root / "ui/index.html").read_text()
    assert "<script" in html and "https://" not in html
    print(f"Package valid; digest {_tree_digest(root)}")
    print(f"Meshy credit commitments: {provenance['reserved_credits']}; reported: {provenance['reported_credits']}")


if __name__ == "__main__":
    main()
