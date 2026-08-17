"""Encrypted cross-chat context snapshots and skill-observation records."""
from __future__ import annotations

import hashlib
import json
import re
import secrets
import sqlite3
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .memory import _master_key, memory_database

SNAPSHOT_TTL_SECONDS = 30 * 24 * 60 * 60
MAX_SNAPSHOTS_PER_WORKSPACE = 50
MAX_CHANGED_FILES = 100
MAX_FIELD_CHARS = 8_000
VALID_OBSERVATION_STATUSES = {"OPEN", "ACTIONED", "DECLINED"}


class ContinuityError(RuntimeError):
    pass


def _workspace_target(workspace: str) -> str:
    if not str(workspace).strip():
        raise ContinuityError("cross-chat context requires an active workspace")
    try:
        resolved = str(Path(workspace).expanduser().resolve())
    except (OSError, RuntimeError) as exc:
        raise ContinuityError("workspace path is invalid") from exc
    return hashlib.sha256(resolved.encode()).hexdigest()


def _bounded_text(value: Any, limit: int = MAX_FIELD_CHARS) -> str:
    return str(value or "").strip()[:limit]


def _tokens(value: str) -> set[str]:
    return {
        token for token in re.findall(r"[a-z0-9_./-]{2,}", value.lower())
        if token not in {"the", "and", "for", "with", "from", "this", "that", "into"}
    }


def workspace_changed_files(workspace: str) -> list[str]:
    """Return a bounded, read-only git status inventory for snapshot evidence."""
    try:
        completed = subprocess.run(
            ["git", "-C", workspace, "status", "--porcelain=v1", "-z"],
            capture_output=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if completed.returncode != 0:
        return []
    files: list[str] = []
    for entry in completed.stdout.decode("utf-8", errors="replace").split("\0"):
        if not entry:
            continue
        path = entry[3:] if len(entry) > 3 else entry
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        value = path.strip()
        if value and value not in files:
            files.append(value[:1_000])
        if len(files) >= MAX_CHANGED_FILES:
            break
    return files


class ContinuityStore:
    """Share the encrypted memory database without mixing approval semantics."""

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
                CREATE TABLE IF NOT EXISTS context_snapshots (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    workspace_hash TEXT NOT NULL,
                    nonce BLOB NOT NULL,
                    ciphertext BLOB NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    expires_at REAL,
                    UNIQUE(session_id, workspace_hash)
                );
                CREATE INDEX IF NOT EXISTS context_snapshots_lookup_idx
                    ON context_snapshots(workspace_hash, pinned, updated_at DESC);
                CREATE TABLE IF NOT EXISTS skill_observations (
                    id TEXT PRIMARY KEY,
                    number INTEGER NOT NULL,
                    workspace_hash TEXT NOT NULL,
                    status TEXT NOT NULL,
                    nonce BLOB NOT NULL,
                    ciphertext BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(workspace_hash, number)
                );
                CREATE INDEX IF NOT EXISTS skill_observations_lookup_idx
                    ON skill_observations(workspace_hash, status, number DESC);
                """
            )
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    @staticmethod
    def _snapshot_aad(identifier: str, session_id: str, target: str) -> bytes:
        return f"locus-context-v1|{identifier}|{session_id}|{target}".encode()

    @staticmethod
    def _observation_aad(identifier: str, number: int, target: str, status: str) -> bytes:
        return f"locus-observation-v1|{identifier}|{number}|{target}|{status}".encode()

    def _decrypt_snapshot(self, row: sqlite3.Row) -> dict[str, Any]:
        try:
            raw = self._cipher.decrypt(
                bytes(row["nonce"]),
                bytes(row["ciphertext"]),
                self._snapshot_aad(str(row["id"]), str(row["session_id"]), str(row["workspace_hash"])),
            )
            payload = json.loads(raw)
        except Exception as exc:  # noqa: BLE001 - corrupt encrypted rows must be isolated
            raise ContinuityError("a context snapshot could not be decrypted") from exc
        return {
            **payload,
            "id": str(row["id"]),
            "session_id": str(row["session_id"]),
            "pinned": bool(row["pinned"]),
            "created_at": float(row["created_at"]),
            "updated_at": float(row["updated_at"]),
            "expires_at": float(row["expires_at"]) if row["expires_at"] is not None else None,
        }

    def save_snapshot(
        self,
        workspace: str,
        session_id: str,
        payload: dict[str, Any],
        *,
        pinned: bool = False,
    ) -> dict[str, Any]:
        target = _workspace_target(workspace)
        session_id = _bounded_text(session_id, 160)
        if not session_id:
            raise ContinuityError("context snapshot requires a session id")
        now = time.time()
        document = {
            "goal": _bounded_text(payload.get("goal"), 4_000),
            "outcome": _bounded_text(payload.get("outcome"), 8_000),
            "mode": _bounded_text(payload.get("mode"), 32),
            "plan": payload.get("plan") if isinstance(payload.get("plan"), dict) else None,
            "todos": [
                {
                    "content": _bounded_text(item.get("content"), 1_000),
                    "status": _bounded_text(item.get("status"), 32),
                }
                for item in (payload.get("todos") or [])[:100]
                if isinstance(item, dict) and _bounded_text(item.get("content"), 1_000)
            ],
            "checkpoint": payload.get("checkpoint") if isinstance(payload.get("checkpoint"), dict) else None,
            "changed_files": [
                _bounded_text(item, 1_000) for item in (payload.get("changed_files") or [])[:MAX_CHANGED_FILES]
                if _bounded_text(item, 1_000)
            ],
            "pending": _bounded_text(payload.get("pending"), 4_000),
        }
        with self._lock, self._connect() as connection:
            existing = connection.execute(
                "SELECT id, created_at, pinned FROM context_snapshots WHERE session_id=? AND workspace_hash=?",
                (session_id, target),
            ).fetchone()
            identifier = str(existing["id"]) if existing else uuid.uuid4().hex
            created_at = float(existing["created_at"]) if existing else now
            is_pinned = bool(existing["pinned"]) if existing else pinned
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce,
                json.dumps(document, separators=(",", ":")).encode(),
                self._snapshot_aad(identifier, session_id, target),
            )
            expires_at = None if is_pinned else now + SNAPSHOT_TTL_SECONDS
            connection.execute(
                """
                INSERT INTO context_snapshots(
                    id, session_id, workspace_hash, nonce, ciphertext, pinned,
                    created_at, updated_at, expires_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, workspace_hash) DO UPDATE SET
                    nonce=excluded.nonce, ciphertext=excluded.ciphertext,
                    pinned=excluded.pinned, updated_at=excluded.updated_at,
                    expires_at=excluded.expires_at
                """,
                (
                    identifier, session_id, target, nonce, ciphertext,
                    int(is_pinned), created_at, now, expires_at,
                ),
            )
            self._prune_snapshots(connection, target, now)
            row = connection.execute(
                "SELECT * FROM context_snapshots WHERE id=?", (identifier,)
            ).fetchone()
        if row is None:
            raise ContinuityError("context snapshot could not be stored")
        return self._decrypt_snapshot(row)

    @staticmethod
    def _prune_snapshots(connection: sqlite3.Connection, target: str, now: float) -> None:
        connection.execute(
            "DELETE FROM context_snapshots WHERE pinned=0 AND expires_at IS NOT NULL AND expires_at < ?",
            (now,),
        )
        overflow = connection.execute(
            """
            SELECT id FROM context_snapshots
            WHERE workspace_hash=? AND pinned=0
            ORDER BY updated_at DESC
            LIMIT -1 OFFSET ?
            """,
            (target, MAX_SNAPSHOTS_PER_WORKSPACE),
        ).fetchall()
        if overflow:
            connection.executemany(
                "DELETE FROM context_snapshots WHERE id=?",
                [(str(row["id"]),) for row in overflow],
            )

    def list_snapshots(
        self,
        workspace: str,
        *,
        exclude_session: str = "",
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        target = _workspace_target(workspace)
        now = time.time()
        with self._lock, self._connect() as connection:
            self._prune_snapshots(connection, target, now)
            rows = connection.execute(
                """
                SELECT * FROM context_snapshots
                WHERE workspace_hash=? AND session_id<>?
                ORDER BY pinned DESC, updated_at DESC LIMIT ?
                """,
                (target, exclude_session, max(1, min(int(limit), 100))),
            ).fetchall()
        results: list[dict[str, Any]] = []
        for row in rows:
            try:
                results.append(self._decrypt_snapshot(row))
            except ContinuityError:
                continue
        return results

    def search_snapshots(
        self,
        query: str,
        workspace: str,
        *,
        exclude_session: str = "",
        limit: int = 2,
    ) -> list[dict[str, Any]]:
        candidates = self.list_snapshots(
            workspace, exclude_session=exclude_session, limit=MAX_SNAPSHOTS_PER_WORKSPACE
        )
        query_tokens = _tokens(query)
        now = time.time()

        def score(item: dict[str, Any]) -> tuple[float, float]:
            searchable = " ".join([
                str(item.get("goal") or ""), str(item.get("outcome") or ""),
                str(item.get("pending") or ""), " ".join(item.get("changed_files") or []),
            ])
            overlap = len(query_tokens & _tokens(searchable))
            age_days = max((now - float(item.get("updated_at") or now)) / 86_400, 0)
            return (overlap * 10 + (4 if item.get("pinned") else 0) - min(age_days, 30) / 30, float(item.get("updated_at") or 0))

        candidates.sort(key=score, reverse=True)
        return candidates[:max(0, min(int(limit), 10))]

    def delete_snapshot(self, identifier: str, workspace: str) -> bool:
        target = _workspace_target(workspace)
        with self._lock, self._connect() as connection:
            result = connection.execute(
                "DELETE FROM context_snapshots WHERE id=? AND workspace_hash=?",
                (identifier, target),
            )
        return bool(result.rowcount)

    def set_snapshot_pinned(
        self, identifier: str, workspace: str, pinned: bool
    ) -> dict[str, Any]:
        target = _workspace_target(workspace)
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM context_snapshots WHERE id=? AND workspace_hash=?",
                (identifier, target),
            ).fetchone()
            if row is None:
                raise ContinuityError("context snapshot not found")
            now = time.time()
            connection.execute(
                "UPDATE context_snapshots SET pinned=?, expires_at=?, updated_at=? WHERE id=?",
                (
                    int(pinned),
                    None if pinned else now + SNAPSHOT_TTL_SECONDS,
                    now,
                    identifier,
                ),
            )
            updated = connection.execute(
                "SELECT * FROM context_snapshots WHERE id=?", (identifier,)
            ).fetchone()
        if updated is None:
            raise ContinuityError("context snapshot not found")
        return self._decrypt_snapshot(updated)

    def clear_snapshots(self, workspace: str) -> int:
        target = _workspace_target(workspace)
        with self._lock, self._connect() as connection:
            result = connection.execute(
                "DELETE FROM context_snapshots WHERE workspace_hash=?", (target,)
            )
        return int(result.rowcount)

    def _decrypt_observation(self, row: sqlite3.Row) -> dict[str, Any]:
        try:
            raw = self._cipher.decrypt(
                bytes(row["nonce"]), bytes(row["ciphertext"]),
                self._observation_aad(
                    str(row["id"]), int(row["number"]),
                    str(row["workspace_hash"]), str(row["status"]),
                ),
            )
            payload = json.loads(raw)
        except Exception as exc:  # noqa: BLE001
            raise ContinuityError("a skill observation could not be decrypted") from exc
        return {
            **payload,
            "id": str(row["id"]),
            "number": int(row["number"]),
            "status": str(row["status"]),
            "created_at": float(row["created_at"]),
            "updated_at": float(row["updated_at"]),
        }

    def record_observation(self, workspace: str, payload: dict[str, Any]) -> dict[str, Any]:
        target = _workspace_target(workspace)
        checkpoint_only = payload.get("checkpoint_only") is True
        document = {
            "title": _bounded_text(payload.get("title"), 200) or (
                "Observation checkpoint" if checkpoint_only else "Skill observation"
            ),
            "session_context": _bounded_text(payload.get("session_context"), 2_000),
            "skill": _bounded_text(payload.get("skill"), 200) or "All skills",
            "type": "internal" if str(payload.get("type")).lower() == "internal" else "open-source",
            "phase_area": _bounded_text(payload.get("phase_area"), 500),
            "issue": _bounded_text(payload.get("issue"), 4_000),
            "suggested_improvement": _bounded_text(payload.get("suggested_improvement"), 4_000),
            "principle": _bounded_text(payload.get("principle"), 4_000),
            "checkpoint_only": checkpoint_only,
            "source_session_id": _bounded_text(payload.get("source_session_id"), 160),
            "source_run_id": _bounded_text(payload.get("source_run_id"), 160),
        }
        if not checkpoint_only and not all(
            document[field] for field in ("issue", "suggested_improvement", "principle")
        ):
            raise ContinuityError(
                "skill observations require issue, suggested improvement, and principle"
            )
        now = time.time()
        identifier = uuid.uuid4().hex
        status = "OPEN"
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT COALESCE(MAX(number), 0) AS maximum FROM skill_observations WHERE workspace_hash=?",
                (target,),
            ).fetchone()
            number = int(row["maximum"] if row else 0) + 1
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce,
                json.dumps(document, separators=(",", ":")).encode(),
                self._observation_aad(identifier, number, target, status),
            )
            connection.execute(
                """
                INSERT INTO skill_observations(
                    id, number, workspace_hash, status, nonce, ciphertext, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (identifier, number, target, status, nonce, ciphertext, now, now),
            )
            stored = connection.execute(
                "SELECT * FROM skill_observations WHERE id=?", (identifier,)
            ).fetchone()
        if stored is None:
            raise ContinuityError("skill observation could not be stored")
        return self._decrypt_observation(stored)

    def list_observations(
        self, workspace: str, *, status: str = "", limit: int = 200
    ) -> list[dict[str, Any]]:
        target = _workspace_target(workspace)
        normalized = status.upper()
        if normalized and normalized not in VALID_OBSERVATION_STATUSES:
            raise ContinuityError("invalid observation status")
        query = "SELECT * FROM skill_observations WHERE workspace_hash=?"
        values: list[Any] = [target]
        if normalized:
            query += " AND status=?"
            values.append(normalized)
        query += " ORDER BY number DESC LIMIT ?"
        values.append(max(1, min(int(limit), 1_000)))
        with self._lock, self._connect() as connection:
            rows = connection.execute(query, values).fetchall()
        results: list[dict[str, Any]] = []
        for row in rows:
            try:
                results.append(self._decrypt_observation(row))
            except ContinuityError:
                continue
        return results

    def set_observation_status(
        self, identifier: str, workspace: str, status: str
    ) -> dict[str, Any]:
        target = _workspace_target(workspace)
        normalized = status.upper()
        if normalized not in VALID_OBSERVATION_STATUSES:
            raise ContinuityError("invalid observation status")
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM skill_observations WHERE id=? AND workspace_hash=?",
                (identifier, target),
            ).fetchone()
            if row is None:
                raise ContinuityError("skill observation not found")
            payload = self._decrypt_observation(row)
            document = {
                key: value for key, value in payload.items()
                if key not in {"id", "number", "status", "created_at", "updated_at"}
            }
            now = time.time()
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce,
                json.dumps(document, separators=(",", ":")).encode(),
                self._observation_aad(identifier, int(row["number"]), target, normalized),
            )
            connection.execute(
                "UPDATE skill_observations SET status=?, nonce=?, ciphertext=?, updated_at=? WHERE id=?",
                (normalized, nonce, ciphertext, now, identifier),
            )
            updated = connection.execute(
                "SELECT * FROM skill_observations WHERE id=?", (identifier,)
            ).fetchone()
        if updated is None:
            raise ContinuityError("skill observation not found")
        return self._decrypt_observation(updated)

    def delete_observation(self, identifier: str, workspace: str) -> bool:
        target = _workspace_target(workspace)
        with self._lock, self._connect() as connection:
            result = connection.execute(
                "DELETE FROM skill_observations WHERE id=? AND workspace_hash=?",
                (identifier, target),
            )
        return bool(result.rowcount)

    def export_observations(self, workspace: str) -> dict[str, Any]:
        return {
            "format": "locus-skill-observations",
            "version": 1,
            "exported_at": time.time(),
            "observations": self.list_observations(workspace, limit=1_000),
        }


def format_context_snapshots(results: list[dict[str, Any]], max_tokens: int) -> str:
    if not results or max_tokens <= 0:
        return ""
    sections = [
        "Cross-chat workspace context (local encrypted session snapshots; verify against the current workspace):"
    ]
    for item in results:
        lines = [f"\n## Prior session {item.get('session_id', '')}"]
        if item.get("goal"):
            lines.append("Goal: " + str(item["goal"]))
        if item.get("outcome"):
            lines.append("Outcome: " + str(item["outcome"]))
        if item.get("pending"):
            lines.append("Pending: " + str(item["pending"]))
        files = item.get("changed_files") or []
        if files:
            lines.append("Changed files: " + ", ".join(str(value) for value in files[:30]))
        todos = [
            str(todo.get("content") or "") for todo in item.get("todos") or []
            if isinstance(todo, dict) and todo.get("status") != "completed"
        ]
        if todos:
            lines.append("Open steps: " + "; ".join(todos[:20]))
        sections.append("\n".join(lines))
    return "\n".join(sections)[:max_tokens * 4]


__all__ = [
    "ContinuityError", "ContinuityStore", "format_context_snapshots",
    "workspace_changed_files",
]
