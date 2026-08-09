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

from .paths import APP_DIR

SESSIONS_DIR = APP_DIR / "sessions"

_META_LOCK = threading.Lock()
_APPEND_LOCK = threading.Lock()

MAX_SESSION_BYTES = 64 * 1024 * 1024
MAX_SESSION_LINE_BYTES = 2 * 1024 * 1024
MAX_SESSION_MESSAGES = 20_000
MAX_METADATA_BYTES = 4 * 1024 * 1024


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
