#!/usr/bin/env python3
"""Validate every catalog theme in Agent World without starting Locus or Meshy."""
from __future__ import annotations

import hashlib
import json
import re
import struct
import sys
from pathlib import Path


SHIP_NAMES = {
    "thousand_sunny", "going_merry", "baratie", "navy_h03", "polar_tang",
    "spade_pirates", "red_force", "moby_dick", "perfume_yuda", "oro_jackson",
    "queen_mama_chanter", "dragons_ship",
}
EXTERNAL_DECODERS = {
    "KHR_draco_mesh_compression", "KHR_texture_basisu", "EXT_meshopt_compression",
}


def local_file(root: Path, relative: str) -> Path:
    assert isinstance(relative, str) and relative and not Path(relative).is_absolute()
    path = (root / relative).resolve()
    assert path.is_relative_to(root.resolve()), f"Path escapes theme: {relative}"
    assert path.is_file(), f"Missing packaged file: {path}"
    return path


def verify_public_provenance(value: object, *, theme_id: str, key: str = "") -> None:
    """Provider responses and credentials belong only in private generation state."""
    if isinstance(value, dict):
        for name, child in value.items():
            assert name.lower() not in {
                "api_key", "apikey", "authorization", "access_token", "secret",
                "password", "credential", "credentials", "download_url", "model_urls",
                "thumbnail_url", "image_urls", "texture_urls",
            }, f"Private generation field in provenance: {name}"
            verify_public_provenance(child, theme_id=theme_id, key=name)
    elif isinstance(value, list):
        for child in value:
            verify_public_provenance(child, theme_id=theme_id, key=key)
    elif isinstance(value, str):
        assert not re.search(r"\b(?:msy_[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{16,}|Bearer\s+\S+)", value), "Credential in provenance"
        # Preserve the original outpost's public pricing citation; generated URLs never ship.
        if re.search(r"https?://", value):
            assert theme_id == "outpost" and key == "pricing_source" and value == "https://docs.meshy.ai/en/api/pricing", "Remote URL in provenance"


def verify_glb(path: Path, *, humanoid: bool, ship: bool) -> dict:
    data = path.read_bytes()
    assert len(data) >= 20, f"Truncated GLB: {path}"
    magic, version, length = struct.unpack_from("<4sII", data)
    assert magic == b"glTF" and version == 2 and length == len(data), path
    chunk_length, chunk_type = struct.unpack_from("<I4s", data, 12)
    assert chunk_type == b"JSON" and 20 + chunk_length <= len(data), path
    gltf = json.loads(data[20:20 + chunk_length])
    assert gltf.get("meshes"), f"Missing geometry: {path}"
    assert not set(gltf.get("extensionsRequired", [])) & EXTERNAL_DECODERS, "External decoder would be required"
    assert gltf.get("buffers") and all(not item.get("uri") for item in gltf["buffers"]), "GLB must embed buffers"
    assert all(not item.get("uri") for item in gltf.get("images", [])), "GLB must embed textures"
    for mesh in gltf["meshes"]:
        assert mesh.get("primitives"), f"Empty mesh: {path}"
        for primitive in mesh["primitives"]:
            positions = gltf["accessors"][primitive["attributes"]["POSITION"]]
            assert positions["count"] > 0, f"Empty geometry: {path}"
    if ship:
        assert gltf.get("materials") and gltf.get("images"), f"Ship must be textured: {path}"
        assert all("bufferView" in item for item in gltf["images"]), "Ship textures must be embedded"
        assert any(material.get("pbrMetallicRoughness", {}).get("baseColorTexture") is not None for material in gltf["materials"]), f"Missing ship color texture: {path}"
    if humanoid:
        assert gltf.get("skins"), f"Missing rig: {path.name}"
        clips = [animation.get("name", "").lower() for animation in gltf.get("animations", [])]
        assert any("idle" in clip for clip in clips), f"Missing idle animation: {path.name}"
        assert any("walk" in clip for clip in clips), f"Missing walk animation: {path.name}"
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "meshes": len(gltf["meshes"])}


def verify_theme(themes_root: Path, theme_id: str) -> dict:
    assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", theme_id), "Unsafe catalog theme ID"
    theme_root = themes_root / theme_id
    theme = json.loads(local_file(theme_root, "theme.json").read_text())
    assert theme["version"] == 1 and theme["id"] == theme_id, "Catalog/theme identity mismatch"
    provenance = json.loads(local_file(theme_root, "provenance.json").read_text())
    verify_public_provenance(provenance, theme_id=theme_id)
    assert 0 < provenance["reserved_credits"] < 1000
    assert 0 <= provenance["reported_credits"] <= provenance["reserved_credits"]
    tasks = provenance["tasks"]
    assert tasks and all(task["status"] == "SUCCEEDED" for task in tasks), f"Unfinished asset generation: {theme_id}"
    task_ids = {task["id"] for task in tasks}
    assert len(task_ids) == len(tasks), "Duplicated paid task in credit accounting"
    assert all(task["reserved_credits"] >= 0 and task.get("consumed_credits", 0) >= 0 for task in tasks)
    assert sum(max(task["reserved_credits"], task.get("consumed_credits", 0)) for task in tasks) == provenance["reserved_credits"]
    assert sum(task.get("consumed_credits", 0) for task in tasks) == provenance["reported_credits"]
    if campaigns := provenance.get("campaigns"):
        assert sum(campaign["reserved_credits"] for campaign in campaigns) == provenance["reserved_credits"]
        assert sum(campaign["reported_credits"] for campaign in campaigns) == provenance["reported_credits"]
    assert theme.get("assets") and set(theme["assets"]) == set(provenance["assets"]), "Manifest/provenance asset mismatch"
    if theme_id == "grand-line":
        assert theme.get("environment") == "ocean"
        assert set(theme["assets"]) == {"ship_" + name for name in SHIP_NAMES}, "The Local Line requires all twelve ships"
        assert provenance["reserved_credits"] == provenance["reported_credits"] == 648
        assert len(tasks) == 36, "Record all reference, baseline, and quality-pass tasks"
        for name in SHIP_NAMES:
            stages = {task["stage"]: task for task in tasks if task["asset"].removeprefix("ship_") == name}
            assert set(stages) == {"reference", "model", "upgrade"}, f"Incomplete generation history: {name}"
            for stage, credits in (("reference", 9), ("model", 15), ("upgrade", 30)):
                assert stages[stage]["reserved_credits"] == stages[stage]["consumed_credits"] == credits
            shipped = provenance["assets"]["ship_" + name]
            assert shipped["source_task_id"] == stages["upgrade"]["id"] and stages["upgrade"]["ai_model"] == "meshy-7"
            assert shipped["reference_task_id"] == stages["reference"]["id"]
        assert len(provenance.get("references", {})) == 12, "Missing retained ship references"
        assert provenance.get("source_attribution"), "Missing reference attribution"
        source = provenance["source_image"]
        assert hashlib.sha256(local_file(theme_root, source["path"]).read_bytes()).hexdigest() == source["sha256"]
    for reference in provenance.get("references", {}).values():
        assert hashlib.sha256(local_file(theme_root, reference["path"]).read_bytes()).hexdigest() == reference["sha256"]
        assert reference["task_id"] in task_ids, "Reference task missing from ledger"
    for name, relative in theme["assets"].items():
        path = local_file(theme_root, relative)
        stats = verify_glb(path, humanoid=name == "resident" or name.startswith("resident_"), ship=name.startswith("ship_"))
        assert stats["sha256"] == provenance["assets"][name]["sha256"], f"Asset hash mismatch: {path}"
        print(f"{theme_id}/{name}: {stats['bytes'] / 1_000_000:.2f} MB, {stats['meshes']} meshes")
    print(f"{theme_id}: commitments {provenance['reserved_credits']}; reported {provenance['reported_credits']} Meshy credits")
    return provenance


def verify_shared_assets(ui_root: Path) -> dict:
    """HUD artwork is shared across themes and counted once."""
    root = ui_root / "assets"
    provenance = json.loads(local_file(root, "provenance.json").read_text())
    verify_public_provenance(provenance, theme_id="shared")
    tasks = provenance["tasks"]
    assert len(tasks) == 2 and all(task["status"] == "SUCCEEDED" for task in tasks)
    assert {task["stage"] for task in tasks} == {"reference", "model"}
    assert len({task["id"] for task in tasks}) == len(tasks)
    assert sum(max(task["reserved_credits"], task.get("consumed_credits", 0)) for task in tasks) == provenance["reserved_credits"] == 44
    assert sum(task.get("consumed_credits", 0) for task in tasks) == provenance["reported_credits"] == 44
    artwork = provenance["assets"]["den_den_mushi"]
    model_task = next(task for task in tasks if task["stage"] == "model")
    assert model_task["ai_model"] == "meshy-7" and model_task["settings"]["ultra_mode"] is True
    assert artwork["source_task_id"] == model_task["id"]
    model = local_file(root, artwork["path"])
    stats = verify_glb(model, humanoid=False, ship=True)
    assert stats["sha256"] == artwork["sha256"], "Shared asset hash mismatch"
    reference = provenance["reference"]
    assert reference["task_id"] in {task["id"] for task in tasks}
    assert hashlib.sha256(local_file(root, reference["path"]).read_bytes()).hexdigest() == reference["sha256"]
    print(f"shared/den_den_mushi: {stats['bytes'] / 1_000_000:.2f} MB; 44 Meshy credits")
    return provenance


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
    themes_root = root / "ui/themes"
    catalog = json.loads((themes_root / "catalog.json").read_text())
    assert catalog["version"] == 1 and catalog["themes"], "Missing theme catalog"
    theme_ids = [entry["id"] for entry in catalog["themes"]]
    assert len(set(theme_ids)) == len(theme_ids), "Duplicate catalog theme"
    provenances = [verify_theme(themes_root, theme_id) for theme_id in theme_ids]
    provenances.append(verify_shared_assets(root / "ui"))
    task_ids = [task["id"] for provenance in provenances for task in provenance["tasks"]]
    assert len(set(task_ids)) == len(task_ids), "Paid task counted in more than one theme"
    html = (root / "ui/index.html").read_text()
    assert "<script" in html and "https://" not in html
    print(f"Package valid; {len(theme_ids)} themes; digest {_tree_digest(root)}")
    print(f"All-theme Meshy credits: commitments {sum(p['reserved_credits'] for p in provenances)}; reported {sum(p['reported_credits'] for p in provenances)}")


if __name__ == "__main__":
    main()
