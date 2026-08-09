"""Full-text search across every saved conversation.

One global SQLite FTS5 index over the session JSONL transcripts. The write
path in ``sessions.py`` is deliberately untouched: a stat-diff ``sync`` before
each search compares every session file's ``(mtime, size)`` to the index and
re-parses only what changed. That single mechanism covers appends, trash,
restore, delete, and sessions written by the CLI. Transcripts are append-only,
so growth is tail-parsed from the last indexed byte; a file that shrank or was
replaced is re-read from the start.

The index is derived data. On any schema mismatch it is dropped and rebuilt
lazily — there are no migrations here.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .paths import APP_DIR
from .sessions import (
    MAX_SESSION_BYTES,
    MAX_SESSION_LINE_BYTES,
    MAX_SESSION_MESSAGES,
    SessionMeta,
    SessionStore,
    strip_prompt_decoration,
)

SCHEMA_VERSION = 1
DEFAULT_PATH = APP_DIR / "transcript-index.sqlite3"
MAX_MESSAGE_CHARS = 100_000
MAX_QUERY_CHARS = 500
MAX_HITS_PER_SESSION = 3
#: Pending parse volume above which the first build moves off the request
#: thread. Small histories (and the tests) index inline and deterministically.
BACKGROUND_BUILD_BYTES = 8 * 1024 * 1024

_INDEXED_ROLES = {"user", "assistant"}
_SNIPPET_START = "\x01"
_SNIPPET_END = "\x02"


class TranscriptSearchError(RuntimeError):
    """Raised when the transcript index cannot serve a search."""


class TranscriptIndex:
    """Global FTS index over saved session transcripts."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path is not None else DEFAULT_PATH
        self._lock = threading.RLock()
        self._build_thread: threading.Thread | None = None
        self._abort_build = False
        self._initialize()

    # ---------------------------------------------------------------- schema

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    def _initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._lock, self._connect() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            version = 0
            try:
                row = connection.execute(
                    "SELECT schema_version FROM settings WHERE singleton=1"
                ).fetchone()
                version = int(row[0]) if row else 0
            except sqlite3.DatabaseError:
                version = 0
            if version != SCHEMA_VERSION:
                connection.executescript(
                    """
                    DROP TABLE IF EXISTS settings;
                    DROP TABLE IF EXISTS sessions;
                    DROP TABLE IF EXISTS messages_fts;
                    """
                )
            connection.executescript(
                f"""
                CREATE TABLE IF NOT EXISTS settings (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    schema_version INTEGER NOT NULL DEFAULT {SCHEMA_VERSION},
                    built_at REAL
                );
                INSERT OR IGNORE INTO settings(singleton, schema_version)
                    VALUES(1, {SCHEMA_VERSION});
                CREATE TABLE IF NOT EXISTS sessions (
                    session_id TEXT PRIMARY KEY,
                    mtime REAL NOT NULL,
                    size INTEGER NOT NULL,
                    indexed_bytes INTEGER NOT NULL,
                    message_count INTEGER NOT NULL,
                    indexed_at REAL NOT NULL
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                    content, session_id UNINDEXED, message_index UNINDEXED,
                    role UNINDEXED, tokenize='unicode61'
                );
                """
            )
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    # ----------------------------------------------------------------- sync

    def sync(self) -> dict[str, int]:
        """Bring the index up to date with the sessions directory.

        Returns ``{"updated": n, "removed": n, "pending": n}``. ``pending`` is
        nonzero only while a large first build continues on the background
        thread; callers surface it as ``indexing``.
        """
        with self._lock:
            on_disk: dict[str, Path] = {
                path.stem: path for path in SessionStore.list_sessions()
            }
            with self._connect() as connection:
                known = {
                    str(row["session_id"]): row
                    for row in connection.execute("SELECT * FROM sessions").fetchall()
                }
            # Removals always run, even mid-build: a trashed session must stop
            # matching on the very next search, not when the build finishes.
            removed = 0
            for session_id in known:
                if session_id not in on_disk:
                    self._forget(session_id)
                    removed += 1
            if self._build_thread is not None and self._build_thread.is_alive():
                return {"updated": 0, "removed": removed, "pending": 1}
            stale: list[tuple[str, Path, sqlite3.Row | None]] = []
            pending_bytes = 0
            for session_id, path in on_disk.items():
                try:
                    stat = path.stat()
                except OSError:
                    continue
                if stat.st_size > MAX_SESSION_BYTES:
                    continue
                row = known.get(session_id)
                if row is not None and row["mtime"] == stat.st_mtime \
                        and row["size"] == stat.st_size:
                    continue
                stale.append((session_id, path, row))
                already = int(row["indexed_bytes"]) if row is not None else 0
                pending_bytes += max(stat.st_size - min(already, stat.st_size), 0)
            if not stale:
                return {"updated": 0, "removed": removed, "pending": 0}
            self._abort_build = False
            if pending_bytes > BACKGROUND_BUILD_BYTES:
                worker = threading.Thread(
                    target=self._index_many,
                    args=(stale,),
                    name="transcript-index-build",
                    daemon=True,
                )
                self._build_thread = worker
                worker.start()
                return {"updated": 0, "removed": removed, "pending": len(stale)}
            self._index_many(stale)
            return {"updated": len(stale), "removed": removed, "pending": 0}

    @property
    def is_indexing(self) -> bool:
        thread = self._build_thread
        return thread is not None and thread.is_alive()

    def _index_many(self, stale: list[tuple[str, Path, sqlite3.Row | None]]) -> None:
        for session_id, path, row in stale:
            # Per-file lock so a concurrent delete_all interleaves atomically;
            # its abort flag stops the rest of a build whose inputs it wiped.
            with self._lock:
                if self._abort_build:
                    return
                try:
                    self._index_file(session_id, path, row)
                except (OSError, sqlite3.DatabaseError):
                    continue

    def _forget(self, session_id: str) -> None:
        with self._connect() as connection:
            connection.execute(
                "DELETE FROM messages_fts WHERE session_id=?", (session_id,)
            )
            connection.execute("DELETE FROM sessions WHERE session_id=?", (session_id,))

    def _index_file(
        self, session_id: str, path: Path, row: sqlite3.Row | None
    ) -> None:
        """Parse ``path`` from its last indexed byte and index new messages.

        ``message_index`` must count exactly the records ``SessionStore.load``
        keeps — every ``type == "message"`` record with a dict payload — so a
        hit addresses the same position the session-detail endpoint returns.
        """
        try:
            stat = path.stat()
        except OSError:
            return
        start_byte = 0
        message_index = 0
        if row is not None:
            if stat.st_size >= int(row["size"]):
                start_byte = int(row["indexed_bytes"])
                message_index = int(row["message_count"])
            else:
                # Shrunk or replaced (restore, rewrite): re-read from zero.
                self._forget(session_id)
        rows: list[tuple[str, str, int, str]] = []
        consumed = start_byte
        with path.open("rb") as handle:
            handle.seek(start_byte)
            while True:
                raw = handle.readline()
                if not raw:
                    break
                if not raw.endswith(b"\n"):
                    # A torn tail is mid-write; it re-parses on the next sync.
                    break
                consumed += len(raw)
                if len(raw) > MAX_SESSION_LINE_BYTES or not raw.strip():
                    continue
                try:
                    record = _loads(raw)
                except ValueError:
                    continue
                if not isinstance(record, dict):
                    continue
                message = record.get("message")
                if record.get("type") != "message" or not isinstance(message, dict):
                    continue
                position = message_index
                message_index += 1
                if message_index > MAX_SESSION_MESSAGES:
                    break
                role = str(message.get("role") or "")
                if role not in _INDEXED_ROLES:
                    continue
                content = message.get("content")
                if not isinstance(content, str) or not content.strip():
                    continue
                if role == "user":
                    content = strip_prompt_decoration(content)
                    if not content:
                        continue
                rows.append((content[:MAX_MESSAGE_CHARS], session_id, position, role))
        with self._connect() as connection:
            for content, sid, position, role in rows:
                connection.execute(
                    "INSERT INTO messages_fts(content, session_id, message_index, role)"
                    " VALUES(?, ?, ?, ?)",
                    (content, sid, position, role),
                )
            connection.execute(
                """INSERT INTO sessions(
                       session_id, mtime, size, indexed_bytes, message_count, indexed_at
                   ) VALUES(?, ?, ?, ?, ?, ?)
                   ON CONFLICT(session_id) DO UPDATE SET
                       mtime=excluded.mtime, size=excluded.size,
                       indexed_bytes=excluded.indexed_bytes,
                       message_count=excluded.message_count,
                       indexed_at=excluded.indexed_at""",
                (session_id, stat.st_mtime, stat.st_size, consumed,
                 message_index, time.time()),
            )
            connection.execute(
                "UPDATE settings SET built_at=? WHERE singleton=1", (time.time(),)
            )

    # --------------------------------------------------------------- search

    def search(self, query: str, limit: int = 20) -> dict[str, Any]:
        started = time.monotonic()
        query = query.strip()[:MAX_QUERY_CHARS]
        if not query:
            raise TranscriptSearchError("transcript search requires a query")
        limit = min(max(int(limit), 1), 50)
        status = self.sync()
        terms = [
            term for term in re.findall(r"[\w.-]+", query, flags=re.UNICODE)
            if len(term) > 1
        ]
        fts_query = " OR ".join(
            f'"{term.replace(chr(34), chr(34) * 2)}"' for term in terms[:16]
        )
        results: list[dict[str, Any]] = []
        if fts_query:
            meta = SessionMeta.all()
            per_session: dict[str, int] = {}
            with self._lock, self._connect() as connection:
                rows = connection.execute(
                    f"""SELECT session_id, message_index, role, bm25(messages_fts) AS rank,
                               snippet(messages_fts, 0, '{_SNIPPET_START}',
                                       '{_SNIPPET_END}', '…', 24) AS snippet
                        FROM messages_fts WHERE messages_fts MATCH ?
                        ORDER BY rank LIMIT ?""",
                    (fts_query, limit * 6),
                ).fetchall()
                stats = {
                    str(row["session_id"]): row
                    for row in connection.execute("SELECT * FROM sessions").fetchall()
                }
            for position, row in enumerate(rows):
                session_id = str(row["session_id"])
                if per_session.get(session_id, 0) >= MAX_HITS_PER_SESSION:
                    continue
                stat_row = stats.get(session_id)
                if stat_row is None:
                    continue
                per_session[session_id] = per_session.get(session_id, 0) + 1
                snippet, highlights = _split_snippet(str(row["snippet"] or ""))
                entry = meta.get(session_id, {})
                results.append({
                    "session_id": session_id,
                    "title": entry.get("title"),
                    "pinned": bool(entry.get("pinned", False)),
                    "mtime": float(stat_row["mtime"]),
                    "message_index": int(row["message_index"]),
                    "role": str(row["role"] or ""),
                    "snippet": snippet,
                    "highlights": highlights,
                    "score": 1.0 / (position + 1),
                })
                if len(results) >= limit:
                    break
        return {
            "query": query,
            "indexing": status["pending"] > 0 or self.is_indexing,
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
            "results": results,
        }

    def delete_all(self) -> None:
        with self._lock:
            # A background build started before the wipe must not re-insert
            # text for sessions the user just cleared.
            self._abort_build = True
            with self._connect() as connection:
                connection.execute("DELETE FROM messages_fts")
                connection.execute("DELETE FROM sessions")


def _loads(raw: bytes) -> Any:
    return json.loads(raw.decode("utf-8", errors="replace"))


def _split_snippet(marked: str) -> tuple[str, list[list[int]]]:
    """Convert sentinel-marked snippet text into plain text + highlight ranges."""
    plain: list[str] = []
    highlights: list[list[int]] = []
    length = 0
    open_at: int | None = None
    for char in marked:
        if char == _SNIPPET_START:
            open_at = length
            continue
        if char == _SNIPPET_END:
            if open_at is not None and length > open_at:
                highlights.append([open_at, length - open_at])
            open_at = None
            continue
        plain.append(char)
        length += 1
    return "".join(plain), highlights
