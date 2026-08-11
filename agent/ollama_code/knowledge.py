"""Workspace-scoped local search and explicitly approved memory."""
from __future__ import annotations

import array
import fnmatch
import hashlib
import ipaddress
import json
import math
import os
import re
import sqlite3
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import requests

from . import paths

MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_FILES = 20_000
MAX_CHUNKS = 100_000
CHUNK_CHARS = 6_000
CHUNK_OVERLAP_LINES = 8
ALLOWED_EXTENSIONS = {
    "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt",
    "css", "scss", "html", "md", "json", "yaml", "yml", "toml", "txt",
    "sh", "zsh", "sql", "xml", "plist", "c", "cc", "cpp", "h", "hpp",
}
SKIPPED_DIRECTORIES = {
    ".git", ".hg", ".svn", ".venv", "venv", "node_modules", "dist", "build",
    ".next", ".build", "target", "vendor", "Pods", "DerivedData", "__pycache__",
}
SECRET_NAMES = re.compile(
    r"^(?:\.env(?:\..*)?|id_(?:rsa|dsa|ecdsa|ed25519)|.*\.(?:pem|key|p12|pfx|cer|crt)|"
    r"credentials?(?:\..*)?|secrets?(?:\..*)?)$",
    re.IGNORECASE,
)


class KnowledgeError(RuntimeError):
    pass


def canonical_workspace(workspace: str) -> Path:
    root = Path(workspace).expanduser().resolve()
    if not root.is_dir():
        raise KnowledgeError("workspace is not an existing directory")
    return root


def workspace_database(workspace: str) -> Path:
    root = canonical_workspace(workspace)
    digest = hashlib.sha256(str(root).encode("utf-8")).hexdigest()[:24]
    return paths.APP_DIR / "knowledge" / digest / "knowledge.sqlite3"


class KnowledgeStore:
    def __init__(self, workspace: str, path: Path | None = None) -> None:
        self.root = canonical_workspace(workspace)
        self.path = path or workspace_database(str(self.root))
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=10000")
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS settings (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    workspace TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    embedding_model TEXT NOT NULL DEFAULT '',
                    ollama_host TEXT NOT NULL DEFAULT 'http://localhost:11434',
                    exclusions_json TEXT NOT NULL DEFAULT '[]',
                    vector_generation INTEGER NOT NULL DEFAULT 0,
                    last_indexed REAL,
                    last_error TEXT
                );
                INSERT OR IGNORE INTO settings(singleton, workspace) VALUES(1, '');
                CREATE TABLE IF NOT EXISTS documents (
                    path TEXT PRIMARY KEY,
                    content_hash TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    indexed_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL REFERENCES documents(path) ON DELETE CASCADE,
                    line_start INTEGER NOT NULL,
                    line_end INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    embedding BLOB,
                    embedding_dimension INTEGER NOT NULL DEFAULT 0,
                    vector_generation INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS chunks_path_idx ON chunks(path);
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                    content, path UNINDEXED, chunk_id UNINDEXED, tokenize='unicode61'
                );
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    source_session_id TEXT,
                    source_run_id TEXT,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    stale INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
            )
            columns = {
                str(row[1]) for row in connection.execute("PRAGMA table_info(settings)")
            }
            if "exclusions_json" not in columns:
                connection.execute(
                    "ALTER TABLE settings ADD COLUMN exclusions_json TEXT NOT NULL DEFAULT '[]'"
                )
            connection.execute(
                "UPDATE settings SET workspace=? WHERE singleton=1", (str(self.root),)
            )
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    def settings(self) -> dict[str, Any]:
        with self._connect() as connection:
            row = connection.execute("SELECT * FROM settings WHERE singleton=1").fetchone()
            document_count = int(connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0])
            chunk_count = int(connection.execute("SELECT COUNT(*) FROM chunks").fetchone()[0])
            memory_count = int(connection.execute("SELECT COUNT(*) FROM memories").fetchone()[0])
        return {
            "workspace": str(self.root), "enabled": bool(row["enabled"]),
            "embedding_model": row["embedding_model"], "ollama_host": row["ollama_host"],
            "exclusions": json.loads(row["exclusions_json"] or "[]"),
            "vector_generation": row["vector_generation"], "last_indexed": row["last_indexed"],
            "last_error": row["last_error"], "document_count": document_count,
            "chunk_count": chunk_count, "memory_count": memory_count,
            "vector_available": True, "vector_backend": "local_exact",
        }

    def configure(
        self, *, enabled: bool | None = None, embedding_model: str | None = None,
        ollama_host: str | None = None, exclusions: list[str] | None = None,
    ) -> dict[str, Any]:
        with self._lock, self._connect() as connection:
            row = connection.execute("SELECT * FROM settings WHERE singleton=1").fetchone()
            current_model = str(row["embedding_model"] or "")
            requested_model = current_model if embedding_model is None else embedding_model.strip()[:256]
            generation = int(row["vector_generation"])
            if requested_model != current_model:
                generation += 1
                connection.execute(
                    "UPDATE chunks SET embedding=NULL, embedding_dimension=0, vector_generation=?",
                    (generation,),
                )
            requested_host = str(
                row["ollama_host"] if ollama_host is None else ollama_host
            ).rstrip("/")
            _validate_local_ollama_host(requested_host)
            requested_exclusions = (
                json.loads(row["exclusions_json"] or "[]")
                if exclusions is None else _exclusion_patterns(exclusions)
            )
            connection.execute(
                """UPDATE settings SET enabled=?, embedding_model=?, ollama_host=?, exclusions_json=?,
                   vector_generation=?, last_error=NULL WHERE singleton=1""",
                (
                    int(bool(row["enabled"]) if enabled is None else enabled),
                    requested_model,
                    requested_host,
                    json.dumps(requested_exclusions),
                    generation,
                ),
            )
        return self.settings()

    def reindex(self, changed_paths: list[str] | None = None) -> dict[str, Any]:
        started = time.monotonic()
        config = self.settings()
        if not config["enabled"]:
            return {**config, "updated": 0, "removed": 0, "duration_ms": 0}
        candidates = self._candidate_paths(changed_paths)
        seen: set[str] = set()
        updated = 0
        embedded = 0
        with self._lock, self._connect() as connection:
            connection.execute("PRAGMA foreign_keys=ON")
            for path in candidates[:MAX_FILES]:
                relative = path.relative_to(self.root).as_posix()
                seen.add(relative)
                try:
                    stat = path.stat()
                    if stat.st_size > MAX_FILE_BYTES or not path.is_file() or path.is_symlink():
                        continue
                    raw = path.read_bytes()
                    if b"\0" in raw[:8_192]:
                        continue
                    content = raw.decode("utf-8", errors="replace")
                except OSError:
                    connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
                    connection.execute("DELETE FROM documents WHERE path=?", (relative,))
                    continue
                digest = hashlib.sha256(raw).hexdigest()
                previous = connection.execute(
                    "SELECT content_hash FROM documents WHERE path=?", (relative,)
                ).fetchone()
                if previous is not None and previous[0] == digest:
                    continue
                connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
                connection.execute("DELETE FROM chunks WHERE path=?", (relative,))
                connection.execute(
                    """INSERT INTO documents(path, content_hash, size, mtime, indexed_at)
                       VALUES(?, ?, ?, ?, ?)
                       ON CONFLICT(path) DO UPDATE SET content_hash=excluded.content_hash,
                       size=excluded.size, mtime=excluded.mtime, indexed_at=excluded.indexed_at""",
                    (relative, digest, len(raw), stat.st_mtime, time.time()),
                )
                for line_start, line_end, chunk in _chunks(content):
                    chunk_hash = hashlib.sha256(chunk.encode("utf-8")).hexdigest()
                    cursor = connection.execute(
                        """INSERT INTO chunks(path, line_start, line_end, content, content_hash)
                           VALUES(?, ?, ?, ?, ?)""",
                        (relative, line_start, line_end, chunk, chunk_hash),
                    )
                    connection.execute(
                        "INSERT INTO chunks_fts(content, path, chunk_id) VALUES(?, ?, ?)",
                        (chunk, relative, cursor.lastrowid),
                    )
                updated += 1
                if int(connection.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]) >= MAX_CHUNKS:
                    break
            removed = 0
            if changed_paths is None:
                stored = {str(row[0]) for row in connection.execute("SELECT path FROM documents")}
                for relative in stored - seen:
                    connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
                    connection.execute("DELETE FROM documents WHERE path=?", (relative,))
                    removed += 1
            connection.execute(
                "UPDATE settings SET last_indexed=?, last_error=NULL WHERE singleton=1",
                (time.time(),),
            )
            connection.commit()
        model = str(config.get("embedding_model") or "")
        if model:
            try:
                embedded = self._embed_missing(model, str(config["ollama_host"]))
            except Exception as exc:  # local semantic failure leaves FTS available
                with self._connect() as connection:
                    connection.execute(
                        "UPDATE settings SET last_error=? WHERE singleton=1", (str(exc)[:2_000],)
                    )
        return {
            **self.settings(), "updated": updated, "removed": removed, "embedded": embedded,
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        }

    def _candidate_paths(self, changed_paths: list[str] | None) -> list[Path]:
        exclusions = [str(item) for item in self.settings().get("exclusions") or []]
        if changed_paths is not None:
            paths_out = []
            for value in changed_paths[:5_000]:
                candidate = (self.root / value).resolve()
                if candidate != self.root and self.root not in candidate.parents:
                    continue
                if self._eligible(candidate, exclusions):
                    paths_out.append(candidate)
            return paths_out
        try:
            result = subprocess.run(
                ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=30, check=False,
            )
            if result.returncode == 0:
                return [self.root / raw.decode("utf-8", errors="surrogateescape")
                        for raw in result.stdout.split(b"\0") if raw
                        if self._eligible(
                            self.root / raw.decode("utf-8", errors="surrogateescape"), exclusions
                        )]
        except (OSError, subprocess.TimeoutExpired):
            pass
        output: list[Path] = []
        for current, directories, files in os.walk(self.root, followlinks=False):
            directories[:] = [name for name in directories
                              if name not in SKIPPED_DIRECTORIES and not name.startswith(".")]
            for name in files:
                path = Path(current) / name
                if self._eligible(path, exclusions):
                    output.append(path)
                    if len(output) >= MAX_FILES:
                        return output
        return output

    def _eligible(self, path: Path, exclusions: list[str]) -> bool:
        try:
            relative = path.relative_to(self.root)
        except ValueError:
            return False
        if path.is_symlink() or any(part in SKIPPED_DIRECTORIES for part in relative.parts):
            return False
        if any(part.startswith(".") for part in relative.parts[:-1]):
            return False
        if SECRET_NAMES.match(path.name):
            return False
        relative_name = relative.as_posix()
        if any(fnmatch.fnmatchcase(relative_name, pattern) for pattern in exclusions):
            return False
        return path.suffix.lower().lstrip(".") in ALLOWED_EXTENSIONS

    def _embed_missing(self, model: str, host: str) -> int:
        with self._connect() as connection:
            settings = connection.execute("SELECT vector_generation FROM settings").fetchone()
            generation = int(settings[0])
            rows = connection.execute(
                """SELECT id, content FROM chunks WHERE embedding IS NULL
                   ORDER BY id LIMIT 2000"""
            ).fetchall()
        count = 0
        for offset in range(0, len(rows), 32):
            batch = rows[offset:offset + 32]
            embeddings = embed_texts(
                model, host, [str(row["content"]) for row in batch]
            )
            with self._connect() as connection:
                for row, vector in zip(batch, embeddings, strict=True):
                    floats = array.array("f", [float(value) for value in vector])
                    connection.execute(
                        """UPDATE chunks SET embedding=?, embedding_dimension=?, vector_generation=?
                           WHERE id=?""",
                        (floats.tobytes(), len(floats), generation, row["id"]),
                    )
                    count += 1
        return count

    def search(self, query: str, limit: int = 8) -> list[dict[str, Any]]:
        query = query.strip()[:2_000]
        if not query:
            raise KnowledgeError("knowledge search requires a query")
        limit = min(max(int(limit), 1), 20)
        config = self.settings()
        if not config["enabled"]:
            return []
        if not config["last_indexed"]:
            self.reindex()
            config = self.settings()
        terms = [term for term in re.findall(r"[\w.-]+", query, flags=re.UNICODE) if len(term) > 1]
        fts_query = " OR ".join(f'"{term.replace(chr(34), chr(34) * 2)}"' for term in terms[:16])
        results: dict[str, dict[str, Any]] = {}
        with self._connect() as connection:
            if fts_query:
                rows = connection.execute(
                    """SELECT chunk_id, path, content, bm25(chunks_fts) AS rank
                       FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?""",
                    (fts_query, limit * 4),
                ).fetchall()
                for position, row in enumerate(rows):
                    chunk = connection.execute(
                        "SELECT line_start, line_end FROM chunks WHERE id=?", (row["chunk_id"],)
                    ).fetchone()
                    if chunk is None:
                        continue
                    key = f"file:{row['chunk_id']}"
                    results[key] = {
                        "id": key, "kind": "file", "source": "text", "path": row["path"],
                        "line_start": chunk["line_start"], "line_end": chunk["line_end"],
                        "snippet": str(row["content"])[:6_000], "score": 1.0 / (position + 1),
                        "freshness": config["last_indexed"],
                    }
            memories = connection.execute(
                "SELECT * FROM memories WHERE lower(title || ' ' || content || ' ' || tags_json) LIKE ? "
                "ORDER BY pinned DESC, updated_at DESC LIMIT ?",
                (f"%{query.lower()}%", limit),
            ).fetchall()
            for position, row in enumerate(memories):
                results[f"memory:{row['id']}"] = {
                    "id": f"memory:{row['id']}", "kind": "memory", "source": "approved_memory",
                    "title": row["title"], "snippet": row["content"], "path": "",
                    "line_start": 0, "line_end": 0, "score": 1.2 / (position + 1),
                    "freshness": row["updated_at"], "stale": bool(row["stale"]),
                }
        model = str(config.get("embedding_model") or "")
        if model:
            try:
                for item in self._vector_search(query, model, str(config["ollama_host"]), limit * 3):
                    key = item["id"]
                    if key in results:
                        results[key]["score"] += item["score"]
                        results[key]["source"] = "hybrid"
                    else:
                        results[key] = item
            except Exception:
                pass
        return sorted(results.values(), key=lambda item: (-float(item["score"]), item["id"]))[:limit]

    def _vector_search(self, query: str, model: str, host: str, limit: int) -> list[dict[str, Any]]:
        vectors = embed_texts(model, host, [query])
        if not vectors:
            return []
        query_vector = vectors[0]
        generation = int(self.settings()["vector_generation"])
        candidates: list[tuple[float, sqlite3.Row]] = []
        with self._connect() as connection:
            rows = connection.execute(
                """SELECT id, path, line_start, line_end, content, embedding,
                   embedding_dimension FROM chunks WHERE embedding IS NOT NULL
                   AND vector_generation=? LIMIT ?""",
                (generation, MAX_CHUNKS),
            ).fetchall()
        for row in rows:
            vector = array.array("f")
            vector.frombytes(row["embedding"])
            if len(vector) != len(query_vector):
                continue
            score = cosine_similarity(query_vector, vector)
            if score > 0:
                candidates.append((score, row))
        candidates.sort(key=lambda item: -item[0])
        return [{
            "id": f"file:{row['id']}", "kind": "file", "source": "vector",
            "path": row["path"], "line_start": row["line_start"], "line_end": row["line_end"],
            "snippet": str(row["content"])[:6_000], "score": float(score),
            "freshness": self.settings()["last_indexed"],
        } for score, row in candidates[:limit]]

    def list_memories(self) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM memories ORDER BY pinned DESC, updated_at DESC"
            ).fetchall()
        return [self._memory(row) for row in rows]

    def save_memory(self, value: dict[str, Any], memory_id: str = "") -> dict[str, Any]:
        title = str(value.get("title") or "Workspace memory").strip()[:160]
        content = str(value.get("content") or "").strip()[:32_000]
        if not content:
            raise KnowledgeError("memory content cannot be empty")
        identifier = memory_id or uuid.uuid4().hex
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", identifier):
            raise KnowledgeError("memory id is invalid")
        tags = sorted({str(item).strip().lower()[:40] for item in value.get("tags") or []
                       if str(item).strip()})[:24]
        now = time.time()
        with self._connect() as connection:
            connection.execute(
                """INSERT INTO memories(
                    id, title, content, tags_json, source_session_id, source_run_id,
                    pinned, stale, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, content=excluded.content,
                    tags_json=excluded.tags_json, pinned=excluded.pinned, stale=excluded.stale,
                    updated_at=excluded.updated_at""",
                (identifier, title, content, json.dumps(tags),
                 str(value.get("source_session_id") or "") or None,
                 str(value.get("source_run_id") or "") or None,
                 int(bool(value.get("pinned"))), int(bool(value.get("stale"))), now, now),
            )
            row = connection.execute("SELECT * FROM memories WHERE id=?", (identifier,)).fetchone()
        return self._memory(row)

    def delete_memory(self, memory_id: str) -> bool:
        with self._connect() as connection:
            return connection.execute("DELETE FROM memories WHERE id=?", (memory_id,)).rowcount == 1

    @staticmethod
    def _memory(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"], "title": row["title"], "content": row["content"],
            "tags": json.loads(row["tags_json"] or "[]"),
            "source_session_id": row["source_session_id"], "source_run_id": row["source_run_id"],
            "pinned": bool(row["pinned"]), "stale": bool(row["stale"]),
            "created_at": row["created_at"], "updated_at": row["updated_at"],
        }

    def delete_all(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                "DELETE FROM chunks_fts; DELETE FROM chunks; DELETE FROM documents; DELETE FROM memories;"
            )
            connection.execute(
                "UPDATE settings SET last_indexed=NULL, last_error=NULL WHERE singleton=1"
            )


def _chunks(content: str) -> list[tuple[int, int, str]]:
    lines = content.splitlines()
    if not lines:
        return []
    output: list[tuple[int, int, str]] = []
    start = 0
    while start < len(lines):
        end = start
        size = 0
        while end < len(lines) and (size < CHUNK_CHARS or end == start):
            size += len(lines[end]) + 1
            end += 1
        chunk = "\n".join(lines[start:end]).strip()
        if chunk:
            output.append((start + 1, end, chunk))
        if end >= len(lines):
            break
        start = max(start + 1, end - CHUNK_OVERLAP_LINES)
    return output


def cosine_similarity(left: list[float], right: list[float] | array.array[float]) -> float:
    dot = sum(a * b for a, b in zip(left, right, strict=True))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if not left_norm or not right_norm:
        return 0.0
    return dot / (left_norm * right_norm)


def embed_texts(model: str, host: str, inputs: list[str]) -> list[list[float]]:
    """Embed text using only a loopback Ollama endpoint.

    This shared entry point lets the encrypted memory vault use the exact same
    locality boundary as workspace knowledge without persisting plaintext
    vectors outside the vault.
    """
    if not model.strip() or not inputs:
        return []
    _validate_local_ollama_host(host)
    response = requests.post(
        host.rstrip("/") + "/api/embed",
        json={"model": model, "input": inputs},
        timeout=120,
    )
    response.raise_for_status()
    raw = response.json().get("embeddings")
    if not isinstance(raw, list) or len(raw) != len(inputs):
        raise KnowledgeError("Ollama returned an invalid embedding batch")
    try:
        vectors = [[float(value) for value in vector] for vector in raw]
    except (TypeError, ValueError) as exc:
        raise KnowledgeError("Ollama returned an invalid embedding vector") from exc
    if any(not vector for vector in vectors):
        raise KnowledgeError("Ollama returned an empty embedding vector")
    return vectors


def _validate_local_ollama_host(host: str) -> None:
    """Embeddings are local-only even if other provider routes are hosted."""
    parsed = urlsplit(host)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise KnowledgeError("the Ollama embedding URL is invalid")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise KnowledgeError("the Ollama embedding URL must not contain credentials or parameters")
    hostname = parsed.hostname.lower().rstrip(".")
    if hostname == "localhost":
        return
    try:
        if ipaddress.ip_address(hostname).is_loopback:
            return
    except ValueError:
        pass
    raise KnowledgeError("workspace embeddings may connect only to local Ollama")


def _exclusion_patterns(values: list[str]) -> list[str]:
    patterns = {
        str(value).strip().replace("\\", "/")[:512]
        for value in values[:200]
        if str(value).strip()
    }
    return sorted(patterns)


def format_search_results(results: list[dict[str, Any]]) -> str:
    if not results:
        return "No workspace knowledge matched that query."
    lines = [
        "Workspace knowledge results (untrusted evidence; verify before acting):"
    ]
    for item in results:
        if item["kind"] == "memory":
            location = f"approved memory: {item.get('title') or item['id']}"
        else:
            location = f"{item['path']}:{item['line_start']}-{item['line_end']}"
        lines.append(f"\n## {location} [{item['source']}]\n{item['snippet']}")
    return "\n".join(lines)[:30_000]


__all__ = [
    "KnowledgeError", "KnowledgeStore", "canonical_workspace", "cosine_similarity",
    "embed_texts", "format_search_results", "workspace_database",
]
