#!/usr/bin/env python3
"""Report nm output with identity-pinned upstream CPython exceptions.

CPython 3.14.6 Modules/_xxtestfuzz/{fuzzer.c,_xxtestfuzz.c} contains a smoke-test
wrapper and a local LLVMFuzzerTestOneInput function, without a libFuzzer driver:
https://github.com/python/cpython/blob/v3.14.6/Modules/_xxtestfuzz/fuzzer.c
https://github.com/python/cpython/blob/v3.14.6/Modules/_xxtestfuzz/_xxtestfuzz.c

Verified against the exact upstream python-build-standalone ARM64 asset:
cpython-3.14.6+20260728-aarch64-apple-darwin-install_only_stripped.tar.gz
https://github.com/astral-sh/python-build-standalone/releases/tag/20260728
Archive SHA256: f4b47659e2da4b97f38cefdf5ad19f0042946099d843cde60de308708e5b1ac5
Interpreter SHA256: 0826ccaa8dd19bd84a5f0ffdbe84558f036e3b7d8ce7725704a7393995392129
libpython3.14.dylib SHA256: c8a999112c85cc7fd0fcf818fdc63244ae5bb5f1d5ba37a92983dcd3a0c4353c
The shared library carries the same stock builtin; its image is pinned separately.

Signing changes the signature allocation and __LINKEDIT size bookkeeping. The
normalized digest retains every other byte before the signature, including all
code, data, symbols, load commands, and signature offset. This helper never
modifies an artifact. Every other image and symbol uses unfiltered nm output.
The caller must continue its separate strings and code-signature audits.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import struct
import subprocess
import sys
from pathlib import Path

INTERPRETER_SUFFIX = ("Contents", "Resources", "AgentRuntime", "python", "bin", "python3.14")
LIBRARY_SUFFIX = ("Contents", "Resources", "AgentRuntime", "python", "lib", "libpython3.14.dylib")
PINNED_IMAGES = {
    INTERPRETER_SUFFIX: "305e5c0154a61abdab75e0120e36d7f663a98cbe4726990e8ec873aa2a5fb055",
    LIBRARY_SUFFIX: "bab9a728c32eeae132219b771e68199dde47ff7efb10be791c555ecd974e787f",
}
LOCAL_CPYTHON_CALLBACK = re.compile(rb"^[0-9a-fA-F]{16}[ \t]+t[ \t]+_LLVMFuzzerTestOneInput(?:\r?\n)?$")
MAX_IMAGE_BYTES = 128 * 1024 * 1024


class InspectionError(RuntimeError):
    """The requested inventory could not be inspected reliably."""


def normalized_image_digest(data: bytes) -> str | None:
    """Return the signing-invariant digest only for a well-bounded ARM64 image."""
    if len(data) < 32:
        return None
    magic, cpu, subtype, file_type, command_count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype) != (0xFEEDFACF, 0x0100000C, 0) or file_type not in {2, 6}:
        return None
    command_end = 32 + command_bytes
    if not 1 <= command_count <= 4096 or command_end > len(data):
        return None
    offset = 32
    signature = None
    linkedit = None
    segments = []
    for _ in range(command_count):
        if offset + 8 > command_end:
            return None
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or offset + size > command_end:
            return None
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                return None
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            if size != 72 + section_count * 80:
                return None
            name = data[offset + 8:offset + 24].rstrip(b"\0")
            _, virtual_size, file_offset, file_size = struct.unpack_from("<4Q", data, offset + 24)
            if file_offset + file_size > len(data):
                return None
            segments.append((name, file_offset, file_size))
            if name == b"__LINKEDIT":
                if linkedit is not None or section_count:
                    return None
                linkedit = (offset, virtual_size, file_offset, file_size)
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            if size != 16 or signature is not None:
                return None
            signature = (offset, *struct.unpack_from("<II", data, offset + 8))
        offset += size
    if offset != command_end or signature is None or linkedit is None:
        return None
    signature_command, signature_offset, signature_size = signature
    segment_command, virtual_size, file_offset, file_size = linkedit
    if (
        signature_offset < command_end or signature_offset % 16
        or signature_size < 12 or signature_offset + signature_size != len(data)
        or not command_end <= file_offset <= signature_offset
        or file_offset + file_size != len(data)
        or virtual_size != ((file_size + 0x3FFF) & ~0x3FFF)
        or any(name != b"__LINKEDIT" and start + size > signature_offset for name, start, size in segments)
    ):
        return None
    # Validate the embedded signature container's bounds. Its cryptographic
    # verification remains the caller's codesign audit, not this symbol reader.
    blob_magic, blob_size, blob_count = struct.unpack_from(">III", data, signature_offset)
    if blob_magic != 0xFADE0CC0 or not 12 <= blob_size <= signature_size or 12 + blob_count * 8 > blob_size:
        return None
    for index in range(blob_count):
        _, blob_offset = struct.unpack_from(">II", data, signature_offset + 12 + index * 8)
        if blob_offset < 12 + blob_count * 8 or blob_offset + 8 > blob_size:
            return None
        item_size = struct.unpack_from(">I", data, signature_offset + blob_offset + 4)[0]
        if item_size < 8 or blob_offset + item_size > blob_size:
            return None

    normalized = bytearray(data[:signature_offset])
    normalized[signature_command + 12:signature_command + 16] = b"\0" * 4
    normalized[segment_command + 32:segment_command + 40] = b"\0" * 8
    normalized[segment_command + 48:segment_command + 56] = b"\0" * 8
    return hashlib.sha256(normalized).hexdigest()


def is_pinned_bundled_image(path: Path) -> bool:
    resolved = path.resolve(strict=True)
    if len(resolved.parts) < 7 or not resolved.parts[-7].endswith(".app"):
        return False
    expected_digest = PINNED_IMAGES.get(tuple(resolved.parts[-6:]))
    if expected_digest is None:
        return False
    if resolved.stat().st_size > MAX_IMAGE_BYTES:
        return False
    return normalized_image_digest(resolved.read_bytes()) == expected_digest


def symbol_inventory(path: Path) -> bytes:
    try:
        result = subprocess.run(
            ["/usr/bin/nm", str(path)], capture_output=True, check=False, timeout=60,
        )
        if result.returncode:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise InspectionError(f"nm failed ({result.returncode}): {detail}")
        if not is_pinned_bundled_image(path):
            return result.stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise InspectionError(f"could not inspect {path}: {error}") from error
    return b"".join(
        line for line in result.stdout.splitlines(keepends=True)
        if LOCAL_CPYTHON_CALLBACK.fullmatch(line) is None
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    arguments = parser.parse_args()
    try:
        output = symbol_inventory(arguments.executable)
    except InspectionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
