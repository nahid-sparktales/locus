"""Durable, ordered orchestration history for Locus.

The chat transcript remains append-only JSONL.  This store is deliberately a
separate, queryable ledger for team runs, checkpoints, attempts, evaluation
results, and routing observations.  Every event is sanitized before it crosses
the persistence boundary and receives its sequence number in the same SQLite
transaction that records it.
"""
from __future__ import annotations

import json
import math
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
from .event_triggers import (
    MAX_PENDING_PER_TRIGGER,
    EventTriggerValidationError,
    evaluate_price_event,
    matches_trigger,
    normalize_connection,
    normalize_event,
    normalize_trigger,
    validate_filters_for_source,
)
from .schedules import (
    ScheduleValidationError,
    latest_due_occurrence,
    next_occurrence,
    normalize_schedule,
    timezone,
)

SCHEMA_VERSION = 10
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
            if version < 4:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS turn_usage (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL,
                        workspace_root TEXT,
                        provider TEXT,
                        model TEXT,
                        account TEXT,
                        kind TEXT NOT NULL DEFAULT 'solo',
                        prompt_tokens INTEGER NOT NULL DEFAULT 0,
                        completion_tokens INTEGER NOT NULL DEFAULT 0,
                        occurred_at REAL NOT NULL
                    )
                    """
                )
                connection.execute(
                    "CREATE INDEX IF NOT EXISTS turn_usage_time_idx"
                    " ON turn_usage(occurred_at DESC)"
                )
                connection.execute("UPDATE schema_meta SET version=4 WHERE singleton=1")
                connection.commit()
            if version < 5:
                connection.execute("BEGIN IMMEDIATE")
                columns = {
                    str(row[1]) for row in connection.execute("PRAGMA table_info(runs)")
                }
                for statement in (
                    "ALTER TABLE runs ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'team'",
                    "ALTER TABLE runs ADD COLUMN trace_id TEXT NOT NULL DEFAULT ''",
                    "ALTER TABLE runs ADD COLUMN root_span_id TEXT NOT NULL DEFAULT ''",
                    "ALTER TABLE runs ADD COLUMN content_policy TEXT NOT NULL DEFAULT 'metadata'",
                    "ALTER TABLE runs ADD COLUMN execution_environment TEXT NOT NULL DEFAULT 'local'",
                    "ALTER TABLE runs ADD COLUMN export_state TEXT NOT NULL DEFAULT 'pending'",
                    "ALTER TABLE runs ADD COLUMN export_attempts INTEGER NOT NULL DEFAULT 0",
                    "ALTER TABLE runs ADD COLUMN exported_at REAL",
                ):
                    column = statement.split("ADD COLUMN ", 1)[1].split(" ", 1)[0]
                    if column not in columns:
                        connection.execute(statement)
                connection.execute("UPDATE runs SET trace_id=lower(hex(randomblob(16))) WHERE trace_id='' ")
                connection.execute(
                    "UPDATE runs SET root_span_id=lower(hex(randomblob(8))) WHERE root_span_id=''"
                )
                connection.execute("UPDATE schema_meta SET version=5 WHERE singleton=1")
                connection.commit()
            if version < 6:
                connection.execute("BEGIN IMMEDIATE")
                columns = {
                    str(row[1]) for row in connection.execute("PRAGMA table_info(runs)")
                }
                for statement in (
                    "ALTER TABLE runs ADD COLUMN queue_position INTEGER",
                    "ALTER TABLE runs ADD COLUMN queued_message_id TEXT",
                    "ALTER TABLE runs ADD COLUMN retry_parent_id TEXT",
                    "ALTER TABLE runs ADD COLUMN admitted_at REAL",
                ):
                    column = statement.split("ADD COLUMN ", 1)[1].split(" ", 1)[0]
                    if column not in columns:
                        connection.execute(statement)
                connection.execute(
                    "CREATE INDEX IF NOT EXISTS runs_queue_idx"
                    " ON runs(state, queue_position, created_at)"
                )
                connection.execute("UPDATE schema_meta SET version=6 WHERE singleton=1")
                connection.commit()
            if version < 7:
                connection.execute("BEGIN IMMEDIATE")
                columns = {
                    str(row[1]) for row in connection.execute("PRAGMA table_info(job_attempts)")
                }
                for statement in (
                    "ALTER TABLE job_attempts ADD COLUMN node_id TEXT",
                    "ALTER TABLE job_attempts ADD COLUMN parent_node_id TEXT",
                    "ALTER TABLE job_attempts ADD COLUMN depth INTEGER NOT NULL DEFAULT 0",
                    "ALTER TABLE job_attempts ADD COLUMN execution_engine TEXT NOT NULL DEFAULT 'locus_managed'",
                ):
                    column = statement.split("ADD COLUMN ", 1)[1].split(" ", 1)[0]
                    if column not in columns:
                        connection.execute(statement)
                connection.execute(
                    "UPDATE job_attempts SET node_id=job_id WHERE node_id IS NULL OR node_id=''"
                )
                connection.execute("UPDATE schema_meta SET version=7 WHERE singleton=1")
                connection.commit()
            if version < 8:
                connection.execute("BEGIN IMMEDIATE")
                columns = {
                    str(row[1]) for row in connection.execute("PRAGMA table_info(runs)")
                }
                for statement in (
                    "ALTER TABLE runs ADD COLUMN schedule_id TEXT",
                    "ALTER TABLE runs ADD COLUMN occurrence_id TEXT",
                    "ALTER TABLE runs ADD COLUMN scheduled_for REAL",
                ):
                    column = statement.split("ADD COLUMN ", 1)[1].split(" ", 1)[0]
                    if column not in columns:
                        connection.execute(statement)
                connection.executescript(
                    """
                    CREATE TABLE IF NOT EXISTS schedules (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        prompt TEXT NOT NULL,
                        workspace_root TEXT NOT NULL,
                        mode TEXT NOT NULL,
                        execution_environment TEXT NOT NULL,
                        runner TEXT NOT NULL,
                        team_id TEXT,
                        team_name TEXT,
                        provider TEXT NOT NULL,
                        provider_account_id TEXT,
                        model TEXT NOT NULL,
                        timezone TEXT NOT NULL,
                        rule_json TEXT NOT NULL,
                        enabled INTEGER NOT NULL DEFAULT 1,
                        next_run_at REAL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        last_run_at REAL,
                        last_run_id TEXT,
                        last_error TEXT
                    );
                    CREATE INDEX IF NOT EXISTS schedules_due_idx
                        ON schedules(enabled, next_run_at);
                    CREATE TABLE IF NOT EXISTS schedule_occurrences (
                        id TEXT PRIMARY KEY,
                        schedule_id TEXT NOT NULL,
                        schedule_name TEXT NOT NULL,
                        scheduled_for REAL NOT NULL,
                        trigger TEXT NOT NULL,
                        state TEXT NOT NULL,
                        session_id TEXT,
                        run_id TEXT,
                        error TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS schedule_occurrences_schedule_idx
                        ON schedule_occurrences(schedule_id, scheduled_for DESC);
                    CREATE INDEX IF NOT EXISTS runs_schedule_idx
                        ON runs(schedule_id, scheduled_for DESC);
                    """
                )
                connection.execute("UPDATE schema_meta SET version=8 WHERE singleton=1")
                connection.commit()
            if version < 9:
                connection.execute("BEGIN IMMEDIATE")
                connection.executescript(
                    """
                    CREATE TABLE IF NOT EXISTS connector_connections (
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        public_config_json TEXT NOT NULL DEFAULT '{}',
                        cursor_json TEXT NOT NULL DEFAULT '{}',
                        enabled INTEGER NOT NULL DEFAULT 1,
                        deleted INTEGER NOT NULL DEFAULT 0,
                        health TEXT NOT NULL DEFAULT 'disconnected',
                        last_error TEXT,
                        last_polled_at REAL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS event_triggers (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        connection_id TEXT NOT NULL REFERENCES connector_connections(id)
                            ON DELETE RESTRICT,
                        target_session_id TEXT NOT NULL,
                        instruction TEXT NOT NULL,
                        mode TEXT NOT NULL,
                        filters_json TEXT NOT NULL DEFAULT '{}',
                        action_connection_ids_json TEXT NOT NULL DEFAULT '[]',
                        enabled INTEGER NOT NULL DEFAULT 1,
                        deleted INTEGER NOT NULL DEFAULT 0,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        last_event_at REAL,
                        last_run_id TEXT,
                        last_error TEXT
                    );
                    CREATE INDEX IF NOT EXISTS event_triggers_connection_idx
                        ON event_triggers(connection_id, enabled);
                    CREATE INDEX IF NOT EXISTS event_triggers_session_idx
                        ON event_triggers(target_session_id, enabled);
                    CREATE TABLE IF NOT EXISTS event_deliveries (
                        id TEXT PRIMARY KEY,
                        trigger_id TEXT NOT NULL REFERENCES event_triggers(id) ON DELETE CASCADE,
                        source_event_id TEXT NOT NULL,
                        source TEXT NOT NULL,
                        received_at REAL NOT NULL,
                        occurred_at REAL NOT NULL,
                        event_json TEXT NOT NULL,
                        state TEXT NOT NULL,
                        attempt INTEGER NOT NULL DEFAULT 0,
                        session_id TEXT,
                        run_id TEXT,
                        error TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        UNIQUE(trigger_id, source_event_id)
                    );
                    CREATE INDEX IF NOT EXISTS event_deliveries_pending_idx
                        ON event_deliveries(state, received_at, created_at);
                    CREATE INDEX IF NOT EXISTS event_deliveries_trigger_idx
                        ON event_deliveries(trigger_id, received_at DESC);
                    CREATE TABLE IF NOT EXISTS connector_action_receipts (
                        idempotency_key TEXT PRIMARY KEY,
                        event_delivery_id TEXT REFERENCES event_deliveries(id) ON DELETE SET NULL,
                        tool_name TEXT NOT NULL,
                        result_json TEXT NOT NULL DEFAULT '{}',
                        created_at REAL NOT NULL
                    );
                    """
                )
                connection.execute("UPDATE schema_meta SET version=9 WHERE singleton=1")
                connection.commit()
            if version < 10:
                connection.execute("BEGIN IMMEDIATE")
                columns = {
                    str(row[1])
                    for row in connection.execute("PRAGMA table_info(event_triggers)")
                }
                if "trigger_kind" not in columns:
                    connection.execute(
                        "ALTER TABLE event_triggers ADD COLUMN trigger_kind TEXT"
                        " NOT NULL DEFAULT 'event'"
                    )
                if "runtime_state_json" not in columns:
                    connection.execute(
                        "ALTER TABLE event_triggers ADD COLUMN runtime_state_json TEXT"
                        " NOT NULL DEFAULT '{}'"
                    )
                connection.execute("UPDATE schema_meta SET version=10 WHERE singleton=1")
                connection.commit()
            # Dispatch claims and run creation intentionally use separate
            # transactions. A crash between them is therefore recoverable:
            # link a run that was already created, otherwise make the event
            # pending again because no model turn could have started.
            connection.execute("BEGIN IMMEDIATE")
            claims = connection.execute(
                """
                SELECT deliveries.id, deliveries.attempt, triggers.target_session_id
                FROM event_deliveries AS deliveries
                JOIN event_triggers AS triggers ON triggers.id=deliveries.trigger_id
                WHERE deliveries.state='claiming'
                """
            ).fetchall()
            for claim in claims:
                run_id = uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"locus:event-delivery:{claim['id']}:{int(claim['attempt'] or 0)}",
                ).hex
                run_exists = connection.execute(
                    "SELECT 1 FROM runs WHERE id=?", (run_id,)
                ).fetchone() is not None
                if run_exists:
                    connection.execute(
                        "UPDATE event_deliveries SET state='queued', run_id=?,"
                        " session_id=?, error=NULL, updated_at=? WHERE id=?",
                        (run_id, claim["target_session_id"], time.time(), claim["id"]),
                    )
                else:
                    connection.execute(
                        "UPDATE event_deliveries SET state='pending', run_id=NULL,"
                        " session_id=NULL, error=NULL, updated_at=? WHERE id=?",
                        (time.time(), claim["id"]),
                    )
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
        run_kind: str = "team",
        trace_id: str = "",
        root_span_id: str = "",
        content_policy: str = "metadata",
        execution_environment: str = "local",
        schedule_id: str = "",
        occurrence_id: str = "",
        scheduled_for: float | None = None,
    ) -> None:
        if self.read_only:
            return
        now = time.time()
        trace_id = trace_id if re.fullmatch(r"[0-9a-f]{32}", trace_id) else uuid.uuid4().hex
        root_span_id = (
            root_span_id if re.fullmatch(r"[0-9a-f]{16}", root_span_id)
            else uuid.uuid4().hex[:16]
        )
        run_kind = run_kind if run_kind in {
            "solo", "team", "evaluation", "verification", "memory_review",
        } else "solo"
        content_policy = "content" if content_policy == "content" else "metadata"
        execution_environment = (
            "worktree" if execution_environment == "worktree" else "local"
        )
        safe_manifest = sanitize_event(manifest or {})
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO runs(
                    id, session_id, team_id, team_name, worker_id, owner_pid,
                    workspace_root, execution_path, task_id, state, request,
                    manifest_json, created_at, updated_at, run_kind, trace_id,
                    root_span_id, content_policy, execution_environment,
                    schedule_id, occurrence_id, scheduled_for
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    run_kind=excluded.run_kind,
                    trace_id=CASE WHEN runs.trace_id='' THEN excluded.trace_id ELSE runs.trace_id END,
                    root_span_id=CASE WHEN runs.root_span_id='' THEN excluded.root_span_id
                        ELSE runs.root_span_id END,
                    content_policy=excluded.content_policy,
                    execution_environment=excluded.execution_environment,
                    schedule_id=COALESCE(NULLIF(excluded.schedule_id, ''), runs.schedule_id),
                    occurrence_id=COALESCE(NULLIF(excluded.occurrence_id, ''), runs.occurrence_id),
                    scheduled_for=COALESCE(excluded.scheduled_for, runs.scheduled_for),
                    recoverable=0, recovery_reason=NULL
                """,
                (
                    run_id, session_id, team_id, team_name, worker_id, os.getpid(),
                    workspace_root, execution_path, task_id, state, request[:240_000],
                    _json(safe_manifest), now, now, run_kind, trace_id, root_span_id,
                    content_policy, execution_environment, schedule_id, occurrence_id,
                    scheduled_for,
                ),
            )

    def mark_export(
        self, run_id: str, state: str, *, attempts: int = 0,
        content_policy: str | None = None,
    ) -> None:
        """Record export progress without ever persisting collector errors."""
        if self.read_only:
            return
        state = state if state in {"pending", "exporting", "exported", "failed"} else "failed"
        with self._connect() as connection:
            connection.execute(
                """UPDATE runs SET export_state=?, export_attempts=?, exported_at=?, updated_at=?,
                          content_policy=COALESCE(?, content_policy)
                   WHERE id=?""",
                (
                    state, max(int(attempts), 0),
                    time.time() if state == "exported" else None,
                    time.time(),
                    ("content" if content_policy == "content" else "metadata")
                    if content_policy is not None else None,
                    run_id,
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
        safe.setdefault("run_id", run_id)
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
                        id, owner_pid, state, created_at, updated_at, trace_id,
                        root_span_id
                    ) VALUES(?, ?, ?, ?, ?, ?, ?)""",
                    (
                        run_id, os.getpid(), str(safe.get("state") or "running"), now, now,
                        uuid.uuid4().hex, uuid.uuid4().hex[:16],
                    ),
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
                    role, provider, model, state, goal, started_at, node_id,
                    parent_node_id, depth, execution_engine
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    run_id, job_id, attempt, attempt_id, str(event.get("agent_id") or ""),
                    str(event.get("agent_name") or ""), str(event.get("role") or ""),
                    str(event.get("provider") or ""), str(event.get("model") or ""),
                    str(event.get("state") or "running"), str(event.get("goal") or "")[:120_000],
                    now, str(event.get("node_id") or job_id),
                    str(event.get("parent_node_id") or ""),
                    max(int(event.get("depth") or 0), 0),
                    str(event.get("execution_engine") or "locus_managed"),
                ),
            )
        elif event_type in {"agent_job_completed", "agent_job_incomplete"}:
            result = event.get("result") if isinstance(event.get("result"), dict) else {}
            job_id = str(result.get("job_id") or event.get("job_id") or "")
            if not job_id:
                return
            row = connection.execute(
                """SELECT attempt, attempt_id, execution_engine FROM job_attempts
                   WHERE run_id=? AND job_id=? ORDER BY attempt DESC LIMIT 1""",
                (run_id, job_id),
            ).fetchone()
            if row is None:
                attempt, attempt_id = 1, f"{run_id}:{job_id}:1"
                attempt_engine = str(
                    result.get("execution_engine") or event.get("execution_engine")
                    or "locus_managed"
                )
                connection.execute(
                    """INSERT INTO job_attempts(
                        run_id, job_id, attempt, attempt_id, agent_id, agent_name,
                        role, state, goal, started_at, node_id, parent_node_id,
                        depth, execution_engine
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, 'running', '', ?, ?, ?, ?, ?)""",
                    (run_id, job_id, attempt, attempt_id, str(result.get("agent_id") or ""),
                     str(result.get("agent_name") or ""), str(result.get("role") or ""), now,
                     str(result.get("node_id") or event.get("node_id") or job_id),
                     str(result.get("parent_node_id") or event.get("parent_node_id") or ""),
                     max(int(result.get("depth") or event.get("depth") or 0), 0),
                     attempt_engine),
                )
            else:
                attempt, attempt_id = int(row[0]), str(row[1])
                attempt_engine = str(
                    result.get("execution_engine") or event.get("execution_engine")
                    or row[2] or "locus_managed"
                )
            event["attempt"] = attempt
            event["attempt_id"] = attempt_id
            connection.execute(
                """UPDATE job_attempts SET state=?, result_json=?, completed_at=?, execution_engine=?
                   WHERE run_id=? AND job_id=? AND attempt=?""",
                (str(event.get("state") or (
                    "paused" if event_type == "agent_job_incomplete" else "completed"
                )), _json(result),
                 now if event_type == "agent_job_completed" else None,
                 attempt_engine,
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
            "node_id": row["node_id"] or row["job_id"],
            "parent_node_id": row["parent_node_id"],
            "depth": int(row["depth"] or 0),
            "execution_engine": row["execution_engine"] or "locus_managed",
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

    def list_runs(
        self, *, session_id: str = "", states: list[str] | None = None,
        workspace: str = "", cursor: float = 0, limit: int = 100,
    ) -> list[dict[str, Any]]:
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
        clauses: list[str] = []
        values: list[Any] = []
        if session_id:
            clauses.append("session_id=?")
            values.append(session_id)
        if workspace:
            clauses.append("workspace_root=?")
            values.append(workspace)
        if cursor > 0:
            clauses.append("updated_at<?")
            values.append(float(cursor))
        clean_states = [value for value in (states or []) if value][:20]
        if clean_states:
            clauses.append(f"state IN ({','.join('?' for _ in clean_states)})")
            values.extend(clean_states)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._connect(readonly=True) as connection:
            rows = connection.execute(
                summary_query + where + " ORDER BY updated_at DESC LIMIT ?", (*values, limit)
            ).fetchall()
        return [{
            **self._run_row(row),
            "job_count": int(row["job_count"] or 0),
            "completed_job_count": int(row["completed_job_count"] or 0),
        } for row in rows]

    # ------------------------------------------------------ event automations

    @staticmethod
    def _connector_connection_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "kind": row["kind"],
            "display_name": row["display_name"],
            "public_config": json.loads(row["public_config_json"] or "{}"),
            "cursor": json.loads(row["cursor_json"] or "{}"),
            "enabled": bool(row["enabled"]),
            "health": row["health"],
            "last_error": row["last_error"],
            "last_polled_at": row["last_polled_at"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _event_trigger_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "name": row["name"],
            "connection_id": row["connection_id"],
            "target_session_id": row["target_session_id"],
            "instruction": row["instruction"],
            "mode": row["mode"],
            "trigger_kind": row["trigger_kind"],
            "filters": json.loads(row["filters_json"] or "{}"),
            "runtime_state": json.loads(row["runtime_state_json"] or "{}"),
            "action_connection_ids": json.loads(
                row["action_connection_ids_json"] or "[]"
            ),
            "enabled": bool(row["enabled"]),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "last_event_at": row["last_event_at"],
            "last_run_id": row["last_run_id"],
            "last_error": row["last_error"],
        }

    @staticmethod
    def _event_delivery_row(row: sqlite3.Row) -> dict[str, Any]:
        run_state = row["run_state"] if "run_state" in row.keys() else None
        state = row["state"]
        if state == "queued" and run_state in TERMINAL_STATES:
            state = run_state
        return {
            "id": row["id"],
            "trigger_id": row["trigger_id"],
            "source_event_id": row["source_event_id"],
            "source": row["source"],
            "received_at": row["received_at"],
            "occurred_at": row["occurred_at"],
            "event": json.loads(row["event_json"] or "{}"),
            "state": state,
            "run_state": run_state,
            "attempt": int(row["attempt"] or 0),
            "session_id": row["session_id"],
            "run_id": row["run_id"],
            "error": row["error"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def connector_connections(self) -> list[dict[str, Any]]:
        with self._lock, self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT * FROM connector_connections WHERE deleted=0"
                " ORDER BY enabled DESC, display_name COLLATE NOCASE"
            ).fetchall()
        return [self._connector_connection_row(row) for row in rows]

    def connector_connection(self, connection_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT * FROM connector_connections WHERE id=? AND deleted=0", (connection_id,)
            ).fetchone()
        return self._connector_connection_row(row) if row is not None else None

    def create_connector_connection(
        self, value: dict[str, Any], *, now: float | None = None
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        try:
            normalized = normalize_connection(value)
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        connection_id = str(value.get("id") or uuid.uuid4().hex)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", connection_id):
            raise RunStoreError("connection id is invalid")
        created = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            try:
                connection.execute(
                    """
                    INSERT INTO connector_connections(
                        id, kind, display_name, public_config_json, cursor_json,
                        enabled, health, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, 'disconnected', ?, ?)
                    """,
                    (
                        connection_id, normalized["kind"], normalized["display_name"],
                        _json(normalized["public_config"]), _json(normalized["cursor"]),
                        int(normalized["enabled"]), created, created,
                    ),
                )
            except sqlite3.IntegrityError as exc:
                raise RunStoreError("a connector connection with that id already exists") from exc
        return self.connector_connection(connection_id) or {"id": connection_id, **normalized}

    def update_connector_connection(
        self, connection_id: str, updates: dict[str, Any], *, now: float | None = None
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        existing = self.connector_connection(connection_id)
        if existing is None:
            raise RunStoreError("connector connection not found")
        allowed = {"kind", "display_name", "public_config", "cursor", "enabled"}
        unknown = set(updates) - allowed
        if unknown:
            raise RunStoreError(f"unknown connection field: {sorted(unknown)[0]}")
        merged = {key: existing[key] for key in allowed}
        merged.update(updates)
        try:
            normalized = normalize_connection(merged)
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        current = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                UPDATE connector_connections SET kind=?, display_name=?,
                    public_config_json=?, cursor_json=?, enabled=?, updated_at=?,
                    last_error=CASE WHEN ? THEN NULL ELSE last_error END
                WHERE id=?
                """,
                (
                    normalized["kind"], normalized["display_name"],
                    _json(normalized["public_config"]), _json(normalized["cursor"]),
                    int(normalized["enabled"]), current,
                    int(normalized["enabled"] and not existing["enabled"]), connection_id,
                ),
            )
        return self.connector_connection(connection_id) or existing

    def update_connector_cursor(
        self, connection_id: str, cursor: dict[str, Any], *,
        health: str = "connected", error: str = "", now: float | None = None,
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        existing = self.connector_connection(connection_id)
        if existing is None:
            raise RunStoreError("connector connection not found")
        try:
            normalized = normalize_connection({**existing, "cursor": cursor})
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        current = float(now if now is not None else time.time())
        clean_health = " ".join(health.split())[:80] or "connected"
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                UPDATE connector_connections SET cursor_json=?, health=?, last_error=?,
                    last_polled_at=?, updated_at=? WHERE id=?
                """,
                (
                    _json(normalized["cursor"]), clean_health, error[:4_000] or None,
                    current, current, connection_id,
                ),
            )
        return self.connector_connection(connection_id) or existing

    def delete_connector_connection(self, connection_id: str) -> None:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "UPDATE connector_connections SET enabled=0, deleted=1, updated_at=?"
                " WHERE id=? AND deleted=0", (time.time(), connection_id,)
            )
            if cursor.rowcount != 1:
                raise RunStoreError("connector connection not found")
            connection.execute(
                "UPDATE event_triggers SET enabled=0, last_error=?, updated_at=?"
                " WHERE connection_id=? AND deleted=0",
                ("The source connection was removed.", time.time(), connection_id),
            )

    def event_triggers(self) -> list[dict[str, Any]]:
        with self._lock, self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT * FROM event_triggers WHERE deleted=0"
                " ORDER BY enabled DESC, name COLLATE NOCASE"
            ).fetchall()
        return [self._event_trigger_row(row) for row in rows]

    def event_trigger(self, trigger_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT * FROM event_triggers WHERE id=? AND deleted=0", (trigger_id,)
            ).fetchone()
        return self._event_trigger_row(row) if row is not None else None

    def create_event_trigger(
        self, value: dict[str, Any], *, now: float | None = None
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        try:
            normalized = normalize_trigger(value)
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        source_connection = self.connector_connection(normalized["connection_id"])
        if source_connection is None:
            raise RunStoreError("connector connection not found")
        try:
            validate_filters_for_source(
                str(source_connection["kind"]), normalized["filters"],
                trigger_kind=normalized["trigger_kind"],
            )
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        for action_id in normalized["action_connection_ids"]:
            action_connection = self.connector_connection(action_id)
            if action_connection is None:
                raise RunStoreError(f"action connector connection not found: {action_id}")
            if action_connection["kind"] == "price_feed":
                raise RunStoreError("price feed connections cannot perform actions")
        trigger_id = str(value.get("id") or uuid.uuid4().hex)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", trigger_id):
            raise RunStoreError("trigger id is invalid")
        existing = self.event_trigger(trigger_id)
        if existing is not None:
            definition_fields = (
                "name", "connection_id", "target_session_id", "instruction", "mode",
                "trigger_kind", "filters", "action_connection_ids", "enabled",
            )
            if all(existing.get(key) == normalized.get(key) for key in definition_fields):
                return existing
            raise RunStoreError("an event trigger with that id already exists")
        created = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            try:
                connection.execute(
                    """
                    INSERT INTO event_triggers(
                        id, name, connection_id, target_session_id, instruction,
                        mode, trigger_kind, filters_json, runtime_state_json,
                        action_connection_ids_json, enabled,
                        created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, '{}', ?, ?, ?, ?)
                    """,
                    (
                        trigger_id, normalized["name"], normalized["connection_id"],
                        normalized["target_session_id"], normalized["instruction"],
                        normalized["mode"], normalized["trigger_kind"],
                        _json(normalized["filters"]),
                        _json(normalized["action_connection_ids"]),
                        int(normalized["enabled"]), created, created,
                    ),
                )
            except sqlite3.IntegrityError as exc:
                raise RunStoreError("an event trigger with that id already exists") from exc
        return self.event_trigger(trigger_id) or {"id": trigger_id, **normalized}

    def update_event_trigger(
        self, trigger_id: str, updates: dict[str, Any], *, now: float | None = None
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        existing = self.event_trigger(trigger_id)
        if existing is None:
            raise RunStoreError("event trigger not found")
        allowed = {
            "name", "connection_id", "target_session_id", "instruction", "mode",
            "trigger_kind", "filters", "action_connection_ids", "enabled",
        }
        unknown = set(updates) - allowed
        if unknown:
            raise RunStoreError(f"unknown trigger field: {sorted(unknown)[0]}")
        merged = {key: existing[key] for key in allowed}
        merged.update(updates)
        try:
            normalized = normalize_trigger(merged)
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        source_connection = self.connector_connection(normalized["connection_id"])
        if source_connection is None:
            raise RunStoreError("connector connection not found")
        try:
            validate_filters_for_source(
                str(source_connection["kind"]), normalized["filters"],
                trigger_kind=normalized["trigger_kind"],
            )
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        for action_id in normalized["action_connection_ids"]:
            action_connection = self.connector_connection(action_id)
            if action_connection is None:
                raise RunStoreError(f"action connector connection not found: {action_id}")
            if action_connection["kind"] == "price_feed":
                raise RunStoreError("price feed connections cannot perform actions")
        current = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                UPDATE event_triggers SET name=?, connection_id=?, target_session_id=?,
                    instruction=?, mode=?, trigger_kind=?, filters_json=?,
                    action_connection_ids_json=?, enabled=?, updated_at=?,
                    last_error=CASE WHEN ? THEN NULL ELSE last_error END
                WHERE id=?
                """,
                (
                    normalized["name"], normalized["connection_id"],
                    normalized["target_session_id"], normalized["instruction"],
                    normalized["mode"], normalized["trigger_kind"],
                    _json(normalized["filters"]),
                    _json(normalized["action_connection_ids"]), int(normalized["enabled"]),
                    current, int(normalized["enabled"] and not existing["enabled"]),
                    trigger_id,
                ),
            )
            if (normalized["trigger_kind"] == "price"
                    or existing["trigger_kind"] == "price") and any(
                key in updates for key in {"connection_id", "trigger_kind", "filters"}
            ):
                connection.execute(
                    "UPDATE event_triggers SET runtime_state_json='{}' WHERE id=?",
                    (trigger_id,),
                )
        return self.event_trigger(trigger_id) or existing

    def rearm_price_trigger(self, trigger_id: str) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT trigger_kind FROM event_triggers WHERE id=? AND deleted=0",
                (trigger_id,),
            ).fetchone()
            if row is None:
                raise RunStoreError("event trigger not found")
            if row["trigger_kind"] != "price":
                raise RunStoreError("only price triggers can be re-armed")
            connection.execute(
                "UPDATE event_triggers SET runtime_state_json='{}', enabled=1,"
                " last_error=NULL, updated_at=? WHERE id=?",
                (time.time(), trigger_id),
            )
        return self.event_trigger(trigger_id) or {}

    def pause_event_trigger(self, trigger_id: str, reason: str) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "UPDATE event_triggers SET enabled=0, last_error=?, updated_at=? WHERE id=?",
                (reason.strip()[:4_000] or "The trigger needs attention.", time.time(), trigger_id),
            )
            if cursor.rowcount != 1:
                raise RunStoreError("event trigger not found")
        return self.event_trigger(trigger_id) or {}

    def delete_event_trigger(self, trigger_id: str) -> None:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "UPDATE event_triggers SET enabled=0, deleted=1, updated_at=?"
                " WHERE id=? AND deleted=0",
                (time.time(), trigger_id),
            )
            if cursor.rowcount != 1:
                raise RunStoreError("event trigger not found")

    def ingest_event(
        self, connection_id: str, value: dict[str, Any], *, now: float | None = None
    ) -> list[dict[str, Any]]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        connector = self.connector_connection(connection_id)
        if connector is None:
            raise RunStoreError("connector connection not found")
        if not connector["enabled"]:
            raise RunStoreError("connector connection is paused")
        try:
            event = normalize_event(value, source=str(connector["kind"]))
        except EventTriggerValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        received = float(now if now is not None else time.time())
        created_ids: list[str] = []
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                "SELECT * FROM event_triggers"
                " WHERE connection_id=? AND enabled=1 AND deleted=0"
                " ORDER BY created_at, id",
                (connection_id,),
            ).fetchall()
            for row in rows:
                filters = json.loads(row["filters_json"] or "{}")
                if not matches_trigger(filters, event):
                    continue
                existing = connection.execute(
                    "SELECT id FROM event_deliveries WHERE trigger_id=? AND source_event_id=?",
                    (row["id"], event["source_event_id"]),
                ).fetchone()
                if existing is not None:
                    created_ids.append(str(existing["id"]))
                    continue
                runtime_state = json.loads(row["runtime_state_json"] or "{}")
                should_deliver = True
                if row["trigger_kind"] == "price":
                    public_config = connector.get("public_config") or {}
                    try:
                        max_quote_age = float(
                            public_config.get("max_quote_age_seconds") or 300
                        )
                    except (TypeError, ValueError):
                        max_quote_age = 300
                    if not math.isfinite(max_quote_age):
                        max_quote_age = 300
                    max_quote_age = min(max(max_quote_age, 30), 86_400)
                    updated_state, should_deliver = evaluate_price_event(
                        filters["price_condition"], runtime_state, event,
                        now=received, max_quote_age_seconds=max_quote_age,
                    )
                    if updated_state == runtime_state:
                        continue
                    connection.execute(
                        "UPDATE event_triggers SET runtime_state_json=?,"
                        " last_event_at=?, updated_at=? WHERE id=?",
                        (_json(updated_state), received, received, row["id"]),
                    )
                    runtime_state = updated_state
                    if not should_deliver:
                        continue
                pending = int(connection.execute(
                    """
                    SELECT COUNT(*) FROM event_deliveries AS deliveries
                    LEFT JOIN runs ON runs.id=deliveries.run_id
                    WHERE deliveries.trigger_id=? AND (
                        deliveries.state IN ('pending', 'claiming') OR
                        (deliveries.state='queued' AND (
                            runs.state IS NULL OR runs.state NOT IN (
                                'completed','failed','interrupted','cancelled','discarded'
                            )
                        ))
                    )
                    """,
                    (row["id"],),
                ).fetchone()[0])
                if row["trigger_kind"] == "price" and (
                    filters["price_condition"]["lifecycle"] == "repeat" and pending
                ):
                    # The quote is remembered, but the cooldown remains available
                    # once the existing automatic turn finishes.
                    previous_state = json.loads(row["runtime_state_json"] or "{}")
                    if "last_fired_at" in previous_state:
                        runtime_state["last_fired_at"] = previous_state["last_fired_at"]
                    else:
                        runtime_state.pop("last_fired_at", None)
                    connection.execute(
                        "UPDATE event_triggers SET runtime_state_json=? WHERE id=?",
                        (_json(runtime_state), row["id"]),
                    )
                    continue
                if pending >= MAX_PENDING_PER_TRIGGER:
                    connection.rollback()
                    raise RunStoreError("event trigger queue is full")
                delivery_id = uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"locus:event:{row['id']}:{event['source_event_id']}",
                ).hex
                connection.execute(
                    """
                    INSERT INTO event_deliveries(
                        id, trigger_id, source_event_id, source, received_at,
                        occurred_at, event_json, state, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                    """,
                    (
                        delivery_id, row["id"], event["source_event_id"], event["source"],
                        received, event["occurred_at"], _json(event), received, received,
                    ),
                )
                if row["trigger_kind"] == "price" and (
                    filters["price_condition"]["lifecycle"] == "once"
                ):
                    runtime_state["one_shot_delivery_id"] = delivery_id
                    connection.execute(
                        "UPDATE event_triggers SET runtime_state_json=? WHERE id=?",
                        (_json(runtime_state), row["id"]),
                    )
                connection.execute(
                    "UPDATE event_triggers SET last_event_at=?, updated_at=? WHERE id=?",
                    (received, received, row["id"]),
                )
                created_ids.append(delivery_id)
            connection.commit()
        return [item for delivery_id in created_ids if (
            item := self.event_delivery(delivery_id)
        ) is not None]

    def event_deliveries(
        self, *, trigger_id: str = "", state: str = "", limit: int = 100
    ) -> list[dict[str, Any]]:
        bounded = max(1, min(int(limit), 500))
        clauses: list[str] = []
        values: list[Any] = []
        if trigger_id:
            clauses.append("deliveries.trigger_id=?")
            values.append(trigger_id)
        if state:
            clauses.append("deliveries.state=?")
            values.append(state)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._lock, self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT deliveries.*, runs.state AS run_state FROM event_deliveries AS deliveries"
                " LEFT JOIN runs ON runs.id=deliveries.run_id" + where +
                " ORDER BY deliveries.received_at DESC, deliveries.created_at DESC LIMIT ?",
                (*values, bounded),
            ).fetchall()
        return [self._event_delivery_row(row) for row in rows]

    def event_delivery(self, delivery_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT deliveries.*, runs.state AS run_state FROM event_deliveries AS deliveries"
                " LEFT JOIN runs ON runs.id=deliveries.run_id WHERE deliveries.id=?",
                (delivery_id,),
            ).fetchone()
        return self._event_delivery_row(row) if row is not None else None

    def pending_event_deliveries(self, *, limit: int = 100) -> list[dict[str, Any]]:
        return list(reversed(self.event_deliveries(state="pending", limit=limit)))

    def claim_event_delivery(
        self, delivery_id: str, *, now: float | None = None
    ) -> tuple[dict[str, Any], dict[str, Any], str]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        current = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """
                SELECT deliveries.*, triggers.target_session_id, triggers.enabled AS trigger_enabled,
                    connections.enabled AS connection_enabled
                FROM event_deliveries AS deliveries
                JOIN event_triggers AS triggers ON triggers.id=deliveries.trigger_id
                JOIN connector_connections AS connections ON connections.id=triggers.connection_id
                WHERE deliveries.id=?
                """,
                (delivery_id,),
            ).fetchone()
            if row is None:
                raise RunStoreError("event delivery not found")
            if row["state"] != "pending":
                raise RunStoreError("event delivery is not pending")
            if not row["trigger_enabled"] or not row["connection_enabled"]:
                raise RunStoreError("event trigger or connector is paused")
            session_id = str(row["target_session_id"])
            claiming = connection.execute(
                """
                SELECT deliveries.id FROM event_deliveries AS deliveries
                JOIN event_triggers AS triggers ON triggers.id=deliveries.trigger_id
                WHERE triggers.target_session_id=? AND deliveries.state='claiming'
                    AND deliveries.id<>? LIMIT 1
                """,
                (session_id, delivery_id),
            ).fetchone()
            if claiming is not None:
                raise RunStoreError("the target chat is busy")
            ahead = connection.execute(
                """
                SELECT deliveries.id FROM event_deliveries AS deliveries
                JOIN event_triggers AS triggers ON triggers.id=deliveries.trigger_id
                WHERE triggers.target_session_id=? AND deliveries.state='pending'
                ORDER BY deliveries.received_at, deliveries.created_at, deliveries.id LIMIT 1
                """,
                (session_id,),
            ).fetchone()
            if ahead is None or str(ahead["id"]) != delivery_id:
                raise RunStoreError("another event is ahead of this delivery")
            active = connection.execute(
                "SELECT 1 FROM runs WHERE session_id=? AND state NOT IN"
                " ('completed','failed','interrupted','cancelled','discarded') LIMIT 1",
                (session_id,),
            ).fetchone()
            if active is not None:
                raise RunStoreError("the target chat is busy")
            attempt = int(row["attempt"] or 0)
            run_id = uuid.uuid5(
                uuid.NAMESPACE_URL, f"locus:event-delivery:{delivery_id}:{attempt}"
            ).hex
            connection.execute(
                "UPDATE event_deliveries SET state='claiming', session_id=?,"
                " updated_at=?, error=NULL WHERE id=?",
                (session_id, current, delivery_id),
            )
            connection.commit()
        trigger = self.event_trigger(str(row["trigger_id"]))
        delivery = self.event_delivery(delivery_id)
        assert trigger is not None and delivery is not None
        return trigger, delivery, run_id

    def finish_event_dispatch(
        self, delivery_id: str, *, state: str, run_id: str = "", error: str = ""
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        if state not in {"queued", "failed"}:
            raise RunStoreError("event dispatch state must be queued or failed")
        current = time.time()
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT trigger_id FROM event_deliveries WHERE id=?", (delivery_id,)
            ).fetchone()
            if row is None:
                raise RunStoreError("event delivery not found")
            connection.execute(
                "UPDATE event_deliveries SET state=?, run_id=?, error=?, updated_at=? WHERE id=?",
                (state, run_id or None, error[:4_000] or None, current, delivery_id),
            )
            connection.execute(
                "UPDATE event_triggers SET last_run_id=?, last_error=?, updated_at=? WHERE id=?",
                (run_id or None, error[:4_000] or None, current, row["trigger_id"]),
            )
        return self.event_delivery(delivery_id) or {}

    def retry_event_delivery(self, delivery_id: str) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        delivery = self.event_delivery(delivery_id)
        if delivery is None:
            raise RunStoreError("event delivery not found")
        retryable = delivery["state"] in TERMINAL_STATES or delivery["state"] == "failed"
        if not retryable:
            raise RunStoreError("only stopped event deliveries can be retried")
        with self._lock, self._connect() as connection:
            connection.execute(
                "UPDATE event_deliveries SET state='pending', attempt=attempt+1,"
                " run_id=NULL, session_id=NULL, error=NULL, updated_at=? WHERE id=?",
                (time.time(), delivery_id),
            )
        return self.event_delivery(delivery_id) or {}

    def connector_action_receipt(self, idempotency_key: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT * FROM connector_action_receipts WHERE idempotency_key=?",
                (idempotency_key,),
            ).fetchone()
        if row is None:
            return None
        return {
            "idempotency_key": row["idempotency_key"],
            "event_delivery_id": row["event_delivery_id"],
            "tool_name": row["tool_name"],
            "result": json.loads(row["result_json"] or "{}"),
            "created_at": row["created_at"],
        }

    def record_connector_action_receipt(
        self, idempotency_key: str, *, event_delivery_id: str,
        tool_name: str, result: dict[str, Any], now: float | None = None,
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", idempotency_key):
            raise RunStoreError("idempotency key is invalid")
        created = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO connector_action_receipts(
                    idempotency_key, event_delivery_id, tool_name, result_json, created_at
                ) VALUES(?, NULLIF(?, ''), ?, ?, ?)
                """,
                (
                    idempotency_key, event_delivery_id, tool_name[:160],
                    _json(sanitize_event(result)), created,
                ),
            )
        return self.connector_action_receipt(idempotency_key) or {}

    # ---------------------------------------------------------- scheduled work

    @staticmethod
    def _schedule_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "name": row["name"],
            "prompt": row["prompt"],
            "workspace_root": row["workspace_root"],
            "mode": row["mode"],
            "execution_environment": row["execution_environment"],
            "runner": row["runner"],
            "team_id": row["team_id"],
            "team_name": row["team_name"],
            "provider": row["provider"],
            "provider_account_id": row["provider_account_id"],
            "model": row["model"],
            "timezone": row["timezone"],
            "rule": json.loads(row["rule_json"] or "{}"),
            "enabled": bool(row["enabled"]),
            "next_run_at": row["next_run_at"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "last_run_at": row["last_run_at"],
            "last_run_id": row["last_run_id"],
            "last_error": row["last_error"],
        }

    @staticmethod
    def _occurrence_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "schedule_id": row["schedule_id"],
            "schedule_name": row["schedule_name"],
            "scheduled_for": row["scheduled_for"],
            "trigger": row["trigger"],
            "state": row["state"],
            "session_id": row["session_id"],
            "run_id": row["run_id"],
            "error": row["error"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def schedules(self) -> list[dict[str, Any]]:
        with self._lock, self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT * FROM schedules ORDER BY enabled DESC,"
                " COALESCE(next_run_at, 1e30), name COLLATE NOCASE"
            ).fetchall()
        return [self._schedule_row(row) for row in rows]

    def schedule(self, schedule_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT * FROM schedules WHERE id=?", (schedule_id,)
            ).fetchone()
        return self._schedule_row(row) if row is not None else None

    def schedule_occurrences(
        self, schedule_id: str, *, limit: int = 20
    ) -> list[dict[str, Any]]:
        bounded = max(1, min(int(limit), 100))
        with self._lock, self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT * FROM schedule_occurrences WHERE schedule_id=?"
                " ORDER BY scheduled_for DESC, created_at DESC LIMIT ?",
                (schedule_id, bounded),
            ).fetchall()
        return [self._occurrence_row(row) for row in rows]

    def create_schedule(
        self, value: dict[str, Any], *, now: float | None = None
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        created = float(now if now is not None else time.time())
        try:
            schedule = normalize_schedule(value, now=created)
        except ScheduleValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        schedule_id = str(value.get("id") or uuid.uuid4().hex)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", schedule_id):
            raise RunStoreError("schedule id is invalid")
        with self._lock, self._connect() as connection:
            try:
                connection.execute(
                    """
                    INSERT INTO schedules(
                        id, name, prompt, workspace_root, mode,
                        execution_environment, runner, team_id, team_name,
                        provider, provider_account_id, model, timezone,
                        rule_json, enabled, next_run_at, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        schedule_id, schedule["name"], schedule["prompt"],
                        schedule["workspace_root"], schedule["mode"],
                        schedule["execution_environment"], schedule["runner"],
                        schedule["team_id"] or None, schedule["team_name"] or None,
                        schedule["provider"], schedule["provider_account_id"] or None,
                        schedule["model"], schedule["timezone"],
                        _json(schedule["rule"]), int(schedule["enabled"]),
                        schedule["next_run_at"], created, created,
                    ),
                )
            except sqlite3.IntegrityError as exc:
                raise RunStoreError("a schedule with that id already exists") from exc
        return self.schedule(schedule_id) or {"id": schedule_id, **schedule}

    def update_schedule(
        self, schedule_id: str, updates: dict[str, Any], *, now: float | None = None
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        existing = self.schedule(schedule_id)
        if existing is None:
            raise RunStoreError("schedule not found")
        allowed = {
            "name", "prompt", "workspace_root", "mode", "execution_environment",
            "runner", "team_id", "team_name", "provider", "provider_account_id",
            "model", "timezone", "rule", "enabled",
        }
        unknown = set(updates) - allowed
        if unknown:
            raise RunStoreError(f"unknown schedule field: {sorted(unknown)[0]}")
        merged = {key: existing[key] for key in allowed}
        merged.update(updates)
        changed_timing = bool({"rule", "timezone"} & set(updates))
        reenabled = updates.get("enabled") is True and not existing["enabled"]
        disabled = updates.get("enabled") is False
        current = float(now if now is not None else time.time())
        validation_value = dict(merged)
        if not changed_timing and not reenabled and not disabled:
            # An overdue schedule must remain overdue when only its name or prompt
            # changes. Temporarily disabling it lets validation inspect the past
            # one-time rule without treating the edit as a new schedule.
            validation_value["enabled"] = False
        try:
            schedule = normalize_schedule(validation_value, now=current)
        except ScheduleValidationError as exc:
            raise RunStoreError(str(exc)) from exc
        if not changed_timing and not reenabled and not disabled:
            schedule["enabled"] = existing["enabled"]
            schedule["next_run_at"] = existing["next_run_at"]
        elif disabled:
            schedule["enabled"] = False
            schedule["next_run_at"] = existing["next_run_at"]
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                UPDATE schedules SET
                    name=?, prompt=?, workspace_root=?, mode=?,
                    execution_environment=?, runner=?, team_id=?, team_name=?,
                    provider=?, provider_account_id=?, model=?, timezone=?,
                    rule_json=?, enabled=?, next_run_at=?, updated_at=?,
                    last_error=CASE WHEN ? THEN NULL ELSE last_error END
                WHERE id=?
                """,
                (
                    schedule["name"], schedule["prompt"], schedule["workspace_root"],
                    schedule["mode"], schedule["execution_environment"],
                    schedule["runner"], schedule["team_id"] or None,
                    schedule["team_name"] or None, schedule["provider"],
                    schedule["provider_account_id"] or None, schedule["model"],
                    schedule["timezone"], _json(schedule["rule"]),
                    int(schedule["enabled"]), schedule["next_run_at"], current,
                    int(reenabled), schedule_id,
                ),
            )
        return self.schedule(schedule_id) or existing

    def delete_schedule(self, schedule_id: str) -> None:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            cursor = connection.execute("DELETE FROM schedules WHERE id=?", (schedule_id,))
            if cursor.rowcount != 1:
                raise RunStoreError("schedule not found")

    def pause_schedule(self, schedule_id: str, reason: str) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "UPDATE schedules SET enabled=0, last_error=?, updated_at=? WHERE id=?",
                (reason.strip()[:4_000] or "The schedule needs attention.", time.time(), schedule_id),
            )
            if cursor.rowcount != 1:
                raise RunStoreError("schedule not found")
        return self.schedule(schedule_id) or {}

    def claim_schedule_occurrence(
        self, schedule_id: str, *, trigger: str = "due",
        request_id: str = "", now: float | None = None,
    ) -> tuple[dict[str, Any], dict[str, Any], bool]:
        """Claim one occurrence and advance cadence before outside work begins.

        The returned boolean is true only for the caller that inserted the claim.
        A duplicate due dispatch receives the same deterministic occurrence.
        """
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        if trigger not in {"due", "manual"}:
            raise RunStoreError("trigger must be due or manual")
        current = float(now if now is not None else time.time())
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM schedules WHERE id=?", (schedule_id,)
            ).fetchone()
            if row is None:
                raise RunStoreError("schedule not found")
            schedule = self._schedule_row(row)
            if trigger == "due":
                scheduled_for = None
                zone = timezone(str(schedule["timezone"]))
                if schedule["enabled"] and schedule["next_run_at"] is not None:
                    scheduled_for = latest_due_occurrence(
                        schedule["rule"], zone,
                        earliest=float(schedule["next_run_at"]), now=current,
                    )
                if scheduled_for is None:
                    # A retry of the same dispatch may arrive after the first
                    # caller already advanced next_run_at. Return the durable
                    # occurrence instead of creating a second run or reporting
                    # a misleading not-due error.
                    recent = connection.execute(
                        "SELECT * FROM schedule_occurrences"
                        " WHERE schedule_id=? AND trigger='due'"
                        " ORDER BY scheduled_for DESC LIMIT 1",
                        (schedule_id,),
                    ).fetchone()
                    if recent is not None and float(recent["scheduled_for"]) <= current:
                        occurrence = self._occurrence_row(recent)
                        stale = (
                            occurrence["state"] == "claiming"
                            and float(occurrence["updated_at"]) < current - 300
                        )
                        if stale:
                            connection.execute(
                                "UPDATE schedule_occurrences SET updated_at=? WHERE id=?",
                                (current, occurrence["id"]),
                            )
                            connection.commit()
                            occurrence["updated_at"] = current
                        else:
                            connection.commit()
                        return schedule, occurrence, stale
                    if not schedule["enabled"] or schedule["next_run_at"] is None:
                        raise RunStoreError("schedule is paused")
                    raise RunStoreError("schedule is not due")
                occurrence_id = uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"locus:schedule:{schedule_id}:{scheduled_for:.6f}",
                ).hex
            else:
                scheduled_for = current
                clean_request_id = request_id.strip()
                if clean_request_id and not re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", clean_request_id
                ):
                    raise RunStoreError("request id is invalid")
                occurrence_id = (
                    uuid.uuid5(
                        uuid.NAMESPACE_URL,
                        f"locus:schedule:{schedule_id}:manual:{clean_request_id}",
                    ).hex
                    if clean_request_id else uuid.uuid4().hex
                )
            existing = connection.execute(
                "SELECT * FROM schedule_occurrences WHERE id=?", (occurrence_id,)
            ).fetchone()
            if existing is not None:
                connection.commit()
                return schedule, self._occurrence_row(existing), False
            connection.execute(
                """
                INSERT INTO schedule_occurrences(
                    id, schedule_id, schedule_name, scheduled_for, trigger,
                    state, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, 'claiming', ?, ?)
                """,
                (
                    occurrence_id, schedule_id, schedule["name"], scheduled_for,
                    trigger, current, current,
                ),
            )
            if trigger == "due":
                following = next_occurrence(schedule["rule"], zone, after=current)
                enabled = following is not None
                connection.execute(
                    """
                    UPDATE schedules SET enabled=?, next_run_at=?, last_run_at=?,
                        last_error=NULL, updated_at=? WHERE id=?
                    """,
                    (int(enabled), following, current, current, schedule_id),
                )
            else:
                connection.execute(
                    "UPDATE schedules SET last_run_at=?, last_error=NULL, updated_at=? WHERE id=?",
                    (current, current, schedule_id),
                )
            connection.commit()
            updated = connection.execute(
                "SELECT * FROM schedules WHERE id=?", (schedule_id,)
            ).fetchone()
            occurrence = connection.execute(
                "SELECT * FROM schedule_occurrences WHERE id=?", (occurrence_id,)
            ).fetchone()
        assert updated is not None and occurrence is not None
        return self._schedule_row(updated), self._occurrence_row(occurrence), True

    def finish_schedule_occurrence(
        self, occurrence_id: str, *, state: str, session_id: str = "",
        run_id: str = "", error: str = "",
    ) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        if state not in {"queued", "failed", "skipped"}:
            raise RunStoreError("occurrence state must be queued, failed or skipped")
        current = time.time()
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM schedule_occurrences WHERE id=?", (occurrence_id,)
            ).fetchone()
            if row is None:
                raise RunStoreError("schedule occurrence not found")
            occurrence = self._occurrence_row(row)
            connection.execute(
                """
                UPDATE schedule_occurrences SET state=?, session_id=?, run_id=?,
                    error=?, updated_at=? WHERE id=?
                """,
                (
                    state, session_id or None, run_id or None, error[:4_000] or None,
                    current, occurrence_id,
                ),
            )
            if state != "skipped":
                # A skipped occurrence is a healthy overlap, not a failure: it
                # must not overwrite the schedule's last run or raise its
                # error, which is what the agent's status is read from.
                connection.execute(
                    "UPDATE schedules SET last_run_id=?, last_error=?, updated_at=? WHERE id=?",
                    (
                        run_id or None, error[:4_000] or None, current,
                        occurrence["schedule_id"],
                    ),
                )
            updated = connection.execute(
                "SELECT * FROM schedule_occurrences WHERE id=?", (occurrence_id,)
            ).fetchone()
        assert updated is not None
        return self._occurrence_row(updated)

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
            "run_kind": row["run_kind"], "trace_id": row["trace_id"],
            "root_span_id": row["root_span_id"],
            "content_policy": row["content_policy"],
            "execution_environment": row["execution_environment"],
            "export_state": row["export_state"],
            "export_attempts": int(row["export_attempts"] or 0),
            "exported_at": row["exported_at"],
            "queue_position": row["queue_position"],
            "queued_message_id": row["queued_message_id"],
            "retry_parent_id": row["retry_parent_id"],
            "admitted_at": row["admitted_at"],
            "schedule_id": row["schedule_id"],
            "occurrence_id": row["occurrence_id"],
            "scheduled_for": row["scheduled_for"],
        }

    def queue_run(
        self, run_id: str, *, session_id: str, message_id: str = "",
        team_id: str = "", team_name: str = "",
        workspace_root: str = "", execution_path: str = "", request: str = "",
        run_kind: str = "solo", execution_environment: str = "local",
        retry_parent_id: str = "", manifest: dict[str, Any] | None = None,
        schedule_id: str = "", occurrence_id: str = "",
        scheduled_for: float | None = None,
    ) -> dict[str, Any]:
        """Reserve one durable FIFO slot before a chat worker is admitted."""
        with self._lock:
            with self._connect(readonly=self.read_only) as connection:
                position = int(connection.execute(
                    "SELECT COALESCE(MAX(queue_position), 0) + 1"
                    " FROM runs WHERE state='queued'"
                ).fetchone()[0])
            # The re-entrant store lock keeps the position calculation and
            # reservation ordered even when two app windows queue together.
            self.start_run(
                run_id, session_id=session_id, team_id=team_id, team_name=team_name,
                workspace_root=workspace_root,
                execution_path=execution_path, request=request, state="queued",
                run_kind=run_kind, execution_environment=execution_environment,
                manifest=manifest, schedule_id=schedule_id,
                occurrence_id=occurrence_id, scheduled_for=scheduled_for,
            )
            if not self.read_only:
                with self._connect() as connection:
                    connection.execute(
                        "UPDATE runs SET queue_position=?, queued_message_id=?,"
                        " retry_parent_id=? WHERE id=?",
                        (position, message_id[:160], retry_parent_id[:160] or None, run_id),
                    )
        return self.run(run_id) or {}

    def queue_run_if_idle(self, run_id: str, *, session_id: str, **fields: Any) -> dict[str, Any]:
        """Queue a run only while the chat has nothing in flight.

        The check and the reservation share the store lock, so a due tick and
        a Run Now arriving together cannot both put a turn into one chat.
        """
        with self._lock:
            if self.session_has_active_run(session_id):
                raise RunStoreError("the chat is busy")
            return self.queue_run(run_id, session_id=session_id, **fields)

    def session_has_active_run(self, session_id: str) -> bool:
        """Whether a run with a live owner is working in this chat.

        A paused or interrupted run is waiting for a person, not working: it
        must not count, or one unattended pause would silence a scheduled
        agent for as long as the app stays open.
        """
        if not session_id:
            return False
        active = sorted(ACTIVE_NONRECOVERABLE_STATES | {"waiting_dispatch_approval"})
        places = ",".join("?" * len(active))
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                f"SELECT 1 FROM runs WHERE session_id=? AND state IN ({places}) LIMIT 1",
                (session_id, *active),
            ).fetchone()
        return row is not None

    def rearm_schedule_slot(self, schedule_id: str, *, next_run_at: float) -> dict[str, Any]:
        """Put back a slot whose occurrence was skipped rather than run.

        Claiming an occurrence advances the cadence before the chat is known
        to be free, and for a one-shot schedule that also switches it off. A
        skip would otherwise drop the only run and leave the agent looking as
        though a person had paused it.
        """
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "UPDATE schedules SET enabled=1, next_run_at=?, last_error=NULL,"
                " updated_at=? WHERE id=?",
                (float(next_run_at), time.time(), schedule_id),
            )
            if cursor.rowcount != 1:
                raise RunStoreError("schedule not found")
        return self.schedule(schedule_id) or {}

    def reorder_queue(self, run_id: str, action: str) -> dict[str, Any]:
        if self.read_only:
            raise RunStoreError("the run database is read-only")
        with self._lock, self._connect() as connection:
            rows = connection.execute(
                "SELECT id, session_id FROM runs WHERE state='queued'"
                " ORDER BY queue_position, created_at"
            ).fetchall()
            identifiers = [str(row[0]) for row in rows]
            sessions = {str(row[0]): str(row[1] or "") for row in rows}
            if run_id not in identifiers:
                raise RunStoreError("queued run not found")
            index = identifiers.index(run_id)
            if action == "move_top":
                session_id = sessions[run_id]
                earlier_same_session = [
                    position for position, identifier in enumerate(identifiers[:index])
                    if session_id and sessions[identifier] == session_id
                ]
                destination = earlier_same_session[-1] + 1 if earlier_same_session else 0
                identifiers.insert(destination, identifiers.pop(index))
            elif action == "move_up" and index > 0:
                previous = identifiers[index - 1]
                if not sessions[run_id] or sessions[previous] != sessions[run_id]:
                    identifiers[index - 1], identifiers[index] = (
                        identifiers[index], identifiers[index - 1]
                    )
            elif action == "move_down" and index + 1 < len(identifiers):
                following = identifiers[index + 1]
                if not sessions[run_id] or sessions[following] != sessions[run_id]:
                    identifiers[index + 1], identifiers[index] = (
                        identifiers[index], identifiers[index + 1]
                    )
            elif action == "cancel":
                connection.execute(
                    "UPDATE runs SET state='cancelled', completed_at=?, queue_position=NULL,"
                    " updated_at=? WHERE id=?", (time.time(), time.time(), run_id),
                )
                identifiers.remove(run_id)
            elif action not in {"move_top", "move_up", "move_down", "cancel"}:
                raise RunStoreError("unknown queue action")
            connection.executemany(
                "UPDATE runs SET queue_position=?, updated_at=? WHERE id=?",
                ((position, time.time(), identifier)
                 for position, identifier in enumerate(identifiers, 1)),
            )
        return self.run(run_id) or {}

    def admit(self, run_id: str) -> None:
        if self.read_only:
            return
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE runs SET state='dispatching', admitted_at=?, queue_position=NULL,"
                " updated_at=? WHERE id=? AND state='queued'",
                (time.time(), time.time(), run_id),
            )
            if cursor.rowcount != 1:
                raise RunStoreError("queued run not found")

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
                # A run that never acquired an execution slot is still a
                # durable queue reservation. Preserve its state and position
                # so the next app process can admit it in the same order.
                if str(row["state"]) == "queued":
                    continue
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

    def record_turn_usage(
        self, *, session_id: str, workspace_root: str = "", provider: str = "",
        model: str = "", account: str = "", kind: str = "solo",
        prompt_tokens: int = 0, completion_tokens: int = 0,
    ) -> None:
        """Persist one solo turn's token spend. Counts only — never content."""
        if self.read_only:
            return
        with self._connect() as connection:
            connection.execute(
                """INSERT INTO turn_usage(
                    session_id, workspace_root, provider, model, account, kind,
                    prompt_tokens, completion_tokens, occurred_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (session_id, workspace_root, provider, model, account,
                 kind if kind in {"solo", "evaluation"} else "solo",
                 max(int(prompt_tokens), 0), max(int(completion_tokens), 0),
                 time.time()),
            )

    def usage_summary(self, *, since: float = 0.0) -> dict[str, Any]:
        """Roll up recorded spend. Pure reads, so it works on a read-only store."""
        with self._connect(readonly=True) as connection:
            orchestration = dict(connection.execute(
                """SELECT COUNT(*) AS runs,
                          COALESCE(SUM(json_extract(usage_json,'$.model_calls')), 0) AS model_calls,
                          COALESCE(SUM(json_extract(usage_json,'$.metered_tokens')), 0) AS metered_tokens,
                          COALESCE(SUM(json_extract(usage_json,'$.estimated_cost')), 0) AS estimated_cost
                   FROM runs WHERE legacy=0 AND created_at >= ?""",
                (since,),
            ).fetchone())
            by_day = [dict(row) for row in connection.execute(
                """SELECT strftime('%Y-%m-%d', created_at, 'unixepoch', 'localtime') AS day,
                          COUNT(*) AS runs,
                          COALESCE(SUM(json_extract(usage_json,'$.metered_tokens')), 0) AS metered_tokens,
                          COALESCE(SUM(json_extract(usage_json,'$.estimated_cost')), 0) AS estimated_cost
                   FROM runs WHERE legacy=0 AND created_at >= ?
                   GROUP BY day ORDER BY day DESC LIMIT 120""",
                (since,),
            ).fetchall()]
            by_workspace = [dict(row) for row in connection.execute(
                """SELECT COALESCE(workspace_root, '') AS workspace_root,
                          COUNT(*) AS runs,
                          COALESCE(SUM(json_extract(usage_json,'$.estimated_cost')), 0) AS estimated_cost
                   FROM runs WHERE legacy=0 AND created_at >= ?
                   GROUP BY workspace_root ORDER BY estimated_cost DESC LIMIT 50""",
                (since,),
            ).fetchall()]
            by_model = [dict(row) for row in connection.execute(
                """SELECT COALESCE(a.provider, '') AS provider,
                          COALESCE(a.model, '') AS model,
                          COUNT(*) AS attempts,
                          COALESCE(SUM(json_extract(a.result_json,'$.prompt_tokens')), 0) AS prompt_tokens,
                          COALESCE(SUM(json_extract(a.result_json,'$.completion_tokens')), 0) AS completion_tokens
                   FROM job_attempts a JOIN runs r ON r.id = a.run_id
                   WHERE r.legacy=0 AND r.created_at >= ?
                   GROUP BY provider, model ORDER BY prompt_tokens + completion_tokens DESC
                   LIMIT 50""",
                (since,),
            ).fetchall()]
            by_agent = [dict(row) for row in connection.execute(
                """SELECT agent_id, COUNT(*) AS samples,
                          COALESCE(SUM(estimated_cost), 0) AS estimated_cost,
                          MAX(local) AS local
                   FROM routing_samples WHERE occurred_at >= ?
                   GROUP BY agent_id ORDER BY estimated_cost DESC LIMIT 50""",
                (since,),
            ).fetchall()]
            evaluations = dict(connection.execute(
                """SELECT COUNT(*) AS cases,
                          COALESCE(SUM(json_extract(payload_json,'$.estimated_cost')), 0) AS estimated_cost
                   FROM evaluation_results
                   WHERE state IN ('passed', 'failed') AND created_at >= ?""",
                (since,),
            ).fetchone())
            try:
                solo = dict(connection.execute(
                    """SELECT COUNT(*) AS turns,
                              COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
                              COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
                              MIN(occurred_at) AS recorded_since
                       FROM turn_usage WHERE kind='solo' AND occurred_at >= ?""",
                    (since,),
                ).fetchone())
            except sqlite3.OperationalError:
                # A store that failed the v4 migration reopens read-only
                # without the turn_usage table; the run rollups above still
                # serve, and an empty solo section is the honest answer.
                solo = {
                    "turns": 0, "prompt_tokens": 0, "completion_tokens": 0,
                    "recorded_since": None,
                }
            expensive = [dict(row) for row in connection.execute(
                """SELECT id, team_name, workspace_root, created_at, state,
                          COALESCE(json_extract(usage_json,'$.estimated_cost'), 0) AS estimated_cost
                   FROM runs WHERE legacy=0 AND created_at >= ?
                   ORDER BY estimated_cost DESC, created_at DESC LIMIT 10""",
                (since,),
            ).fetchall()]
        by_agent = [
            {**row, "local": bool(row.get("local"))} for row in by_agent
        ]
        return {
            "since": since,
            "generated_at": time.time(),
            "read_only": self.read_only,
            "orchestration": orchestration,
            "by_day": by_day,
            "by_workspace": by_workspace,
            "by_model": by_model,
            "by_agent": by_agent,
            "evaluations": evaluations,
            "solo": solo,
            "expensive_runs": expensive,
        }

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
