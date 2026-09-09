"""Durable supervisor state. Credentials never enter the run database."""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


def identifier(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,159}", value):
        raise ValueError("Invalid runtime identifier")
    return value


def initialize_schema(db: sqlite3.Connection) -> None:
    db.executescript("""
        CREATE TABLE IF NOT EXISTS runtime_workers (
            session_id TEXT PRIMARY KEY, workspace TEXT NOT NULL, keep_running INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'idle', payload TEXT NOT NULL DEFAULT '{}', updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS runtime_events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, payload TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS runtime_event_session ON runtime_events(session_id,seq);
        CREATE TABLE IF NOT EXISTS runtime_commands (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued', created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS runtime_decisions (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL, fingerprint TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'waiting', response TEXT, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS runtime_automations (
            kind TEXT NOT NULL, automation_id TEXT NOT NULL, keep_running INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(kind,automation_id)
        );
        CREATE TABLE IF NOT EXISTS runtime_deployments (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at REAL NOT NULL
        );
    """)


class PrivateStore:
    """User-only service configuration; atomic writes, never included in exports."""

    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = root / "runtime-secrets.json"
        self.lock = threading.RLock()

    def read(self) -> dict[str, Any]:
        with self.lock:
            if not self.path.exists():
                return {}
            if self.path.is_symlink() or self.path.stat().st_mode & 0o077:
                raise ValueError("Runtime credentials must be a user-only regular file")
            return json.loads(self.path.read_text())

    def set(self, key: str, value: Any) -> None:
        with self.lock:
            data = self.read()
            if value is None:
                data.pop(key, None)
            else:
                data[key] = value
            fd, temporary = tempfile.mkstemp(prefix=".runtime-", dir=self.root)
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump(data, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)

    def token(self) -> str:
        with self.lock:
            value = self.read().get("controller_token")
            if not value:
                value = secrets.token_hex(32)
                self.set("controller_token", value)
            return str(value)


class RuntimeStore:
    def __init__(self, runs):
        self.runs = runs

    def worker(self, session_id: str) -> dict[str, Any] | None:
        with self.runs._connect(readonly=True) as db:
            row = db.execute("SELECT * FROM runtime_workers WHERE session_id=?", (session_id,)).fetchone()
        return {**self._worker(row), "interrupted_commands": self.commands(session_id, "uncertain")} if row else None

    @staticmethod
    def _worker(row) -> dict[str, Any]:
        return {**dict(row), "keep_running": bool(row["keep_running"]), "configuration": json.loads(row["payload"]), "waiting_reason": json.loads(row["payload"]).get("waiting_reason")}

    def workers(self) -> list[dict[str, Any]]:
        with self.runs._connect(readonly=True) as db:
            rows = [self._worker(row) for row in db.execute("SELECT * FROM runtime_workers ORDER BY updated_at")]
        return [{**row, "interrupted_commands": self.commands(row["session_id"], "uncertain")} for row in rows]

    def save_worker(self, session_id: str, workspace: str, *, keep_running: bool | None = None,
                    state: str | None = None, configuration: dict | None = None) -> dict:
        identifier(session_id)
        root = Path(workspace).expanduser().resolve()
        if not root.is_dir():
            raise ValueError("The execution workspace is unavailable")
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM runtime_workers WHERE session_id=?", (session_id,)).fetchone()
            if row and row["workspace"] != str(root):
                raise ValueError("A runtime session cannot silently change its workspace")
            db.execute("INSERT INTO runtime_workers VALUES(?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET "
                       "keep_running=excluded.keep_running,state=excluded.state,payload=excluded.payload,updated_at=excluded.updated_at",
                       (session_id, str(root), int(keep_running if keep_running is not None else bool(row and row["keep_running"])),
                        state or (row["state"] if row else "idle"),
                        json.dumps(configuration) if configuration is not None else (row["payload"] if row else "{}"), time.time()))
        return self.worker(session_id)

    def state(self, session_id: str, state: str, reason: str = "") -> None:
        with self.runs._connect() as db:
            db.execute("UPDATE runtime_workers SET state=?,payload=json_set(payload,'$.waiting_reason',?),updated_at=? WHERE session_id=?", (state, reason, time.time(), session_id))

    def append(self, session_id: str, event: dict) -> dict:
        from .runstore import sanitize_event
        safe = sanitize_event(event)
        with self.runs._connect() as db:
            cursor = db.execute("INSERT INTO runtime_events(session_id,payload,created_at) VALUES(?,?,?)",
                                (session_id, json.dumps(safe), time.time()))
            seq = cursor.lastrowid
        return {**safe, "runtime_seq": seq, "runtime_session_id": session_id}

    def events(self, session_id: str, after: int = 0, limit: int = 500) -> list[dict]:
        with self.runs._connect(readonly=True) as db:
            rows = db.execute("SELECT seq,payload FROM runtime_events WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?",
                              (session_id, max(after, 0), min(max(limit, 1), 1000))).fetchall()
        return [{**json.loads(row["payload"]), "runtime_seq": row["seq"], "runtime_session_id": session_id} for row in rows]

    def enqueue(self, session_id: str, command: dict) -> str:
        key = identifier(str(command.get("request_id") or command.get("run_id") or secrets.token_hex(16)))
        payload = json.dumps(command, sort_keys=True)
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT session_id,payload FROM runtime_commands WHERE id=?", (key,)).fetchone()
            if previous and (previous["session_id"] != session_id or previous["payload"] != payload):
                raise ValueError("This request ID already identifies different work")
            db.execute("INSERT OR IGNORE INTO runtime_commands VALUES(?,?,?,'queued',?)", (key, session_id, payload, time.time()))
        return key

    def commands(self, session_id: str, state: str = "queued") -> list[dict]:
        with self.runs._connect(readonly=True) as db:
            rows = db.execute("SELECT * FROM runtime_commands WHERE session_id=? AND state=? ORDER BY created_at,id",
                              (session_id, state)).fetchall()
        return [{**dict(row), "command": json.loads(row["payload"])} for row in rows]

    def command_state(self, key: str, state: str) -> None:
        with self.runs._connect() as db:
            db.execute("UPDATE runtime_commands SET state=? WHERE id=?", (state, key))

    def decision(self, session_id: str, event: dict) -> dict:
        from .runstore import sanitize_event
        fingerprint = hashlib.sha256(json.dumps(event, sort_keys=True).encode()).hexdigest()
        payload = json.dumps(sanitize_event(event), sort_keys=True)
        key = f"{session_id}:{fingerprint}"
        with self.runs._connect() as db:
            db.execute("INSERT OR IGNORE INTO runtime_decisions VALUES(?,?,?,?,'waiting',NULL,?)",
                       (key, session_id, payload, fingerprint, time.time()))
        return {"id": key, "fingerprint": fingerprint, "event": event}

    def decisions(self, session_id: str = "", *, include_inflight=False) -> list[dict]:
        with self.runs._connect(readonly=True) as db:
            rows = db.execute("SELECT * FROM runtime_decisions WHERE (state='waiting' OR (? AND state IN ('executing','uncertain'))) AND (?='' OR session_id=?) ORDER BY created_at",
                              (int(include_inflight), session_id, session_id)).fetchall()
        return [{**dict(row), "event": json.loads(row["payload"])} for row in rows]

    def claim_native(self, session_id: str, key: str, fingerprint: str):
        from .runtime import NATIVE_EVENTS
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM runtime_decisions WHERE id=?", (key,)).fetchone()
            if not row or row['session_id'] != session_id or row['fingerprint'] != fingerprint or row['state'] != 'waiting' or json.loads(row['payload']).get('type') not in NATIVE_EVENTS:
                raise ValueError('This native operation is already claimed or needs review. It must not be replayed.')
            db.execute("UPDATE runtime_decisions SET state='executing' WHERE id=?", (key,))
        return {"ok": True}

    def broker_left(self, session_id: str):
        with self.runs._connect() as db:
            changed = db.execute("UPDATE runtime_decisions SET state='uncertain' WHERE session_id=? AND state='executing'", (session_id,)).rowcount
            if changed:
                reason = "A desktop action has an uncertain outcome. Review its effects, then stop this agent before allowing new work."
                db.execute("UPDATE runtime_workers SET state='waiting_for_locus',payload=json_set(payload,'$.waiting_reason',?) WHERE session_id=?", (reason, session_id))

    def resolve(self, key: str, fingerprint: str, response: dict) -> str:
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM runtime_decisions WHERE id=?", (key,)).fetchone()
            from .runtime import NATIVE_EVENTS
            allowed_states = {"executing", "uncertain"} if row and json.loads(row["payload"]).get("type") in NATIVE_EVENTS else {"waiting"}
            if not row or row["fingerprint"] != fingerprint or row["state"] not in allowed_states:
                raise ValueError("This decision is no longer current")
            from .runstore import sanitize_event
            saved_response = sanitize_event(response)
            if json.loads(row["payload"]).get("type") in {"identity_context_request", "identity_action_request"}:
                saved_response = {"type": response.get("type"), "request_id": response.get("request_id"), "result": "[private result omitted]"}
            db.execute("UPDATE runtime_decisions SET state='sending',response=? WHERE id=?", (json.dumps(saved_response), key))
            return row["session_id"]

    def interrupted(self, session_id: str) -> None:
        with self.runs._connect() as db:
            db.execute("UPDATE runtime_commands SET state='uncertain' WHERE session_id=? AND state='sent'", (session_id,))
            db.execute("UPDATE runtime_decisions SET state='interrupted' WHERE session_id=? AND state IN ('waiting','sending','executing','uncertain')", (session_id,))
            db.execute("UPDATE runtime_workers SET state='interrupted' WHERE session_id=?", (session_id,))

    def automation_enabled(self, kind: str, key: str) -> bool:
        with self.runs._connect(readonly=True) as db:
            row = db.execute("SELECT keep_running FROM runtime_automations WHERE kind=? AND automation_id=?", (kind, key)).fetchone()
        return bool(row and row[0])

    def set_automation(self, kind: str, key: str, enabled: bool) -> None:
        if kind not in {"schedule", "event", "goal"}:
            raise ValueError("Unknown automation kind")
        with self.runs._connect() as db:
            db.execute("INSERT INTO runtime_automations VALUES(?,?,?) ON CONFLICT(kind,automation_id) DO UPDATE SET keep_running=excluded.keep_running",
                       (kind, identifier(key), int(enabled)))
