"""Bounded MCP image observations and session-owned preview storage.

Only the provider/broker transport carries image data. Transcripts and UI events
carry opaque session-scoped references, never server-supplied paths or base64.
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import re
import shutil
import threading
import uuid
from pathlib import Path
from typing import Any

from .image_files import FORMAT_SUFFIXES, image_info

MAX_IMAGES = 10
MAX_IMAGE_BYTES = 15 * 1024 * 1024
MAX_TOTAL_BYTES = 25 * 1024 * 1024
MAX_IMAGE_PIXELS = 40_000_000
MAX_SESSION_BYTES = 250 * 1024 * 1024
MAX_SESSION_IMAGES = 1_000
_MIME_TYPES = {"image/png", "image/jpeg", "image/gif", "image/webp"}
_MEDIA_ID = re.compile(r"[a-f0-9]{32}\Z")
_LOCK = threading.RLock()


def _get(item: Any, key: str, default: Any = None) -> Any:
    return item.get(key, default) if isinstance(item, dict) else getattr(item, key, default)


def normalize_mcp_media(content: list[Any]) -> tuple[list[dict[str, Any]], list[str]]:
    """Extract validated inline images, leaving text/resource formatting to MCP."""
    images: list[dict[str, Any]] = []
    notes: list[str] = []
    total = 0
    for item in content:
        kind = _get(item, "type", "")
        resource = _get(item, "resource") if kind == "resource" else item
        mime = str(_get(resource, "mime_type", _get(resource, "mimeType", "")) or "").lower()
        if kind == "image":
            encoded = _get(item, "data", "")
        elif resource is not None and mime.startswith("image/") and _get(resource, "blob") is not None:
            encoded = _get(resource, "blob")
        else:
            continue
        reason = ""
        if len(images) >= MAX_IMAGES:
            reason = "the result exceeds 10 images"
        elif mime not in _MIME_TYPES:
            reason = "its image format is unsupported"
        elif not isinstance(encoded, str) or not encoded:
            reason = "its image data is missing"
        elif len(encoded) > ((MAX_IMAGE_BYTES + 2) // 3) * 4:
            reason = "it exceeds 15 MiB"
        else:
            try:
                data = base64.b64decode(encoded, validate=True)
            except (ValueError, binascii.Error):
                reason = "its base64 data is malformed"
            else:
                info = image_info(data, MAX_IMAGE_BYTES)
                if info is None or info.mime_type != mime:
                    reason = "its bytes do not match a supported image format"
                elif info.width * info.height > MAX_IMAGE_PIXELS:
                    reason = "its dimensions exceed 40 million pixels"
                elif total + len(data) > MAX_TOTAL_BYTES:
                    reason = "the result exceeds 25 MiB of images"
                else:
                    images.append({"name": f"mcp-image-{len(images) + 1}{FORMAT_SUFFIXES[info.format]}",
                                   "mime_type": mime, "data": encoded, "size": len(data),
                                   "width": info.width, "height": info.height})
                    total += len(data)
        if reason:
            note = f"MCP image omitted: {reason}."
            if note not in notes:
                notes.append(note)
    return images, notes


def native_tool_result(text: str, images: list[dict[str, Any]]) -> str | dict[str, Any]:
    images = [image for image in images if image.get("_model_visible", True)]
    if not images:
        return text
    return {"content_items": [{"type": "inputText", "text": text}, *[
        {"type": "inputImage", "imageUrl": f"data:{item['mime_type']};base64,{item['data']}"}
        for item in images]], "success": not text.startswith(("Error", "Permission denied", "Not run:"))}


def validate_native_tool_result(value: Any) -> str | dict[str, Any]:
    """Validate the existing structured tool envelope at broker boundaries."""
    if isinstance(value, str):
        return value
    if not isinstance(value, dict) or set(value) - {"content_items", "success"}:
        raise ValueError("Invalid structured tool result")
    parts = value.get("content_items")
    if not isinstance(parts, list) or len(parts) > MAX_IMAGES + 1:
        raise ValueError("Invalid structured tool result content")
    images = []
    text_parts = []
    for part in parts:
        if not isinstance(part, dict):
            raise ValueError("Invalid structured tool result content")
        if part.get("type") == "inputText" and isinstance(part.get("text"), str):
            text_parts.append(part["text"])
        elif part.get("type") == "inputImage" and isinstance(part.get("imageUrl"), str):
            match = re.fullmatch(r"data:(image/[\w.+-]+);base64,(.+)", part["imageUrl"], re.S)
            if not match:
                raise ValueError("Tool images require inline validated image data")
            images.append({"type": "image", "mime_type": match[1], "data": match[2]})
        else:
            raise ValueError("Unsupported structured tool result content")
    _, notes = normalize_mcp_media(images)
    if notes:
        raise ValueError(" ".join(notes))
    if sum(len(text) for text in text_parts) > 1_000_000:
        raise ValueError("Structured tool result text is too large")
    return {"content_items": parts, "success": bool(value.get("success", True))}


def claude_tool_result(value: Any) -> dict[str, Any]:
    value = validate_native_tool_result(value)
    if isinstance(value, str):
        return {"content": [{"type": "text", "text": value}],
                "isError": value.startswith(("Error", "Permission denied", "Not run:"))}
    content = []
    for part in value["content_items"]:
        if part["type"] == "inputText":
            content.append({"type": "text", "text": part["text"]})
        else:
            header, encoded = part["imageUrl"].split(",", 1)
            content.append({"type": "image", "mimeType": header[5:-7], "data": encoded})
    return {"content": content, "isError": not value["success"]}


def split_tool_result(value: Any) -> tuple[str, list[dict[str, Any]]]:
    """Recover text and validated observations from the neutral tool envelope."""
    value = validate_native_tool_result(value)
    if isinstance(value, str):
        return value, []
    text = []
    images = []
    for part in value["content_items"]:
        if part["type"] == "inputText":
            text.append(part["text"])
        else:
            header, data = part["imageUrl"].split(",", 1)
            images.append({"type": "image", "mime_type": header[5:-7], "data": data})
    normalized, _ = normalize_mcp_media(images)
    return "\n".join(text), normalized


def responses_tool_result(value: Any) -> str | list[dict[str, Any]]:
    """Map neutral tool output to the Responses function-output content union."""
    value = validate_native_tool_result(value)
    if isinstance(value, str):
        return value
    return [
        {"type": "input_text", "text": part["text"]}
        if part["type"] == "inputText"
        else {"type": "input_image", "image_url": part["imageUrl"], "detail": "auto"}
        for part in value["content_items"]
    ]


def bound_classic_media(messages: list[dict[str, Any]]) -> None:
    """Keep only the newest bounded MCP observations in a model's history."""
    count = total = 0
    for message in reversed(messages):
        if not message.get("_mcp_observation"):
            continue
        kept = []
        for item in message.get("attachments", []):
            size = int(item.get("size") or 0)
            if count < MAX_IMAGES and total + size <= MAX_TOTAL_BYTES:
                kept.append(item)
                count += 1
                total += size
        if kept:
            message["attachments"] = kept
        else:
            message.pop("attachments", None)


def bound_responses_media(history: list[dict[str, Any]], *, remove_all: bool = False) -> bool:
    """Bound image parts without dropping function replies or their call IDs."""
    count = total = 0
    removed = False
    for item in reversed(history):
        if item.get("type") != "function_call_output" or not isinstance(item.get("output"), list):
            continue
        kept = []
        for part in item["output"]:
            if part.get("type") == "input_image":
                encoded = str(part.get("image_url") or "").partition(",")[2]
                size = len(encoded) * 3 // 4 - len(encoded) + len(encoded.rstrip("="))
                if remove_all or count >= MAX_IMAGES or total + size > MAX_TOTAL_BYTES:
                    removed = True
                    continue
                count += 1
                total += size
            kept.append(part)
        item["output"] = kept or [{"type": "input_text", "text": "MCP image preview is available in chat."}]
    return removed


def media_directory(session_id: str, *, root: Path | None = None) -> Path:
    from .sessions import SESSIONS_DIR
    if not session_id or session_id in {".", ".."} or Path(session_id).name != session_id or "\\" in session_id:
        raise ValueError("Invalid media session")
    directory = (root if root is not None else SESSIONS_DIR) / "media" / session_id
    if any(path.is_symlink() for path in (directory, directory.parent, directory.parent.parent)):
        raise ValueError("Media storage must not cross a symlink")
    return directory


def cache_media(session_id: str, invocation_id: str, images: list[dict[str, Any]]) -> list[dict[str, Any]]:
    directory = media_directory(session_id)
    references = []
    with _LOCK:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        existing = list(directory.glob("*.image"))
        size = sum(path.stat().st_size for path in existing)
        if len(existing) + len(images) > MAX_SESSION_IMAGES or size + sum(image["size"] for image in images) > MAX_SESSION_BYTES:
            raise OSError("This chat's image preview storage limit was reached")
        created_paths = []
        try:
            for image in images:
                identifier = uuid.uuid4().hex
                metadata = {key: image[key] for key in ("name", "mime_type", "size", "width", "height")}
                metadata.update(id=identifier, invocation_id=invocation_id, session_id=session_id)
                data_path = directory / f"{identifier}.image"
                meta_path = directory / f"{identifier}.json"
                for path, data in ((data_path, base64.b64decode(image["data"], validate=True)),
                                   (meta_path, json.dumps(metadata).encode())):
                    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    created_paths.append(path)
                    with os.fdopen(descriptor, "wb") as handle:
                        handle.write(data)
                references.append(metadata)
        except BaseException:
            for path in reversed(created_paths):
                path.unlink(missing_ok=True)
            raise
    return references


def read_cached_media(session_id: str, media_id: str) -> tuple[bytes, dict[str, Any]]:
    if not _MEDIA_ID.fullmatch(media_id):
        raise ValueError("Invalid media identifier")
    directory = media_directory(session_id)
    metadata_path, data_path = directory / f"{media_id}.json", directory / f"{media_id}.image"
    with _LOCK:
        if metadata_path.is_symlink() or data_path.is_symlink() or metadata_path.stat().st_size > 4096:
            raise ValueError("Invalid media storage")
        metadata = json.loads(metadata_path.read_text())
        if not isinstance(metadata, dict) or metadata.get("id") != media_id or data_path.stat().st_size > MAX_IMAGE_BYTES:
            raise ValueError("Invalid media storage")
        data = data_path.read_bytes()
        info = image_info(data, MAX_IMAGE_BYTES)
        if info is None or info.width * info.height > MAX_IMAGE_PIXELS or info.mime_type != metadata.get("mime_type") or len(data) != metadata.get("size"):
            raise ValueError("Invalid cached image")
        return data, metadata


def move_session_media(session_id: str, destination_id: str, *, source_root: Path, destination_root: Path) -> None:
    source = media_directory(session_id, root=source_root)
    destination = media_directory(destination_id, root=destination_root)
    with _LOCK:
        if source.exists():
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if destination.exists():
                raise OSError("Destination media already exists")
            shutil.move(str(source), str(destination))


def remove_session_media(session_id: str) -> None:
    """Remove previews when creation of their owning session is rolled back."""
    directory = media_directory(session_id)
    with _LOCK:
        if directory.exists():
            shutil.rmtree(directory)


def copy_session_media(source_id: str, destination_id: str, records: list[dict[str, Any]]) -> None:
    references = {str(item.get("id")) for record in records
                  for item in (record.get("message") or {}).get("media", []) if isinstance(item, dict)}
    if not references:
        return
    destination = media_directory(destination_id)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    for identifier in references:
        try:
            data, metadata = read_cached_media(source_id, identifier)
        except (OSError, ValueError):
            continue
        metadata["session_id"] = destination_id
        for path, content in ((destination / f"{identifier}.image", data),
                              (destination / f"{identifier}.json", json.dumps(metadata).encode())):
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as handle:
                handle.write(content)
