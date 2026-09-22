#!/usr/bin/env python3
"""Prepare local ship textures for Agent World without changing mesh geometry.

Keeps original GLBs in a private source directory, embeds 2K color / 1K PBR
textures, and writes a private packaging report. Makes no network or Meshy calls.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import struct

from PIL import Image


SHIPS = (
    "thousand_sunny", "going_merry", "baratie", "navy_h03", "polar_tang",
    "spade_pirates", "red_force", "moby_dick", "perfume_yuda", "oro_jackson",
    "queen_mama_chanter", "dragons_ship",
)
GEOMETRY_KEYS = ("accessors", "meshes", "nodes", "scenes", "scene", "skins", "animations")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_glb(data: bytes) -> tuple[dict, bytes]:
    assert len(data) >= 28
    assert struct.unpack_from("<4sII", data) == (b"glTF", 2, len(data))
    offset, chunks = 12, []
    while offset < len(data):
        length, kind = struct.unpack_from("<I4s", data, offset)
        assert length % 4 == 0 and offset + 8 + length <= len(data)
        chunks.append((kind, data[offset + 8:offset + 8 + length]))
        offset += 8 + length
    assert [kind for kind, _ in chunks] == [b"JSON", b"BIN\x00"]
    gltf = json.loads(chunks[0][1])
    assert len(gltf["buffers"]) == 1 and not gltf["buffers"][0].get("uri")
    assert gltf["buffers"][0]["byteLength"] <= len(chunks[1][1])
    assert not set(gltf.get("extensionsRequired", [])) & {
        "KHR_draco_mesh_compression", "KHR_texture_basisu", "EXT_meshopt_compression",
    }
    assert all(not image.get("uri") and "bufferView" in image for image in gltf["images"])
    assert all(view.get("buffer", 0) == 0 for view in gltf["bufferViews"])
    return gltf, chunks[1][1]


def view_bytes(gltf: dict, binary: bytes, index: int) -> bytes:
    view = gltf["bufferViews"][index]
    offset, length = view.get("byteOffset", 0), view["byteLength"]
    assert offset >= 0 and length > 0 and offset + length <= len(binary)
    return binary[offset:offset + length]


def geometry_digest(gltf: dict, binary: bytes) -> str:
    image_views = {image["bufferView"] for image in gltf["images"]}
    for accessor in gltf["accessors"]:
        assert accessor.get("bufferView") not in image_views, "Image and geometry share a buffer view"
        for sparse in accessor.get("sparse", {}).values():
            if isinstance(sparse, dict):
                assert sparse.get("bufferView") not in image_views
    metadata = json.dumps({key: gltf.get(key) for key in GEOMETRY_KEYS}, sort_keys=True).encode()
    payload = b"".join(view_bytes(gltf, binary, i) for i in range(len(gltf["bufferViews"])) if i not in image_views)
    return digest(metadata + payload)


def pack_glb(gltf: dict, binary: bytes) -> bytes:
    encoded = json.dumps(gltf, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    binary += b"\x00" * (-len(binary) % 4)
    total = 12 + 8 + len(encoded) + 8 + len(binary)
    return (struct.pack("<4sII", b"glTF", 2, total)
            + struct.pack("<I4s", len(encoded), b"JSON") + encoded
            + struct.pack("<I4s", len(binary), b"BIN\x00") + binary)


def optimize(source: bytes, *, color_size: int = 2048, pbr_size: int = 1024) -> tuple[bytes, dict]:
    assert color_size in (512, 1024, 2048) and pbr_size in (256, 512, 1024)
    original, original_binary = parse_glb(source)
    gltf = copy.deepcopy(original)
    colors, alpha_colors = set(), set()
    for material in gltf.get("materials", []):
        color = material.get("pbrMetallicRoughness", {}).get("baseColorTexture")
        if color is not None:
            image_id = gltf["textures"][color["index"]]["source"]
            colors.add(image_id)
            if material.get("alphaMode", "OPAQUE") != "OPAQUE":
                alpha_colors.add(image_id)
    images, replacements = [], {}
    for index, image in enumerate(gltf["images"]):
        view = image["bufferView"]
        assert view not in replacements, "Shared image buffer view requires explicit handling"
        texture = Image.open(io.BytesIO(view_bytes(original, original_binary, view)))
        old_size = texture.size
        maximum = color_size if index in colors else pbr_size
        texture.thumbnail((maximum, maximum), Image.Resampling.LANCZOS)
        is_jpeg = index in colors and index not in alpha_colors
        encoded = io.BytesIO()
        if is_jpeg:
            texture.convert("RGB").save(encoded, format="JPEG", quality=94, subsampling=0, optimize=True)
            image["mimeType"] = "image/jpeg"
        else:
            if texture.mode not in ("RGB", "RGBA"):
                texture = texture.convert("RGBA" if "transparency" in texture.info else "RGB")
            texture.save(encoded, format="PNG", compress_level=6)
            image["mimeType"] = "image/png"
        replacements[view] = encoded.getvalue()
        assert abs(old_size[0] / old_size[1] - texture.width / texture.height) < 0.002
        images.append({"index": index, "role": "base_color" if index in colors else "pbr",
                       "source_size": list(old_size), "runtime_size": list(texture.size),
                       "mime_type": image["mimeType"]})
    binary = bytearray()
    for index, view in enumerate(gltf["bufferViews"]):
        binary.extend(b"\x00" * (-len(binary) % 4))
        payload = replacements.get(index, view_bytes(original, original_binary, index))
        view["byteOffset"], view["byteLength"] = len(binary), len(payload)
        binary.extend(payload)
    gltf["buffers"][0]["byteLength"] = len(binary)
    output = pack_glb(gltf, bytes(binary))
    checked, checked_binary = parse_glb(output)
    geometry_sha = geometry_digest(original, original_binary)
    assert geometry_sha == geometry_digest(checked, checked_binary), "Geometry changed"
    for key in ("materials", "textures", "samplers"):
        assert original.get(key) == checked.get(key), f"Material behavior changed: {key}"
    for image in checked["images"]:
        Image.open(io.BytesIO(view_bytes(checked, checked_binary, image["bufferView"]))).verify()
    return output, {"source_sha256": digest(source), "sha256": digest(output),
                    "source_bytes": len(source), "runtime_bytes": len(output),
                    "geometry_sha256": geometry_sha, "geometry_unchanged": True,
                    "images": images,
                    "source_texture_rgba_bytes": sum(w * h * 4 for item in images for w, h in [item["source_size"]]),
                    "runtime_texture_rgba_bytes": sum(w * h * 4 for item in images for w, h in [item["runtime_size"]])}


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    private = Path.home() / ".codex/agent-world-grand-line-generation"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-dir", type=Path, default=repo / "plugins/agent-world/ui/themes/grand-line/assets")
    parser.add_argument("--source-dir", type=Path, default=private / "source-4k")
    parser.add_argument("--report", type=Path, default=private / "optimization.json")
    args = parser.parse_args()
    assert not args.source_dir.resolve().is_relative_to(repo), "Originals must remain outside the repository"
    assert not args.report.resolve().is_relative_to(repo), "Write the report to private generation state"
    args.source_dir.mkdir(parents=True, exist_ok=True)
    report = {"operation": "runtime_texture_optimization", "meshy_credits": 0,
              "base_color_max_dimension": 2048, "base_color_jpeg_quality": 94,
              "pbr_max_dimension": 1024, "pbr_format": "PNG",
              "geometry_unchanged": True, "assets": {}}
    for name in SHIPS:
        target = args.asset_dir / (name + ".glb")
        source = args.source_dir / target.name
        if not source.exists():
            with source.open("xb") as handle:
                handle.write(target.read_bytes())
                handle.flush()
                os.fsync(handle.fileno())
        output, metadata = optimize(source.read_bytes())
        temporary = target.with_suffix(".glb.tmp")
        temporary.write_bytes(output)
        temporary.replace(target)
        report["assets"]["ship_" + name] = metadata
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(f"{name}: {metadata['source_bytes'] / 1e6:.2f} → {metadata['runtime_bytes'] / 1e6:.2f} MB; geometry unchanged", flush=True)
    report["source_bytes"] = sum(item["source_bytes"] for item in report["assets"].values())
    report["runtime_bytes"] = sum(item["runtime_bytes"] for item in report["assets"].values())
    for phase in ("source", "runtime"):
        total = sum(item[phase + "_texture_rgba_bytes"] for item in report["assets"].values())
        report[phase + "_texture_rgba_bytes"] = total
        report[phase + "_texture_rgba_with_mipmaps_estimate_bytes"] = round(total * 4 / 3)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Total: {report['source_bytes'] / 1e6:.2f} → {report['runtime_bytes'] / 1e6:.2f} MB")
    print(f"Texture RGBA estimate: {report['source_texture_rgba_bytes'] / 2**20:.0f} → {report['runtime_texture_rgba_bytes'] / 2**20:.0f} MiB before mipmaps; {report['runtime_texture_rgba_with_mipmaps_estimate_bytes'] / 2**20:.0f} MiB with mipmaps")


if __name__ == "__main__":
    main()
