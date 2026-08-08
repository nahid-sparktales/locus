"""Durable, ordered orchestration history for Locus.

The chat transcript remains append-only JSONL.  This store is deliberately a
separate, queryable ledger for team runs, checkpoints, attempts, evaluation
results, and routing observations.  Every event is sanitized before it crosses
the persistence boundary and receives its sequence number in the same SQLite
transaction that records it.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from . import paths

SCHEMA_VERSION = 3
DEFAULT_RETENTION_DAYS = 90
DEFAULT_MAX_BYTES = 2 * 1024 * 1024 * 1024
MAX_EVENT_JSON_BYTES = 512 * 1024
MAX_EXPORT_EVENTS = 50_000

TERMINAL_STATES = {"completed", "failed", "interrupted", "cancelled", "discarded"}
RECOVERABLE_STATES = {
    "paused", "interrupted", "waiting_dispatch_approval",
}

# These states have a live owner.  A stale recovery bit from plan approval or
# an earlier checkpoint must never survive once execution is moving again.
ACTIVE_NONRECOVERABLE_STATES = {
    "queued", "dispatching", "running", "reviewing", "pausing",
    "waiting_permission", "waiting_computer",
}

_SECRET_KEY = re.compile(
    r"(?:api[_-]?key|authorization|cookie|credential|password|secret|signature|token)$",
    re.IGNORECASE,
)
_SAFE_TOKEN_KEYS = {
    "prompt_tokens", "completion_tokens", "metered_tokens", "max_metered_tokens",
    "token_limit", "tokens", "approx_tokens",
}
_SENSITIVE_TEXT = (
    re.compile(r"(?im)(authorization\s*:\s*)[^\r\n]+"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(
        r"(?i)(\b(?:api[_-]?key|password|client[_-]?secret)\b\s*[:=]\s*)"
        r"(?:['\"][^'\"\r\n]+['\"]|[^\s,;}]+)"
    ),
)


class RunStoreError(RuntimeError):
    pass


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)


def sanitize_event(value: Any, *, include_content: bool = True, depth: int = 0) -> Any:
    """Return a bounded JSON value with credential-shaped fields removed."""
    if depth > 12:
        return "[truncated]"
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for raw_key, item in list(value.items())[:256]:
            key = str(raw_key)[:128]
            if _SECRET_KEY.search(key) and key.lower() not in _SAFE_TOKEN_KEYS:
                result[key] = "[redacted]"
                continue
            if not include_content and key.lower() in {
                "content", "output", "reasoning", "reasoning_text", "result",
                "arguments", "prompt", "goal", "detail", "preview", "text",
            }:
                result[key] = "[content omitted]"
                continue
            result[key] = sanitize_event(item, include_content=include_content, depth=depth + 1)
        return result
    if isinstance(value, (list, tuple)):
        return [sanitize_event(item, include_content=include_content, depth=depth + 1)
                for item in list(value)[:512]]
    if isinstance(value, str):
        text = value[:240_000]
        text = _SENSITIVE_TEXT[0].sub(r"\1[redacted]", text)
        text = _SENSITIVE_TEXT[1].sub("Bearer [redacted]", text)
        text = _SENSITIVE_TEXT[2].sub(r"\1[redacted]", text)
        return text
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)[:4_000]


def _alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


class RunStore:
    """Thread-safe SQLite facade shared by the control and worker services."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (paths.APP_DIR / "agent-runs.sqlite3")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.path.parent.chmod(0o700)
        except OSError:
            pass
        self._lock = threading.RLock()
        self.read_only = False
        try:
            self._initialize()
        except (OSError, sqlite3.DatabaseError) as exc:
            # A migration failure must not destroy history.  Reopen read-only
            # when possible and let the UI explain why new details are absent.
            self.read_only = True
            if not self.path.exists():
                raise RunStoreError(f"could not create the run database: {exc}") from exc
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    def _connect(self, *, readonly: bool = False) -> sqlite3.Connection:
        if readonly or self.read_only:
            uri = f"file:{self.path}?mode=ro"
            connection = sqlite3.connect(uri, uri=True, timeout=5)
        else:
            connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=5000")
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.executescript(
                """
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS schema_meta (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    version INTEGER NOT NULL
                );
                INSERT OR IGNORE INTO schema_meta(singleton, version) VALUES(1, 0);

                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY,
                    session_id TEXT,
                    team_id TEXT,
                    team_name TEXT,
                    worker_id TEXT,
                    owner_pid INTEGER NOT NULL DEFAULT 0,
                    workspace_root TEXT,
                    execution_path TEXT,
                    task_id TEXT,
                    state TEXT NOT NULL,
                    request TEXT NOT NULL DEFAULT '',
                    manifest_json TEXT NOT NULL DEFAULT '{}',
                    plan_json TEXT,
                    usage_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    last_seq INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    legacy INTEGER NOT NULL DEFAULT 0,
                    recoverable INTEGER NOT NULL DEFAULT 0,
                    recovery_reason TEXT
                );
                CREATE INDEX IF NOT EXISTS runs_session_idx ON runs(session_id, updated_at DESC);
                CREATE INDEX IF NOT EXISTS runs_state_idx ON runs(state, updated_at DESC);

                CREATE TABLE IF NOT EXISTS run_events (
                    event_id TEXT PRIMARY KEY,
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    occurred_at REAL NOT NULL,
                    type TEXT NOT NULL,
                    job_id TEXT,
                    attempt_id TEXT,
                    schema_version INTEGER NOT NULL,
                    payload_json TEXT NOT NULL,
                    UNIQUE(run_id, seq)
                );
                CREATE INDEX IF NOT EXISTS run_events_run_idx ON run_events(run_id, seq);

                CREATE TABLE IF NOT EXISTS job_attempts (
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    job_id TEXT NOT NULL,
                    attempt INTEGER NOT NULL,
                    attempt_id TEXT NOT NULL UNIQUE,
                    agent_id TEXT,
                    agent_name TEXT,
                    role TEXT,
                    state TEXT NOT NULL,
                    goal TEXT NOT NULL DEFAULT '',
                    result_json TEXT,
                    started_at REAL,
                    completed_at REAL,
                    PRIMARY KEY(run_id, job_id, attempt)
                );

                CREATE TABLE IF NOT EXISTS checkpoints (
                    id TEXT PRIMARY KEY,
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    state_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS checkpoints_run_idx ON checkpoints(run_id, seq DESC);

                CREATE TABLE IF NOT EXISTS routing_samples (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id TEXT NOT NULL,
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    quality REAL,
                    reliable INTEGER NOT NULL,
                    latency_ms INTEGER NOT NULL,
                    estimated_cost REAL NOT NULL DEFAULT 0,
                    local INTEGER NOT NULL DEFAULT 0,
                    evaluation INTEGER NOT NULL DEFAULT 0,
                    occurred_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS routing_agent_idx
                    ON routing_samples(agent_id, occurred_at DESC);

                CREATE TABLE IF NOT EXISTS evaluation_suites (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    workspace_root TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS evaluation_results (
                    id TEXT PRIMARY KEY,
                    suite_id TEXT NOT NULL REFERENCES evaluation_suites(id) ON DELETE CASCADE,
                    case_id TEXT NOT NULL,
                    run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    state TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    completed_at REAL
                );

                CREATE TABLE IF NOT EXISTS mcp_tasks (
                    id TEXT PRIMARY KEY,
                    server_id TEXT NOT NULL,
                    run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    job_id TEXT,
                    tool_call_id TEXT,
                    tool_name TEXT NOT NULL,
                    state TEXT NOT NULL,
                    status_message TEXT,
                    payload_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL
                );
                CREATE INDEX IF NOT EXISTS mcp_tasks_origin_idx
                    ON mcp_tasks(run_id, job_id, updated_at DESC);

                UPDATE schema_meta SET version = 2 WHERE singleton = 1 AND version < 2;
                COMMIT;
                """
            )
            version = int(connection.execute(
                "SELECT version FROM schema_meta WHERE singleton=1"
            ).fetchone()[0])
            if version < 3:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute("ALTER TABLE job_attempts ADD COLUMN provider TEXT")
                connection.execute("ALTER TABLE job_attempts ADD COLUMN model TEXT")
                connection.execute("UPDATE schema_meta SET version=3 WHERE singleton=1")
                connection.commit()

    def upsert_mcp_task(
        self,
        task_id: str,
        *,
        server_id: str,
        tool_name: str,
        state: str,
        run_id: str = "",
        job_id: str = "",
        tool_call_id: str = "",
        status_message: str = "",
        payload: dict[str, Any] | None = None,
    ) -> None:
        if self.read_only:
            return
        now = time.time()
        terminal = state in {"completed", "failed", "cancelled"}
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO mcp_tasks(
                    id, server_id, run_id, job_id, tool_call_id, tool_name,
                    state, status_message, payload_json, created_at, updated_at,
                    completed_at
                ) VALUES(?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state=excluded.state,
                    status_message=excluded.status_message,
                    payload_json=excluded.payload_json,
                    updated_at=excluded.updated_at,
                    completed_at=excluded.completed_at
                """,
                (
                    task_id, server_id, run_id, job_id, tool_call_id, tool_name,
                    state, status_message[:4_000], _json(sanitize_event(payload or {})),
                    now, now, now if terminal else None,
                ),
            )

    def mcp_tasks(self, *, run_id: str = "", nonterminal: bool = False) -> list[dict[str, Any]]:
        clauses: list[str] = []
        values: list[Any] = []
        if run_id:
            clauses.append("run_id = ?")
            values.append(run_id)
        if nonterminal:
            clauses.append("state IN ('working', 'input_required')")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._lock, self._connect(readonly=self.read_only) as connection:
            rows = connection.execute(
                f"SELECT * FROM mcp_tasks {where} ORDER BY updated_at DESC LIMIT 1000",  # noqa: S608
                values,
            ).fetchall()
        return [
            {**dict(row), "payload": json.loads(row["payload_json"] or "{}")}
            for row in rows
        ]

    def mcp_task(self, task_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=self.read_only) as connection:
            row = connection.execute(
                "SELECT * FROM mcp_tasks WHERE id=?", (task_id,)
            ).fetchone()
        if row is None:
            return None
        return {**dict(row), "payload": json.loads(row["payload_json"] or "{}")}

    def start_run(
        self,
        run_id: str,
        *,
        session_id: str = "",
        team_id: str = "",
        team_name: str = "",
        worker_id: str = "",
        workspace_root: str = "",
        execution_path: str = "",
        task_id: str = "",
        request: str = "",
        manifest: dict[str, Any] | None = None,
        state: str = "queued",
    ) -> None:
        if self.read_only:
            return
        now = time.time()
        safe_manifest = sanitize_event(manifest or {})
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO runs(
                    id, session_id, team_id, team_name, worker_id, owner_pid,
                    workspace_root, execution_path, task_id, state, request,
                    manifest_json, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    session_id=COALESCE(NULLIF(excluded.session_id, ''), runs.session_id),
                    team_id=COALESCE(NULLIF(excluded.team_id, ''), runs.team_id),
                    team_name=COALESCE(NULLIF(excluded.team_name, ''), runs.team_name),
                    worker_id=COALESCE(NULLIF(excluded.worker_id, ''), runs.worker_id),
                    owner_pid=excluded.owner_pid,
                    workspace_root=COALESCE(NULLIF(excluded.workspace_root, ''), runs.workspace_root),
                    execution_path=COALESCE(NULLIF(excluded.execution_path, ''), runs.execution_path),
                    task_id=COALESCE(NULLIF(excluded.task_id, ''), runs.task_id),
                    request=COALESCE(NULLIF(excluded.request, ''), runs.request),
                    manifest_json=CASE WHEN excluded.manifest_json='{}'
                        THEN runs.manifest_json ELSE excluded.manifest_json END,
                    state=excluded.state, updated_at=excluded.updated_at,
                    recoverable=0, recovery_reason=NULL
                """,
                (
                    run_id, session_id, team_id, team_name, worker_id, os.getpid(),
                    workspace_root, execution_path, task_id, state, request[:240_000],
                    _json(safe_manifest), now, now,
                ),
            )

    def import_legacy_snapshot(
        self,
        session_id: str,
        snapshot: dict[str, Any],
        *,
        workspace_root: str = "",
    ) -> dict[str, Any] | None:
        """Import an old JSONL final-state summary without inventing a replay log."""
        if self.read_only:
            return None
        source_run_id = str(snapshot.get("run_id") or "")
        activities = snapshot.get("activities")
        if not source_run_id or not isinstance(activities, list):
            return None
        existing = self.run(source_run_id)
        if existing is not None:
            return existing
        state = str(snapshot.get("orchestration_state") or "interrupted")
        if state not in TERMINAL_STATES:
            state = "interrupted"
        now = time.time()
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """INSERT OR IGNORE INTO runs(
                    id, session_id, worker_id, workspace_root, state, created_at,
                    updated_at, completed_at, legacy, recoverable, recovery_reason
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?)""",
                (
                    source_run_id, session_id, str(snapshot.get("worker_id") or ""),
                    workspace_root, state, now, now, now,
                    "Imported from a legacy final-state snapshot; ordered replay is unavailable.",
                ),
            )
            for index, raw in enumerate(activities[:1_000], 1):
                if not isinstance(raw, dict):
                    continue
                value = sanitize_event(raw)
                job_id = str(value.get("id") or f"legacy-{index}")[:128]
                attempt_id = f"legacy:{source_run_id}:{job_id}:1"
                connection.execute(
                    """INSERT OR IGNORE INTO job_attempts(
                        run_id, job_id, attempt, attempt_id, agent_name, role,
                        state, goal, result_json, started_at, completed_at
                    ) VALUES(?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        source_run_id, job_id, attempt_id,
                        str(value.get("agent_name") or "Agent"),
                        str(value.get("role") or "generalist"),
                        str(value.get("state") or "completed"),
                        str(value.get("goal") or "")[:120_000], _json(value), now, now,
                    ),
                )
            connection.commit()
        return self.run(source_run_id)

    def append_event(self, run_id: str, event: dict[str, Any]) -> dict[str, Any]:
        """Persist, number, and return one public event envelope."""
        safe = sanitize_event(event)
        if not isinstance(safe, dict):
            safe = {"type": "unknown"}
        event_type = str(safe.get("type") or "unknown")[:128]
        now = time.time()
        event_id = str(safe.get("event_id") or uuid.uuid4().hex)
        if self.read_only:
            return {
                **safe, "event_id": event_id, "seq": int(safe.get("seq") or 0),
                "occurred_at": now, "schema_version": SCHEMA_VERSION,
            }
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT last_seq FROM runs WHERE id = ?", (run_id,)).fetchone()
            if row is None:
                connection.execute(
                    """INSERT INTO runs(
                        id, owner_pid, state, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?)""",
                    (run_id, os.getpid(), str(safe.get("state") or "running"), now, now),
                )
                row = connection.execute("SELECT last_seq FROM runs WHERE id = ?", (run_id,)).fetchone()
            seq = int(row[0]) + 1
            safe.update({
                "event_id": event_id,
                "seq": seq,
                "occurred_at": now,
                "schema_version": SCHEMA_VERSION,
            })
            self._update_attempt(connection, run_id, safe, now)
            encoded = _json(safe)
            if len(encoded.encode("utf-8")) > MAX_EVENT_JSON_BYTES:
                safe = sanitize_event(safe, include_content=False)
                safe["content_truncated"] = True
                encoded = _json(safe)
            job_id = str(safe.get("job_id") or "") or None
            attempt_id = str(safe.get("attempt_id") or "") or None
            connection.execute(
                """INSERT INTO run_events(
                    event_id, run_id, seq, occurred_at, type, job_id, attempt_id,
                    schema_version, payload_json
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (event_id, run_id, seq, now, event_type, job_id, attempt_id,
                 SCHEMA_VERSION, encoded),
            )
            state = str(safe.get("state") or "")
            updates = ["last_seq = ?", "updated_at = ?", "owner_pid = ?"]
            values: list[Any] = [seq, now, os.getpid()]
            if event_type == "dispatch_plan":
                updates.append("plan_json = ?")
                values.append(_json(safe.get("plan") or {}))
            if event_type in {"orchestration_started", "orchestration_state",
                              "orchestration_completed", "orchestration_paused"} and state:
                updates.append("state = ?")
                values.append(state)
                if state in TERMINAL_STATES:
                    updates.extend([
                        "completed_at = ?", "recoverable = 0", "recovery_reason = NULL",
                    ])
                    values.append(now)
                elif state in ACTIVE_NONRECOVERABLE_STATES:
                    updates.extend(["recoverable = 0", "recovery_reason = NULL"])
            elif event_type in {"permission_request", "computer_action_request"}:
                # These waits still have a live worker.  They must clear a
                # stale approval/checkpoint recovery bit even though their
                # durable event does not replace the orchestration state.
                updates.extend(["recoverable = 0", "recovery_reason = NULL"])
            if isinstance(safe.get("usage"), dict):
                updates.append("usage_json = ?")
                values.append(_json(safe["usage"]))
            values.append(run_id)
            connection.execute(f"UPDATE runs SET {', '.join(updates)} WHERE id = ?", values)
            connection.commit()
        return safe

    def _update_attempt(
        self, connection: sqlite3.Connection, run_id: str, event: dict[str, Any], now: float
    ) -> None:
        event_type = str(event.get("type") or "")
        if event_type == "agent_job_started":
            job_id = str(event.get("job_id") or "")
            if not job_id:
                return
            attempt = int(connection.execute(
                "SELECT COALESCE(MAX(attempt), 0) + 1 FROM job_attempts WHERE run_id=? AND job_id=?",
                (run_id, job_id),
            ).fetchone()[0])
            # ``attempt_id`` is globally unique in the schema, while job IDs
            # such as ``writer`` are intentionally reused by every team run.
            # Include the run boundary so the second team run cannot collide
            # with the first run's ``writer:1`` record.
            attempt_id = str(
                event.get("attempt_id") or f"{run_id}:{job_id}:{attempt}"
            )
            event["attempt_id"] = attempt_id
            event["attempt"] = attempt
            connection.execute(
                """INSERT INTO job_attempts(
                    run_id, job_id, attempt, attempt_id, agent_id, agent_name,
                    role, provider, model, state, goal, started_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    run_id, job_id, attempt, attempt_id, str(event.get("agent_id") or ""),
                    str(event.get("agent_name") or ""), str(event.get("role") or ""),
                    str(event.get("provider") or ""), str(event.get("model") or ""),
                    str(event.get("state") or "running"), str(event.get("goal") or "")[:120_000],
                    now,
                ),
            )
        elif event_type in {"agent_job_completed", "agent_job_incomplete"}:
            result = event.get("result") if isinstance(event.get("result"), dict) else {}
            job_id = str(result.get("job_id") or event.get("job_id") or "")
            if not job_id:
                return
            row = connection.execute(
                """SELECT attempt, attempt_id FROM job_attempts
                   WHERE run_id=? AND job_id=? ORDER BY attempt DESC LIMIT 1""",
                (run_id, job_id),
            ).fetchone()
            if row is None:
                attempt, attempt_id = 1, f"{run_id}:{job_id}:1"
                connection.execute(
                    """INSERT INTO job_attempts(
                        run_id, job_id, attempt, attempt_id, agent_id, agent_name,
                        role, state, goal, started_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, 'running', '', ?)""",
                    (run_id, job_id, attempt, attempt_id, str(result.get("agent_id") or ""),
                     str(result.get("agent_name") or ""), str(result.get("role") or ""), now),
                )
            else:
                attempt, attempt_id = int(row[0]), str(row[1])
            event["attempt"] = attempt
            event["attempt_id"] = attempt_id
            connection.execute(
                """UPDATE job_attempts SET state=?, result_json=?, completed_at=?
                   WHERE run_id=? AND job_id=? AND attempt=?""",
                (str(event.get("state") or (
                    "paused" if event_type == "agent_job_incomplete" else "completed"
                )), _json(result),
                 now if event_type == "agent_job_completed" else None,
                 run_id, job_id, attempt),
            )

    def checkpoint(self, run_id: str, kind: str, state: dict[str, Any]) -> dict[str, Any]:
        safe = sanitize_event(state)
        now = time.time()
        checkpoint_id = uuid.uuid4().hex
        if self.read_only:
            return {"id": checkpoint_id, "run_id": run_id, "seq": 0,
                    "kind": kind, "state": safe, "created_at": now}
        with self._lock, self._connect() as connection:
            row = connection.execute("SELECT last_seq FROM runs WHERE id=?", (run_id,)).fetchone()
            if row is None:
                raise RunStoreError(f"run not found: {run_id}")
            seq = int(row[0])
            connection.execute(
                "INSERT INTO checkpoints(id, run_id, seq, kind, state_json, created_at) VALUES(?, ?, ?, ?, ?, ?)",
                (checkpoint_id, run_id, seq, kind[:64], _json(safe), now),
            )
        return {"id": checkpoint_id, "run_id": run_id, "seq": seq,
                "kind": kind, "state": safe, "created_at": now}

    def latest_checkpoint(self, run_id: str) -> dict[str, Any] | None:
        with self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT * FROM checkpoints WHERE run_id=? ORDER BY seq DESC, created_at DESC LIMIT 1",
                (run_id,),
            ).fetchone()
        if row is None:
            return None
        return {"id": row["id"], "run_id": row["run_id"], "seq": row["seq"],
                "kind": row["kind"], "state": json.loads(row["state_json"]),
                "created_at": row["created_at"]}

    def events(self, run_id: str, after_seq: int = 0, limit: int = 5_000) -> list[dict[str, Any]]:
        limit = min(max(int(limit), 1), 10_000)
        with self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT payload_json FROM run_events WHERE run_id=? AND seq>? ORDER BY seq LIMIT ?",
                (run_id, max(int(after_seq), 0), limit),
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def attempts(self, run_id: str) -> list[dict[str, Any]]:
        with self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT * FROM job_attempts WHERE run_id=? ORDER BY started_at, job_id, attempt",
                (run_id,),
            ).fetchall()
        return [{
            "run_id": row["run_id"], "job_id": row["job_id"], "attempt": row["attempt"],
            "attempt_id": row["attempt_id"], "agent_id": row["agent_id"],
            "agent_name": row["agent_name"], "role": row["role"], "state": row["state"],
            "provider": row["provider"], "model": row["model"],
            "goal": row["goal"],
            "result": json.loads(row["result_json"]) if row["result_json"] else None,
            "started_at": row["started_at"], "completed_at": row["completed_at"],
        } for row in rows]

    def run(self, run_id: str, *, include_events: bool = False) -> dict[str, Any] | None:
        with self._connect(readonly=True) as connection:
            row = connection.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
        if row is None:
            return None
        value = self._run_row(row)
        value["checkpoint"] = self.latest_checkpoint(run_id)
        value["attempts"] = self.attempts(run_id)
        value.update(self._job_summary(value["attempts"]))
        if include_events:
            value["events"] = self.events(run_id, limit=MAX_EXPORT_EVENTS)
        return value

    def list_runs(self, *, session_id: str = "", limit: int = 100) -> list[dict[str, Any]]:
        limit = min(max(int(limit), 1), 500)
        summary_query = """
            SELECT runs.*,
              (SELECT COUNT(DISTINCT attempts.job_id)
                 FROM job_attempts AS attempts
                WHERE attempts.run_id=runs.id) AS job_count,
              (SELECT COUNT(*)
                 FROM job_attempts AS latest
                WHERE latest.run_id=runs.id
                  AND latest.state='completed'
                  AND latest.attempt=(
                    SELECT MAX(candidate.attempt)
                      FROM job_attempts AS candidate
                     WHERE candidate.run_id=latest.run_id
                       AND candidate.job_id=latest.job_id
                  )) AS completed_job_count
              FROM runs
        """
        with self._connect(readonly=True) as connection:
            if session_id:
                rows = connection.execute(
                    summary_query + " WHERE session_id=? ORDER BY updated_at DESC LIMIT ?",
                    (session_id, limit),
                ).fetchall()
            else:
                rows = connection.execute(
                    summary_query + " ORDER BY updated_at DESC LIMIT ?", (limit,)
                ).fetchall()
        return [{
            **self._run_row(row),
            "job_count": int(row["job_count"] or 0),
            "completed_job_count": int(row["completed_job_count"] or 0),
        } for row in rows]

    @staticmethod
    def _job_summary(attempts: list[dict[str, Any]]) -> dict[str, int]:
        latest: dict[str, dict[str, Any]] = {}
        for attempt in attempts:
            job_id = str(attempt.get("job_id") or "")
            if job_id:
                latest[job_id] = attempt
        return {
            "job_count": len(latest),
            "completed_job_count": sum(
                str(attempt.get("state") or "") == "completed"
                for attempt in latest.values()
            ),
        }

    @staticmethod
    def _run_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"], "session_id": row["session_id"], "team_id": row["team_id"],
            "team_name": row["team_name"], "worker_id": row["worker_id"],
            "workspace_root": row["workspace_root"], "execution_path": row["execution_path"],
            "task_id": row["task_id"], "state": row["state"], "request": row["request"],
            "manifest": json.loads(row["manifest_json"] or "{}"),
            "plan": json.loads(row["plan_json"]) if row["plan_json"] else None,
            "usage": json.loads(row["usage_json"] or "{}"), "created_at": row["created_at"],
            "updated_at": row["updated_at"], "completed_at": row["completed_at"],
            "last_seq": row["last_seq"], "pinned": bool(row["pinned"]),
            "legacy": bool(row["legacy"]), "recoverable": bool(row["recoverable"]),
            "recovery_reason": row["recovery_reason"],
        }

    def mark_abandoned(
        self, lease_active: Callable[[str], bool] | None = None
    ) -> list[dict[str, Any]]:
        """Mark runs recoverable only after their worker and provider lease are gone."""
        if self.read_only:
            return []
        changed: list[str] = []
        with self._lock, self._connect() as connection:
            rows = connection.execute(
                "SELECT id, owner_pid, state FROM runs WHERE state NOT IN ('completed','failed','interrupted','cancelled','discarded')"
            ).fetchall()
            for row in rows:
                if _alive(int(row["owner_pid"] or 0)):
                    continue
                if lease_active is not None and lease_active(str(row["id"])):
                    continue
                connection.execute(
                    "UPDATE runs SET state='interrupted', recoverable=1, recovery_reason=?, updated_at=? WHERE id=?",
                    ("The task worker stopped before the run reached a terminal checkpoint.",
                     time.time(), row["id"]),
                )
                changed.append(str(row["id"]))
        return [self.run(run_id) for run_id in changed if self.run(run_id) is not None]

    def set_state(self, run_id: str, state: str, *, recoverable: bool | None = None,
                  reason: str | None = None) -> None:
        if self.read_only:
            return
        if state in ACTIVE_NONRECOVERABLE_STATES:
            recoverable = False
            reason = None
        values: list[Any] = [state, time.time()]
        fields = ["state=?", "updated_at=?"]
        if recoverable is not None:
            fields.append("recoverable=?")
            values.append(1 if recoverable else 0)
            if not recoverable and reason is None:
                fields.append("recovery_reason=NULL")
        if reason is not None:
            fields.append("recovery_reason=?")
            values.append(reason[:4_000])
        if state in TERMINAL_STATES:
            fields.append("completed_at=?")
            values.append(time.time())
        values.append(run_id)
        with self._connect() as connection:
            cursor = connection.execute(f"UPDATE runs SET {', '.join(fields)} WHERE id=?", values)
            if cursor.rowcount != 1:
                raise RunStoreError(f"run not found: {run_id}")

    def set_pinned(self, run_id: str, pinned: bool) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE runs SET pinned=?, updated_at=? WHERE id=?",
                (int(pinned), time.time(), run_id),
            )
            if cursor.rowcount != 1:
                raise RunStoreError(f"run not found: {run_id}")
        return self.run(run_id) or {}

    def update_task(self, run_id: str, task: dict[str, Any]) -> None:
        if self.read_only:
            return
        with self._connect() as connection:
            connection.execute(
                """UPDATE runs SET task_id=?, workspace_root=?, execution_path=?, updated_at=?
                   WHERE id=?""",
                (str(task.get("id") or ""), str(task.get("workspace_root") or ""),
                 str(task.get("execution_path") or ""), time.time(), run_id),
            )

    def discard(self, run_id: str) -> dict[str, Any]:
        run = self.run(run_id)
        if run is None:
            raise RunStoreError(f"run not found: {run_id}")
        self.set_state(run_id, "discarded", recoverable=False)
        return self.run(run_id) or run

    def export(self, run_id: str, *, include_content: bool = False) -> dict[str, Any]:
        run = self.run(run_id, include_events=True)
        if run is None:
            raise RunStoreError(f"run not found: {run_id}")
        value = sanitize_event(run, include_content=include_content)
        return {
            "format": "locusrun", "version": 1, "exported_at": time.time(),
            "content_included": include_content, "run": value,
        }

    def record_routing_sample(
        self, agent_id: str, *, tags: list[str], quality: float | None,
        reliable: bool, latency_ms: int, estimated_cost: float,
        local: bool, evaluation: bool,
    ) -> None:
        if self.read_only:
            return
        with self._connect() as connection:
            connection.execute(
                """INSERT INTO routing_samples(
                    agent_id, tags_json, quality, reliable, latency_ms,
                    estimated_cost, local, evaluation, occurred_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (agent_id, _json(tags[:24]), quality, int(reliable), max(latency_ms, 0),
                 max(estimated_cost, 0), int(local), int(evaluation), time.time()),
            )

    def routing_samples(self, agent_id: str, tags: list[str], limit: int = 50) -> list[dict[str, Any]]:
        wanted = {tag.lower() for tag in tags}
        with self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT * FROM routing_samples WHERE agent_id=? ORDER BY occurred_at DESC LIMIT 250",
                (agent_id,),
            ).fetchall()
        output = []
        for row in rows:
            sample_tags = [str(item) for item in json.loads(row["tags_json"] or "[]")]
            if wanted and not wanted.intersection(tag.lower() for tag in sample_tags):
                continue
            output.append({
                "quality": row["quality"], "reliable": bool(row["reliable"]),
                "latency_ms": row["latency_ms"], "estimated_cost": row["estimated_cost"],
                "local": bool(row["local"]), "evaluation": bool(row["evaluation"]),
                "occurred_at": row["occurred_at"], "tags": sample_tags,
            })
            if len(output) >= limit:
                break
        return output

    def prune(self, *, retention_days: int = DEFAULT_RETENTION_DAYS,
              max_bytes: int = DEFAULT_MAX_BYTES) -> int:
        if self.read_only:
            return 0
        cutoff = time.time() - max(retention_days, 1) * 86_400
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM runs WHERE pinned=0 AND updated_at<? AND state IN ('completed','failed','interrupted','cancelled','discarded')",
                (cutoff,),
            )
            removed = max(cursor.rowcount, 0)
            connection.commit()
            connection.execute("PRAGMA wal_checkpoint(PASSIVE)")
        with self._connect() as connection:
            size = _logical_database_bytes(connection)
            if size > max_bytes:
                rows = connection.execute(
                    """SELECT id FROM runs WHERE pinned=0 AND state IN
                       ('completed','failed','interrupted','cancelled','discarded')
                       ORDER BY updated_at ASC"""
                ).fetchall()
                for row in rows:
                    connection.execute("DELETE FROM runs WHERE id=?", (row["id"],))
                    removed += 1
                    if _logical_database_bytes(connection) <= max_bytes:
                        break
        return removed


def _logical_database_bytes(connection: sqlite3.Connection) -> int:
    """Measure live SQLite pages so free pages do not trigger over-pruning."""
    page_size = int(connection.execute("PRAGMA page_size").fetchone()[0])
    page_count = int(connection.execute("PRAGMA page_count").fetchone()[0])
    free_pages = int(connection.execute("PRAGMA freelist_count").fetchone()[0])
    return max(page_count - free_pages, 0) * page_size


__all__ = [
    "DEFAULT_MAX_BYTES", "DEFAULT_RETENTION_DAYS", "RECOVERABLE_STATES",
    "RunStore", "RunStoreError", "SCHEMA_VERSION", "sanitize_event",
]
