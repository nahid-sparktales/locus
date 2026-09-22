#!/usr/bin/env python3
"""Validate every catalog theme in Agent World without starting Locus or Meshy.

Requires the agent Python dependencies and Pillow with WebP support to verify
decoded texture pixels in addition to package structure and provenance.
"""
from __future__ import annotations

import argparse
import hashlib
import gzip
import io
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
ISLAND_NAMES = {
    "island_twin_cape", "island_little_garden", "island_drum", "island_alabasta",
    "island_water_seven", "island_enies_lobby", "island_sabaody", "island_marineford",
    "island_wano", "island_whole_cake", "island_laugh_tale", "island_jaya",
    "island_skypiea", "scenery_red_line",
}
EXTRA_SHIP_NAMES = {"ship_mihawk_coffin", "ship_garp_battleship", "ship_marine_patrol"}
MOUNTAIN_NAMES = {"scenery_reverse_mountain"}
CREATURE_NAMES = {"creature_laboon", "creature_sea_king"}
NEW_WORLD_ISLAND_NAMES = {"island_elbaf", "island_egghead"}
MARINEFORD_ISLAND_NAMES = {"island_mary_geoise", "island_impel_down", "island_amazon_lily"}
SABAODY_ZUNESHA_NAMES = {"island_sabaody_archipelago", "creature_zunesha", "creature_momonosuke"}
BUDGET_ISLAND_NAMES = {"island_dressrosa", "island_punk_hazard", "island_hachinosu", "island_long_ring_long_land"}
GRAND_LINE_CAMPAIGNS = (
    ("islands_and_cliffs", ISLAND_NAMES, 546),
    ("extra_ships", EXTRA_SHIP_NAMES, 117),
    ("reverse_mountain", MOUNTAIN_NAMES, 39),
    ("sea_creatures", CREATURE_NAMES, 78),
    ("new_world_islands", NEW_WORLD_ISLAND_NAMES, 78),
    ("marineford_landmarks", MARINEFORD_ISLAND_NAMES, 117),
    ("sabaody_and_companions", SABAODY_ZUNESHA_NAMES, 117),
    ("budget_island_expansion", BUDGET_ISLAND_NAMES, 60),
)
NEW_MODEL_NAMES = set().union(*(names for _, names, _ in GRAND_LINE_CAMPAIGNS))
GRAND_LINE_ASSET_NAMES = {"ship_" + name for name in SHIP_NAMES} | NEW_MODEL_NAMES
GRAND_LINE_CREDITS = 648 + sum(credits for _, _, credits in GRAND_LINE_CAMPAIGNS)
ALL_THEME_CREDITS = GRAND_LINE_CREDITS + 209 + 44
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
        assert not value.startswith(("/Users/", "/home/", "file://")), "Private filesystem path in provenance"



def glb_payload(path: Path) -> bytes:
    """Decode the explicit local container with a bounded expansion budget."""
    if path.name.endswith('.glb.gz'):
        assert path.stat().st_size <= 64 * 1024 * 1024, 'Compressed model exceeds the local asset limit'
        with gzip.open(path, 'rb') as handle:
            data = handle.read(64 * 1024 * 1024 + 1)
            assert len(data) <= 64 * 1024 * 1024 and not handle.read(1), 'GLB container expands beyond its limit'
        return data
    return path.read_bytes()


def verify_container_encoding(path: Path, asset: dict) -> None:
    container = asset.get('container_encoding')
    assert bool(container) == path.name.endswith('.glb.gz'), 'Explicit GLB container metadata is required'
    if not container:
        return
    encoded = path.read_bytes()
    decoded = glb_payload(path)
    assert container['format'] == 'gzip' and container['compression_level'] == 9 and container['meshy_credits'] == 0
    assert container['geometry_unchanged'] is True and container['materials_unchanged'] is True and container['decoded_pixels_unchanged'] is True
    assert not Path(container['source_path']).is_absolute() and '..' not in Path(container['source_path']).parts
    assert container['source_path'].endswith('.glb')
    assert hashlib.sha256(decoded).hexdigest() == container['source_sha256']
    assert len(decoded) == container['source_bytes'] and len(encoded) == container['runtime_bytes'] == asset['runtime_bytes']
    assert len(encoded) < len(decoded) and hashlib.sha256(encoded).hexdigest() == asset['sha256']
    assert geometry_digest(path) == asset['geometry_sha256']

def verify_glb(path: Path, *, humanoid: bool, ship: bool) -> dict:
    encoded = path.read_bytes()
    data = glb_payload(path)
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
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "bytes": len(encoded), "meshes": len(gltf["meshes"])}



def verify_reference(root: Path, reference: dict) -> None:
    path = local_file(root, reference['path'])
    payload = path.read_bytes()
    assert hashlib.sha256(payload).hexdigest() == reference['sha256'], f'Reference hash mismatch: {path.name}'
    if encoding := reference.get('encoding'):
        from PIL import Image
        assert encoding == {'format': 'JPEG', 'quality': 94, 'subsampling': 0,
                            'dimensions_unchanged': True, 'purpose': 'reference_artwork'}
        assert path.suffix == '.jpg' and payload[:3] == b'\xff\xd8\xff'
        image = Image.open(io.BytesIO(payload))
        assert image.format == 'JPEG' and list(image.size) == reference['dimensions']
        image.verify()
        assert len(payload) == reference['bytes'] < reference['source_bytes']
        assert re.fullmatch(r'[0-9a-f]{64}', reference['source_sha256'])
        assert not Path(reference['source_path']).is_absolute() and '..' not in Path(reference['source_path']).parts
        assert Path(reference['source_path']).suffix == '.png'


def verify_texture_encoding(path: Path, asset: dict) -> None:
    encoding = asset.get('texture_encoding')
    if not encoding:
        return
    from PIL import Image
    from OptimizeGrandLineAssets import parse_glb, view_bytes
    payload = glb_payload(path)
    gltf, binary = parse_glb(payload)
    assert encoding['operation'] == 'lossless_png_to_webp' and encoding['meshy_credits'] == 0
    assert encoding['geometry_unchanged'] is True and encoding['decoded_pixels_unchanged'] is True
    assert geometry_digest(path) == asset['geometry_sha256'] and asset['geometry_unchanged'] is True
    container = asset.get('container_encoding', {})
    assert hashlib.sha256(payload).hexdigest() == container.get('source_sha256', asset['sha256'])
    assert len(payload) == encoding['runtime_bytes'] == container.get('source_bytes', asset['runtime_bytes']) < encoding['source_bytes']
    assert re.fullmatch(r'[0-9a-f]{64}', encoding['source_sha256'])
    assert not Path(encoding['source_path']).is_absolute() and '..' not in Path(encoding['source_path']).parts
    assert len(encoding['images']) == len(gltf['images'])
    converted = set()
    for index, (image, metadata) in enumerate(zip(gltf['images'], encoding['images'])):
        encoded = view_bytes(gltf, binary, image['bufferView'])
        decoded = Image.open(io.BytesIO(encoded)).convert('RGBA')
        assert metadata['index'] == index and metadata['mime_type'] == image['mimeType']
        assert len(encoded) == metadata['bytes'] and hashlib.sha256(encoded).hexdigest() == metadata['encoded_sha256']
        assert list(decoded.size) == metadata['dimensions'] and hashlib.sha256(decoded.tobytes()).hexdigest() == metadata['rgba_sha256']
        if image['mimeType'] == 'image/webp':
            assert metadata['source_mime_type'] == 'image/png' and metadata['bytes'] < metadata['source_bytes']
            assert encoded[:4] == b'RIFF' and encoded[8:12] == b'WEBP' and b'VP8L' in encoded[:40], 'Require lossless WebP'
            converted.add(index)
        else:
            assert metadata['mime_type'] == metadata['source_mime_type'] and metadata['bytes'] == metadata['source_bytes']
    assert converted and 'EXT_texture_webp' in gltf['extensionsUsed'] and 'EXT_texture_webp' in gltf['extensionsRequired']
    referenced = set()
    for texture in gltf.get('textures', []):
        assert texture.get('source') not in converted, 'WebP must use the standard glTF extension'
        if extension := texture.get('extensions', {}).get('EXT_texture_webp'):
            assert set(extension) == {'source'} and extension['source'] in converted
            assert 'source' not in texture, 'This package uses a required WebP extension without PNG fallback'
            referenced.add(extension['source'])
    assert referenced == converted, 'Unreferenced WebP image'

def geometry_digest(path: Path) -> str:
    """Match the optimizer's geometry fingerprint without decoding any textures."""
    data = glb_payload(path)
    assert struct.unpack_from("<4sII", data) == (b"glTF", 2, len(data)), path
    offset, chunks = 12, []
    while offset < len(data):
        length, kind = struct.unpack_from("<I4s", data, offset)
        assert length % 4 == 0 and offset + 8 + length <= len(data), path
        chunks.append((kind, data[offset + 8:offset + 8 + length]))
        offset += 8 + length
    assert [kind for kind, _ in chunks] == [b"JSON", b"BIN\x00"], path
    gltf, binary = json.loads(chunks[0][1]), chunks[1][1]
    assert len(gltf["buffers"]) == 1 and not gltf["buffers"][0].get("uri"), path
    assert gltf["buffers"][0]["byteLength"] <= len(binary), path
    image_views = {image["bufferView"] for image in gltf["images"]}
    for accessor in gltf["accessors"]:
        assert accessor.get("bufferView") not in image_views, "Image and geometry share a buffer view"
        for sparse in accessor.get("sparse", {}).values():
            if isinstance(sparse, dict):
                assert sparse.get("bufferView") not in image_views
    metadata = json.dumps({key: gltf.get(key) for key in
                           ("accessors", "meshes", "nodes", "scenes", "scene", "skins", "animations")}, sort_keys=True).encode()
    digest = hashlib.sha256(metadata)
    for index, view in enumerate(gltf["bufferViews"]):
        start, length = view.get("byteOffset", 0), view["byteLength"]
        assert view.get("buffer", 0) == 0 and start >= 0 and length > 0 and start + length <= len(binary), path
        if index not in image_views:
            digest.update(binary[start:start + length])
    return digest.hexdigest()


def verify_grand_line_history(theme: dict, provenance: dict, *, require_complete: bool = True) -> None:
    """Allow only complete approved campaigns; the distributable requires all three."""
    assets, references, tasks = provenance["assets"], provenance["references"], provenance["tasks"]
    assert theme.get("environment") == "ocean"
    assert set(theme["assets"]) == set(assets), "Manifest/provenance asset mismatch"
    assert {"ship_" + name for name in SHIP_NAMES} <= set(assets) <= GRAND_LINE_ASSET_NAMES
    present = []
    for campaign, names, credits in GRAND_LINE_CAMPAIGNS:
        included = set(assets) & names
        assert not included or included == names, f"Incomplete published campaign: {campaign}"
        if included:
            present.append((campaign, names, credits))
    if require_complete:
        assert set(assets) == GRAND_LINE_ASSET_NAMES, "The Local Line requires every approved ship, island and creature"
        assert len(tasks) == 36 + 2 * len(NEW_MODEL_NAMES) and len(references) == len(GRAND_LINE_ASSET_NAMES), "Retain all paid tasks and reference artwork"
    expected_names = SHIP_NAMES | set().union(*(names for _, names, _ in present))
    assert set(references) == expected_names, "Reference artwork must match every original ship and completed campaign"
    assert len(tasks) == 36 + sum(len(names) * 2 for _, names, _ in present), "Unexpected or missing paid generation history"
    assert {task["asset"] for task in tasks} == expected_names, "Unknown asset in generation history"
    task_ids = [task["id"] for task in tasks]
    assert len(set(task_ids)) == len(task_ids), "Duplicated paid task in credit accounting"
    expected_credits = 648 + sum(credits for _, _, credits in present)
    assert provenance["reserved_credits"] == provenance["reported_credits"] == provenance["credit_ceiling"] == expected_credits
    assert all(task["status"] == "SUCCEEDED" for task in tasks), "Incomplete paid task"
    assert sum(task["reserved_credits"] for task in tasks) == sum(task["consumed_credits"] for task in tasks) == expected_credits
    campaigns = provenance.get("campaigns", [])
    indexed = {item["name"]: item for item in campaigns}
    assert len(indexed) == len(campaigns), "Duplicated campaign accounting"
    expected_campaigns = {"ship_references_and_two_model_passes": 648, **{name: credits for name, _, credits in present}}
    assert set(indexed) == set(expected_campaigns), "Published campaigns do not match asset history"
    for name, credits in expected_campaigns.items():
        assert indexed[name]["reserved_credits"] == indexed[name]["reported_credits"] == credits
        if name != "ship_references_and_two_model_passes":
            assert indexed[name]["approved_credits"] == credits, "Campaign approval does not match its actual cost"
    for name in SHIP_NAMES:
        history = [task for task in tasks if task["asset"] == name]
        stages = {task["stage"]: task for task in history}
        assert len(history) == 3 and set(stages) == {"reference", "model", "upgrade"}, f"Incomplete generation history: {name}"
        for stage, credits in (("reference", 9), ("model", 15), ("upgrade", 30)):
            assert stages[stage]["reserved_credits"] == stages[stage]["consumed_credits"] == credits
        shipped = assets["ship_" + name]
        assert shipped["source_task_id"] == stages["upgrade"]["id"] and stages["upgrade"]["ai_model"] == "meshy-7"
        assert shipped["reference_task_id"] == references[name]["task_id"] == stages["reference"]["id"]
    for _, names, _ in present:
        for name in names:
            history = [task for task in tasks if task["asset"] == name]
            stages = {task["stage"]: task for task in history}
            preview_stage = "preview" if name in BUDGET_ISLAND_NAMES else "reference"
            assert len(history) == 2 and set(stages) == {preview_stage, "model"}, f"Incomplete generation history: {name}"
            costs = (("preview", 5), ("model", 10)) if name in BUDGET_ISLAND_NAMES else (("reference", 9), ("model", 30))
            for stage, credits in costs:
                assert stages[stage]["reserved_credits"] == stages[stage]["consumed_credits"] == credits
            settings = stages["model"]["settings"]
            if name in BUDGET_ISLAND_NAMES:
                assert stages["preview"]["ai_model"] == "meshy-t2"
                preview_settings = stages["preview"]["settings"]
                assert preview_settings["mode"] == "preview" and preview_settings["model_type"] == "smart-topology"
                assert preview_settings["target_polycount"] == 15000
                assert stages["model"]["ai_model"] == "meshy-7.1"
                assert settings["mode"] == "refine" and settings["enable_pbr"] is True
                assert settings["preview_task_id"] == references[name]["task_id"] == stages["preview"]["id"]
            else:
                assert stages["reference"]["ai_model"] == "nano-banana-pro"
                assert stages["model"]["ai_model"] == "meshy-7"
                assert settings["target_polycount"] == 40000 and settings["should_texture"] is True and settings["enable_pbr"] is True
                assert settings["input_task_id"] == references[name]["task_id"] == stages["reference"]["id"]
            assert assets[name]["source_task_id"] == stages["model"]["id"]
            assert assets[name]["reference_task_id"] == stages[preview_stage]["id"]
            assert assets[name]["path"] == theme["assets"][name]
            assert assets[name]["geometry_unchanged"] is True
            for key in ("source_sha256", "sha256", "geometry_sha256"):
                assert re.fullmatch(r"[0-9a-f]{64}", assets[name][key]), f"Invalid {key}: {name}"
            assert 0 < assets[name]["runtime_bytes"] <= assets[name]["source_bytes"]
    assert provenance.get("source_attribution"), "Missing reference attribution"


def verify_theme(themes_root: Path, theme_id: str, *, require_complete: bool = True) -> dict:
    assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", theme_id), "Unsafe catalog theme ID"
    theme_root = themes_root / theme_id
    theme = json.loads(local_file(theme_root, "theme.json").read_text())
    assert theme["version"] == 1 and theme["id"] == theme_id, "Catalog/theme identity mismatch"
    provenance = json.loads(local_file(theme_root, "provenance.json").read_text())
    verify_public_provenance(provenance, theme_id=theme_id)
    assert 0 < provenance["reserved_credits"] <= (GRAND_LINE_CREDITS if theme_id == "grand-line" else 999)
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
        verify_grand_line_history(theme, provenance, require_complete=require_complete)
        source = provenance["source_image"]
        verify_reference(theme_root, source)
    if require_complete or theme_id != "grand-line":
        model_files = {path.relative_to(theme_root).as_posix() for path in (theme_root / "assets").iterdir()
                       if path.is_file() and (path.name.endswith(".glb") or path.name.endswith(".glb.gz"))}
        assert model_files == set(theme["assets"].values()), "Untracked or duplicate runtime model in package"
        if theme_id == "grand-line":
            reference_files = {path.relative_to(theme_root).as_posix() for path in (theme_root / "references").iterdir() if path.is_file()}
            expected_references = {ref["path"] for ref in provenance["references"].values()} | {provenance["source_image"]["path"]}
            assert reference_files == expected_references, "Reference inventory does not match retained artwork"
    for reference in provenance.get("references", {}).values():
        verify_reference(theme_root, reference)
        assert reference["task_id"] in task_ids, "Reference task missing from ledger"
    for name, relative in theme["assets"].items():
        path = local_file(theme_root, relative)
        stats = verify_glb(path, humanoid=name == "resident" or name.startswith("resident_"), ship=name.startswith("ship_") or name in NEW_MODEL_NAMES)
        assert stats["sha256"] == provenance["assets"][name]["sha256"], f"Asset hash mismatch: {path}"
        verify_container_encoding(path, provenance["assets"][name])
        verify_texture_encoding(path, provenance["assets"][name])
        if name in NEW_MODEL_NAMES:
            assert stats["bytes"] == provenance["assets"][name]["runtime_bytes"], f"Runtime byte count mismatch: {name}"
            assert geometry_digest(path) == provenance["assets"][name]["geometry_sha256"], f"Geometry fingerprint mismatch: {name}"
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
    verify_reference(root, reference)
    print(f"shared/den_den_mushi: {stats['bytes'] / 1_000_000:.2f} MB; 44 Meshy credits")
    return provenance


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-incomplete-campaigns", action="store_true", help="Validate completed campaigns during generation; the release gate still requires every approved campaign")
    args = parser.parse_args()
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
    provenances = [verify_theme(themes_root, theme_id, require_complete=not args.allow_incomplete_campaigns) for theme_id in theme_ids]
    provenances.append(verify_shared_assets(root / "ui"))
    task_ids = [task["id"] for provenance in provenances for task in provenance["tasks"]]
    assert len(set(task_ids)) == len(task_ids), "Paid task counted in more than one theme"
    html = (root / "ui/index.html").read_text()
    assert "<script" in html and "https://" not in html
    print(f"Package valid{' (completed campaigns; final campaign gate skipped)' if args.allow_incomplete_campaigns else ''}; {len(theme_ids)} themes; digest {_tree_digest(root)}")
    total_reserved = sum(p["reserved_credits"] for p in provenances)
    total_reported = sum(p["reported_credits"] for p in provenances)
    assert total_reserved == total_reported
    if not args.allow_incomplete_campaigns:
        assert total_reserved == ALL_THEME_CREDITS, "Lifetime credit total does not match all retained campaigns"
    print(f"All-theme Meshy credits: commitments {total_reserved}; reported {total_reported}")


if __name__ == "__main__":
    main()
