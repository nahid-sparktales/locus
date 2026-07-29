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
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any

APP_DIR = Path.home() / ".ollama-code"
SESSIONS_DIR = APP_DIR / "sessions"
TRASH_DIR = APP_DIR / "session-trash"
META_PATH = APP_DIR / "session-metadata.json"

_META_LOCK = threading.Lock()
_APPEND_LOCK = threading.Lock()


# The sibling paths are derived from SESSIONS_DIR at call time, so pointing
# SESSIONS_DIR at a temp directory (as the tests do) relocates the metadata
# file and the trash folder with it.
def _app_dir() -> Path:
    return SESSIONS_DIR.parent


def _meta_path() -> Path:
    return _app_dir() / "session-metadata.json"


def _trash_dir() -> Path:
    return _app_dir() / "session-trash"


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


class SessionMeta:
    """Organizer metadata keyed by session id, persisted as one JSON file."""

    @staticmethod
    def _read() -> dict[str, dict[str, Any]]:
        try:
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


class SessionStore:
    """Appends conversation records to one JSONL file per run."""

    def __init__(self, cwd: str, model: str = "") -> None:
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
        self.append({
            "type": "meta",
            "cwd": cwd,
            "model": model,
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
        return sorted(SESSIONS_DIR.glob("*.jsonl"), reverse=True)

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
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return messages
        for line in lines:
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") == "message" and isinstance(rec.get("message"), dict):
                messages.append(rec["message"])
        return messages

    @staticmethod
    def header(path: Path) -> dict[str, Any]:
        """The leading meta record: cwd, model, started."""
        try:
            with path.open(encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
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
            with path.open(encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
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
            with path.open(encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
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
            with path.open(encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if rec.get("type") == "message":
                        return True
        except OSError:
            return False
        return False

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
        out: list[dict[str, Any]] = []
        for f in SessionStore.list_sessions():
            session_id = f.stem
            entry = meta.get(session_id, {})
            if entry.get("archived") and not include_archived:
                continue
            if not SessionStore.has_messages(f):
                continue
            try:
                stat = f.stat()
            except OSError:
                continue
            if query:
                haystack = " ".join([
                    str(entry.get("title") or ""),
                    SessionStore.preview(f),
                    session_id,
                ]).lower()
                if query.strip().lower() not in haystack:
                    continue
            out.append({
                "id": session_id,
                "name": f.name,
                "preview": SessionStore.preview(f),
                "mtime": stat.st_mtime,
                "size": stat.st_size,
                "title": entry.get("title"),
                "pinned": bool(entry.get("pinned", False)),
                "archived": bool(entry.get("archived", False)),
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
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        target = _trash_dir() / stamp
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
        try:
            (target / "manifest.json").write_text(
                json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
            )
        except OSError:
            pass
        SessionMeta.forget(moved)
        return len(moved), str(target)

    @staticmethod
    def restore_from_trash(batch: str | None = None) -> int:
        """Move a trash batch (default: newest) back into the sessions folder."""
        if not _trash_dir().exists():
            return 0
        batches = sorted((p for p in _trash_dir().iterdir() if p.is_dir()), reverse=True)
        if not batches:
            return 0
        folder = _trash_dir() / batch if batch else batches[0]
        if not folder.is_dir():
            return 0
        try:
            manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            manifest = {"sessions": {}}
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        restored = 0
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
            restored += 1
            entry = (manifest.get("sessions") or {}).get(path.stem)
            if isinstance(entry, dict) and entry:
                SessionMeta.update(destination.stem, **entry)
        if restored and not any(folder.glob("*.jsonl")):
            # Drop the manifest too so the emptied batch does not linger and
            # make the next "restore newest" a no-op.
            try:
                (folder / "manifest.json").unlink(missing_ok=True)
                folder.rmdir()
            except OSError:
                pass
        return restored


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
        fields["title"] = title.strip() or None
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
