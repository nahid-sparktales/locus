"""Session persistence.

Conversations are JSONL files under ``~/.ollama-code/sessions``. Organizer
metadata (title, pinned, archived) lives in a single sidecar manifest so the
transcript files stay append-only, and cleared sessions move to a recoverable
trash folder rather than being deleted.
"""
from __future__ import annotations

import fcntl
import json
import re
import shutil
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any

from .paths import APP_DIR

SESSIONS_DIR = APP_DIR / "sessions"

_META_LOCK = threading.Lock()
_ORGANIZATION_LOCK = threading.Lock()
_APPEND_LOCK = threading.Lock()

MAX_SESSION_BYTES = 64 * 1024 * 1024
MAX_SESSION_LINE_BYTES = 2 * 1024 * 1024
MAX_SESSION_MESSAGES = 20_000
MAX_METADATA_BYTES = 4 * 1024 * 1024
MAX_ORGANIZATION_BYTES = 4 * 1024 * 1024


class SessionTooLargeError(ValueError):
    """A transcript exceeds the bounded restore/export limits."""


# The sibling paths are derived from SESSIONS_DIR at call time, so pointing
# SESSIONS_DIR at a temp directory (as the tests do) relocates the metadata
# file and the trash folder with it.
def _app_dir() -> Path:
    return SESSIONS_DIR.parent


def _meta_path() -> Path:
    return _app_dir() / "session-metadata.json"


def _trash_dir() -> Path:
    return _app_dir() / "session-trash"


def _organization_path() -> Path:
    return _app_dir() / "chat-organization.json"


def _slug(text: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return slug[-40:] or "session"


@contextmanager
def _meta_guard():
    """Serialize metadata updates within this process and across processes.

    A thread lock alone is not enough: a second ollama-code (the CLI beside
    the app) would read-modify-write the same file and silently drop titles,
    pins and archive flags.
    """
    with _META_LOCK:
        lock_path = _meta_path().with_suffix(".lock")
        handle = None
        try:
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            handle = lock_path.open("w")
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        except OSError:
            handle = None  # best effort: still guarded within this process
        try:
            yield
        finally:
            if handle is not None:
                try:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                finally:
                    handle.close()


@contextmanager
def _organization_guard():
    """Serialize folder and placement mutations across app and CLI agents."""
    with _ORGANIZATION_LOCK:
        lock_path = _organization_path().with_suffix(".lock")
        handle = None
        try:
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            handle = lock_path.open("w")
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        except OSError:
            handle = None
        try:
            yield
        finally:
            if handle is not None:
                try:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                finally:
                    handle.close()


class SessionMeta:
    """Organizer metadata keyed by session id, persisted as one JSON file."""

    @staticmethod
    def _read() -> dict[str, dict[str, Any]]:
        try:
            if _meta_path().stat().st_size > MAX_METADATA_BYTES:
                return {}
            data = json.loads(_meta_path().read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    @staticmethod
    def _write(data: dict[str, dict[str, Any]]) -> None:
        try:
            _meta_path().parent.mkdir(parents=True, exist_ok=True)
            tmp = _meta_path().with_suffix(".json.tmp")
            tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            tmp.replace(_meta_path())
        except OSError:
            pass

    @staticmethod
    def all() -> dict[str, dict[str, Any]]:
        with _meta_guard():
            return SessionMeta._read()

    @staticmethod
    def get(session_id: str) -> dict[str, Any]:
        return SessionMeta.all().get(session_id, {})

    @staticmethod
    def update(session_id: str, **fields: Any) -> dict[str, Any]:
        """Merge ``fields`` into a session's metadata and return the result."""
        with _meta_guard():
            data = SessionMeta._read()
            entry = dict(data.get(session_id) or {})
            for key, value in fields.items():
                if value is None:
                    entry.pop(key, None)
                else:
                    entry[key] = value
            if entry:
                data[session_id] = entry
            else:
                data.pop(session_id, None)
            SessionMeta._write(data)
            return entry

    @staticmethod
    def forget(session_ids: list[str]) -> None:
        if not session_ids:
            return
        with _meta_guard():
            data = SessionMeta._read()
            for session_id in session_ids:
                data.pop(session_id, None)
            SessionMeta._write(data)


class ChatOrganizationStore:
    """Versioned nested folders and session placement, separate from JSONL chat data."""

    VERSION = 1

    @staticmethod
    def _empty() -> dict[str, Any]:
        return {"version": ChatOrganizationStore.VERSION, "folders": [], "placements": {}}

    @staticmethod
    def _canonical_workspace(value: str) -> str:
        return str(Path(value).expanduser().resolve(strict=False))

    @staticmethod
    def _read() -> dict[str, Any]:
        try:
            if _organization_path().stat().st_size > MAX_ORGANIZATION_BYTES:
                return ChatOrganizationStore._empty()
            value = json.loads(_organization_path().read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return ChatOrganizationStore._empty()
        if not isinstance(value, dict) or value.get("version") != ChatOrganizationStore.VERSION:
            return ChatOrganizationStore._empty()
        folders = value.get("folders")
        placements = value.get("placements")
        if not isinstance(folders, list) or not isinstance(placements, dict):
            return ChatOrganizationStore._empty()
        sanitized_folders: list[dict[str, Any]] = []
        folder_ids: set[str] = set()
        for raw in folders:
            if not isinstance(raw, dict):
                continue
            folder_id = raw.get("id")
            workspace = raw.get("workspace")
            name = raw.get("name")
            if (
                not isinstance(folder_id, str) or not folder_id or folder_id in folder_ids
                or not isinstance(workspace, str) or not workspace
                or not isinstance(name, str) or not name.strip()
            ):
                continue
            parent_id = raw.get("parent_id")
            sanitized_folders.append({
                "id": folder_id,
                "workspace": ChatOrganizationStore._canonical_workspace(workspace),
                "parent_id": parent_id if isinstance(parent_id, str) else None,
                "name": " ".join(name.split())[:80],
                "order": max(0, raw.get("order") if isinstance(raw.get("order"), int) else 0),
            })
            folder_ids.add(folder_id)

        folders_by_id = {folder["id"]: folder for folder in sanitized_folders}
        for folder in sanitized_folders:
            parent_id = folder["parent_id"]
            parent = folders_by_id.get(parent_id)
            if parent is None or parent["workspace"] != folder["workspace"]:
                folder["parent_id"] = None
                continue
            visited = {folder["id"]}
            cursor = parent
            while cursor is not None:
                if cursor["id"] in visited:
                    folder["parent_id"] = None
                    break
                visited.add(cursor["id"])
                cursor = folders_by_id.get(cursor.get("parent_id"))

        sanitized_placements: dict[str, dict[str, Any]] = {}
        for session_id, raw in placements.items():
            if not isinstance(session_id, str) or not session_id or not isinstance(raw, dict):
                continue
            workspace = raw.get("workspace")
            if not isinstance(workspace, str) or not workspace:
                continue
            canonical = ChatOrganizationStore._canonical_workspace(workspace)
            folder_id = raw.get("folder_id") if isinstance(raw.get("folder_id"), str) else None
            folder = folders_by_id.get(folder_id)
            if folder_id is not None and (
                folder is None or folder.get("workspace") != canonical
            ):
                folder_id = None
            sanitized_placements[session_id] = {
                "session_id": session_id,
                "workspace": canonical,
                "folder_id": folder_id,
                "order": max(0, raw.get("order") if isinstance(raw.get("order"), int) else 0),
            }
        return {
            "version": ChatOrganizationStore.VERSION,
            "folders": sanitized_folders,
            "placements": sanitized_placements,
        }

    @staticmethod
    def _write(value: dict[str, Any]) -> None:
        _organization_path().parent.mkdir(parents=True, exist_ok=True)
        tmp = _organization_path().with_suffix(".json.tmp")
        tmp.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        tmp.replace(_organization_path())

    @staticmethod
    def snapshot(workspace: str | None = None) -> dict[str, Any]:
        with _organization_guard():
            value = ChatOrganizationStore._read()
        if not workspace:
            return value
        canonical = ChatOrganizationStore._canonical_workspace(workspace)
        return {
            "version": ChatOrganizationStore.VERSION,
            "folders": [
                dict(folder) for folder in value["folders"]
                if isinstance(folder, dict) and folder.get("workspace") == canonical
            ],
            "placements": {
                session_id: dict(placement)
                for session_id, placement in value["placements"].items()
                if isinstance(placement, dict) and placement.get("workspace") == canonical
            },
        }

    @staticmethod
    def placement(session_id: str) -> dict[str, Any] | None:
        with _organization_guard():
            placement = ChatOrganizationStore._read()["placements"].get(session_id)
        return dict(placement) if isinstance(placement, dict) else None

    @staticmethod
    def _folder(value: dict[str, Any], folder_id: str | None) -> dict[str, Any] | None:
        if folder_id is None:
            return None
        return next(
            (
                folder for folder in value["folders"]
                if isinstance(folder, dict) and folder.get("id") == folder_id
            ),
            None,
        )

    @staticmethod
    def _normalized_name(raw: str) -> str:
        name = " ".join(raw.split())[:80]
        if not name:
            raise ValueError("folder name is required")
        return name

    @staticmethod
    def _assert_unique_name(
        value: dict[str, Any], workspace: str, parent_id: str | None,
        name: str, excluding: str | None = None,
    ) -> None:
        folded = name.casefold()
        for folder in value["folders"]:
            if not isinstance(folder, dict) or folder.get("id") == excluding:
                continue
            if folder.get("workspace") == workspace and folder.get("parent_id") == parent_id \
                    and str(folder.get("name") or "").casefold() == folded:
                raise ValueError("a folder with that name already exists here")

    @staticmethod
    def _normalize_orders(value: dict[str, Any], workspace: str, parent_id: str | None) -> None:
        folders = sorted(
            (
                folder for folder in value["folders"]
                if isinstance(folder, dict)
                and folder.get("workspace") == workspace
                and folder.get("parent_id") == parent_id
            ),
            key=lambda item: (int(item.get("order") or 0), str(item.get("name") or "").casefold()),
        )
        for order, folder in enumerate(folders):
            folder["order"] = order
        placements = sorted(
            (
                placement for placement in value["placements"].values()
                if isinstance(placement, dict)
                and placement.get("workspace") == workspace
                and placement.get("folder_id") == parent_id
            ),
            key=lambda item: (int(item.get("order") or 0), str(item.get("session_id") or "")),
        )
        for order, placement in enumerate(placements):
            placement["order"] = order

    @staticmethod
    def create_folder(
        workspace: str, name: str, parent_id: str | None = None, index: int | None = None,
    ) -> dict[str, Any]:
        canonical = ChatOrganizationStore._canonical_workspace(workspace)
        name = ChatOrganizationStore._normalized_name(name)
        with _organization_guard():
            value = ChatOrganizationStore._read()
            parent = ChatOrganizationStore._folder(value, parent_id)
            if parent_id is not None and (parent is None or parent.get("workspace") != canonical):
                raise ValueError("parent folder is not in this workspace")
            ChatOrganizationStore._assert_unique_name(value, canonical, parent_id, name)
            siblings = [
                folder for folder in value["folders"]
                if isinstance(folder, dict)
                and folder.get("workspace") == canonical
                and folder.get("parent_id") == parent_id
            ]
            insertion = max(0, min(index if index is not None else len(siblings), len(siblings)))
            for folder in siblings:
                if int(folder.get("order") or 0) >= insertion:
                    folder["order"] = int(folder.get("order") or 0) + 1
            record = {
                "id": str(uuid.uuid4()),
                "workspace": canonical,
                "parent_id": parent_id,
                "name": name,
                "order": insertion,
            }
            value["folders"].append(record)
            ChatOrganizationStore._normalize_orders(value, canonical, parent_id)
            ChatOrganizationStore._write(value)
            return dict(record)

    @staticmethod
    def update_folder(
        folder_id: str, *, name: str | None = None,
        parent_id: str | None | object = ..., index: int | None = None,
    ) -> dict[str, Any]:
        with _organization_guard():
            value = ChatOrganizationStore._read()
            folder = ChatOrganizationStore._folder(value, folder_id)
            if folder is None:
                raise KeyError(folder_id)
            workspace = str(folder.get("workspace") or "")
            old_parent = folder.get("parent_id")
            target_parent = old_parent if parent_id is ... else parent_id
            parent = ChatOrganizationStore._folder(value, target_parent if isinstance(target_parent, str) else None)
            if target_parent is not None and (
                not isinstance(target_parent, str) or parent is None or parent.get("workspace") != workspace
            ):
                raise ValueError("parent folder is not in this workspace")
            cursor = parent
            while cursor is not None:
                if cursor.get("id") == folder_id:
                    raise ValueError("a folder cannot be moved inside itself")
                cursor = ChatOrganizationStore._folder(value, cursor.get("parent_id"))
            updated_name = ChatOrganizationStore._normalized_name(name) if name is not None else str(folder["name"])
            ChatOrganizationStore._assert_unique_name(
                value, workspace, target_parent if isinstance(target_parent, str) else None,
                updated_name, excluding=folder_id,
            )
            folder["name"] = updated_name
            folder["parent_id"] = target_parent
            siblings = sorted(
                [
                sibling for sibling in value["folders"]
                if isinstance(sibling, dict) and sibling.get("id") != folder_id
                and sibling.get("workspace") == workspace and sibling.get("parent_id") == target_parent
                ],
                key=lambda item: (
                    int(item.get("order") or 0), str(item.get("name") or "").casefold()
                ),
            )
            insertion = max(0, min(index if index is not None else len(siblings), len(siblings)))
            siblings.insert(insertion, folder)
            for order, sibling in enumerate(siblings):
                sibling["order"] = order
            ChatOrganizationStore._normalize_orders(value, workspace, old_parent)
            ChatOrganizationStore._write(value)
            return dict(folder)

    @staticmethod
    def delete_folder(folder_id: str) -> dict[str, Any]:
        with _organization_guard():
            value = ChatOrganizationStore._read()
            folder = ChatOrganizationStore._folder(value, folder_id)
            if folder is None:
                raise KeyError(folder_id)
            workspace = str(folder.get("workspace") or "")
            parent_id = folder.get("parent_id")
            for child in value["folders"]:
                if isinstance(child, dict) and child.get("parent_id") == folder_id:
                    child["parent_id"] = parent_id
            for placement in value["placements"].values():
                if isinstance(placement, dict) and placement.get("folder_id") == folder_id:
                    placement["folder_id"] = parent_id
            value["folders"] = [
                candidate for candidate in value["folders"]
                if not isinstance(candidate, dict) or candidate.get("id") != folder_id
            ]
            ChatOrganizationStore._normalize_orders(value, workspace, parent_id)
            ChatOrganizationStore._write(value)
            return {"id": folder_id, "promoted_to": parent_id}

    @staticmethod
    def move_session(session_id: str, folder_id: str | None, index: int | None = None) -> dict[str, Any]:
        path = SessionStore.path_for(session_id)
        if path is None:
            raise KeyError(session_id)
        workspace = str(SessionStore.header(path).get("cwd") or "")
        if not workspace:
            raise ValueError("legacy chats without a workspace cannot be placed in folders")
        canonical = ChatOrganizationStore._canonical_workspace(workspace)
        with _organization_guard():
            value = ChatOrganizationStore._read()
            folder = ChatOrganizationStore._folder(value, folder_id)
            if folder_id is not None and (folder is None or folder.get("workspace") != canonical):
                raise ValueError("target folder is not in the chat's workspace")
            previous = value["placements"].get(session_id)
            old_parent = previous.get("folder_id") if isinstance(previous, dict) else None
            siblings = sorted(
                [
                placement for key, placement in value["placements"].items()
                if key != session_id and isinstance(placement, dict)
                and placement.get("workspace") == canonical and placement.get("folder_id") == folder_id
                ],
                key=lambda item: (
                    int(item.get("order") or 0), str(item.get("session_id") or "")
                ),
            )
            insertion = max(0, min(index if index is not None else len(siblings), len(siblings)))
            placement = {
                "session_id": session_id,
                "workspace": canonical,
                "folder_id": folder_id,
                "order": insertion,
            }
            value["placements"][session_id] = placement
            siblings.insert(insertion, placement)
            for order, sibling in enumerate(siblings):
                sibling["order"] = order
            ChatOrganizationStore._normalize_orders(value, canonical, old_parent)
            ChatOrganizationStore._write(value)
            return dict(placement)

    @staticmethod
    def detach_sessions(session_ids: list[str]) -> dict[str, Any]:
        detached: dict[str, Any] = {}
        with _organization_guard():
            value = ChatOrganizationStore._read()
            affected: set[tuple[str, str | None]] = set()
            for session_id in session_ids:
                placement = value["placements"].pop(session_id, None)
                if isinstance(placement, dict):
                    detached[session_id] = placement
                    affected.add((str(placement.get("workspace") or ""), placement.get("folder_id")))
            for workspace, folder_id in affected:
                ChatOrganizationStore._normalize_orders(value, workspace, folder_id)
            if detached:
                ChatOrganizationStore._write(value)
        return detached

    @staticmethod
    def restore_placement(source_id: str, target_id: str, placement: Any) -> None:
        if not isinstance(placement, dict):
            return
        workspace = str(placement.get("workspace") or "")
        folder_id = placement.get("folder_id") if isinstance(placement.get("folder_id"), str) else None
        with _organization_guard():
            value = ChatOrganizationStore._read()
            folder = ChatOrganizationStore._folder(value, folder_id)
            if folder_id is not None and (folder is None or folder.get("workspace") != workspace):
                folder_id = None
            restored = dict(placement)
            restored.update({"session_id": target_id, "folder_id": folder_id})
            value["placements"].pop(source_id, None)
            value["placements"][target_id] = restored
            ChatOrganizationStore._normalize_orders(value, workspace, folder_id)
            ChatOrganizationStore._write(value)

    @staticmethod
    def clone_placement(source_id: str, target_id: str) -> dict[str, Any] | None:
        source = ChatOrganizationStore.placement(source_id)
        if source is None:
            return None
        return ChatOrganizationStore.move_session(
            target_id,
            source.get("folder_id") if isinstance(source.get("folder_id"), str) else None,
            int(source.get("order") or 0) + 1,
        )


class SessionStore:
    """Appends conversation records to one JSONL file per run."""

    def __init__(
        self,
        cwd: str,
        model: str = "",
        provider: str = "",
        account: str = "",
    ) -> None:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
        stem = f"{ts}-{_slug(cwd)}"
        # Two sessions started in the same millisecond (new chat twice in a
        # row, or a retry right after a turn) must not share a file: create it
        # exclusively and step the suffix until we win.
        self.path = SESSIONS_DIR / f"{stem}.jsonl"
        for attempt in range(1, 1000):
            try:
                self.path.touch(exist_ok=False)
                break
            except FileExistsError:
                self.path = SESSIONS_DIR / f"{stem}-{attempt}.jsonl"
            except OSError:
                break
        # The model name alone does not say who served it: two accounts for the
        # same provider run the same models, so an exported transcript needs
        # the account that produced it.
        self.append({
            "type": "meta",
            "cwd": cwd,
            "model": model,
            "provider": provider,
            "account": account,
            "started": datetime.now().isoformat(timespec="seconds"),
        })

    @property
    def session_id(self) -> str:
        return self.path.stem

    def append(self, record: dict[str, Any]) -> None:
        # Module-level lock, not per-instance: `core.session` is reassigned by
        # new-session and retry, so two stores can briefly target one file, and
        # the terminal pump writes from its own thread while a turn is running.
        line = json.dumps(record, ensure_ascii=False, default=str) + "\n"
        try:
            with _APPEND_LOCK, self.path.open("a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass  # session logging must never crash the app

    # ------------------------------------------------------------------ reads

    @staticmethod
    def list_sessions() -> list[Path]:
        """All session files, newest first (filenames start with a timestamp)."""
        if not SESSIONS_DIR.exists():
            return []
        paths = (
            resolved
            for candidate in SESSIONS_DIR.glob("*.jsonl")
            if (resolved := SessionStore.path_for(candidate.stem)) is not None
        )
        return sorted(paths, reverse=True)

    @staticmethod
    def path_for(session_id: str) -> Path | None:
        """Resolve a session id to its file, refusing anything outside the folder.

        Ids arrive from HTTP path parameters, so "../../etc/passwd" must not
        escape the sessions directory.
        """
        name = session_id.removesuffix(".jsonl")
        if not name or "/" in name or "\\" in name or name.startswith("."):
            return None
        candidate = SESSIONS_DIR / f"{name}.jsonl"
        try:
            root = SESSIONS_DIR.resolve()
            if candidate.resolve().parent != root:
                return None
        except OSError:
            return None
        return candidate if candidate.is_file() else None

    #: Historical name for :meth:`path_for`.
    find = path_for

    @staticmethod
    def load(path: Path) -> list[dict[str, Any]]:
        """Reconstruct the message list from a session file."""
        messages: list[dict[str, Any]] = []
        try:
            if path.stat().st_size > MAX_SESSION_BYTES:
                raise SessionTooLargeError(
                    f"{path.name} is larger than the {MAX_SESSION_BYTES // (1024 * 1024)} MB "
                    "session safety limit"
                )
            with path.open("rb") as handle:
                for line_number, raw in enumerate(handle, 1):
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        raise SessionTooLargeError(
                            f"{path.name} line {line_number} exceeds the "
                            f"{MAX_SESSION_LINE_BYTES // (1024 * 1024)} MB record limit"
                        )
                    if not raw.strip():
                        continue
                    try:
                        rec = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get("type") == "message" and isinstance(rec.get("message"), dict):
                        messages.append(rec["message"])
                        if len(messages) > MAX_SESSION_MESSAGES:
                            raise SessionTooLargeError(
                                f"{path.name} contains more than "
                                f"{MAX_SESSION_MESSAGES:,} messages"
                            )
        except OSError:
            return messages
        return messages

    @staticmethod
    def export_messages(
        path: Path, *, include_reasoning: bool = False,
        include_tool_details: bool = False, include_attachments: bool = True,
    ) -> list[dict[str, Any]]:
        """Return a full-length, secret-minimized transcript for file export."""
        messages = SessionStore.load(path)
        output: list[dict[str, Any]] = []
        for message in messages:
            role = str(message.get("role") or "")
            if role not in {"user", "assistant", "tool"}:
                continue
            if message.get("_display_only") and not include_reasoning:
                continue
            item: dict[str, Any] = {"role": role}
            if role == "user":
                item["content"] = strip_prompt_decoration(str(message.get("content") or ""))
                if include_attachments:
                    attachments: list[dict[str, str]] = []
                    for attachment in message.get("attachments") or []:
                        if not isinstance(attachment, dict):
                            continue
                        mime_type = str(attachment.get("mime_type") or "")
                        data = str(attachment.get("data") or "")
                        if mime_type not in {
                            "image/png", "image/jpeg", "image/gif", "image/webp",
                        } or not data:
                            continue
                        attachments.append({
                            "name": str(attachment.get("name") or "image")[:255],
                            "mime_type": mime_type,
                            "data": data,
                        })
                    if attachments:
                        item["attachments"] = attachments
            elif role == "assistant":
                item["content"] = str(message.get("content") or "")
                phase = str(message.get("_phase") or "")
                item_id = str(message.get("_item_id") or "")
                if phase:
                    item["phase"] = phase
                if item_id:
                    item["item_id"] = item_id
                if include_reasoning:
                    sections = [
                        str(section)
                        for section in message.get("_display_reasoning_sections") or []
                        if str(section)
                    ]
                    if sections:
                        item["reasoning_sections"] = sections
                    reasoning = str(
                        message.get("_display_reasoning")
                        or message.get("reasoning_content")
                        or ""
                    )
                    if reasoning:
                        item["reasoning"] = reasoning
            else:
                item["name"] = str(message.get("name") or "tool")[:255]
                item["content"] = str(message.get("content") or "") if include_tool_details else ""
            output.append(item)
        return output

    @staticmethod
    def duplicate(path: Path) -> SessionStore:
        """Clone durable conversation content without live run/thread ownership."""
        if path.stat().st_size > MAX_SESSION_BYTES:
            raise SessionTooLargeError(
                f"{path.name} is larger than the {MAX_SESSION_BYTES // (1024 * 1024)} MB "
                "session safety limit"
            )
        header = SessionStore.header(path)
        clone = SessionStore(
            str(header.get("cwd") or ""),
            model=str(header.get("model") or ""),
            provider=str(header.get("provider") or ""),
            account=str(header.get("account") or ""),
        )
        records: list[dict[str, Any]] = []
        try:
            with path.open("rb") as source:
                for line_number, raw in enumerate(source, 1):
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        raise SessionTooLargeError(
                            f"{path.name} line {line_number} exceeds the record limit"
                        )
                    try:
                        record = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict):
                        continue
                    record_type = record.get("type")
                    if record_type == "meta":
                        copied = {
                            key: record.get(key)
                            for key in ("cwd", "model", "provider", "account")
                            if record.get(key) is not None
                        }
                        copied.update({
                            "type": "meta",
                            "started": datetime.now().isoformat(timespec="seconds"),
                            "duplicated_from": path.stem,
                        })
                        records.append(copied)
                    elif record_type == "message" and isinstance(record.get("message"), dict):
                        message = dict(record["message"])
                        message.pop("run_id", None)
                        message.pop("team_run_id", None)
                        records.append({"type": "message", "message": message})
                    elif record_type == "model" and record.get("model"):
                        records.append({"type": "model", "model": record["model"]})
        except Exception:
            clone.path.unlink(missing_ok=True)
            raise
        if not records or records[0].get("type") != "meta":
            clone.path.unlink(missing_ok=True)
            raise ValueError("the source chat has no valid provenance record")
        with _APPEND_LOCK, clone.path.open("w", encoding="utf-8") as destination:
            for record in records:
                destination.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        return clone

    @staticmethod
    def chatgpt_thread_state(path: Path) -> dict[str, Any] | None:
        """Return the latest secret-free managed-thread resume marker.

        The marker stays outside message history so exports and canonical
        transcript rebuilds never treat a helper id as user content. Reads use
        the normal transcript ceilings to keep damaged files bounded.
        """
        latest: dict[str, Any] | None = None
        try:
            if path.stat().st_size > MAX_SESSION_BYTES:
                return None
            with path.open("rb") as handle:
                for raw in handle:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        return None
                    if not raw.strip():
                        continue
                    try:
                        record = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict) or record.get("type") != "chatgpt_thread":
                        continue
                    thread_id = record.get("thread_id")
                    protocol = record.get("protocol_version")
                    fingerprint = record.get("tool_schema_fingerprint")
                    revision = record.get("history_revision")
                    if (
                        isinstance(thread_id, str) and thread_id
                        and isinstance(protocol, str) and protocol
                        and isinstance(fingerprint, str) and fingerprint
                        and isinstance(revision, int) and revision >= 0
                    ):
                        latest = {
                            "thread_id": thread_id,
                            "protocol_version": protocol,
                            "tool_schema_fingerprint": fingerprint,
                            "history_revision": revision,
                        }
        except OSError:
            return None
        return latest

    @staticmethod
    def agent_activity(path: Path) -> dict[str, Any]:
        """Rebuild the latest bounded team-activity snapshot in one pass.

        Agent events are separate JSONL records, so older clients can continue
        treating the file as an ordinary chat transcript. The stored events
        never contain route credentials or provider reasoning signatures.
        """
        activities: dict[str, dict[str, Any]] = {}
        orchestration_state: str | None = None
        run_id: str | None = None
        worker_id: str | None = None
        seen = 0
        try:
            if path.stat().st_size > MAX_SESSION_BYTES:
                return {"activities": []}
            with path.open("rb") as handle:
                for raw in handle:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        break
                    try:
                        record = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict) or record.get("type") != "agent_activity":
                        continue
                    event = record.get("event")
                    if not isinstance(event, dict):
                        continue
                    seen += 1
                    if seen > 2_000:
                        break
                    event_type = str(event.get("type") or "")
                    run_id = str(event.get("run_id") or run_id or "") or None
                    worker_id = str(event.get("worker_id") or worker_id or "") or None
                    if event_type in {"orchestration_started", "orchestration_state", "orchestration_completed"}:
                        orchestration_state = str(event.get("state") or orchestration_state or "") or None
                    if event_type == "agent_job_started":
                        job_id = str(event.get("job_id") or "")
                        if not job_id:
                            continue
                        activities[job_id] = {
                            "id": job_id,
                            "agent_name": str(event.get("agent_name") or "Agent"),
                            "role": str(event.get("role") or "generalist"),
                            "provider": str(event.get("provider") or ""),
                            "model": str(event.get("model") or ""),
                            "goal": str(event.get("goal") or "")[:2_000],
                            "state": "running",
                            "output": "",
                            "reasoning_text": None,
                            "tool": None,
                            "evidence": [],
                            "elapsed_milliseconds": 0,
                            "prompt_tokens": 0,
                            "completion_tokens": 0,
                            "writer_job_id": event.get("writer_job_id"),
                            "writer_position": event.get("writer_position"),
                            "writer_total": event.get("writer_total"),
                        }
                    elif event_type == "agent_job_continuing":
                        job_id = str(event.get("job_id") or "")
                        if job_id and job_id in activities:
                            activities[job_id]["state"] = "running"
                            activities[job_id]["output"] = str(
                                event.get("message") or "Continuing coding job…"
                            )[:2_000]
                    elif event_type == "agent_job_incomplete":
                        job_id = str(event.get("job_id") or "")
                        if not job_id:
                            continue
                        result = event.get("result")
                        if not isinstance(result, dict):
                            result = {}
                        current = activities.get(job_id, {})
                        current.update({
                            "id": job_id,
                            "agent_name": str(event.get("agent_name") or current.get("agent_name") or "Agent"),
                            "role": str(result.get("role") or current.get("role") or "implementer"),
                            "provider": str(current.get("provider") or ""),
                            "model": str(current.get("model") or ""),
                            "goal": str(current.get("goal") or ""),
                            "state": "paused",
                            "output": str(event.get("message") or result.get("output") or "")[:120_000],
                            "reasoning_text": None,
                            "tool": None,
                            "evidence": [str(item) for item in result.get("evidence") or []][:128],
                            "elapsed_milliseconds": int(result.get("elapsed_ms") or 0),
                            "prompt_tokens": int(result.get("prompt_tokens") or 0),
                            "completion_tokens": int(result.get("completion_tokens") or 0),
                            "writer_job_id": event.get("writer_job_id"),
                            "writer_position": event.get("writer_position"),
                            "writer_total": event.get("writer_total"),
                        })
                        activities[job_id] = current
                    elif event_type == "agent_job_completed":
                        result = event.get("result")
                        if not isinstance(result, dict):
                            continue
                        job_id = str(result.get("job_id") or "")
                        if not job_id:
                            continue
                        current = activities.get(job_id, {})
                        current.update({
                            "id": job_id,
                            "agent_name": str(result.get("agent_name") or current.get("agent_name") or "Agent"),
                            "role": str(result.get("role") or current.get("role") or "generalist"),
                            "provider": str(current.get("provider") or ""),
                            "model": str(current.get("model") or ""),
                            "goal": str(current.get("goal") or ""),
                            "state": "failed" if event.get("state") == "failed" else "completed",
                            "output": str(result.get("output") or result.get("error") or "")[:120_000],
                            "reasoning_text": str(result.get("reasoning_text") or "")[:120_000] or None,
                            "tool": None,
                            "evidence": [str(item) for item in result.get("evidence") or []][:128],
                            "elapsed_milliseconds": int(result.get("elapsed_ms") or 0),
                            "prompt_tokens": int(result.get("prompt_tokens") or 0),
                            "completion_tokens": int(result.get("completion_tokens") or 0),
                        })
                        activities[job_id] = current
        except OSError:
            pass
        return {
            "activities": list(activities.values()),
            "orchestration_state": orchestration_state,
            "run_id": run_id,
            "worker_id": worker_id,
        }

    @staticmethod
    def header(path: Path) -> dict[str, Any]:
        """The leading meta record: cwd, model, started."""
        try:
            with path.open("rb") as f:
                for raw in f:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        return {}
                    try:
                        rec = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get("type") == "meta":
                        return rec
                    break
        except OSError:
            pass
        return {}

    @staticmethod
    def provenance(path: Path) -> dict[str, Any]:
        """Where a session ran: workspace, model, and start time.

        The model is whatever it was last switched to, since a conversation
        can move between models while it runs.
        """
        info = dict(SessionStore.header(path))
        try:
            with path.open("rb") as f:
                for raw in f:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        break
                    try:
                        rec = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get("type") == "model" and rec.get("model"):
                        info["model"] = rec["model"]
        except OSError:
            pass
        return info

    @staticmethod
    def preview(path: Path, limit: int = 80) -> str:
        """First user message in the file, for session listings."""
        try:
            with path.open("rb") as f:
                for raw in f:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        return "(session record is too large)"
                    try:
                        rec = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get("type") == "message" and rec.get("message", {}).get("role") == "user":
                        content = str(rec["message"].get("content", ""))
                        content = strip_prompt_decoration(content).replace("\n", " ").strip()
                        if content:
                            return content[:limit] + ("…" if len(content) > limit else "")
        except OSError:
            pass
        return "(no user messages)"

    @staticmethod
    def has_messages(path: Path) -> bool:
        """True when a transcript holds at least one message record."""
        try:
            with path.open("rb") as f:
                for raw in f:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        return False
                    try:
                        rec = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get("type") == "message":
                        return True
        except OSError:
            return False
        return False

    @staticmethod
    def _summary_record(path: Path, preview_limit: int = 80) -> dict[str, Any] | None:
        """Read the fields needed by the organizer in one bounded pass.

        The workspace sidebar requests hundreds of summaries at once.  The old
        implementation opened every JSONL file separately for ``has_messages``,
        ``preview`` and provenance, which made expanding workspace groups scale
        with three full directory scans.  A summary only needs the leading meta
        record and the first user message, so stop as soon as both are known.
        """
        header: dict[str, Any] = {}
        preview = ""
        has_messages = False
        try:
            if path.stat().st_size > MAX_SESSION_BYTES:
                return None
            with path.open("rb") as handle:
                for raw in handle:
                    if len(raw) > MAX_SESSION_LINE_BYTES:
                        return None
                    try:
                        record = json.loads(raw.decode("utf-8", errors="replace"))
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict):
                        continue
                    if record.get("type") == "meta" and not header:
                        header = record
                        continue
                    if record.get("type") != "message" or not isinstance(
                        record.get("message"), dict
                    ):
                        continue
                    has_messages = True
                    message = record["message"]
                    if message.get("role") == "user" and not preview:
                        content = str(message.get("content", ""))
                        content = strip_prompt_decoration(content).replace("\n", " ").strip()
                        if content:
                            preview = content[:preview_limit]
                            if len(content) > preview_limit:
                                preview += "…"
                    if header and preview:
                        break
        except OSError:
            return None
        if not has_messages:
            return None
        return {
            "preview": preview or "(no user messages)",
            "cwd": str(header.get("cwd") or "") or None,
        }

    @staticmethod
    def summaries(
        limit: int = 50,
        include_archived: bool = False,
        query: str = "",
    ) -> list[dict[str, Any]]:
        """Session listing with organizer metadata merged in.

        Sessions with no messages are omitted: every launch and workspace
        switch opens a transcript, and empty ones are noise in the sidebar.
        """
        meta = SessionMeta.all()
        organization = ChatOrganizationStore.snapshot()["placements"]
        out: list[dict[str, Any]] = []
        for f in SessionStore.list_sessions():
            session_id = f.stem
            entry = meta.get(session_id, {})
            if entry.get("archived") and not include_archived:
                continue
            summary = SessionStore._summary_record(f)
            if summary is None:
                continue
            try:
                stat = f.stat()
            except OSError:
                continue
            placement = organization.get(session_id)
            if isinstance(placement, dict):
                summary_workspace = str(summary.get("cwd") or "")
                canonical_summary_workspace = (
                    ChatOrganizationStore._canonical_workspace(summary_workspace)
                    if summary_workspace else ""
                )
                if placement.get("workspace") != canonical_summary_workspace:
                    placement = None
            if query:
                haystack = " ".join([
                    str(entry.get("title") or ""),
                    str(summary["preview"]),
                    str(summary["cwd"] or ""),
                    session_id,
                ]).lower()
                if query.strip().lower() not in haystack:
                    continue
            out.append({
                "id": session_id,
                "name": f.name,
                "preview": summary["preview"],
                "cwd": summary["cwd"],
                "mtime": stat.st_mtime,
                "size": stat.st_size,
                "title": entry.get("title"),
                "pinned": bool(entry.get("pinned", False)),
                "archived": bool(entry.get("archived", False)),
                "task": entry.get("task"),
                "team": entry.get("team"),
                "workspace_root": entry.get("workspace_root"),
                "execution_path": entry.get("execution_path"),
                "environment": entry.get("environment"),
                "folder_id": (
                    placement.get("folder_id") if isinstance(placement, dict) else None
                ),
                "sort_order": (
                    int(placement.get("order") or 0)
                    if isinstance(placement, dict) else None
                ),
            })
        # Sort before truncating, otherwise a pinned session drops off the
        # list as soon as `limit` newer sessions exist.
        out.sort(key=lambda s: (not s["pinned"], -s["mtime"]))
        return out[:limit]

    # ----------------------------------------------------------------- writes

    @staticmethod
    def move_to_trash(session_ids: list[str]) -> tuple[int, str]:
        """Move sessions into the recovery folder. Returns (count, path)."""
        if not session_ids:
            return 0, str(_trash_dir())
        # A UUID is unnecessary here, but microseconds plus an exclusive suffix
        # prevents two rapid individual deletes from sharing a manifest.
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        target = _trash_dir() / stamp
        for attempt in range(1, 1000):
            if not target.exists():
                break
            target = _trash_dir() / f"{stamp}-{attempt}"
        target.mkdir(parents=True, exist_ok=True)
        meta = SessionMeta.all()
        moved: list[str] = []
        manifest: dict[str, Any] = {
            "cleared_at": datetime.now().isoformat(timespec="seconds"),
            "sessions": {},
        }
        for session_id in session_ids:
            path = SessionStore.path_for(session_id)
            if path is None:
                continue
            try:
                shutil.move(str(path), str(target / path.name))
            except OSError:
                continue
            moved.append(session_id)
            manifest["sessions"][session_id] = meta.get(session_id, {})
        manifest["organization"] = ChatOrganizationStore.detach_sessions(moved)
        try:
            (target / "manifest.json").write_text(
                json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
            )
        except OSError:
            pass
        SessionMeta.forget(moved)
        return len(moved), str(target)

    @staticmethod
    def restore_from_trash_details(batch: str | None = None) -> list[str]:
        """Restore a trash batch and return the resulting session ids."""
        if not _trash_dir().exists():
            return []
        batches = sorted((p for p in _trash_dir().iterdir() if p.is_dir()), reverse=True)
        if not batches:
            return []
        if batch and (
            "/" in batch or "\\" in batch or batch.startswith(".") or Path(batch).name != batch
        ):
            return []
        folder = _trash_dir() / batch if batch else batches[0]
        try:
            if folder.resolve().parent != _trash_dir().resolve():
                return []
        except OSError:
            return []
        if not folder.is_dir():
            return []
        try:
            manifest_path = folder / "manifest.json"
            if manifest_path.stat().st_size > MAX_METADATA_BYTES:
                manifest = {"sessions": {}}
            else:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            manifest = {"sessions": {}}
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        restored_ids: list[str] = []
        for path in sorted(folder.glob("*.jsonl")):
            destination = SESSIONS_DIR / path.name
            # A session with this id may have been recreated since the clear;
            # never overwrite it.
            if destination.exists():
                stem, suffix = destination.stem, destination.suffix
                for attempt in range(1, 1000):
                    candidate = SESSIONS_DIR / f"{stem}-restored-{attempt}{suffix}"
                    if not candidate.exists():
                        destination = candidate
                        break
            try:
                shutil.move(str(path), str(destination))
            except OSError:
                continue
            restored_ids.append(destination.stem)
            entry = (manifest.get("sessions") or {}).get(path.stem)
            if isinstance(entry, dict) and entry:
                SessionMeta.update(destination.stem, **entry)
            placement = (manifest.get("organization") or {}).get(path.stem)
            ChatOrganizationStore.restore_placement(path.stem, destination.stem, placement)
        if restored_ids and not any(folder.glob("*.jsonl")):
            # Drop the manifest too so the emptied batch does not linger and
            # make the next "restore newest" a no-op.
            try:
                (folder / "manifest.json").unlink(missing_ok=True)
                folder.rmdir()
            except OSError:
                pass
        return restored_ids

    @staticmethod
    def restore_from_trash(batch: str | None = None) -> int:
        """Compatibility wrapper returning the historical restored count."""
        return len(SessionStore.restore_from_trash_details(batch))


# --------------------------------------------------------------------------
# Module-level organizer API.


def session_metadata(session_id: str) -> dict[str, Any]:
    """Organizer metadata for one session, with defaults filled in."""
    entry = SessionMeta.get(session_id)
    return {
        "title": str(entry.get("title") or ""),
        "pinned": bool(entry.get("pinned", False)),
        "archived": bool(entry.get("archived", False)),
    }


def update_session_metadata(
    session_id: str,
    title: str | None = None,
    pinned: bool | None = None,
    archived: bool | None = None,
) -> dict[str, Any]:
    """Set any of a session's organizer fields and return the new state."""
    fields: dict[str, Any] = {}
    if title is not None:
        fields["title"] = " ".join(title.split())[:120] or None
    if pinned is not None:
        fields["pinned"] = bool(pinned) or None
    if archived is not None:
        fields["archived"] = bool(archived) or None
    if fields:
        SessionMeta.update(session_id, **fields)
    return session_metadata(session_id)


def clear_saved_sessions(active_session_id: str) -> dict[str, Any]:
    """Move every session except the active one into the recovery folder."""
    ids = [f.stem for f in SessionStore.list_sessions() if f.stem != active_session_id]
    count, path = SessionStore.move_to_trash(ids)
    return {
        "count": count,
        "preserved_session_id": active_session_id,
        "recovery_path": path,
    }


_DECORATION_MARKER = "User request:"


def strip_prompt_decoration(content: str) -> str:
    """Remove the GUI's mode/context wrapper from a stored user message."""
    if not content.lstrip().startswith("[Locus mode:"):
        return content
    index = content.rfind(_DECORATION_MARKER)
    if index == -1:
        return ""
    return content[index + len(_DECORATION_MARKER):].strip()


def split_parity_prompt(content: str, mode: str) -> tuple[str, str]:
    """Split a decorated GUI message into (context, raw request) for the model.

    Codex-native parity turns send the user's own words as the final input
    item, with the selected context files and attachment guidance as a
    separate leading item. The ``[Locus mode: X]`` header always goes; the
    mode-instruction paragraph (always the second section, and never itself
    blank-line separated) goes too for ask/work, while plan/build keep it —
    the plan-approval and GSD flows ride on that instruction. Persistence is
    untouched: sessions keep the decorated form this function reads.
    """
    if not content.lstrip().startswith("[Locus mode:"):
        return "", content
    index = content.rfind(_DECORATION_MARKER)
    if index == -1:
        return "", content
    raw = content[index + len(_DECORATION_MARKER):].strip()
    sections = content[:index].split("\n\n")
    # Section 0 is the header; section 1 is the mode instruction.
    kept = sections[2:] if mode in ("ask", "work") else sections[1:]
    context = "\n\n".join(part for part in kept if part.strip()).strip()
    return context, raw
