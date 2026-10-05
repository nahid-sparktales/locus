#!/usr/bin/env python3
"""Compile actual state frames into Locus's v1 or v2 atlas geometry.

Only deterministic pixel operations: identify connected foreground, crop the
existing pixels, remove alpha <= 4 matte residue, uniformly scale/translate all
frames in a resource, and leave unused cells transparent. No image synthesis,
repainting, frame duplication, or individual pose/baseline normalization.

Requires Pillow. Example:
  python Tools/PrepareCompanionAtlases.py --source Clover=/path/to/source.png \
      --output-dir Locus/Resources/Companions --preview-dir /tmp/companion-review
"""
from __future__ import annotations

import argparse
from collections import deque
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

COUNTS = (6, 8, 8, 4, 5, 8, 6, 6, 6)
V2_COUNTS = COUNTS + (8, 8)
CELL = (192, 208)
SIZE = (1536, 1872)
ALPHA_FLOOR = 4


def foreground_components(image: Image.Image) -> list[dict]:
    """Find complete frame silhouettes even when generated pixels cross a grid line."""
    width, height = image.size
    pixels = bytearray(image.getchannel("A").point(lambda a: 255 if a > 32 else 0).tobytes())
    result = []
    for start in range(len(pixels)):
        if not pixels[start]:
            continue
        pixels[start] = 0
        pending = deque([start])
        points = []
        left = right = start % width
        top = bottom = start // width
        total_x = total_y = 0
        while pending:
            index = pending.popleft()
            x, y = index % width, index // width
            points.append(index)
            total_x += x
            total_y += y
            left, right = min(left, x), max(right, x)
            top, bottom = min(top, y), max(bottom, y)
            for neighbor in (index - width if y else -1, index + width if y + 1 < height else -1,
                             index - 1 if x else -1, index + 1 if x + 1 < width else -1):
                if neighbor >= 0 and pixels[neighbor]:
                    pixels[neighbor] = 0
                    pending.append(neighbor)
        if len(points) >= 256:
            result.append({"points": points, "box": (left, top, right + 1, bottom + 1),
                           "center": (total_x / len(points), total_y / len(points))})
    return result


def compile_atlas(source: Path, destination: Path, version: int = 1) -> dict:
    counts = V2_COUNTS if version == 2 else COUNTS
    size = (1536, 208 * len(counts))
    with Image.open(source) as opened:
        if opened.format != "PNG" or "A" not in opened.getbands():
            raise ValueError(f"{source.name}: expected a PNG with alpha")
        if opened.width * opened.height > 40_000_000:
            raise ValueError("Source exceeds the 40-megapixel limit")
        image = opened.convert("RGBA")
    width, height = image.size
    by_cell = {}
    for component in foreground_components(image):
        x, y = component["center"]
        col, row = min(7, int(x * 8 / width)), min(10, int(y * 11 / height))
        key = row, col
        if row >= len(counts):
            continue  # v1 has no pointer-look rows; do not fabricate replacements.
        if col >= counts[row]:
            continue
        if key not in by_cell or len(component["points"]) > len(by_cell[key]["points"]):
            by_cell[key] = component
    expected = {(row, col) for row, count in enumerate(counts) for col in range(count)}
    if set(by_cell) != expected:
        raise ValueError(f"{source.name}: missing distinct silhouettes at {sorted(expected - set(by_cell))}")

    frames = {}
    local_boxes = []
    clipped = []
    for (row, col), component in by_cell.items():
        left, top, right, bottom = component["box"]
        if left == 0 or top == 0 or right == width or bottom == height:
            clipped.append([row, col])
        # A mask around the existing connected silhouette retains its original
        # antialias pixels, without retaining detached generated matte specks.
        box = (max(0, left - 2), max(0, top - 2), min(width, right + 2), min(height, bottom + 2))
        frame = image.crop(box)
        support = Image.new("L", frame.size)
        mask = support.load()
        for index in component["points"]:
            mask[index % width - box[0], index // width - box[1]] = 255
        support = support.filter(ImageFilter.MaxFilter(5))
        alpha = frame.getchannel("A").point(lambda value: 0 if value <= ALPHA_FLOOR else value)
        frame.putalpha(ImageChops.multiply(alpha, support))
        origin_x, origin_y = col * width / 8, row * height / 11
        local_box = (box[0] - origin_x, box[1] - origin_y, box[2] - origin_x, box[3] - origin_y)
        local_boxes.append(local_box)
        frames[row, col] = frame, local_box
    if clipped:
        raise ValueError(f"{source.name}: source artwork is clipped by the canvas at frames {clipped}; regenerate, never reconstruct missing pixels")

    # One transform for the entire resource preserves relative jump offsets,
    # pose sizes and baselines. Transparent insets prevent adjacent-cell sampling.
    union = (min(b[0] for b in local_boxes), min(b[1] for b in local_boxes),
             max(b[2] for b in local_boxes), max(b[3] for b in local_boxes))
    # V2's verified gaze frames allow a tighter inset matching original Pitou.
    fill = .92 if version == 2 else .70
    scale = min(CELL[0] * fill / (union[2] - union[0]), CELL[1] * fill / (union[3] - union[1]))
    offset_x = CELL[0] / 2 - (union[0] + union[2]) / 2 * scale
    offset_y = CELL[1] / 2 - (union[1] + union[3]) / 2 * scale
    atlas = Image.new("RGBA", size)
    for (row, col), (frame, box) in frames.items():
        size = max(1, round(frame.width * scale)), max(1, round(frame.height * scale))
        rendered = frame.resize(size, Image.Resampling.LANCZOS)
        atlas.alpha_composite(rendered, (col * CELL[0] + round(offset_x + box[0] * scale),
                                         row * CELL[1] + round(offset_y + box[1] * scale)))
    validate(atlas, version)
    destination.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(destination, optimize=True)
    return {"source": str(source), "sourceSize": [width, height], "destination": str(destination),
            "size": list(atlas.size), "version": version, "occupiedFrames": sum(counts), "unusedFrames": 15,
            "alphaFloor": ALPHA_FLOOR, "uniformScale": scale, "sourceCanvasClippedFrames": clipped,
            "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "outputSHA256": hashlib.sha256(destination.read_bytes()).hexdigest()}


def validate(image: Image.Image, version: int = 1) -> None:
    counts = V2_COUNTS if version == 2 else COUNTS
    if image.size != (1536, 208 * len(counts)) or image.mode != "RGBA":
        raise ValueError("Compiled atlas must match the selected version's RGBA geometry")
    for row, count in enumerate(counts):
        for col in range(8):
            box = col * CELL[0], row * CELL[1], (col + 1) * CELL[0], (row + 1) * CELL[1]
            alpha = image.crop(box).getchannel("A")
            bounds = alpha.getbbox()
            if (col < count) != (bounds is not None):
                raise ValueError(f"Wrong occupancy at {row},{col}")
            if bounds and (bounds[0] < 4 or bounds[1] < 4 or bounds[2] > CELL[0] - 4 or bounds[3] > CELL[1] - 4):
                raise ValueError(f"Insufficient transparent margin at {row},{col}")


def previews(paths: list[Path], folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    atlases = [(p.stem, Image.open(p).convert("RGBA")) for p in paths]
    def rendered_frame(name: str, atlas: Image.Image, row: int, col: int, points: int) -> Image.Image:
        frame = atlas.crop((col * CELL[0], row * CELL[1], (col + 1) * CELL[0], (row + 1) * CELL[1]))
        # Match native scaledToFit + presentationScale, including transparent inset.
        scale = 1 if name in {"Pitou", "Scout"} else 1.4
        return frame.resize((round(points * CELL[0] / CELL[1] * scale), round(points * scale)), Image.Resampling.LANCZOS)
    # Each frame occupies 160 by 160 points, rendered with preserved aspect.
    panel = Image.new("RGB", (len(paths) * 180, 440), "white")
    draw = ImageDraw.Draw(panel)
    for index, (name, atlas) in enumerate(atlases):
        x = index * 180
        draw.rectangle((x, 220, x + 180, 440), fill=(25, 27, 34))
        draw.text((x + 12, 12), name, fill=(30, 30, 30))
        draw.text((x + 12, 232), name, fill=(225, 225, 225))
        frame = rendered_frame(name, atlas, 0, 0, 160)
        for y in (42, 262):
            panel.paste(frame, (x + (180 - frame.width) // 2, y + (160 - frame.height) // 2), frame)
    panel.save(folder / "companions-light-dark-160.png")
    counts = V2_COUNTS if any(atlas.height == 2288 for _, atlas in atlases) else COUNTS
    sequence = [(row, col) for row, count in enumerate(counts) for col in range(count)]
    animation = []
    for row, col in sequence:
        canvas = Image.new("RGB", (len(paths) * 180, 220), (245, 246, 249))
        draw = ImageDraw.Draw(canvas)
        for index, (name, atlas) in enumerate(atlases):
            draw.text((index * 180 + 12, 10), f"{name} {row + 1}:{col + 1}", fill=(20, 20, 20))
            frame = rendered_frame(name, atlas, row, col, 160)
            canvas.paste(frame, (index * 180 + (180 - frame.width) // 2, 40 + (160 - frame.height) // 2), frame)
        animation.append(canvas)
    animation[0].save(folder / "companions-all-motion.gif", save_all=True,
        append_images=animation[1:], duration=140, loop=0, disposal=2)
    # Inspect every frame without depending on a viewer's GIF animation support.
    strip = Image.new("RGB", (8 * 120, len(paths) * len(counts) * 135), (245, 246, 249))
    draw = ImageDraw.Draw(strip)
    for index, (name, atlas) in enumerate(atlases):
        for row, count in enumerate(counts):
            for col in range(count):
                y = (index * len(counts) + row) * 135
                draw.text((col * 120 + 3, y + 2), f"{name} {row + 1}:{col + 1}", fill=(20, 20, 20))
                frame = rendered_frame(name, atlas, row, col, 110)
                strip.paste(frame, (col * 120 + (120 - frame.width) // 2, y + 22 + (110 - frame.height) // 2), frame)
    strip.save(folder / "companions-all-frame-strip.png")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="append", default=[], metavar="NAME=PNG")
    parser.add_argument("--output-dir", type=Path, default=Path("Locus/Resources/Companions"))
    parser.add_argument("--preview-dir", type=Path)
    parser.add_argument("--version", type=int, choices=(1, 2), default=1)
    options = parser.parse_args()
    reports, outputs = [], []
    for entry in options.source:
        name, raw_path = entry.split("=", 1)
        if name not in {"Gon", "Ninja", "Clover", "Shadow", "Pirate", "Scout"}:
            parser.error("Only generated variant names are accepted; the original Pitou is never overwritten")
        target = options.output_dir / f"{name}.png"
        reports.append(compile_atlas(Path(raw_path), target, options.version))
        outputs.append(target)
    if options.preview_dir:
        previews(outputs, options.preview_dir)
        (options.preview_dir / "atlas-validation.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
