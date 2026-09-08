"""Stdlib-only image header inspection.

The response-document boundary derives an image part's ``width``, ``height``
and ``format`` from the bytes on disk, never from tool arguments; the image
tools use the same parser to refuse a provider payload that is not the picture
it claims to be. Only the container headers are read: PNG IHDR, the first JPEG
SOF frame, the GIF logical screen and the WebP VP8/VP8L/VP8X chunk. Anything
truncated, inconsistent or unknown answers ``None`` rather than a guess.
"""
from __future__ import annotations

import os
import struct
from dataclasses import dataclass
from pathlib import Path

#: Bytes read from a file before giving up on finding its dimensions. JPEG
#: metadata (EXIF thumbnails, ICC profiles) routinely runs to tens of KB before
#: the frame header, so this is generous while staying far below any image.
HEADER_SCAN_BYTES = 1_048_576
#: The largest image the response boundary accepts by default.
DEFAULT_MAX_BYTES = 50_000_000

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_JPEG_SOF_MARKERS = frozenset(
    marker for marker in range(0xC0, 0xD0) if marker not in {0xC4, 0xC8, 0xCC}
)
_JPEG_STANDALONE = frozenset({0x01, 0xD8, *range(0xD0, 0xD8)})

FORMAT_MIME = {"png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"}
FORMAT_SUFFIXES = {"png": ".png", "jpeg": ".jpg", "gif": ".gif", "webp": ".webp"}


@dataclass(frozen=True)
class ImageInfo:
    width: int
    height: int
    format: str

    @property
    def mime_type(self) -> str:
        return FORMAT_MIME[self.format]


def sniff_format(head: bytes) -> str | None:
    """The container format the leading bytes announce, or None."""
    if head.startswith(_PNG_SIGNATURE):
        return "png"
    if head[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return None


def _png(data: bytes) -> ImageInfo | None:
    if len(data) < 24 or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return _checked(width, height, "png")


def _jpeg(data: bytes) -> ImageInfo | None:
    index = 2
    length = len(data)
    while index < length:
        if data[index] != 0xFF:
            return None
        while index < length and data[index] == 0xFF:
            index += 1
        if index >= length:
            return None
        marker = data[index]
        index += 1
        if marker in _JPEG_STANDALONE:
            continue
        if marker in {0xD9, 0xDA}:
            # End of image or start of scan without a frame header first.
            return None
        if index + 2 > length:
            return None
        segment = struct.unpack(">H", data[index:index + 2])[0]
        if segment < 2:
            return None
        if marker in _JPEG_SOF_MARKERS:
            if index + 7 > length:
                return None
            height, width = struct.unpack(">HH", data[index + 3:index + 7])
            return _checked(width, height, "jpeg")
        index += segment
    return None


def _gif(data: bytes) -> ImageInfo | None:
    if len(data) < 10:
        return None
    width, height = struct.unpack("<HH", data[6:10])
    return _checked(width, height, "gif")


def _webp(data: bytes) -> ImageInfo | None:
    if len(data) < 30:
        return None
    chunk = data[12:16]
    if chunk == b"VP8 ":
        if data[23:26] != b"\x9d\x01\x2a":
            return None
        width = struct.unpack("<H", data[26:28])[0] & 0x3FFF
        height = struct.unpack("<H", data[28:30])[0] & 0x3FFF
        return _checked(width, height, "webp")
    if chunk == b"VP8L":
        if data[20] != 0x2F or len(data) < 25:
            return None
        bits = struct.unpack("<I", data[21:25])[0]
        width = (bits & 0x3FFF) + 1
        height = ((bits >> 14) & 0x3FFF) + 1
        return _checked(width, height, "webp")
    if chunk == b"VP8X":
        width = int.from_bytes(data[24:27], "little") + 1
        height = int.from_bytes(data[27:30], "little") + 1
        return _checked(width, height, "webp")
    return None


def _checked(width: int, height: int, fmt: str) -> ImageInfo | None:
    if width <= 0 or height <= 0 or width > 65_535 * 4 or height > 65_535 * 4:
        return None
    return ImageInfo(width=width, height=height, format=fmt)


_PARSERS = {"png": _png, "jpeg": _jpeg, "gif": _gif, "webp": _webp}


def image_info(
    source: bytes | bytearray | str | os.PathLike[str],
    max_bytes: int = DEFAULT_MAX_BYTES,
) -> ImageInfo | None:
    """Dimensions and format of ``source`` (bytes or a path), or None.

    A path larger than ``max_bytes`` is refused without being read; bytes
    longer than ``max_bytes`` are refused too. Only the header is inspected.
    """
    if isinstance(source, (bytes, bytearray)):
        if len(source) > max_bytes:
            return None
        head = bytes(source[:HEADER_SCAN_BYTES])
    else:
        path = Path(source)
        try:
            if not path.is_file() or path.stat().st_size > max_bytes:
                return None
            with path.open("rb") as handle:
                head = handle.read(HEADER_SCAN_BYTES)
        except OSError:
            return None
    fmt = sniff_format(head)
    if fmt is None:
        return None
    try:
        return _PARSERS[fmt](head)
    except (struct.error, IndexError):
        return None


__all__ = [
    "DEFAULT_MAX_BYTES",
    "FORMAT_MIME",
    "FORMAT_SUFFIXES",
    "HEADER_SCAN_BYTES",
    "ImageInfo",
    "image_info",
    "sniff_format",
]
