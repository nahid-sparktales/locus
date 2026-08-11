"""Encrypted local memory with approval states and explicit scope boundaries."""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import paths, proxy

VALID_SCOPES = {"personal", "workspace", "agent"}
VALID_STATUSES = {"candidate", "approved"}
CANDIDATE_TTL_SECONDS = 30 * 24 * 60 * 60
MAX_MEMORY_CONTENT = 32_000


class MemoryError(RuntimeError):
    pass


def memory_database() -> Path:
    return paths.APP_DIR / "memory" / "memory.sqlite3"


def _fallback_key(path: Path | None = None) -> bytes:
    """Standalone CLI fallback; the macOS app supplies a Keychain key."""
    key_path = path or (paths.APP_DIR / "memory" / "master.key")
    key_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        key_path.parent.chmod(0o700)
    except OSError:
        pass
    try:
        value = key_path.read_bytes()
        if len(value) == 32:
            return value
    except OSError:
        pass
    value = secrets.token_bytes(32)
    try:
        descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        # Another standalone process may have won the first-run key race.
        # Always adopt the complete winner; never overwrite or split the vault.
        try:
            existing = key_path.read_bytes()
        except OSError as read_error:
            raise MemoryError("the memory encryption key is unavailable") from read_error
        if len(existing) == 32:
            return existing
        raise MemoryError("the memory encryption key is invalid") from exc
    try:
        os.write(descriptor, value)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return value


def _master_key(key: bytes | None = None, fallback_path: Path | None = None) -> bytes:
    value = key or proxy.memory_master_key() or _fallback_key(fallback_path)
    if len(value) != 32:
        raise MemoryError("memory encryption requires a 256-bit key")
    return value


def _target(scope: str, *, workspace: str = "", agent_id: str = "") -> str:
    if scope == "personal":
        return "personal"
    if scope == "workspace":
        if not workspace.strip():
            raise MemoryError("workspace memory requires an active workspace")
        try:
            value = str(Path(workspace).expanduser().resolve())
        except (OSError, RuntimeError) as exc:
            raise MemoryError("workspace memory target is invalid") from exc
        return "workspace:" + hashlib.sha256(value.encode()).hexdigest()
    if scope == "agent":
        value = agent_id.strip()
        if not value:
            raise MemoryError("agent memory requires an agent id")
        return "agent:" + hashlib.sha256(value.encode()).hexdigest()
    raise MemoryError("memory scope must be personal, workspace, or agent")


class MemoryVault:
    def __init__(
        self,
        path: Path | None = None,
        *,
        key: bytes | None = None,
        fallback_key_path: Path | None = None,
    ) -> None:
        self.path = path or memory_database()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._key = _master_key(key, fallback_key_path)
        self._cipher = AESGCM(self._key)
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=10000")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL CHECK(status IN ('candidate', 'approved')),
                    scope TEXT NOT NULL CHECK(scope IN ('personal', 'workspace', 'agent')),
                    target_hash TEXT NOT NULL,
                    nonce BLOB NOT NULL,
                    ciphertext BLOB NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    stale INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    expires_at REAL
                );
                CREATE INDEX IF NOT EXISTS memories_lookup_idx
                    ON memories(status, scope, target_hash, pinned, updated_at);
                """
            )
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    @staticmethod
    def _aad(
        identifier: str, status: str, scope: str, target_hash: str, revision: int
    ) -> bytes:
        return f"memory-v1|{identifier}|{status}|{scope}|{target_hash}|{revision}".encode()

    def _seal(
        self,
        payload: dict[str, Any],
        *,
        identifier: str,
        status: str,
        scope: str,
        target_hash: str,
        revision: int,
    ) -> tuple[bytes, bytes]:
        nonce = secrets.token_bytes(12)
        plaintext = json.dumps(
            payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode()
        return nonce, self._cipher.encrypt(
            nonce, plaintext, self._aad(identifier, status, scope, target_hash, revision)
        )

    def _open(self, row: sqlite3.Row) -> dict[str, Any]:
        try:
            plaintext = self._cipher.decrypt(
                bytes(row["nonce"]),
                bytes(row["ciphertext"]),
                self._aad(
                    row["id"], row["status"], row["scope"],
                    row["target_hash"], int(row["revision"]),
                ),
            )
            payload = json.loads(plaintext)
        except Exception as exc:  # authentication failure must stay generic
            raise MemoryError("a memory record could not be decrypted") from exc
        return {
            "id": row["id"], "status": row["status"], "scope": row["scope"],
            "title": str(payload.get("title") or "Memory"),
            "content": str(payload.get("content") or ""),
            "tags": list(payload.get("tags") or []),
            "reason": str(payload.get("reason") or ""),
            "source_session_id": payload.get("source_session_id"),
            "source_run_id": payload.get("source_run_id"),
            "provenance": payload.get("provenance") or {},
            "pinned": bool(row["pinned"]), "stale": bool(row["stale"]),
            "revision": int(row["revision"]),
            "created_at": float(row["created_at"]),
            "updated_at": float(row["updated_at"]),
            "expires_at": row["expires_at"],
        }

    def save(
        self,
        value: dict[str, Any],
        memory_id: str = "",
        *,
        workspace: str = "",
        agent_id: str = "",
        default_status: str = "approved",
    ) -> dict[str, Any]:
        identifier = memory_id or uuid.uuid4().hex
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", identifier):
            raise MemoryError("memory id is invalid")
        status = str(value.get("status") or default_status).lower()
        scope = str(value.get("scope") or "workspace").lower()
        if status not in VALID_STATUSES or scope not in VALID_SCOPES:
            raise MemoryError("memory status or scope is invalid")
        target_hash = _target(scope, workspace=workspace, agent_id=agent_id)
        content = str(value.get("content") or "").strip()[:MAX_MEMORY_CONTENT]
        if not content:
            raise MemoryError("memory content cannot be empty")
        title = str(value.get("title") or "Memory").strip()[:160] or "Memory"
        tags = sorted({
            str(item).strip().lower()[:40] for item in value.get("tags") or []
            if str(item).strip()
        })[:24]
        payload = {
            "title": title,
            "content": content,
            "tags": tags,
            "reason": str(value.get("reason") or "")[:2_000],
            "source_session_id": str(value.get("source_session_id") or "") or None,
            "source_run_id": str(value.get("source_run_id") or "") or None,
            "provenance": value.get("provenance")
            if isinstance(value.get("provenance"), dict) else {},
        }
        now = time.time()
        with self._lock, self._connect() as connection:
            previous = connection.execute(
                "SELECT * FROM memories WHERE id=?", (identifier,)
            ).fetchone()
            revision = int(previous["revision"]) + 1 if previous else 1
            created_at = float(previous["created_at"]) if previous else now
            expires_at = (
                now + CANDIDATE_TTL_SECONDS if status == "candidate" else None
            )
            nonce, ciphertext = self._seal(
                payload, identifier=identifier, status=status, scope=scope,
                target_hash=target_hash, revision=revision,
            )
            connection.execute(
                """INSERT INTO memories(
                    id, status, scope, target_hash, nonce, ciphertext, pinned, stale,
                    revision, created_at, updated_at, expires_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET status=excluded.status, scope=excluded.scope,
                    target_hash=excluded.target_hash, nonce=excluded.nonce,
                    ciphertext=excluded.ciphertext, pinned=excluded.pinned,
                    stale=excluded.stale, revision=excluded.revision,
                    updated_at=excluded.updated_at, expires_at=excluded.expires_at""",
                (
                    identifier, status, scope, target_hash, nonce, ciphertext,
                    int(bool(value.get("pinned"))), int(bool(value.get("stale"))),
                    revision, created_at, now, expires_at,
                ),
            )
            row = connection.execute(
                "SELECT * FROM memories WHERE id=?", (identifier,)
            ).fetchone()
        return self._open(row)

    def approve(
        self, memory_id: str, *, workspace: str = "", agent_id: str = ""
    ) -> dict[str, Any]:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM memories WHERE id=?", (memory_id,)
            ).fetchone()
        if row is None:
            raise MemoryError("memory candidate not found")
        value = self._open(row)
        value["status"] = "approved"
        return self.save(
            value, memory_id, workspace=workspace, agent_id=agent_id,
            default_status="approved",
        )

    def expire_candidates(self) -> int:
        with self._connect() as connection:
            return connection.execute(
                "DELETE FROM memories WHERE status='candidate' AND expires_at < ?",
                (time.time(),),
            ).rowcount

    def list(
        self,
        *,
        workspace: str = "",
        agent_id: str = "",
        status: str = "",
        scopes: list[str] | tuple[str, ...] | None = None,
    ) -> list[dict[str, Any]]:
        self.expire_candidates()
        selected_scopes = tuple(
            scope for scope in (scopes or ("personal", "workspace", "agent"))
            if scope in VALID_SCOPES
        )
        targets: list[tuple[str, str]] = []
        for scope in selected_scopes:
            try:
                targets.append((scope, _target(scope, workspace=workspace, agent_id=agent_id)))
            except MemoryError:
                continue
        if not targets:
            return []
        clauses = " OR ".join("(scope=? AND target_hash=?)" for _ in targets)
        parameters: list[Any] = [item for pair in targets for item in pair]
        status_clause = ""
        if status in VALID_STATUSES:
            status_clause = " AND status=?"
            parameters.append(status)
        with self._connect() as connection:
            rows = connection.execute(
                f"SELECT * FROM memories WHERE ({clauses}){status_clause} "
                "ORDER BY pinned DESC, updated_at DESC",
                parameters,
            ).fetchall()
        return [self._open(row) for row in rows]

    def search(
        self,
        query: str,
        *,
        workspace: str = "",
        agent_id: str = "",
        scopes: list[str] | tuple[str, ...] | None = None,
        limit: int = 8,
        approved_only: bool = True,
    ) -> list[dict[str, Any]]:
        value = query.strip().lower()[:2_000]
        if not value:
            raise MemoryError("memory search requires a query")
        terms = [term for term in re.findall(r"[\w.-]+", value) if len(term) > 1][:24]
        candidates = self.list(
            workspace=workspace, agent_id=agent_id,
            status="approved" if approved_only else "", scopes=scopes,
        )
        ranked: list[tuple[float, dict[str, Any]]] = []
        now = time.time()
        for memory in candidates:
            haystack = " ".join((
                memory["title"], memory["content"], " ".join(memory["tags"])
            )).lower()
            phrase = 4.0 if value in haystack else 0.0
            matches = sum(haystack.count(term) for term in terms)
            if not phrase and not matches:
                continue
            age_days = max((now - memory["updated_at"]) / 86_400, 0)
            score = phrase + matches + (2.0 if memory["pinned"] else 0) + 1 / (1 + age_days)
            if memory["stale"]:
                score *= 0.4
            ranked.append((score, memory))
        ranked.sort(key=lambda item: (-item[0], item[1]["id"]))
        return [{**memory, "score": score} for score, memory in ranked[:min(max(limit, 1), 20)]]

    def delete(self, memory_id: str) -> bool:
        with self._connect() as connection:
            return connection.execute(
                "DELETE FROM memories WHERE id=?", (memory_id,)
            ).rowcount == 1

    def delete_all(
        self, *, workspace: str = "", agent_id: str = "", scopes: list[str] | None = None
    ) -> int:
        memories = self.list(workspace=workspace, agent_id=agent_id, scopes=scopes)
        identifiers = [item["id"] for item in memories]
        if not identifiers:
            return 0
        with self._connect() as connection:
            return connection.executemany(
                "DELETE FROM memories WHERE id=?", ((item,) for item in identifiers)
            ).rowcount

    def status(self, *, workspace: str = "", agent_id: str = "") -> dict[str, Any]:
        items = self.list(workspace=workspace, agent_id=agent_id)
        return {
            "encrypted": True,
            "cipher": "AES-256-GCM",
            "approved_count": sum(item["status"] == "approved" for item in items),
            "candidate_count": sum(item["status"] == "candidate" for item in items),
            "candidate_ttl_days": 30,
        }

    def export(self, *, workspace: str = "", agent_id: str = "") -> dict[str, Any]:
        return {
            "format": "locus-memory-export",
            "version": 1,
            "exported_at": time.time(),
            "memories": self.list(workspace=workspace, agent_id=agent_id),
        }

    def import_values(
        self,
        document: dict[str, Any],
        *,
        workspace: str = "",
        agent_id: str = "",
    ) -> int:
        if document.get("format") != "locus-memory-export" or document.get("version") != 1:
            raise MemoryError("memory import format is not supported")
        values = document.get("memories")
        if not isinstance(values, list) or len(values) > 10_000:
            raise MemoryError("memory import is malformed or too large")
        imported = 0
        for raw in values:
            if not isinstance(raw, dict):
                continue
            self.save(
                raw, str(raw.get("id") or ""), workspace=workspace, agent_id=agent_id,
                default_status=str(raw.get("status") or "approved"),
            )
            imported += 1
        return imported


def format_memory_results(results: list[dict[str, Any]]) -> str:
    if not results:
        return "No approved memory matched that query."
    lines = ["Approved memory results (local user-controlled context):"]
    for item in results:
        stale = " · stale" if item.get("stale") else ""
        lines.append(
            f"\n## {item['title']} [{item['scope']}{stale}]\n{item['content']}"
        )
    return "\n".join(lines)[:30_000]


__all__ = [
    "MemoryError", "MemoryVault", "format_memory_results", "memory_database",
]
