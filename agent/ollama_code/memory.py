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

from . import paths

VALID_SCOPES = {"personal", "workspace", "agent"}
VALID_STATUSES = {"candidate", "approved"}
VALID_KINDS = {"preference", "fact", "decision", "procedure", "relationship"}
CANDIDATE_TTL_SECONDS = 30 * 24 * 60 * 60
MAX_MEMORY_CONTENT = 32_000


class MemoryError(RuntimeError):
    pass


def memory_database() -> Path:
    return paths.APP_DIR / "memory" / "memory.sqlite3"


def _fallback_key(path: Path | None = None) -> bytes:
    """Load or create the user-only local key used for the encrypted vault."""
    key_path = path or (paths.APP_DIR / "memory" / "master.key")
    key_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        key_path.parent.chmod(0o700)
    except OSError:
        pass
    try:
        value = key_path.read_bytes()
        if len(value) == 32:
            try:
                key_path.chmod(0o600)
            except OSError:
                pass
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
    value = key or _fallback_key(fallback_path)
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
                CREATE TABLE IF NOT EXISTS memory_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    workspace_hash TEXT NOT NULL,
                    agent_hash TEXT NOT NULL,
                    session_id TEXT,
                    run_id TEXT,
                    stage TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    reason_code TEXT NOT NULL DEFAULT '',
                    memory_id TEXT,
                    occurred_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS memory_events_target_idx
                    ON memory_events(workspace_hash, agent_hash, occurred_at DESC);
                """
            )
            columns = {
                str(row["name"])
                for row in connection.execute("PRAGMA table_info(memories)").fetchall()
            }
            migrations = {
                "last_used_at": "ALTER TABLE memories ADD COLUMN last_used_at REAL",
                "use_count": "ALTER TABLE memories ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0",
                "superseded_by": "ALTER TABLE memories ADD COLUMN superseded_by TEXT",
            }
            for name, statement in migrations.items():
                if name not in columns:
                    connection.execute(statement)
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

    def _open_payload(self, row: sqlite3.Row) -> dict[str, Any]:
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
        if not isinstance(payload, dict):
            raise MemoryError("a memory record is malformed")
        return payload

    def _open(self, row: sqlite3.Row) -> dict[str, Any]:
        payload = self._open_payload(row)
        return {
            "id": row["id"], "status": row["status"], "scope": row["scope"],
            "title": str(payload.get("title") or "Memory"),
            "content": str(payload.get("content") or ""),
            "tags": list(payload.get("tags") or []),
            "reason": str(payload.get("reason") or ""),
            "source_session_id": payload.get("source_session_id"),
            "source_run_id": payload.get("source_run_id"),
            "provenance": payload.get("provenance") or {},
            "kind": str(payload.get("kind") or "fact"),
            "confidence": float(payload.get("confidence", 1.0)),
            "valid_from": payload.get("valid_from"),
            "valid_until": payload.get("valid_until"),
            "last_confirmed_at": payload.get("last_confirmed_at"),
            "supersedes": list(payload.get("supersedes") or []),
            "embedding_model": str(payload.get("embedding_model") or ""),
            "pinned": bool(row["pinned"]), "stale": bool(row["stale"]),
            "last_used_at": row["last_used_at"],
            "use_count": int(row["use_count"] or 0),
            "superseded_by": row["superseded_by"],
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
        kind = str(value.get("kind") or "fact").strip().lower()
        if kind not in VALID_KINDS:
            raise MemoryError("memory type must be preference, fact, decision, procedure, or relationship")
        try:
            confidence = min(max(float(value.get("confidence", 1.0)), 0.0), 1.0)
        except (TypeError, ValueError) as exc:
            raise MemoryError("memory confidence must be between 0 and 1") from exc

        def timestamp(name: str) -> float | None:
            raw = value.get(name)
            if raw in (None, ""):
                return None
            try:
                return float(raw)
            except (TypeError, ValueError) as exc:
                raise MemoryError(f"memory {name} must be a Unix timestamp") from exc

        valid_from = timestamp("valid_from")
        valid_until = timestamp("valid_until")
        if valid_from is not None and valid_until is not None and valid_until <= valid_from:
            raise MemoryError("memory valid-until date must be after its valid-from date")
        existing_embedding = value.get("embedding")
        embedding = (
            [float(item) for item in existing_embedding]
            if isinstance(existing_embedding, list) else []
        )
        payload = {
            "title": title,
            "content": content,
            "tags": tags,
            "reason": str(value.get("reason") or "")[:2_000],
            "source_session_id": str(value.get("source_session_id") or "") or None,
            "source_run_id": str(value.get("source_run_id") or "") or None,
            "provenance": value.get("provenance")
            if isinstance(value.get("provenance"), dict) else {},
            "kind": kind,
            "confidence": confidence,
            "valid_from": valid_from,
            "valid_until": valid_until,
            "last_confirmed_at": timestamp("last_confirmed_at"),
            "supersedes": [str(item)[:128] for item in value.get("supersedes") or []][:32],
            # Embeddings stay inside the authenticated ciphertext. An empty
            # vector means semantic recall will lazily create one later.
            "embedding": embedding,
            "embedding_model": str(value.get("embedding_model") or "")[:256],
        }
        now = time.time()
        with self._lock, self._connect() as connection:
            previous = connection.execute(
                "SELECT * FROM memories WHERE id=?", (identifier,)
            ).fetchone()
            if previous is not None:
                previous_payload = self._open_payload(previous)
                for key in (
                    "reason", "source_session_id", "source_run_id", "provenance",
                    "last_confirmed_at", "supersedes", "embedding", "embedding_model",
                    "feedback",
                ):
                    if key not in value:
                        payload[key] = previous_payload.get(key)
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
        result = self._open(row)
        result["conflicts"] = self.conflicts_for(
            result, workspace=workspace, agent_id=agent_id
        )
        return result

    def approve(
        self, memory_id: str, *, workspace: str = "", agent_id: str = "",
        resolution: str = "keep_both",
    ) -> dict[str, Any]:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM memories WHERE id=?", (memory_id,)
            ).fetchone()
        if row is None:
            raise MemoryError("memory candidate not found")
        value = self._open(row)
        value["status"] = "approved"
        value["last_confirmed_at"] = time.time()
        conflicts = self.conflicts_for(value, workspace=workspace, agent_id=agent_id)
        if resolution not in {"keep_both", "replace"}:
            raise MemoryError("memory conflict resolution must be keep_both or replace")
        result = self.save(
            value, memory_id, workspace=workspace, agent_id=agent_id,
            default_status="approved",
        )
        if resolution == "replace" and conflicts:
            conflict_ids = [str(item["id"]) for item in conflicts]
            result = self.save(
                {**result, "supersedes": conflict_ids},
                memory_id,
                workspace=workspace,
                agent_id=agent_id,
                default_status="approved",
            )
            with self._connect() as connection:
                connection.executemany(
                    "UPDATE memories SET stale=1, superseded_by=? WHERE id=?",
                    ((memory_id, identifier) for identifier in conflict_ids),
                )
            result["supersedes"] = conflict_ids
            result["conflicts"] = []
        else:
            result["conflicts"] = conflicts
        return result

    def expire_candidates(self, *, workspace: str = "", agent_id: str = "") -> int:
        now = time.time()
        with self._connect() as connection:
            identifiers = [str(row[0]) for row in connection.execute(
                "SELECT id FROM memories WHERE status='candidate' AND expires_at < ?",
                (now,),
            ).fetchall()]
            count = connection.execute(
                "DELETE FROM memories WHERE status='candidate' AND expires_at < ?",
                (now,),
            ).rowcount
        for identifier in identifiers:
            self.record_event(
                "expiration", "expired", workspace=workspace, agent_id=agent_id,
                memory_id=identifier,
            )
        return count

    def list(
        self,
        *,
        workspace: str = "",
        agent_id: str = "",
        status: str = "",
        scopes: list[str] | tuple[str, ...] | None = None,
    ) -> list[dict[str, Any]]:
        self.expire_candidates(workspace=workspace, agent_id=agent_id)
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
        values = [self._open(row) for row in rows]
        if status == "candidate":
            for value in values:
                value["conflicts"] = self.conflicts_for(
                    value, workspace=workspace, agent_id=agent_id
                )
        return values

    @staticmethod
    def _topic_tokens(memory: dict[str, Any]) -> set[str]:
        text = " ".join((memory.get("title") or "", " ".join(memory.get("tags") or [])))
        return {
            token for token in re.findall(r"[a-z0-9_.-]+", text.lower())
            if len(token) > 2
        }

    def conflicts_for(
        self,
        memory: dict[str, Any],
        *,
        workspace: str = "",
        agent_id: str = "",
    ) -> list[dict[str, Any]]:
        """Return current memories about the same topic with different content."""
        topic = self._topic_tokens(memory)
        if not topic:
            return []
        normalized = re.sub(r"\s+", " ", str(memory.get("content") or "").strip().lower())
        conflicts: list[dict[str, Any]] = []
        for candidate in self.list(
            workspace=workspace,
            agent_id=agent_id,
            status="approved",
            scopes=[str(memory.get("scope") or "workspace")],
        ):
            if candidate["id"] == memory.get("id") or candidate.get("stale"):
                continue
            candidate_topic = self._topic_tokens(candidate)
            overlap = len(topic & candidate_topic) / max(min(len(topic), len(candidate_topic)), 1)
            other = re.sub(r"\s+", " ", candidate["content"].strip().lower())
            if overlap >= 0.5 and normalized != other:
                conflicts.append({
                    "id": candidate["id"],
                    "title": candidate["title"],
                    "content": candidate["content"],
                    "kind": candidate.get("kind", "fact"),
                    "confidence": candidate.get("confidence", 1.0),
                })
        return conflicts[:12]

    def _store_embedding(
        self, row: sqlite3.Row, payload: dict[str, Any], model: str, vector: list[float]
    ) -> None:
        """Reseal a vector without presenting indexing as a user edit."""
        payload = dict(payload)
        payload["embedding"] = [float(value) for value in vector]
        payload["embedding_model"] = model[:256]
        nonce, ciphertext = self._seal(
            payload,
            identifier=row["id"], status=row["status"], scope=row["scope"],
            target_hash=row["target_hash"], revision=int(row["revision"]),
        )
        # Do not let a slow embedding response overwrite a memory edited while
        # the vector was being calculated. Matching both the revision and the
        # authenticated ciphertext makes this a compare-and-swap update.
        with self._lock, self._connect() as connection:
            connection.execute(
                """UPDATE memories SET nonce=?, ciphertext=?
                WHERE id=? AND revision=? AND nonce=? AND ciphertext=?""",
                (
                    nonce, ciphertext, row["id"], int(row["revision"]),
                    row["nonce"], row["ciphertext"],
                ),
            )

    def search(
        self,
        query: str,
        *,
        workspace: str = "",
        agent_id: str = "",
        scopes: list[str] | tuple[str, ...] | None = None,
        limit: int = 8,
        approved_only: bool = True,
        embedding_model: str = "",
        ollama_host: str = "http://127.0.0.1:11434",
    ) -> list[dict[str, Any]]:
        value = query.strip().lower()[:2_000]
        if not value:
            raise MemoryError("memory search requires a query")
        terms = [term for term in re.findall(r"[\w.-]+", value) if len(term) > 1][:24]
        candidates = self.list(
            workspace=workspace, agent_id=agent_id,
            status="approved" if approved_only else "", scopes=scopes,
        )
        semantic: dict[str, float] = {}
        model = embedding_model.strip()[:256]
        if model and candidates:
            try:
                from .knowledge import cosine_similarity, embed_texts

                with self._connect() as connection:
                    placeholders = ",".join("?" for _ in candidates)
                    rows = {
                        str(row["id"]): row for row in connection.execute(
                            f"SELECT * FROM memories WHERE id IN ({placeholders})",
                            [item["id"] for item in candidates],
                        ).fetchall()
                    }
                missing = []
                payloads: dict[str, dict[str, Any]] = {}
                for item in candidates:
                    payload = self._open_payload(rows[item["id"]])
                    payloads[item["id"]] = payload
                    if payload.get("embedding_model") != model or not payload.get("embedding"):
                        missing.append(item)
                inputs = [value] + [
                    f"{item['title']}\n{item['content']}\n{' '.join(item['tags'])}"
                    for item in missing
                ]
                vectors = embed_texts(model, ollama_host, inputs)
                query_vector = vectors[0]
                for item, vector in zip(missing, vectors[1:], strict=True):
                    row = rows[item["id"]]
                    payload = payloads[item["id"]]
                    self._store_embedding(row, payload, model, vector)
                    payloads[item["id"]] = {**payload, "embedding": vector, "embedding_model": model}
                for item in candidates:
                    vector = payloads[item["id"]].get("embedding") or []
                    if len(vector) == len(query_vector):
                        semantic[item["id"]] = max(cosine_similarity(query_vector, vector), 0.0)
            except Exception:  # semantic recall is optional; lexical recall remains available
                semantic = {}

        ranked: list[tuple[float, dict[str, Any]]] = []
        now = time.time()
        for memory in candidates:
            haystack = " ".join((
                memory["title"], memory["content"], " ".join(memory["tags"])
            )).lower()
            phrase = 4.0 if value in haystack else 0.0
            matches = sum(haystack.count(term) for term in terms)
            semantic_score = semantic.get(memory["id"], 0.0)
            if not phrase and not matches and semantic_score < 0.2:
                continue
            age_days = max((now - memory["updated_at"]) / 86_400, 0)
            confidence = float(memory.get("confidence", 1.0))
            score = (
                phrase + min(matches, 8) * 0.8 + semantic_score * 5.0
                + (2.0 if memory["pinned"] else 0)
                + confidence + 1 / (1 + age_days / 30)
            )
            valid_from = memory.get("valid_from")
            valid_until = memory.get("valid_until")
            if valid_from is not None and float(valid_from) > now:
                continue
            if valid_until is not None and float(valid_until) < now:
                score *= 0.15
            if memory["stale"]:
                score *= 0.4
            reasons: list[str] = []
            if phrase:
                reasons.append("exact phrase")
            elif matches:
                reasons.append(f"{matches} matching term{'s' if matches != 1 else ''}")
            if semantic_score:
                reasons.append(f"semantic similarity {semantic_score:.0%}")
            if memory["pinned"]:
                reasons.append("pinned")
            reasons.append(f"{confidence:.0%} confidence")
            ranked.append((score, {**memory, "retrieval_reason": ", ".join(reasons)}))
        ranked.sort(key=lambda item: (-item[0], item[1]["id"]))
        selected = [{**memory, "score": score} for score, memory in ranked[:min(max(limit, 1), 20)]]
        if selected:
            with self._connect() as connection:
                connection.executemany(
                    "UPDATE memories SET last_used_at=?, use_count=use_count+1 WHERE id=?",
                    ((now, item["id"]) for item in selected),
                )
        return selected

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

    def feedback(self, memory_id: str, outcome: str) -> dict[str, Any]:
        """Record a small user-controlled quality signal inside ciphertext."""
        if outcome not in {"helpful", "ignored", "incorrect"}:
            raise MemoryError("memory feedback must be helpful, ignored, or incorrect")
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM memories WHERE id=?", (memory_id,)
            ).fetchone()
            if row is None:
                raise MemoryError("memory not found")
            payload = self._open_payload(row)
            feedback = payload.get("feedback")
            feedback = dict(feedback) if isinstance(feedback, dict) else {}
            feedback[outcome] = int(feedback.get(outcome) or 0) + 1
            payload["feedback"] = feedback
            nonce, ciphertext = self._seal(
                payload, identifier=row["id"], status=row["status"],
                scope=row["scope"], target_hash=row["target_hash"],
                revision=int(row["revision"]),
            )
            stale = 1 if outcome == "incorrect" else int(row["stale"])
            connection.execute(
                "UPDATE memories SET nonce=?, ciphertext=?, stale=? WHERE id=?",
                (nonce, ciphertext, stale, memory_id),
            )
            updated = connection.execute(
                "SELECT * FROM memories WHERE id=?", (memory_id,)
            ).fetchone()
        return self._open(updated)

    def record_event(
        self, stage: str, outcome: str, *, workspace: str = "", agent_id: str = "",
        session_id: str = "", run_id: str = "", reason_code: str = "",
        memory_id: str = "",
    ) -> None:
        """Persist bounded, content-free memory pipeline diagnostics."""
        workspace_hash = hashlib.sha256(workspace.encode()).hexdigest() if workspace else ""
        agent_hash = hashlib.sha256(agent_id.encode()).hexdigest() if agent_id else ""
        now = time.time()
        with self._lock, self._connect() as connection:
            connection.execute(
                """INSERT INTO memory_events(
                    workspace_hash, agent_hash, session_id, run_id, stage, outcome,
                    reason_code, memory_id, occurred_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    workspace_hash, agent_hash, session_id[:160] or None, run_id[:160] or None,
                    stage[:64], outcome[:64], reason_code[:128], memory_id[:128] or None, now,
                ),
            )
            cutoff = now - 90 * 24 * 60 * 60
            connection.execute("DELETE FROM memory_events WHERE occurred_at < ?", (cutoff,))
            connection.execute(
                """DELETE FROM memory_events WHERE id IN (
                    SELECT id FROM memory_events
                    WHERE workspace_hash=? AND agent_hash=?
                    ORDER BY occurred_at DESC LIMIT -1 OFFSET 5000
                )""",
                (workspace_hash, agent_hash),
            )

    def diagnostics(self, *, workspace: str = "", agent_id: str = "") -> dict[str, Any]:
        workspace_hash = hashlib.sha256(workspace.encode()).hexdigest() if workspace else ""
        agent_hash = hashlib.sha256(agent_id.encode()).hexdigest() if agent_id else ""
        with self._connect() as connection:
            rows = connection.execute(
                """SELECT session_id, run_id, stage, outcome, reason_code, memory_id, occurred_at
                   FROM memory_events WHERE workspace_hash=? AND agent_hash=?
                   ORDER BY occurred_at DESC LIMIT 100""",
                (workspace_hash, agent_hash),
            ).fetchall()
        events = [dict(row) for row in rows]
        counts: dict[str, int] = {}
        for event in events:
            key = f"{event['stage']}:{event['outcome']}"
            counts[key] = counts.get(key, 0) + 1
        status = self.status(workspace=workspace, agent_id=agent_id)
        last_proposal = next(
            (event for event in events if event["stage"] == "proposal"), None
        )
        last_approval = next(
            (event for event in events if event["stage"] == "approval"
             and event["outcome"] == "accepted"), None
        )
        return {
            **status,
            "events": events,
            "counts": counts,
            "last_proposal": last_proposal,
            "last_approval": last_approval,
            "history_available": bool(events),
        }

    def maintain(self, *, workspace: str = "", agent_id: str = "") -> dict[str, Any]:
        """Mark expired facts stale and summarize items needing human review."""
        now = time.time()
        items = self.list(workspace=workspace, agent_id=agent_id)
        expired_ids = [
            item["id"] for item in items
            if item.get("valid_until") is not None
            and float(item["valid_until"]) < now
            and not item["stale"]
        ]
        if expired_ids:
            with self._connect() as connection:
                connection.executemany(
                    "UPDATE memories SET stale=1 WHERE id=?",
                    ((identifier,) for identifier in expired_ids),
                )
            for identifier in expired_ids:
                self.record_event(
                    "expiration", "expired", workspace=workspace, agent_id=agent_id,
                    memory_id=identifier,
                )
        conflicts = {
            item["id"]: self.conflicts_for(
                item, workspace=workspace, agent_id=agent_id
            )
            for item in items if item["status"] == "approved" and not item["stale"]
        }
        conflicts = {key: value for key, value in conflicts.items() if value}
        return {
            "ok": True,
            "expired_marked_stale": len(expired_ids),
            "conflict_count": sum(len(value) for value in conflicts.values()) // 2,
            "conflicts": conflicts,
        }

    def status(self, *, workspace: str = "", agent_id: str = "") -> dict[str, Any]:
        items = self.list(workspace=workspace, agent_id=agent_id)
        now = time.time()
        conflict_ids = {
            item["id"] for item in items
            if item["status"] == "approved" and self.conflicts_for(
                item, workspace=workspace, agent_id=agent_id
            )
        }
        return {
            "encrypted": True,
            "cipher": "AES-256-GCM",
            "approved_count": sum(item["status"] == "approved" for item in items),
            "candidate_count": sum(item["status"] == "candidate" for item in items),
            "candidate_ttl_days": 30,
            "stale_count": sum(bool(item["stale"]) for item in items),
            "expired_count": sum(
                item.get("valid_until") is not None
                and float(item["valid_until"]) < now for item in items
            ),
            "conflict_count": len(conflict_ids),
            "semantic_encrypted": True,
            "memory_version": 2,
        }

    def export(self, *, workspace: str = "", agent_id: str = "") -> dict[str, Any]:
        return {
            "format": "locus-memory-export",
            "version": 2,
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
        if document.get("format") != "locus-memory-export" or document.get("version") not in {1, 2}:
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
        reason = str(item.get("retrieval_reason") or "matched the request")
        lines.append(
            f"\n## {item['title']} [{item.get('kind', 'fact')} · {item['scope']}{stale}]"
            f"\nWhy recalled: {reason}\n{item['content']}"
        )
    return "\n".join(lines)[:30_000]


__all__ = [
    "MemoryError", "MemoryVault", "format_memory_results", "memory_database",
]
