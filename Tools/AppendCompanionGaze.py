#!/usr/bin/env python3
"""Append 16 approved gaze poses without changing an existing v1 atlas's pixels.

Requires Pillow. All inputs and the output are explicit; generation is separate:
  python3 Tools/AppendCompanionGaze.py --original Original-v1.png \
      --gaze Approved-look-strip.png --output Character-v2.png \
      --report /tmp/character-gaze.json --preview-dir /tmp/character-review

Only deterministic extraction, matte cleanup, uniform scaling, and positioning.
No eyes are painted, frames synthesized, mirrored, or duplicated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics

from PIL import Image, ImageChops, ImageDraw, ImageFilter

from PrepareCompanionAtlases import foreground_components

CELL = (192, 208)
ORIGINAL_SIZE = (1536, 1872)
OUTPUT_SIZE = (1536, 2288)
MAX_BYTES = 20 * 1024 * 1024


def read_rgba(path: Path) -> Image.Image:
    if not 0 < path.stat().st_size <= MAX_BYTES:
        raise ValueError("Input must be nonempty and at most 20 MB")
    with Image.open(path) as image:
        if image.format != "PNG" or "A" not in image.getbands():
            raise ValueError("Input must be a PNG with alpha")
        if image.width * image.height > 40_000_000:
            raise ValueError("Input exceeds 40 million decoded pixels")
        return image.convert("RGBA")


def foreground_box(image: Image.Image) -> tuple[int, int, int, int]:
    box = image.getchannel("A").point(lambda value: 255 if value > 32 else 0).getbbox()
    if box is None:
        raise ValueError("Frame has no visible silhouette")
    return box


def foot_center(image: Image.Image) -> float:
    box = foreground_box(image)
    start = box[3] - max(4, round((box[3] - box[1]) * 0.15))
    pixels = image.getchannel("A").load()
    total = weighted = 0
    for y in range(start, box[3]):
        for x in range(box[0], box[2]):
            alpha = pixels[x, y]
            if alpha > 32:
                total += alpha
                weighted += x * alpha
    if not total:
        raise ValueError("Frame has no visible baseline")
    return weighted / total


def compile_gaze(original_path: Path, gaze_path: Path, output_path: Path) -> dict:
    if output_path.resolve() in {original_path.resolve(), gaze_path.resolve()}:
        raise ValueError("Output must not overwrite either source input")
    original = read_rgba(original_path)
    if original.size != ORIGINAL_SIZE:
        raise ValueError("Original must have exact 1536 x 1872 v1 geometry")
    source = read_rgba(gaze_path)
    by_cell = {}
    for component in foreground_components(source):
        column = min(7, int(component["center"][0] * 8 / source.width))
        row = min(1, int(component["center"][1] * 2 / source.height))
        key = row, column
        if key in by_cell:
            raise ValueError(f"Multiple silhouettes in gaze cell {key}")
        by_cell[key] = component
    if set(by_cell) != {(row, column) for row in range(2) for column in range(8)}:
        raise ValueError("Gaze strip must contain exactly 16 separate 8 x 2 silhouettes")

    idle = original.crop((0, 0, *CELL))
    idle_box = foreground_box(idle)
    target_x, target_y = foot_center(idle), idle_box[3]
    first = by_cell[0, 0]["box"]
    scale = (idle_box[3] - idle_box[1]) / (first[3] - first[1])
    baselines = {
        row: statistics.median(by_cell[row, column]["box"][3] for column in range(8))
        for row in range(2)
    }
    source_x = statistics.median(
        component["box"][0] + foot_center(source.crop(component["box"]))
        - column * source.width / 8
        for (_, column), component in by_cell.items()
    )
    atlas = Image.new("RGBA", OUTPUT_SIZE)
    atlas.paste(original, (0, 0))
    frames = []
    for (row, column), component in sorted(by_cell.items()):
        left, top, right, bottom = component["box"]
        if not (left > 1 and top > 1 and right < source.width - 1 and bottom < source.height - 1):
            raise ValueError(f"Gaze cell {(row, column)} touches the source edge")
        box = left - 2, top - 2, right + 2, bottom + 2
        frame = source.crop(box)
        support = Image.new("L", frame.size)
        pixels = support.load()
        for index in component["points"]:
            pixels[index % source.width - box[0], index // source.width - box[1]] = 255
        support = support.filter(ImageFilter.MaxFilter(5))
        alpha = frame.getchannel("A").point(lambda value: 0 if value <= 4 else value)
        frame.putalpha(ImageChops.multiply(alpha, support))
        frame = frame.resize(
            (round(frame.width * scale), round(frame.height * scale)), Image.Resampling.LANCZOS
        )
        x = round(target_x + (box[0] - column * source.width / 8 - source_x) * scale)
        y = round(target_y + (box[1] - baselines[row]) * scale)
        if x < 0 or y < 0 or x + frame.width > CELL[0] or y + frame.height > CELL[1]:
            raise ValueError(f"Gaze cell {(row, column)} would be clipped after packing")
        cell = Image.new("RGBA", CELL)
        cell.alpha_composite(frame, (x, y))
        bounds = foreground_box(cell)
        if not (0 < bounds[0] < bounds[2] < CELL[0] and 0 < bounds[1] < bounds[3] < CELL[1]):
            raise ValueError(f"Gaze cell {(row, column)} has no transparent safety inset")
        atlas.paste(cell, (column * CELL[0], (row + 9) * CELL[1]))
        frames.append({
            "index": row * 8 + column, "box": bounds,
            "sha256": hashlib.sha256(cell.tobytes()).hexdigest(),
        })
    if len({frame["sha256"] for frame in frames}) != 16:
        raise ValueError("Gaze strip contains duplicate frames")
    if atlas.crop((0, 0, *ORIGINAL_SIZE)).tobytes() != original.tobytes():
        raise ValueError("Original animation pixels changed")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(output_path, optimize=True)
    return {
        "source_generated_file": gaze_path.name,
        "source_sha256": hashlib.sha256(gaze_path.read_bytes()).hexdigest(),
        "original_file_sha256": hashlib.sha256(original_path.read_bytes()).hexdigest(),
        "original_rgba_sha256": hashlib.sha256(original.tobytes()).hexdigest(),
        "final_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
        "scale": scale, "idle_box": idle_box, "new_frames": frames,
        "first_nine_rows_unchanged": True,
    }


def write_preview(atlas_path: Path, directory: Path) -> None:
    """Show every direction at 160 px on both appearances, beside original idle."""
    atlas = read_rgba(atlas_path)
    idle = atlas.crop((0, 0, *CELL))
    sheet = Image.new("RGB", (1440, 808), (245, 246, 247))
    draw = ImageDraw.Draw(sheet)
    draw.text((8, 7), f"{atlas_path.stem}: idle, then 0-7 / 8-15; light and dark", fill=(30, 30, 35))
    for display_row in range(4):
        row = display_row % 2
        background = (245, 246, 247) if display_row < 2 else (24, 25, 30)
        for column in range(9):
            frame = idle if column == 0 else atlas.crop((
                (column - 1) * CELL[0], (row + 9) * CELL[1],
                column * CELL[0], (row + 10) * CELL[1],
            ))
            frame = frame.resize((148, 160), Image.Resampling.LANCZOS)
            tile = Image.new("RGBA", (160, 194), (*background, 255))
            tile.alpha_composite(frame, (6, 12))
            ImageDraw.Draw(tile).text(
                (8, 177), "idle" if column == 0 else str(row * 8 + column - 1),
                fill=(25, 25, 30) if display_row < 2 else (232, 232, 236),
            )
            sheet.paste(tile.convert("RGB"), (column * 160, 32 + display_row * 194))
    directory.mkdir(parents=True, exist_ok=True)
    sheet.save(directory / f"{atlas_path.stem}-gaze-review.png")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, required=True)
    parser.add_argument("--gaze", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--preview-dir", type=Path)
    args = parser.parse_args()
    report = compile_gaze(args.original, args.gaze, args.output)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    if args.preview_dir:
        write_preview(args.output, args.preview_dir)
    print(json.dumps({key: value for key, value in report.items() if key != "new_frames"}, indent=2))


if __name__ == "__main__":
    main()
