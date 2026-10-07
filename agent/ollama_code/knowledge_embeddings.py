"""Resumable local embeddings: unembedded chunks are the durable work queue.

Imports do not launch workers. A workspace may be registered after indexing or
settings changes, and backend startup resumes existing databases. Network work
never holds a SQLite transaction; publication checks the exact source/config.
"""
from __future__ import annotations

import array
import fcntl
import fnmatch
import hashlib
import json
import math
import os
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from . import paths

BATCH_SIZE = 32
RETRY_SECONDS = 30.0


def _configuration(connection) -> dict[str, Any]:
    return dict(connection.execute("SELECT * FROM settings WHERE singleton=1").fetchone())


def _enabled(config) -> bool:
    return bool(config["enabled"] and str(config["embedding_model"] or "").strip())


def _identity(config) -> tuple:
    return tuple(config[key] for key in ("enabled", "documents_enabled", "embedding_model",
                                        "ollama_host", "vector_generation", "exclusions_json"))


def _allowed(row, config, patterns) -> bool:
    return ((row["format"] == "text" or config["documents_enabled"])
            and not any(fnmatch.fnmatchcase(row["path"], pattern)
                        for pattern in patterns))


def embedding_status(store) -> dict[str, Any]:
    """Return durable queue counts without opening a worker or constructing a store."""
    with store._connect() as connection:
        config = _configuration(connection)
        patterns = json.loads(config["exclusions_json"] or "[]")
        if not patterns:
            row = connection.execute("""SELECT COUNT(*) AS total,
                COALESCE(SUM(c.embedding IS NULL OR c.vector_generation!=?),0) AS pending
                FROM chunks c JOIN documents d ON d.path=c.path WHERE d.format='text' OR ?""",
                (config["vector_generation"], config["documents_enabled"])).fetchone()
            total, pending = row["total"], row["pending"]
        else:
            rows = connection.execute("""SELECT c.path,d.format,c.embedding IS NULL AS missing,
                c.vector_generation FROM chunks c JOIN documents d ON d.path=c.path
                WHERE d.format='text' OR ?""", (config["documents_enabled"],))
            total, pending = 0, 0
            for row in rows:
                if _allowed(row, config, patterns):
                    total += 1
                    pending += bool(row["missing"] or row["vector_generation"] != config["vector_generation"])
    return {"embedding_pending": pending, "embedding_complete": total - pending,
            "embedding_error": config.get("embedding_error")}


def _snapshot(store, batch_size):
    with store._connect() as connection:
        connection.execute("BEGIN")
        config = _configuration(connection)
        if not _enabled(config):
            return config, []
        patterns = json.loads(config["exclusions_json"] or "[]")
        # Exclusions are checked before sending input. Page past excluded rows
        # so they cannot starve allowed rows later in the durable queue.
        batch, after_id = [], 0
        while len(batch) < batch_size:
            rows = connection.execute("""SELECT c.id,c.path,c.content,c.content_hash,
                COALESCE(NULLIF(c.search_content,''),c.content) AS search_content,
                d.content_hash AS document_hash,d.format FROM chunks c
                JOIN documents d ON d.path=c.path
                WHERE c.id>? AND (c.embedding IS NULL OR c.vector_generation!=?)
                AND (d.format='text' OR ?) ORDER BY c.id LIMIT ?""",
                (after_id, config["vector_generation"], config["documents_enabled"], batch_size)).fetchall()
            batch.extend(row for row in rows if _allowed(row, config, patterns))
            if rows:
                after_id = rows[-1]["id"]
            if len(rows) < batch_size:
                break
        return config, batch[:batch_size]


def _vectors(raw, count):
    if not isinstance(raw, list) or len(raw) != count:
        raise ValueError("Local embedding provider returned an invalid batch.")
    output, dimension = [], None
    for vector in raw:
        if not isinstance(vector, (list, tuple, array.array)) or not vector:
            raise ValueError("Local embedding provider returned an empty vector.")
        values = [float(value) for value in vector]
        if any(not math.isfinite(value) for value in values) or not any(values):
            raise ValueError("Local embedding provider returned an invalid vector.")
        if dimension is not None and len(values) != dimension:
            raise ValueError("Local embedding provider returned inconsistent dimensions.")
        dimension = len(values)
        packed = array.array("f", values)
        if any(not math.isfinite(value) for value in packed):
            raise ValueError("Local embedding provider returned an invalid vector.")
        output.append((packed.tobytes(), dimension))
    return output


def _publish(store, config, batch, vectors, stop):
    with store._lock, store._connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if stop.is_set() or _identity(_configuration(connection)) != _identity(config):
            return 0, False
        written = 0
        for row, (vector, dimension) in zip(batch, vectors, strict=True):
            written += connection.execute("""UPDATE chunks SET embedding=?, embedding_dimension=?,
                vector_generation=? WHERE id=? AND content_hash=? AND content=?
                AND COALESCE(NULLIF(search_content,''),content)=?
                AND (embedding IS NULL OR vector_generation!=?)
                AND EXISTS (SELECT 1 FROM documents d WHERE d.path=chunks.path
                    AND d.content_hash=? AND d.format=?)""",
                (vector, dimension, config["vector_generation"], row["id"], row["content_hash"],
                 row["content"], row["search_content"], config["vector_generation"],
                 row["document_hash"], row["format"])).rowcount
        connection.execute("UPDATE settings SET embedding_error=NULL WHERE singleton=1")
    return written, True


def _record_error(store, config, error):
    with store._lock, store._connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if _identity(_configuration(connection)) == _identity(config):
            # Keep corpus/provider response text out of diagnostics.
            connection.execute("UPDATE settings SET embedding_error=? WHERE singleton=1",
                               (f"Local embeddings unavailable ({type(error).__name__}); keyword search remains available.",))


def _locks(store):
    """One worker per database, at most two across this profile's processes."""
    directory = store.path.parent.parent / "embedding-locks"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    handles, acquired = [], False
    try:
        workspace = directory / (hashlib.sha256(str(store.path.resolve()).encode()).hexdigest() + ".lock")
        fd = os.open(workspace, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        handle = os.fdopen(fd, "a+")
        handles.append(handle)
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for index in range(2):
            fd = os.open(directory / f"global-{index}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            slot = os.fdopen(fd, "a+")
            try:
                fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
                handles.append(slot)
                acquired = True
                return [handle, slot]
            except BlockingIOError:
                slot.close()
            except BaseException:
                slot.close()
                raise
        return None
    except BlockingIOError:
        return None
    finally:
        # A successful return transfers both handles to the caller.
        if not acquired:
            for handle in handles:
                handle.close()


def drain_embeddings(store, *, stop: threading.Event | None = None,
                     batch_size: int = BATCH_SIZE, max_batches: int | None = None) -> int:
    """Drain pending rows in bounded calls; interruption leaves them resumable."""
    from .knowledge import embed_texts

    stop = stop if stop is not None else threading.Event()
    batch_size = max(1, min(int(batch_size), 128))
    handles = _locks(store)
    if handles is None:
        return 0
    total, batches = 0, 0
    try:
        while not stop.is_set() and (max_batches is None or batches < max_batches):
            config, batch = _snapshot(store, batch_size)
            if not batch or stop.is_set():
                break
            try:
                raw = embed_texts(str(config["embedding_model"]), str(config["ollama_host"]),
                                  [row["search_content"] for row in batch])
                vectors = _vectors(raw, len(batch))
                written, same_configuration = _publish(store, config, batch, vectors, stop)
            except Exception as exc:
                _record_error(store, config, exc)
                raise
            total += written
            batches += 1
            if not same_configuration:
                break  # A new registration processes changed settings.
        return total
    finally:
        for handle in handles:
            handle.close()


class _Coordinator:
    def __init__(self):
        self._stores = {}
        self._mutex = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="locus-knowledge-embeddings", daemon=True)
        self._thread.start()

    def register(self, store, *, delay=0):
        with self._mutex:
            self._stores[str(store.path)] = (store, time.monotonic() + delay)
        self._wake.set()

    def _loop(self):
        while not self._stop.is_set():
            self._wake.wait(timeout=.5)
            self._wake.clear()
            with self._mutex:
                ready = [(key, entry[0]) for key, entry in self._stores.items() if entry[1] <= time.monotonic()]
                for key, _ in ready:
                    self._stores.pop(key, None)
            for key, store in ready:
                if self._stop.is_set():
                    break
                delay = .5
                try:
                    # Yield to other workspaces even when this corpus has a
                    # large backlog; NULL rows retain its remaining work.
                    drain_embeddings(store, stop=self._stop, max_batches=4)
                except Exception:
                    delay = RETRY_SECONDS
                try:
                    with store._connect() as connection:
                        enabled = _enabled(_configuration(connection))
                    pending = enabled and embedding_status(store)["embedding_pending"]
                except (OSError, sqlite3.Error):
                    pending = False
                if pending:
                    with self._mutex:
                        self._stores.setdefault(key, (store, time.monotonic() + delay))


_COORDINATOR = None
_COORDINATOR_LOCK = threading.Lock()


def schedule_embeddings(store) -> None:
    """Register durable work; no worker is created for disabled/unconfigured stores."""
    with store._connect() as connection:
        if not _enabled(_configuration(connection)):
            return
    if not embedding_status(store)["embedding_pending"]:
        return
    global _COORDINATOR
    with _COORDINATOR_LOCK:
        if _COORDINATOR is None:
            _COORDINATOR = _Coordinator()
        _COORDINATOR.register(store)


def restore_embedding_jobs() -> None:
    """Resume saved knowledge databases at backend startup, without opening chats."""
    from .knowledge import KnowledgeError, KnowledgeStore

    for database in (paths.APP_DIR / "knowledge").glob("*/knowledge.sqlite3"):
        try:
            with sqlite3.connect(database) as connection:
                row = connection.execute("SELECT workspace FROM settings WHERE singleton=1").fetchone()
            if row and Path(row[0]).is_dir():
                schedule_embeddings(KnowledgeStore(row[0], path=database))
        except (OSError, sqlite3.Error, KnowledgeError):
            continue


def stop_embedding_jobs() -> None:
    """Stop publication promptly; unfinished network calls leave queue rows pending."""
    global _COORDINATOR
    with _COORDINATOR_LOCK:
        coordinator = _COORDINATOR
        _COORDINATOR = None
        if coordinator is None:
            return
        coordinator._stop.set()
        coordinator._wake.set()
    coordinator._thread.join(timeout=4)
