"""Workspace-scoped local retrieval with source-grounded evidence."""
from __future__ import annotations

import array
import copy
import fnmatch
import hashlib
import json
import math
import os
import re
import sqlite3
import subprocess
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

from . import paths
from .knowledge_chunks import CHUNKER_VERSION, extracted_chunks, text_chunks
from .proxy import sanitized_child_environment

MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_FILES = 20_000
MAX_CHUNKS = 100_000
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
_LOCKS: dict[str, threading.RLock] = {}
_LOCKS_GUARD = threading.Lock()


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
        with _LOCKS_GUARD:
            self._lock = _LOCKS.setdefault(str(self.path), threading.RLock())
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=10000")
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    def _initialize(self) -> None:
        with self._lock, self._connect() as connection:
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
            if "documents_enabled" not in columns:
                connection.execute("ALTER TABLE settings ADD COLUMN documents_enabled INTEGER NOT NULL DEFAULT 0")
            for name, declaration in (("embedding_error", "TEXT"), ("rerank_model", "TEXT NOT NULL DEFAULT ''"),
                                      ("index_version", "TEXT NOT NULL DEFAULT ''"),
                                      ("adaptive_rag_enabled", "INTEGER NOT NULL DEFAULT 1")):
                if name not in columns:
                    connection.execute(f"ALTER TABLE settings ADD COLUMN {name} {declaration}")
            document_columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(documents)")}
            if "format" not in document_columns:
                connection.execute("ALTER TABLE documents ADD COLUMN format TEXT NOT NULL DEFAULT 'text'")
            for name, declaration in (("chunker_version", "TEXT NOT NULL DEFAULT ''"), ("source_stat", "TEXT")):
                if name not in document_columns:
                    connection.execute(f"ALTER TABLE documents ADD COLUMN {name} {declaration}")
            chunk_columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(chunks)")}
            if "locator_json" not in chunk_columns:
                connection.execute("ALTER TABLE chunks ADD COLUMN locator_json TEXT")
            for name, declaration in (
                ("context", "TEXT NOT NULL DEFAULT ''"), ("search_content", "TEXT NOT NULL DEFAULT ''"),
                ("parent_key", "TEXT NOT NULL DEFAULT ''"), ("parent_content", "TEXT NOT NULL DEFAULT ''"),
                ("parent_line_start", "INTEGER NOT NULL DEFAULT 0"), ("parent_line_end", "INTEGER NOT NULL DEFAULT 0"),
                ("parent_locator_json", "TEXT"),
            ):
                if name not in chunk_columns:
                    connection.execute(f"ALTER TABLE chunks ADD COLUMN {name} {declaration}")
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
            from .knowledge_embeddings import embedding_status
            progress = embedding_status(self)
        return {
            "workspace": str(self.root), "enabled": bool(row["enabled"]),
            "documents_enabled": bool(row["documents_enabled"]),
            "adaptive_rag_enabled": bool(row["adaptive_rag_enabled"]),
            "embedding_model": row["embedding_model"], "ollama_host": row["ollama_host"],
            "exclusions": json.loads(row["exclusions_json"] or "[]"),
            "vector_generation": row["vector_generation"], "last_indexed": row["last_indexed"],
            "last_error": row["last_error"], "document_count": document_count,
            "chunk_count": chunk_count, "memory_count": memory_count,
            "index_version": row["index_version"], "rerank_model": row["rerank_model"],
            **progress,
            "vector_available": True, "vector_backend": "local_exact",
        }

    def configure(
        self, *, enabled: bool | None = None, embedding_model: str | None = None,
        ollama_host: str | None = None, exclusions: list[str] | None = None,
        documents_enabled: bool | None = None,
        rerank_model: str | None = None,
        adaptive_rag_enabled: bool | None = None,
    ) -> dict[str, Any]:
        with self._lock, self._connect() as connection:
            row = connection.execute("SELECT * FROM settings WHERE singleton=1").fetchone()
            current_model = str(row["embedding_model"] or "")
            requested_model = current_model if embedding_model is None else embedding_model.strip()[:256]
            generation = int(row["vector_generation"])
            requested_host = str(
                row["ollama_host"] if ollama_host is None else ollama_host
            ).rstrip("/")
            _validate_local_ollama_host(requested_host)
            if requested_model != current_model or requested_host != str(row["ollama_host"]).rstrip("/"):
                generation += 1
                connection.execute("UPDATE chunks SET embedding=NULL, embedding_dimension=0, vector_generation=?", (generation,))
            requested_exclusions = (
                json.loads(row["exclusions_json"] or "[]")
                if exclusions is None else _exclusion_patterns(exclusions)
            )
            connection.execute(
                """UPDATE settings SET enabled=?, embedding_model=?, ollama_host=?, exclusions_json=?,
                   vector_generation=?, last_error=NULL, embedding_error=NULL WHERE singleton=1""",
                (
                    int(bool(row["enabled"]) if enabled is None else enabled),
                    requested_model,
                    requested_host,
                    json.dumps(requested_exclusions),
                    generation,
                ),
            )
            if documents_enabled is not None:
                connection.execute("UPDATE settings SET documents_enabled=? WHERE singleton=1", (int(documents_enabled),))
            if rerank_model is not None:
                connection.execute("UPDATE settings SET rerank_model=? WHERE singleton=1", (str(rerank_model).strip()[:256],))
            if adaptive_rag_enabled is not None:
                connection.execute("UPDATE settings SET adaptive_rag_enabled=? WHERE singleton=1", (int(adaptive_rag_enabled),))
            # A disabled library must stop being searchable immediately, even
            # before an extraction job observes its cancellation.
            if documents_enabled is False or enabled is False:
                connection.execute("DELETE FROM chunks_fts WHERE path IN (SELECT path FROM documents WHERE format!='text')")
                connection.execute("DELETE FROM documents WHERE format!='text'")
        from .knowledge_embeddings import schedule_embeddings
        schedule_embeddings(self)
        return self.settings()

    def reindex(self, changed_paths: list[str] | None = None) -> dict[str, Any]:
        started = time.monotonic()
        config = self.settings()
        if not config["enabled"]:
            return {**config, "updated": 0, "removed": 0, "duration_ms": 0}
        if config["index_version"] != CHUNKER_VERSION:
            changed_paths = None
        candidates = self._candidate_paths(changed_paths)
        document_candidates: list[Path] = []
        seen: set[str] = set()
        updated = 0
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current = connection.execute("SELECT * FROM settings WHERE singleton=1").fetchone()
            if not current["enabled"]:
                return {**self.settings(), "updated": 0, "removed": 0, "duration_ms": 0}
            for path in candidates[:MAX_FILES]:
                if not self._eligible(path, json.loads(current["exclusions_json"]), bool(current["documents_enabled"])):
                    continue
                relative = path.relative_to(self.root).as_posix()
                seen.add(relative)
                if path.suffix.lower().lstrip(".") in {"pdf", "docx", "xlsx", "csv", "tsv"}:
                    document_candidates.append(path)
                    continue
                try:
                    stat = path.stat()
                    if stat.st_size > MAX_FILE_BYTES or not path.is_file() or path.is_symlink():
                        continue
                    raw = path.read_bytes()
                    if _stat_key(path.stat()) != _stat_key(stat):
                        continue
                    if b"\0" in raw[:8_192]:
                        continue
                    content = raw.decode("utf-8", errors="replace")
                except OSError:
                    connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
                    connection.execute("DELETE FROM documents WHERE path=?", (relative,))
                    continue
                digest = hashlib.sha256(raw).hexdigest()
                previous = connection.execute(
                    "SELECT content_hash,chunker_version FROM documents WHERE path=?", (relative,)
                ).fetchone()
                if previous is not None and previous[0] == digest and previous[1] == CHUNKER_VERSION:
                    continue
                connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
                connection.execute("DELETE FROM chunks WHERE path=?", (relative,))
                connection.execute(
                    """INSERT INTO documents(path,content_hash,size,mtime,indexed_at,format,chunker_version,source_stat)
                       VALUES(?,?,?,?,?,'text',?,?)
                       ON CONFLICT(path) DO UPDATE SET content_hash=excluded.content_hash,
                       size=excluded.size,mtime=excluded.mtime,indexed_at=excluded.indexed_at,
                       format=excluded.format,chunker_version=excluded.chunker_version,source_stat=excluded.source_stat""",
                    (relative, digest, len(raw), stat.st_mtime, time.time(), CHUNKER_VERSION, _stat_key(stat)),
                )
                self._insert_chunks(connection, relative, text_chunks(content, path=relative))
                updated += 1
            removed = 0
            if changed_paths is None:
                stored = {str(row[0]) for row in connection.execute("SELECT path FROM documents WHERE format='text'")}
                for relative in stored - seen:
                    connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
                    connection.execute("DELETE FROM documents WHERE path=?", (relative,))
                    removed += 1
            connection.execute(
                "UPDATE settings SET last_indexed=?, index_version=?, last_error=NULL WHERE singleton=1",
                (time.time(), CHUNKER_VERSION),
            )
            connection.commit()
        from .knowledge_embeddings import schedule_embeddings
        schedule_embeddings(self)
        if self.settings()["documents_enabled"]:
            from .document_library import DocumentError, DocumentStore
            library = DocumentStore(str(self.root))
            library.reconcile()
            for candidate in document_candidates:
                try:
                    library.submit(candidate.relative_to(self.root).as_posix(), automatic=True)
                except (DocumentError, OSError):
                    continue
        return {
            **self.settings(), "updated": updated, "removed": removed, "embedded": 0,
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        }

    def _candidate_paths(self, changed_paths: list[str] | None) -> list[Path]:
        config = self.settings()
        exclusions = [str(item) for item in config.get("exclusions") or []]
        if changed_paths is not None:
            paths_out = []
            for value in changed_paths[:5_000]:
                candidate = Path(os.path.abspath(self.root / value))
                if candidate != self.root and self.root not in candidate.parents:
                    continue
                if self._eligible(candidate, exclusions, config["documents_enabled"]):
                    paths_out.append(candidate)
            return paths_out
        try:
            result = subprocess.run(
                ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                cwd=self.root, env=sanitized_child_environment(),
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=30, check=False,
            )
            if result.returncode == 0:
                return [self.root / raw.decode("utf-8", errors="surrogateescape")
                        for raw in result.stdout.split(b"\0") if raw
                        if self._eligible(
                            self.root / raw.decode("utf-8", errors="surrogateescape"), exclusions, config["documents_enabled"]
                        )]
        except (OSError, subprocess.TimeoutExpired):
            pass
        output: list[Path] = []
        for current, directories, files in os.walk(self.root, followlinks=False):
            directories[:] = [name for name in directories
                              if name not in SKIPPED_DIRECTORIES and not name.startswith(".")]
            for name in files:
                path = Path(current) / name
                if self._eligible(path, exclusions, config["documents_enabled"]):
                    output.append(path)
                    if len(output) >= MAX_FILES:
                        return output
        return output

    def _eligible(self, path: Path, exclusions: list[str], documents_enabled: bool | None = None) -> bool:
        try:
            relative = path.relative_to(self.root)
        except ValueError:
            return False
        if ".." in relative.parts or any((self.root / Path(*relative.parts[:i])).is_symlink()
                                        for i in range(1, len(relative.parts) + 1)):
            return False
        if any(part in SKIPPED_DIRECTORIES for part in relative.parts):
            return False
        if any(part.startswith(".") for part in relative.parts[:-1]):
            return False
        if SECRET_NAMES.match(path.name):
            return False
        relative_name = relative.as_posix()
        if any(fnmatch.fnmatchcase(relative_name, pattern) for pattern in exclusions):
            return False
        extension = path.suffix.lower().lstrip(".")
        if extension in ALLOWED_EXTENSIONS:
            return True
        if extension not in {"pdf", "docx", "xlsx", "csv", "tsv"}:
            return False
        if documents_enabled is None:
            with self._connect() as connection:
                documents_enabled = bool(connection.execute("SELECT documents_enabled FROM settings WHERE singleton=1").fetchone()[0])
        return documents_enabled

    def document_path_allowed(self, path: Path) -> bool:
        return self._eligible(path, self.settings()["exclusions"])

    def remove_document_chunks(self, relative: str) -> None:
        with self._lock, self._connect() as connection:
            connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
            connection.execute("DELETE FROM documents WHERE path=?", (relative,))

    def has_document_hash(self, relative: str, digest: str) -> bool:
        with self._connect() as connection:
            return connection.execute("SELECT 1 FROM documents WHERE path=? AND content_hash=? AND chunker_version=?", (relative, digest, CHUNKER_VERSION)).fetchone() is not None

    def index_extracted_document(self, relative: str, digest: str, segments: list[dict[str, Any]], format: str) -> None:
        config = self.settings()
        if not config["enabled"] or not config["documents_enabled"]:
            raise KnowledgeError("Document knowledge is disabled for this workspace.")
        path = self.root / relative
        if not self.document_path_allowed(path):
            raise KnowledgeError("Document is excluded from workspace knowledge.")
        stat = path.stat()
        with self._lock, self._connect() as connection:
            # Settings can change while the native parser is finishing. Check
            # them again under the same lock as publication, so disabling the
            # library cannot be followed by a late re-insertion.
            current = connection.execute("SELECT enabled,documents_enabled,exclusions_json FROM settings WHERE singleton=1").fetchone()
            if not current["enabled"] or not current["documents_enabled"] or not self._eligible(path, json.loads(current["exclusions_json"]), bool(current["documents_enabled"])):
                raise KnowledgeError("Document knowledge was disabled or this document was excluded.")
            connection.execute("DELETE FROM chunks_fts WHERE path=?", (relative,))
            connection.execute("DELETE FROM documents WHERE path=?", (relative,))
            connection.execute(
                "INSERT INTO documents(path,content_hash,size,mtime,indexed_at,format,chunker_version,source_stat) VALUES(?,?,?,?,?,?,?,?)",
                (relative, digest, stat.st_size, stat.st_mtime, time.time(), format, CHUNKER_VERSION, None),
            )
            self._insert_chunks(connection, relative, extracted_chunks(segments, path=relative))

    @staticmethod
    def _insert_chunks(connection: sqlite3.Connection, relative: str, chunks: list[dict[str, Any]]) -> None:
        chunks = [chunk for chunk in chunks if chunk["content"].strip()]
        count = int(connection.execute("SELECT COUNT(*) FROM chunks").fetchone()[0])
        if count + len(chunks) > MAX_CHUNKS:
            raise KnowledgeError("Workspace knowledge reached its 100,000 chunk limit.")
        for chunk in chunks:
            search_content = chunk["context"] + "\n" + chunk["content"]
            cursor = connection.execute(
                """INSERT INTO chunks(path,line_start,line_end,content,content_hash,locator_json,
                   context,search_content,parent_key,parent_content,parent_line_start,parent_line_end,parent_locator_json)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (relative, chunk["line_start"], chunk["line_end"], chunk["content"], chunk["content_hash"],
                 json.dumps(chunk["locator"]) if chunk.get("locator") else None,
                 chunk["context"], search_content, chunk["parent_key"], chunk["parent_content"],
                 chunk["parent_line_start"], chunk["parent_line_end"],
                 json.dumps(chunk["parent_locator"]) if chunk.get("parent_locator") else None),
            )
            connection.execute("INSERT INTO chunks_fts(content,path,chunk_id) VALUES(?,?,?)",
                               (search_content, relative, cursor.lastrowid))

    def _embed_missing(self, model: str, host: str) -> int:
        # Compatibility for callers that explicitly drain the durable queue.
        from .knowledge_embeddings import drain_embeddings
        config = self.settings()
        if model != config["embedding_model"] or host.rstrip("/") != config["ollama_host"].rstrip("/"):
            return 0
        return drain_embeddings(self)

    def search(self, query: str, limit: int = 8) -> list[dict[str, Any]]:
        return self.search_with_diagnostics(query, limit)["results"]

    def search_with_diagnostics(self, query: str, limit: int = 8, *, files_only: bool = False,
                                sources=None, allow_reindex: bool = True, deadline=None,
                                should_stop=None, pack: bool = True, on_lexical=None) -> dict[str, Any]:
        from .knowledge_retrieval import (
            RERANK_CANDIDATES,
            fuse_candidates,
            query_terms,
            rerank_candidates,
            stop_reason,
        )
        started = time.monotonic()
        query = query.strip()[:2_000]
        if not query:
            raise KnowledgeError("knowledge search requires a query")
        limit = min(max(int(limit), 1), 20)
        if deadline is not None and not math.isfinite(deadline):
            raise KnowledgeError("Retrieval deadline must be a finite monotonic time.")
        if sources is not None and (not isinstance(sources, (tuple, list, set, frozenset))
                or any(value not in {"workspace", "documents"} for value in sources)):
            raise KnowledgeError("Knowledge sources must be workspace or documents.")
        selected = {"workspace", "documents"} if sources is None else set(sources)
        diagnostics: dict[str, Any] = {"lexical_candidates": 0, "semantic_candidates": 0,
            "candidate_count": 0, "rejected_sources": 0, "reranked": False, "fallbacks": [],
            "partial_reasons": []}

        def finish(results, reason=None):
            reason = reason or stop_reason(deadline, should_stop)
            if reason and reason not in diagnostics["partial_reasons"]:
                diagnostics["partial_reasons"].append(reason)
            diagnostics.update(returned=len(results), duration_ms=round((time.monotonic() - started) * 1_000, 2),
                               partial=bool(diagnostics["partial_reasons"] or diagnostics["fallbacks"]))
            if reason in {"deadline_exceeded", "cancelled"}:
                diagnostics[reason] = True
            return {"results": results, "diagnostics": diagnostics}

        if reason := stop_reason(deadline, should_stop):
            return finish([], reason)
        config = self.settings()
        diagnostics["embedding_pending"] = config["embedding_pending"]
        if not config["enabled"]:
            diagnostics["disabled"] = True
            return finish([])
        if not selected:
            return finish([])
        if not config["last_indexed"] or config["index_version"] != CHUNKER_VERSION:
            if not allow_reindex:
                return finish([], "index_not_ready")
            if reason := stop_reason(deadline, should_stop):
                return finish([], reason)
            self.reindex()
            config = self.settings()
        text_enabled = "workspace" in selected
        documents_enabled = "documents" in selected and config["documents_enabled"]
        terms = query_terms(query)
        fts_query = " OR ".join(f'"{term}"' for term in terms)
        lexical: list[dict[str, Any]] = []
        with self._connect() as connection:
            if deadline is not None or should_stop is not None:
                connection.set_progress_handler(lambda: int(stop_reason(deadline, should_stop) is not None), 1000)
            try:
                if fts_query:
                    rows = connection.execute(
                        """SELECT c.*,d.content_hash AS document_hash,d.format,d.source_stat,d.indexed_at,
                           bm25(chunks_fts) AS rank FROM chunks_fts
                           JOIN chunks c ON c.id=chunks_fts.chunk_id JOIN documents d ON d.path=c.path
                           WHERE chunks_fts MATCH ? AND ((d.format='text' AND ?) OR (d.format!='text' AND ?))
                           ORDER BY rank,c.id LIMIT ?""",
                        (fts_query, text_enabled, documents_enabled, max(RERANK_CANDIDATES, limit * 4)),
                    ).fetchall()
                    lexical = [self._search_item(row, "text") for row in rows]
                if not files_only and text_enabled:
                    memories = connection.execute(
                        "SELECT * FROM memories WHERE stale=0 AND lower(title || ' ' || content || ' ' || tags_json) LIKE ? "
                        "ORDER BY pinned DESC, updated_at DESC LIMIT ?", (f"%{query.lower()}%", limit),
                    ).fetchall()
                    lexical.extend({"id": f"memory:{row['id']}", "kind": "memory", "source": "approved_memory",
                        "title": row["title"], "snippet": row["content"], "path": "", "line_start": 0,
                        "line_end": 0, "freshness": row["updated_at"], "stale": False} for row in memories)
            except sqlite3.OperationalError:
                if not stop_reason(deadline, should_stop):
                    raise
        fresh: dict[tuple[str, str], bool] = {}
        lexical_count = len(lexical)
        lexical = self._fresh_candidates(lexical, self.settings(), fresh,
                                         deadline=deadline, should_stop=should_stop)
        diagnostics["rejected_sources"] = lexical_count - len(lexical)
        if on_lexical is not None:
            # The host may keep this bounded snapshot if its overall wait ends
            # before a local model responds. It still revalidates at delivery.
            on_lexical(copy.deepcopy(fuse_candidates(lexical, [], query)[:RERANK_CANDIDATES]))
        semantic: list[dict[str, Any]] = []
        controls = {key: value for key, value in (("deadline", deadline), ("should_stop", should_stop)) if value is not None}
        if config["embedding_model"] and not stop_reason(deadline, should_stop):
            try:
                semantic = self._vector_search(query, config["embedding_model"], config["ollama_host"],
                    max(RERANK_CANDIDATES, limit * 4), sources=selected, **controls)
            except Exception as exc:
                diagnostics["fallbacks"].append(f"semantic_unavailable:{type(exc).__name__}")
        # Filter before fusion and before a model sees evidence. Recheck again
        # after network calls, since sources/settings may change during retrieval.
        current = self.settings()
        retrieved_count = len(lexical) + len(semantic)
        fresh = {}
        lexical = self._fresh_candidates(lexical, current, fresh, deadline=deadline, should_stop=should_stop)
        semantic = self._fresh_candidates(semantic, current, fresh, deadline=deadline, should_stop=should_stop)
        diagnostics["rejected_sources"] += retrieved_count - len(lexical) - len(semantic)
        diagnostics.update(lexical_candidates=len(lexical), semantic_candidates=len(semantic))
        candidates = fuse_candidates(lexical, semantic, query)[:RERANK_CANDIDATES]
        diagnostics["candidate_count"] = len(candidates)
        if current["rerank_model"] and candidates and current["enabled"] and not stop_reason(deadline, should_stop):
            try:
                candidates = rerank_candidates(query, candidates, model=current["rerank_model"], host=current["ollama_host"], **controls)
                diagnostics["reranked"] = True
            except Exception as exc:
                diagnostics["fallbacks"].append(f"reranker_unavailable:{type(exc).__name__}")
        current = self.settings()
        valid = self._fresh_candidates(candidates, current, {}, deadline=deadline, should_stop=should_stop)
        diagnostics["rejected_sources"] += len(candidates) - len(valid)
        results = self.pack_results(valid, limit=limit) if pack else valid
        diagnostics["embedding_pending"] = current["embedding_pending"]
        return finish(results)

    def revalidate_results(self, results: list[dict[str, Any]], *, deadline=None,
                           should_stop=None) -> list[dict[str, Any]]:
        """Recheck retained evidence against current settings, index and source bytes."""
        config = self.settings()
        if not config["last_indexed"] or config["index_version"] != CHUNKER_VERSION:
            return []
        return self._fresh_candidates([dict(item) for item in results], config, {},
                                      deadline=deadline, should_stop=should_stop)

    @staticmethod
    def pack_results(results: list[dict[str, Any]], limit: int = 8, byte_budget: int = 24_000) -> list[dict[str, Any]]:
        from .knowledge_retrieval import pack_evidence, select_diverse

        packed = pack_evidence(select_diverse(results, min(max(int(limit), 1), 20)), byte_budget=max(0, int(byte_budget)))
        for item in packed:
            item.pop("source_stat", None)
        return packed

    @staticmethod
    def _search_item(row: sqlite3.Row, source: str) -> dict[str, Any]:
        return {"id": f"file:{row['id']}", "kind": "file", "source": source, "path": row["path"],
            "line_start": row["line_start"], "line_end": row["line_end"], "snippet": row["content"],
            "context": row["context"], "parent_key": row["parent_key"], "parent_content": row["parent_content"],
            "parent_line_start": row["parent_line_start"], "parent_line_end": row["parent_line_end"],
            "parent_locator": json.loads(row["parent_locator_json"]) if row["parent_locator_json"] else None,
            "locator": json.loads(row["locator_json"]) if row["locator_json"] else {
                "kind": "line", "line_start": row["line_start"], "line_end": row["line_end"]},
            "content_hash": row["document_hash"], "format": row["format"],
            "source_stat": row["source_stat"], "freshness": row["indexed_at"]}

    def _fresh_candidates(self, candidates: list[dict[str, Any]], config: dict[str, Any],
                          cache: dict[tuple[str, str], bool], *, deadline=None, should_stop=None) -> list[dict[str, Any]]:
        from .knowledge_retrieval import stop_reason
        if not config["enabled"]:
            return []
        output = []
        identifiers = [item["id"].split(":", 1)[-1] for item in candidates]
        if not identifiers:
            return output
        placeholders = ",".join("?" for _ in identifiers)
        with self._connect() as connection:
            indexed = {(f"file:{row[0]}", row[1]) for row in connection.execute(
                f"SELECT c.id,d.content_hash FROM chunks c JOIN documents d ON d.path=c.path WHERE c.id IN ({placeholders})",
                identifiers)}
            memories = {f"memory:{row[0]}" for row in connection.execute(
                f"SELECT id FROM memories WHERE stale=0 AND id IN ({placeholders})", identifiers)}
        for item in candidates:
            if item["kind"] == "memory":
                if not item.get("stale") and item["id"] in memories:
                    output.append(item)
                continue
            if (item["id"], item["content_hash"]) not in indexed:
                continue
            key = (item["path"], item["content_hash"])
            if key not in cache:
                path = self.root / item["path"]
                cache[key] = False
                if (item["format"] != "text" and not config["documents_enabled"]) or not self._eligible(path, config["exclusions"], config["documents_enabled"]):
                    continue
                try:
                    before = path.stat()
                    if not path.is_file() or before.st_size > (MAX_FILE_BYTES if item["format"] == "text" else 100 * 1024 * 1024):
                        continue
                    if item.get("source_stat") == _stat_key(before):
                        cache[key] = True
                    else:
                        if stop_reason(deadline, should_stop):
                            continue
                        digest = hashlib.sha256()
                        read_bytes = 0
                        with path.open("rb") as source:
                            for block in iter(lambda: source.read(65536), b""):
                                if stop_reason(deadline, should_stop):
                                    break
                                read_bytes += len(block)
                                if read_bytes > before.st_size:
                                    break
                                digest.update(block)
                        cache[key] = (read_bytes == before.st_size and digest.hexdigest() == item["content_hash"]
                                      and _stat_key(before) == _stat_key(path.stat()))
                    if cache[key]:
                        item["source_stat"] = _stat_key(before)
                except OSError:
                    pass
            if cache[key]:
                output.append(item)
        return output

    def _vector_search(self, query: str, model: str, host: str, limit: int, *, sources=None,
                       deadline=None, should_stop=None) -> list[dict[str, Any]]:
        from .knowledge_retrieval import check_retrieval

        check_retrieval(deadline, should_stop)
        before = self.settings()
        controls = {key: value for key, value in (("deadline", deadline), ("should_stop", should_stop)) if value is not None}
        vectors = embed_texts(model, host, [query], **controls)
        check_retrieval(deadline, should_stop)
        config = self.settings()
        if (not vectors or not config["enabled"] or config["embedding_model"] != model
                or config["ollama_host"] != host or config["vector_generation"] != before["vector_generation"]):
            return []
        query_vector = vectors[0]
        if not query_vector or any(not math.isfinite(value) for value in query_vector):
            raise KnowledgeError("Invalid local query embedding")
        candidates: list[tuple[float, sqlite3.Row]] = []
        selected = {"workspace", "documents"} if sources is None else set(sources)
        with self._connect() as connection:
            rows = connection.execute(
                """SELECT c.*,d.content_hash AS document_hash,d.format,d.source_stat,d.indexed_at
                   FROM chunks c JOIN documents d ON d.path=c.path WHERE embedding IS NOT NULL
                   AND vector_generation=? AND ((d.format='text' AND ?) OR (d.format!='text' AND ?)) LIMIT ?""",
                (config["vector_generation"], "workspace" in selected,
                 "documents" in selected and config["documents_enabled"], MAX_CHUNKS),
            )
            for row in rows:
                check_retrieval(deadline, should_stop)
                if row["format"] != "text" and not config["documents_enabled"]:
                    continue
                vector = array.array("f")
                try:
                    vector.frombytes(row["embedding"])
                except ValueError:
                    continue
                if len(vector) != len(query_vector):
                    continue
                score = cosine_similarity(query_vector, vector)
                if math.isfinite(score) and score > 0:
                    candidates.append((score, row))
        candidates.sort(key=lambda item: (-item[0], item[1]["id"]))
        return [{**self._search_item(row, "vector"), "semantic_score": score} for score, row in candidates[:limit]]

    def list_memories(self) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM memories ORDER BY pinned DESC, updated_at DESC"
            ).fetchall()
        return [self._memory(row) for row in rows]

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


def _stat_key(stat: os.stat_result) -> str:
    return json.dumps([stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns])


def cosine_similarity(left: list[float], right: list[float] | array.array[float]) -> float:
    dot = sum(a * b for a, b in zip(left, right, strict=True))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if not left_norm or not right_norm:
        return 0.0
    return dot / (left_norm * right_norm)


def embed_texts(model: str, host: str, inputs: list[str], *, deadline=None,
                should_stop=None) -> list[list[float]]:
    """Embed text using only a loopback Ollama endpoint.

    This shared entry point lets the encrypted memory vault use the exact same
    locality boundary as workspace knowledge without persisting plaintext
    vectors outside the vault.
    """
    if not model.strip() or not inputs:
        return []
    from .knowledge_retrieval import check_retrieval
    from .memory_embeddings import _LocalTransport

    check_retrieval(deadline, should_stop)
    end = min(time.monotonic() + (5 if len(inputs) == 1 else 30),
              deadline if deadline is not None else float("inf"))
    result = _LocalTransport(host)._json("/api/embed", {"model": model, "input": inputs,
        "truncate": False, "keep_alive": "5m"}, end)
    check_retrieval(end, should_stop)
    raw = result.get("embeddings")
    if not isinstance(raw, list) or len(raw) != len(inputs):
        raise KnowledgeError("Ollama returned an invalid embedding batch")
    try:
        vectors = [[float(value) for value in vector] for vector in raw]
    except (TypeError, ValueError) as exc:
        raise KnowledgeError("Ollama returned an invalid embedding vector") from exc
    if any(not vector or any(not math.isfinite(value) for value in vector) for vector in vectors):
        raise KnowledgeError("Ollama returned an empty embedding vector")
    return vectors


def _validate_local_ollama_host(host: str) -> None:
    """Share the same direct, non-redirecting loopback boundary as memory."""
    from locus_memory.errors import ProviderError

    from .memory_embeddings import local_origin
    try:
        local_origin(host)
    except (ProviderError, ValueError) as exc:
        raise KnowledgeError("workspace embeddings may connect only to local Ollama using a plain HTTP origin") from exc


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
            locator = item.get("locator") or {}
            kind = locator.get("kind", "line")
            if kind == "pdf":
                detail = f"page {locator.get('page', 1)}"
            elif kind == "paragraph":
                detail = f"paragraph {locator.get('paragraph_start', 1)}"
                if locator.get("heading"):
                    detail += f", {locator['heading']}"
            elif kind == "sheet":
                detail = f"{locator.get('sheet', 'Sheet')}!{locator.get('cell_range', '')}"
            else:
                detail = ""
            if detail:
                parameters = urlencode({"locator": json.dumps(locator, separators=(",", ":")), "hash": item.get("content_hash", "")})
                url = "locus-workspace://open/" + quote(item["path"], safe="/") + "?" + parameters
                location = f"[{item['path']} · {detail}]({url})"
            else:
                location = f"{item['path']}:{item['line_start']}-{item['line_end']}"
        context = f"Retrieval context: {item['context']}\n" if item.get("context") else ""
        lines.append(f"\n## {location} [{item['source']}]\n{context}{item['snippet']}")
    return "\n".join(lines)[:30_000]


__all__ = [
    "KnowledgeError", "KnowledgeStore", "canonical_workspace", "cosine_similarity",
    "embed_texts", "format_search_results", "workspace_database",
]
