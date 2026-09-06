"""Durable workspace document jobs, with a cancellable local extraction worker.

SQLite owns state and generations; filesystem locks enforce the two global /
one workspace extraction budget across the app's separate chat processes.
Extracted text remains local and enters knowledge search only after opt-in.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import queue
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from . import paths
from .document_extract import EXTRACTOR_VERSION, FORMATS, MAX_SOURCE_BYTES, MAX_TEXT_BYTES
from .knowledge import KnowledgeError, KnowledgeStore, canonical_workspace, workspace_database
from .proxy import sanitized_child_environment

TEMPORARY_LIFETIME = 24 * 60 * 60
DOCUMENT_DEADLINE = 600
MAX_WIRE_BYTES = 40 * 1024 * 1024
TERMINAL = {"ready", "partial", "failed", "cancelled"}
_SHUTTING_DOWN = threading.Event()


class DocumentError(ValueError):
    pass


class _JobInterrupted(Exception):
    pass


def _now() -> float:
    return time.time()


def document_id(path: str) -> str:
    return hashlib.sha256(path.encode()).hexdigest()[:32]


def _source_fingerprint(value: os.stat_result) -> str:
    return json.dumps([value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns])


def contained_source(workspace: Path, relative: str) -> Path:
    candidate = workspace / relative
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise DocumentError("Document is no longer available.") from exc
    if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise DocumentError("Document path must be relative to the workspace.")
    if workspace not in resolved.parents or resolved != candidate.absolute():
        raise DocumentError("Documents must be regular files inside the workspace, without symbolic links.")
    if not resolved.is_file() or resolved.stat().st_size > MAX_SOURCE_BYTES:
        raise DocumentError("Document must be a regular file no larger than 100 MB.")
    return resolved


class DocumentStore:
    def __init__(self, workspace: str, *, start_worker: bool = True) -> None:
        self.root = canonical_workspace(workspace)
        self.directory = workspace_database(str(self.root)).parent
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / "document-library.sqlite3"
        self.job_directory = self.directory / "document-jobs"
        self.job_directory.mkdir(exist_ok=True, mode=0o700)
        self._initialize()
        self.cleanup_expired()
        if start_worker:
            _coordinator().register(self)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=10000")
        return connection

    def _initialize(self) -> None:
        with self._connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS library_documents (
                    id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, format TEXT NOT NULL,
                    content_hash TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL,
                    job_id TEXT, excluded INTEGER NOT NULL DEFAULT 0,
                    segment_count INTEGER NOT NULL DEFAULT 0, truncated INTEGER NOT NULL DEFAULT 0,
                    warnings_json TEXT NOT NULL DEFAULT '[]', error TEXT, updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS document_jobs (
                    id TEXT PRIMARY KEY, document_id TEXT, workspace TEXT NOT NULL,
                    path TEXT NOT NULL, format TEXT NOT NULL, persistent INTEGER NOT NULL,
                    content_hash TEXT NOT NULL, state TEXT NOT NULL, progress INTEGER NOT NULL DEFAULT 0,
                    total INTEGER NOT NULL DEFAULT 0, options_json TEXT NOT NULL,
                    error TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    expires_at REAL, owner_pid INTEGER, result_available INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS document_jobs_state_idx ON document_jobs(state, created_at);
                CREATE INDEX IF NOT EXISTS document_jobs_cache_idx ON document_jobs(content_hash,format,options_json,state);
            """)
            db.execute("BEGIN IMMEDIATE")
            columns = {row[1] for row in db.execute("PRAGMA table_info(library_documents)")}
            if "source_fingerprint" not in columns:
                db.execute("ALTER TABLE library_documents ADD COLUMN source_fingerprint TEXT")
        self.path.chmod(0o600)

    @staticmethod
    def _job(row: sqlite3.Row) -> dict[str, Any]:
        value = dict(row)
        value["persistent"] = bool(value["persistent"])
        value["result_available"] = bool(value["result_available"])
        value["options"] = json.loads(value.pop("options_json"))
        value.pop("owner_pid", None)
        return value

    @staticmethod
    def _document(row: sqlite3.Row) -> dict[str, Any]:
        value = dict(row)
        value["title"] = Path(value["path"]).name
        value["warnings"] = json.loads(value.pop("warnings_json"))
        value["excluded"] = bool(value["excluded"])
        value["truncated"] = bool(value["truncated"])
        value.pop("source_fingerprint", None)
        return value

    def documents(self, *, limit: int = 100, offset: int = 0, query: str = "") -> dict[str, Any]:
        with self._connect() as db:
            # Filter the complete catalog before pagination. Casefold handles
            # Unicode filenames; instr treats %, _ and quotes as literal text.
            db.create_function("locus_casefold", 1, lambda value: value.casefold(), deterministic=True)
            search = query.strip().casefold()
            predicate = " WHERE instr(locus_casefold(path), ?) > 0" if search else ""
            parameters = (search,) if search else ()
            total = db.execute("SELECT COUNT(*) FROM library_documents" + predicate, parameters).fetchone()[0]
            rows = db.execute(
                "SELECT * FROM library_documents" + predicate + " ORDER BY updated_at DESC, id LIMIT ? OFFSET ?",
                (*parameters, min(max(limit, 1), 500), max(offset, 0)),
            ).fetchall()
        return {"documents": [self._document(row) for row in rows], "total": total}

    def jobs(self, *, limit: int = 100) -> list[dict[str, Any]]:
        with self._connect() as db:
            rows = db.execute("SELECT * FROM document_jobs ORDER BY created_at DESC LIMIT ?", (min(max(limit, 1), 500),)).fetchall()
        return [self._job(row) for row in rows]

    def job(self, job_id: str) -> dict[str, Any]:
        with self._connect() as db:
            row = db.execute("SELECT * FROM document_jobs WHERE id=?", (job_id,)).fetchone()
        if row is None:
            raise DocumentError("Document job was not found or has expired.")
        return self._job(row)

    def _options(self, ocr_mode: str, ocr_languages: list[str] | None) -> dict[str, Any]:
        if ocr_mode not in {"auto", "always"}:
            raise DocumentError("OCR mode must be auto or always.")
        languages = list(dict.fromkeys(ocr_languages or []))[:8]
        if any(not re.fullmatch(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,2}", language) for language in languages):
            raise DocumentError("OCR languages must be valid language identifiers.")
        return {"ocr_mode": ocr_mode, "ocr_languages": languages, "extractor_version": EXTRACTOR_VERSION}

    def submit(self, path: str, *, persistent: bool = True, ocr_mode: str = "auto", ocr_languages: list[str] | None = None, automatic: bool = False) -> dict[str, Any]:
        source = contained_source(self.root, path)
        if persistent:
            knowledge = KnowledgeStore(str(self.root))
            config = knowledge.settings()
            if not config["enabled"] or not config["documents_enabled"]:
                raise DocumentError("Enable document knowledge for this workspace before indexing documents.")
            if not knowledge.document_path_allowed(source):
                raise DocumentError("This document is excluded from workspace knowledge.")
        options = self._options(ocr_mode, ocr_languages)
        if persistent:
            with self._connect() as db:
                document = db.execute("SELECT * FROM library_documents WHERE path=?", (path,)).fetchone()
                previous = db.execute("SELECT * FROM document_jobs WHERE id=?", (document["job_id"],)).fetchone() if document and document["job_id"] else None
            if document and document["excluded"]:
                raise DocumentError("This document is excluded. Include it before retrying.")
            if previous and automatic:
                # Watcher refreshes must retain an explicit OCR retry/language
                # choice while still invalidating the old extractor version.
                old_options = json.loads(previous["options_json"])
                options = self._options(old_options.get("ocr_mode", "auto"), old_options.get("ocr_languages"))
            if previous and document["source_fingerprint"] == _source_fingerprint(source.stat()):
                if json.loads(previous["options_json"]) == options:
                    state = previous["state"]
                    if state in {"queued", "running"} and (self.job_directory / previous["id"] / "source").is_file():
                        return self._job(previous)
                    if automatic and state in {"failed", "cancelled"} and document["status"] == state:
                        return self._job(previous)
                    if state in {"ready", "partial"} and previous["result_available"] and (self.job_directory / previous["id"] / "result.json").is_file():
                        if knowledge.has_document_hash(path, previous["content_hash"]):
                            return self._job(previous)
        return self._submit_source(source, path, persistent=persistent, options=options, automatic=automatic)

    def submit_upload(self, source: Path, filename: str, *, persistent: bool = False, ocr_mode: str = "auto", ocr_languages: list[str] | None = None) -> dict[str, Any]:
        name = Path(filename).name
        if name != filename or name in {"", ".", ".."} or any(ord(char) < 32 for char in name):
            raise DocumentError("Upload needs an ordinary filename.")
        if persistent:
            if not KnowledgeStore(str(self.root)).settings()["documents_enabled"]:
                raise DocumentError("Enable document knowledge for this workspace before importing documents.")
            folder = self.root / "Locus Documents"
            if folder.is_symlink():
                raise DocumentError("The document import folder must not be a symbolic link.")
            folder.mkdir(exist_ok=True)
            stem, suffix = Path(name).stem, Path(name).suffix
            for index in range(10_000):
                destination = folder / (name if index == 0 else f"{stem} {index + 1}{suffix}")
                try:
                    with destination.open("xb") as handle, source.open("rb") as incoming:
                        shutil.copyfileobj(incoming, handle)
                    return self.submit(destination.relative_to(self.root).as_posix(), persistent=True, ocr_mode=ocr_mode, ocr_languages=ocr_languages)
                except FileExistsError:
                    continue
            raise DocumentError("Could not choose an unused imported filename.")
        return self._submit_source(source, name, persistent=False, options=self._options(ocr_mode, ocr_languages))

    def _submit_source(self, source: Path, relative: str, *, persistent: bool, options: dict[str, Any], automatic: bool = False) -> dict[str, Any]:
        format = Path(relative).suffix.lower().lstrip(".")
        if format not in FORMATS:
            raise DocumentError("Choose a PDF, DOCX, XLSX, CSV or TSV document.")
        identifier = uuid.uuid4().hex
        target = self.job_directory / identifier
        target.mkdir(mode=0o700)
        digest = hashlib.sha256()
        size = 0
        try:
            descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "rb") as incoming, (target / "source").open("xb") as outgoing:
                before = os.fstat(incoming.fileno())
                if not stat.S_ISREG(before.st_mode):
                    raise DocumentError("Document source must be a regular file.")
                fingerprint = _source_fingerprint(before)
                while chunk := incoming.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_SOURCE_BYTES:
                        raise DocumentError("Document exceeds the 100 MB limit.")
                    digest.update(chunk)
                    outgoing.write(chunk)
                if fingerprint != _source_fingerprint(os.fstat(incoming.fileno())) or fingerprint != _source_fingerprint(source.stat(follow_symlinks=False)):
                    raise DocumentError("Source changed while preparing extraction; retry its latest version.")
            (target / "source").chmod(0o600)
            content_hash = digest.hexdigest()
            doc_id = document_id(relative) if persistent else None
            now = _now()
            with self._connect() as db:
                db.execute("BEGIN IMMEDIATE")
                if persistent:
                    old = db.execute("SELECT * FROM library_documents WHERE id=?", (doc_id,)).fetchone()
                    if old and old["excluded"]:
                        raise DocumentError("This document is excluded. Include it before retrying.")
                    if old and old["job_id"]:
                        previous = db.execute("SELECT * FROM document_jobs WHERE id=?", (old["job_id"],)).fetchone()
                        reusable = previous and previous["state"] in {"queued", "running", "ready", "partial"}
                        if reusable and previous["state"] in {"ready", "partial"}:
                            reusable = previous["result_available"] and (self.job_directory / previous["id"] / "result.json").is_file() and KnowledgeStore(str(self.root)).has_document_hash(relative, content_hash)
                        if automatic and previous and previous["state"] in {"failed", "cancelled"} and old["status"] == previous["state"]:
                            reusable = True
                        if reusable and previous["content_hash"] == content_hash and json.loads(previous["options_json"]) == options:
                            db.execute("UPDATE library_documents SET source_fingerprint=? WHERE id=?", (fingerprint, doc_id))
                            shutil.rmtree(target)
                            return self._job(previous)
                        db.execute("UPDATE document_jobs SET state='cancelled', updated_at=? WHERE id=? AND state IN ('queued','running')", (now, old["job_id"]))
                    db.execute("""INSERT INTO library_documents(id,path,format,content_hash,size,status,job_id,updated_at,source_fingerprint)
                        VALUES(?,?,?,?,?,'queued',?,?,?) ON CONFLICT(id) DO UPDATE SET
                        content_hash=excluded.content_hash,size=excluded.size,status='queued',job_id=excluded.job_id,
                        error=NULL,truncated=0,segment_count=0,warnings_json='[]',updated_at=excluded.updated_at,
                        source_fingerprint=excluded.source_fingerprint""",
                        (doc_id, relative, format, content_hash, size, identifier, now, fingerprint))
                    KnowledgeStore(str(self.root)).remove_document_chunks(relative)
                db.execute("""INSERT INTO document_jobs(id,document_id,workspace,path,format,persistent,content_hash,state,options_json,created_at,updated_at,expires_at)
                    VALUES(?,?,?,?,?,?,?,'queued',?,?,?,?)""",
                    (identifier, doc_id, str(self.root), relative, format, int(persistent), content_hash, json.dumps(options), now, now, None if persistent else now + TEMPORARY_LIFETIME))
        except BaseException:
            shutil.rmtree(target, ignore_errors=True)
            raise
        _coordinator().register(self)
        return self.job(identifier)

    def result(self, job_id: str) -> dict[str, Any]:
        job = self.job(job_id)
        if not job["result_available"]:
            raise DocumentError("Extraction result is not available yet.")
        try:
            result = json.loads((self.job_directory / job_id / "result.json").read_text())
        except (OSError, ValueError) as exc:
            raise DocumentError("Extraction result is no longer available; retry the document.") from exc
        return {"job": job, "content_hash": job["content_hash"], "format": job["format"], **result}

    def cancel(self, job_id: str) -> dict[str, Any]:
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM document_jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise DocumentError("Document job was not found.")
            if row["state"] not in TERMINAL:
                db.execute("UPDATE document_jobs SET state='cancelled', updated_at=? WHERE id=?", (_now(), job_id))
                db.execute("UPDATE library_documents SET status='cancelled',updated_at=? WHERE job_id=?", (_now(), job_id))
                if row["state"] == "queued":
                    with contextlib.suppress(OSError):
                        (self.job_directory / job_id / "source").unlink()
        return self.job(job_id)

    def exclude(self, doc_id: str, excluded: bool) -> dict[str, Any]:
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM library_documents WHERE id=?", (doc_id,)).fetchone()
            if row is None:
                raise DocumentError("Document was not found.")
            db.execute("UPDATE library_documents SET excluded=?,status=?,updated_at=? WHERE id=?", (int(excluded), "excluded" if excluded else "queued", _now(), doc_id))
            if excluded:
                db.execute("UPDATE document_jobs SET state='cancelled',updated_at=? WHERE document_id=? AND state IN ('queued','running')", (_now(), doc_id))
                KnowledgeStore(str(self.root)).remove_document_chunks(row["path"])
                # Re-inclusion must reindex even when the source bytes did not change.
                db.execute("UPDATE library_documents SET job_id=NULL WHERE id=?", (doc_id,))
        if not excluded:
            self.submit(row["path"])
        with self._connect() as db:
            return self._document(db.execute("SELECT * FROM library_documents WHERE id=?", (doc_id,)).fetchone())

    def remove(self, doc_id: str) -> None:
        # Removal affects the searchable library, never the user's source file.
        self.exclude(doc_id, True)

    def cancel_persistent(self) -> None:
        with self._connect() as db:
            db.execute("UPDATE document_jobs SET state='cancelled',updated_at=? WHERE persistent=1 AND state IN ('queued','running')", (_now(),))
            # Disabling is a workspace generation boundary, unlike cancelling
            # one job. Re-enabling must rediscover these interrupted sources.
            db.execute("UPDATE library_documents SET status='cancelled',job_id=NULL,updated_at=? WHERE status IN ('queued','running')", (_now(),))

    def cleanup_expired(self) -> None:
        with self._connect() as db:
            rows = db.execute("SELECT id FROM document_jobs WHERE expires_at IS NOT NULL AND expires_at < ?", (_now(),)).fetchall()
            for row in rows:
                db.execute("DELETE FROM document_jobs WHERE id=?", (row["id"],))
                shutil.rmtree(self.job_directory / row["id"], ignore_errors=True)

    def reconcile(self) -> None:
        """Retire removed/excluded sources, then schedule only content changes."""
        knowledge = KnowledgeStore(str(self.root))
        config = knowledge.settings()
        if not config["enabled"] or not config["documents_enabled"]:
            self.cancel_persistent()
            return
        with self._connect() as db:
            rows = db.execute("SELECT * FROM library_documents WHERE excluded=0").fetchall()
        for row in rows:
            try:
                source = contained_source(self.root, row["path"])
                if not knowledge.document_path_allowed(source):
                    raise DocumentError("Document is excluded by workspace settings.")
                self.submit(row["path"], automatic=True)
            except (DocumentError, KnowledgeError, OSError) as exc:
                if row["status"] == "unavailable":
                    continue
                knowledge.remove_document_chunks(row["path"])
                with self._connect() as db:
                    db.execute("UPDATE library_documents SET status='unavailable', error=?, updated_at=? WHERE id=?", (str(exc)[:1000], _now(), row["id"]))
                    db.execute("UPDATE document_jobs SET state='cancelled',updated_at=? WHERE document_id=? AND state IN ('queued','running')", (_now(), row["id"]))

    def _pending(self) -> list[str]:
        with self._connect() as db:
            # A process crash leaves a durable queued job, not an endless spinner.
            for row in db.execute("SELECT id,owner_pid FROM document_jobs WHERE state='running'").fetchall():
                try:
                    if row["owner_pid"]:
                        os.kill(row["owner_pid"], 0)
                        continue
                except (ProcessLookupError, PermissionError):
                    pass
                db.execute("UPDATE document_jobs SET state='queued',owner_pid=NULL,updated_at=? WHERE id=?", (_now(), row["id"]))
            return [row[0] for row in db.execute("SELECT id FROM document_jobs WHERE state='queued' ORDER BY created_at LIMIT 100")]

    def _cached_result(self, job: dict[str, Any]) -> dict[str, Any] | None:
        with self._connect() as db:
            candidates = db.execute("""SELECT id FROM document_jobs
                WHERE id<>? AND content_hash=? AND format=? AND options_json=?
                AND state IN ('ready','partial') AND result_available=1
                AND (expires_at IS NULL OR expires_at>?) ORDER BY updated_at DESC""",
                (job["id"], job["content_hash"], job["format"], json.dumps(job["options"]), _now())).fetchall()
        for candidate in candidates:
            try:
                cached = self.result(candidate["id"])
                if cached.get("extractor_version") != job["options"]["extractor_version"]:
                    continue
                result = {key: cached[key] for key in ("segments", "truncated", "warnings", "extractor_version")}
                # Delimited tables use the filename as their sheet label; PDF,
                # Word and XLSX locators are intrinsic to the source bytes.
                if job["format"] in {"csv", "tsv"}:
                    for segment in result["segments"]:
                        segment["locator"]["sheet"] = Path(job["path"]).stem
                return result
            except (DocumentError, KeyError, TypeError):
                continue
        return None

    def _execute(self, job_id: str) -> None:
        with self._connect() as db:
            changed = db.execute("UPDATE document_jobs SET state='running',owner_pid=?,updated_at=? WHERE id=? AND state='queued'", (os.getpid(), _now(), job_id)).rowcount
            if not changed:
                return
            db.execute("UPDATE library_documents SET status='running',updated_at=? WHERE job_id=?", (_now(), job_id))
        try:
            job = self.job(job_id)
            result = self._cached_result(job)
            if result is None:
                result = _extract(self, job)
            with self._connect() as db:
                db.execute("BEGIN IMMEDIATE")
                current = db.execute("SELECT state FROM document_jobs WHERE id=?", (job_id,)).fetchone()
                if current is None or current["state"] != "running":
                    return
                if job["persistent"]:
                    doc = db.execute("SELECT * FROM library_documents WHERE id=?", (job["document_id"],)).fetchone()
                    if not doc or doc["job_id"] != job_id or doc["excluded"]:
                        return
                    source = contained_source(self.root, job["path"])
                    digest = hashlib.sha256()
                    with source.open("rb") as handle:
                        for data in iter(lambda: handle.read(1024 * 1024), b""):
                            digest.update(data)
                    if digest.hexdigest() != job["content_hash"]:
                        raise DocumentError("Source changed during extraction; retry its latest version.")
                    KnowledgeStore(str(self.root)).index_extracted_document(job["path"], job["content_hash"], result["segments"], job["format"])
                target = self.job_directory / job_id / "result.json"
                temporary = target.with_suffix(".tmp")
                temporary.write_text(json.dumps(result, ensure_ascii=False))
                temporary.chmod(0o600)
                temporary.replace(target)
                state = "partial" if result["truncated"] else "ready"
                db.execute("UPDATE document_jobs SET state=?,result_available=1,owner_pid=NULL,progress=MAX(progress,total),updated_at=? WHERE id=?", (state, _now(), job_id))
                db.execute("UPDATE library_documents SET status=?,error=NULL,segment_count=?,truncated=?,warnings_json=?,updated_at=? WHERE job_id=?", (state, len(result["segments"]), int(result["truncated"]), json.dumps(result["warnings"]), _now(), job_id))
        except _JobInterrupted:
            with self._connect() as db:
                db.execute("UPDATE document_jobs SET state='queued',owner_pid=NULL,updated_at=? WHERE id=? AND state='running'", (_now(), job_id))
                db.execute("UPDATE library_documents SET status='queued',updated_at=? WHERE job_id=? AND status='running'", (_now(), job_id))
        except Exception as exc:
            with self._connect() as db:
                db.execute("UPDATE document_jobs SET state='failed',error=?,owner_pid=NULL,updated_at=? WHERE id=? AND state='running'", (str(exc)[:1000], _now(), job_id))
                db.execute("UPDATE library_documents SET status='failed',error=?,updated_at=? WHERE job_id=? AND status='running'", (str(exc)[:1000], _now(), job_id))
        finally:
            # Results are bounded and durable; retaining a second 100 MB copy
            # of every completed source would grow storage on each reindex.
            with contextlib.suppress(OSError, DocumentError):
                if self.job(job_id)["state"] in TERMINAL:
                    (self.job_directory / job_id / "source").unlink()


def _extract(store: DocumentStore, job: dict[str, Any]) -> dict[str, Any]:
    if job["format"] == "pdf":
        helper = os.environ.get("LOCUS_DOCUMENT_EXTRACTOR_PATH", "")
        if not helper or not Path(helper).is_file() or not os.access(helper, os.X_OK):
            raise DocumentError("PDF extraction requires the bundled Locus document helper. Reinstall Locus or configure LOCUS_DOCUMENT_EXTRACTOR_PATH for development.")
        command = [helper]
    else:
        command = [sys.executable, "-m", "ollama_code.document_extract"]
    source = store.job_directory / job["id"] / "source"
    request = {
        "protocol_version": 1, "request_id": job["id"], "path": str(source),
        "format": job["format"], "filename": job["path"], "expected_hash": job["content_hash"], **job["options"],
    }
    # A document parser needs locale/runtime paths, not provider credentials,
    # broker tokens, or proxy configuration inherited by the main agent.
    inherited = sanitized_child_environment()
    environment = {key: value for key, value in inherited.items() if key in {
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
        "APP_SANDBOX_CONTAINER_ID", "CFFIXED_USER_HOME",
    }}
    # Agent source/dependencies may be outside site-packages in the sealed app.
    environment["PYTHONPATH"] = os.pathsep.join(sys.path)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    records: queue.Queue[bytes | None] = queue.Queue(maxsize=128)
    error_tail = bytearray()
    stop_readers = threading.Event()

    def read_stdout() -> None:
        assert process.stdout is not None
        try:
            while not stop_readers.is_set():
                line = process.stdout.readline(MAX_TEXT_BYTES + 65_536)
                if not line:
                    break
                while not stop_readers.is_set():
                    try:
                        records.put(line, timeout=.1)
                        break
                    except queue.Full:
                        pass
        finally:
            with contextlib.suppress(queue.Full):
                records.put(None, timeout=.2)

    def read_stderr() -> None:
        assert process.stderr is not None
        while data := process.stderr.read(4096):
            error_tail.extend(data)
            if len(error_tail) > 4096:
                del error_tail[:-4096]

    readers = [threading.Thread(target=read_stdout, daemon=True), threading.Thread(target=read_stderr, daemon=True)]
    for reader in readers:
        reader.start()
    assert process.stdin is not None
    process.stdin.write((json.dumps(request) + "\n").encode())
    process.stdin.close()
    segments: list[dict[str, Any]] = []
    terminal: dict[str, Any] | None = None
    consumed = 0
    text_bytes = 0
    deadline = time.monotonic() + DOCUMENT_DEADLINE
    last_check = 0.0
    try:
        while True:
            if _SHUTTING_DOWN.is_set():
                raise _JobInterrupted
            if time.monotonic() > deadline:
                if segments:
                    terminal = {"ok": True, "truncated": True, "warnings": ["Extraction reached its ten-minute deadline; complete sections were retained."]}
                    break
                raise DocumentError("Document extraction exceeded its ten-minute deadline.")
            if time.monotonic() - last_check > .15:
                if store.job(job["id"])["state"] != "running":
                    raise DocumentError("Document extraction was cancelled.")
                last_check = time.monotonic()
            try:
                raw = records.get(timeout=.15)
            except queue.Empty:
                if process.poll() is not None and not readers[0].is_alive():
                    break
                continue
            if raw is None:
                break
            consumed += len(raw)
            if consumed > MAX_WIRE_BYTES:
                raise DocumentError("Extraction output exceeded its bounded protocol size.")
            try:
                item = json.loads(raw)
            except (ValueError, UnicodeError) as exc:
                raise DocumentError("Document helper returned invalid output.") from exc
            if item.get("protocol_version") != 1 or terminal is not None:
                raise DocumentError("Document helper returned an invalid protocol sequence.")
            if item.get("type") == "segment":
                text = item.get("text")
                if not isinstance(text, str) or not isinstance(item.get("locator"), dict):
                    raise DocumentError("Document helper returned an invalid text segment.")
                text_bytes += len(text.encode())
                if text_bytes > MAX_TEXT_BYTES:
                    raise DocumentError("Document helper exceeded the 5 MB text limit.")
                segments.append({"text": text, "locator": item["locator"], "method": str(item.get("method", "embedded"))})
            elif item.get("type") == "progress":
                with store._connect() as db:
                    db.execute("UPDATE document_jobs SET progress=?,total=?,updated_at=? WHERE id=? AND state='running'", (max(0, int(item.get("progress", 0))), max(0, int(item.get("total", 0))), _now(), job["id"]))
            elif item.get("type") == "result":
                terminal = item
            else:
                raise DocumentError("Document helper returned an unknown record.")
        if terminal is None or not terminal.get("ok"):
            raise DocumentError(str((terminal or {}).get("error") or "Document helper ended before completing extraction."))
        return {
            "segments": segments, "truncated": bool(terminal.get("truncated")),
            "warnings": [str(item)[:1000] for item in terminal.get("warnings", [])][:100],
            "extractor_version": EXTRACTOR_VERSION,
        }
    finally:
        stop_readers.set()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        for reader in readers:
            reader.join(timeout=1)
        for stream in (process.stdout, process.stderr):
            if stream:
                stream.close()


class _Coordinator:
    def __init__(self) -> None:
        self._stores: dict[str, DocumentStore] = {}
        self._running: set[tuple[str, str]] = set()
        self._mutex = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._last_cleanup = 0.0
        threading.Thread(target=self._loop, name="locus-document-jobs", daemon=True).start()

    def register(self, store: DocumentStore) -> None:
        with self._mutex:
            self._stores[str(store.path)] = store
        self._wake.set()

    def _loop(self) -> None:
        while not self._stop.is_set():
            self._wake.wait(timeout=.5)
            self._wake.clear()
            if self._stop.is_set():
                break
            with self._mutex:
                stores = list(self._stores.values())
            if time.monotonic() - self._last_cleanup > 60:
                for store in stores:
                    with contextlib.suppress(OSError, sqlite3.Error):
                        store.cleanup_expired()
                self._last_cleanup = time.monotonic()
            for store in stores:
                with self._mutex:
                    if len(self._running) >= 2 or any(key[0] == str(store.path) for key in self._running):
                        continue
                try:
                    pending = store._pending()
                    if not pending:
                        continue
                    locks = self._locks(store)
                    if locks is None:
                        continue
                    key = (str(store.path), pending[0])
                    with self._mutex:
                        self._running.add(key)
                    threading.Thread(target=self._run, args=(store, key, locks), daemon=True).start()
                except (OSError, sqlite3.Error):
                    continue

    def _locks(self, store: DocumentStore) -> list[Any] | None:
        directory = paths.APP_DIR / "document-extraction-locks"
        directory.mkdir(exist_ok=True, parents=True, mode=0o700)
        workspace = (directory / (hashlib.sha256(str(store.root).encode()).hexdigest() + ".lock")).open("a+")
        try:
            fcntl.flock(workspace, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            workspace.close()
            return None
        for index in range(2):
            slot = (directory / f"global-{index}.lock").open("a+")
            try:
                fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return [workspace, slot]
            except BlockingIOError:
                slot.close()
        workspace.close()
        return None

    def _run(self, store: DocumentStore, key: tuple[str, str], locks: list[Any]) -> None:
        try:
            store._execute(key[1])
        finally:
            for lock in locks:
                lock.close()
            with self._mutex:
                self._running.discard(key)
            self._wake.set()


_COORDINATOR: _Coordinator | None = None
_COORDINATOR_LOCK = threading.Lock()


def _coordinator() -> _Coordinator:
    global _COORDINATOR
    with _COORDINATOR_LOCK:
        if _COORDINATOR is None:
            _SHUTTING_DOWN.clear()
            _COORDINATOR = _Coordinator()
        return _COORDINATOR


def restore_document_jobs() -> None:
    """Called at backend startup: resume saved jobs without opening their chats."""
    for database in (paths.APP_DIR / "knowledge").glob("*/document-library.sqlite3"):
        try:
            with sqlite3.connect(database) as db:
                row = db.execute("SELECT workspace FROM document_jobs ORDER BY created_at DESC LIMIT 1").fetchone()
            if row and Path(row[0]).is_dir():
                DocumentStore(row[0])
        except (OSError, sqlite3.Error, KnowledgeError):
            continue


def stop_document_jobs() -> None:
    """Reap parser children and leave interrupted jobs queued for relaunch."""
    global _COORDINATOR
    with _COORDINATOR_LOCK:
        coordinator = _COORDINATOR
        if coordinator is None:
            return
        _SHUTTING_DOWN.set()
        coordinator._stop.set()
        coordinator._wake.set()
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        with coordinator._mutex:
            if not coordinator._running:
                break
        time.sleep(.05)
    with _COORDINATOR_LOCK:
        _COORDINATOR = None
