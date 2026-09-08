"""Header parsing for the image formats the response boundary accepts.

The fixtures here are hand-built bytes rather than files checked into the
repository, so the other image suites import them to write real pictures into
a workspace.
"""
from __future__ import annotations

import struct
import zlib

import pytest

from ollama_code.image_files import ImageInfo, image_info, sniff_format


def png_bytes(width: int = 4, height: int = 3) -> bytes:
    """A complete, decodable RGBA PNG of the given size."""
    def chunk(kind: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body)) + kind + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )
    raw = b"".join(b"\x00" + b"\x10\x80\xff\xff" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def jpeg_bytes(width: int = 640, height: int = 480) -> bytes:
    """A JPEG header with an APP0 segment and a baseline SOF0 frame."""
    app0 = b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = struct.pack(">BHHB", 8, height, width, 3) + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    return (
        b"\xff\xd8"
        + b"\xff\xe0" + struct.pack(">H", len(app0) + 2) + app0
        + b"\xff\xc0" + struct.pack(">H", len(sof) + 2) + sof
        + b"\xff\xda\x00\x02\xff\xd9"
    )


def gif_bytes(width: int = 12, height: int = 7) -> bytes:
    return b"GIF89a" + struct.pack("<HH", width, height) + b"\x00\x00\x00\x3b"


def webp_lossless_bytes(width: int = 30, height: int = 20) -> bytes:
    bits = (width - 1) | ((height - 1) << 14)
    payload = b"\x2f" + struct.pack("<I", bits) + b"\x00" * 8
    chunk = b"VP8L" + struct.pack("<I", len(payload)) + payload
    return b"RIFF" + struct.pack("<I", 4 + len(chunk)) + b"WEBP" + chunk


def webp_lossy_bytes(width: int = 320, height: int = 240) -> bytes:
    payload = b"\x10\x02\x00" + b"\x9d\x01\x2a" + struct.pack("<HH", width, height) + b"\x00" * 8
    chunk = b"VP8 " + struct.pack("<I", len(payload)) + payload
    return b"RIFF" + struct.pack("<I", 4 + len(chunk)) + b"WEBP" + chunk


def webp_extended_bytes(width: int = 1000, height: int = 500) -> bytes:
    payload = b"\x10\x00\x00\x00" + (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little")
    chunk = b"VP8X" + struct.pack("<I", len(payload)) + payload + b"\x00" * 8
    return b"RIFF" + struct.pack("<I", 4 + len(chunk)) + b"WEBP" + chunk


@pytest.mark.parametrize("data, expected", [
    (png_bytes(4, 3), ImageInfo(4, 3, "png")),
    (jpeg_bytes(640, 480), ImageInfo(640, 480, "jpeg")),
    (gif_bytes(12, 7), ImageInfo(12, 7, "gif")),
    (webp_lossless_bytes(30, 20), ImageInfo(30, 20, "webp")),
    (webp_lossy_bytes(320, 240), ImageInfo(320, 240, "webp")),
    (webp_extended_bytes(1000, 500), ImageInfo(1000, 500, "webp")),
])
def test_dimensions_and_format_come_from_the_container_header(data, expected, tmp_path):
    assert image_info(data) == expected
    assert sniff_format(data[:16]) == expected.format
    path = tmp_path / "picture.bin"
    path.write_bytes(data)
    assert image_info(path) == expected


def test_jpeg_frame_header_is_found_behind_large_metadata_segments():
    exif = b"\xff\xe1" + struct.pack(">H", 60_000 + 2) + b"Exif\x00\x00" + b"\x00" * 59_994
    data = b"\xff\xd8" + exif + jpeg_bytes(1200, 800)[2:]
    assert image_info(data) == ImageInfo(1200, 800, "jpeg")


@pytest.mark.parametrize("data", [
    b"",
    b"not an image at all",
    b"\x89PNG\r\n\x1a\n" + b"\x00" * 8,
    png_bytes()[:20],
    b"\xff\xd8\xff\xda\x00\x02",
    b"\xff\xd8\xff\xe0\x00\x10",
    b"GIF89a\x00\x00\x00\x00",
    b"RIFF\x10\x00\x00\x00WEBPVP8 \x04\x00\x00\x00abcd",
    b"RIFF\x10\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x00\x00\x00\x00\x00",
    b"RIFF\x10\x00\x00\x00WAVEfmt ",
    b"<svg xmlns='http://www.w3.org/2000/svg'/>",
])
def test_truncated_or_foreign_bytes_are_refused_instead_of_guessed(data, tmp_path):
    assert image_info(data) is None
    path = tmp_path / "picture.bin"
    path.write_bytes(data)
    assert image_info(path) is None


def test_size_ceiling_refuses_before_reading_and_missing_paths_are_none(tmp_path):
    data = png_bytes(2, 2)
    assert image_info(data, max_bytes=len(data)) == ImageInfo(2, 2, "png")
    assert image_info(data, max_bytes=len(data) - 1) is None
    path = tmp_path / "big.png"
    path.write_bytes(data)
    assert image_info(path, max_bytes=len(data) - 1) is None
    assert image_info(tmp_path / "absent.png") is None
    assert image_info(tmp_path) is None
