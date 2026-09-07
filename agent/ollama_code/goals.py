"""Durable conversation objectives and trusted execution accounting.

Goals share the run database, but their accounting and evidence outlive run
retention. All admission and accounting decisions use SQLite write transactions
because the control service and individual chat workers are separate processes.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import uuid
from collections.abc import Callable
from contextlib import nullcontext
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .runstore import RunStore


class GoalError(RuntimeError):
    pass


class GoalBudgetExceeded(GoalError):
    pass


TERMINAL = {"completed", "cancelled"}
RUN_TERMINAL = {"completed", "failed", "interrupted", "cancelled", "discarded"}
LIVE_RUNS = {"queued", "dispatching", "running", "reviewing", "pausing",
             "waiting_permission", "waiting_computer", "waiting_dispatch_approval"}


def initialize_schema(connection: sqlite3.Connection) -> None:
    connection.executescript("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS goals (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, objective TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1, execution_revision INTEGER NOT NULL DEFAULT 1,
            status TEXT NOT NULL DEFAULT 'active',
            reason TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
            evidence_json TEXT NOT NULL DEFAULT '[]', next_step TEXT NOT NULL DEFAULT '',
            model_call_budget INTEGER, token_budget INTEGER,
            model_calls INTEGER NOT NULL DEFAULT 0, prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            execution_json TEXT NOT NULL DEFAULT '{}', current_run_id TEXT,
            continuation_ordinal INTEGER NOT NULL DEFAULT 0,
            no_progress_count INTEGER NOT NULL DEFAULT 0, progress_fingerprint TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS goals_one_unfinished_session
            ON goals(session_id) WHERE status NOT IN ('completed','cancelled');
        CREATE INDEX IF NOT EXISTS goals_status_idx ON goals(status, updated_at);
        CREATE TABLE IF NOT EXISTS goal_runs (
            run_id TEXT PRIMARY KEY, goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
            revision INTEGER NOT NULL, ordinal INTEGER NOT NULL, report_json TEXT,
            reconciled INTEGER NOT NULL DEFAULT 0, automatic INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL,
            UNIQUE(goal_id, ordinal)
        );
        CREATE TABLE IF NOT EXISTS goal_usage (
            goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
            run_id TEXT NOT NULL, call_id TEXT NOT NULL, state TEXT NOT NULL,
            model_calls INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0,
            reserved_tokens INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL,
            tokens_known INTEGER NOT NULL DEFAULT 1, model_calls_known INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY(goal_id,run_id,call_id)
        );
        CREATE TABLE IF NOT EXISTS goal_actions (
            goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
            run_id TEXT NOT NULL, action_id TEXT NOT NULL, tool TEXT NOT NULL,
            read_only INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL, ok INTEGER,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            PRIMARY KEY(goal_id,run_id,action_id)
        );
        CREATE TABLE IF NOT EXISTS goal_inputs (
            goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
            input_id TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0,
            owner_pid INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, PRIMARY KEY(goal_id,input_id)
        );
        UPDATE schema_meta SET version=13 WHERE singleton=1;
        COMMIT;
    """)


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _text(value: Any, name: str, maximum: int, *, required: bool = False) -> str:
    if not isinstance(value, str):
        raise GoalError(f"{name} must be text")
    value = value.strip()
    if (required and not value) or len(value) > maximum:
        raise GoalError(f"{name} must contain {'1' if required else '0'}–{maximum} characters")
    return value


def _count(value: Any, name: str, *, optional: bool = False) -> int | None:
    if value is None and optional:
        return None
    if not isinstance(value, int) or isinstance(value, bool) or value < (1 if optional else 0):
        raise GoalError(f"{name} must be a {'positive' if optional else 'nonnegative'} integer")
    if value > 2**53 - 1:
        raise GoalError(f"{name} is too large")
    return value


def _execution(value: Any) -> dict[str, Any]:
    from .runstore import sanitize_event
    if not isinstance(value, dict):
        raise GoalError("execution must be an object")
    allowed = {"provider", "provider_account_id", "model", "runner", "team_id", "team_name",
               "workspace_root", "execution_path", "execution_environment", "agent_config",
               "team_manifest", "team_configuration", "solo_swarm"}
    result = sanitize_event({key: item for key, item in value.items() if key in allowed})
    for key in ("provider", "model", "workspace_root"):
        result[key] = _text(result.get(key, ""), key, 4096, required=True)
    if not os.path.isabs(result["workspace_root"]):
        raise GoalError("workspace_root must be absolute")
    result["runner"] = result.get("runner", "solo")
    if not isinstance(result["runner"], str):
        raise GoalError("runner must be text")
    if result["runner"] not in {"solo", "team"}:
        raise GoalError("persistent goals support ordinary solo or team chats")
    if result["runner"] == "team" and not result.get("team_id"):
        raise GoalError("team_id is required for a team goal")
    for key in ("provider_account_id", "team_id", "team_name", "execution_path"):
        if result.get(key) is not None:
            result[key] = _text(result[key], key, 4096)
    if result["provider"] != "ollama":
        try:
            uuid.UUID(result.get("provider_account_id") or "")
        except (ValueError, TypeError, AttributeError) as error:
            raise GoalError("choose an exact saved model account for this goal") from error
    if "agent_config" in result and not isinstance(result["agent_config"], dict):
        raise GoalError("agent_config must be an object")
    if str(result.get("team_id", "")).startswith("capsule-"):
        raise GoalError("task capsules cannot run as persistent goals")
    result["execution_environment"] = result.get("execution_environment", "local")
    if not isinstance(result["execution_environment"], str):
        raise GoalError("execution_environment must be text")
    if result["execution_environment"] not in {"local", "worktree"}:
        raise GoalError("unknown execution environment")
    if len(_json(result)) > 240_000:
        raise GoalError("execution configuration is too large")
    return result


class GoalStore:
    def __init__(self, run_store: RunStore):
        self.run_store = run_store

    def _write(self) -> sqlite3.Connection:
        if self.run_store.read_only:
            raise GoalError("the goal database is read-only")
        connection = self.run_store._connect()
        connection.execute("BEGIN IMMEDIATE")
        return connection

    @staticmethod
    def _row(connection: sqlite3.Connection, goal_id: str) -> sqlite3.Row:
        row = connection.execute("SELECT * FROM goals WHERE id=?", (goal_id,)).fetchone()
        if row is None:
            raise GoalError("goal not found")
        return row

    @staticmethod
    def _present(connection: sqlite3.Connection, row: sqlite3.Row) -> dict[str, Any]:
        value = dict(row)
        value["evidence"] = json.loads(value.pop("evidence_json"))
        value["execution"] = json.loads(value.pop("execution_json"))
        value.pop("progress_fingerprint", None)
        count = connection.execute(
            "SELECT COUNT(*) FROM goal_inputs WHERE goal_id=? AND consumed=0", (row["id"],)
        ).fetchone()[0]
        value["pending_input_count"] = count
        value["pending_user_input"] = count > 0
        known = connection.execute("SELECT COALESCE(MIN(tokens_known),1),COALESCE(MIN(model_calls_known),1)"
                                   " FROM goal_usage WHERE goal_id=?", (row["id"],)).fetchone()
        value["token_usage_available"], value["model_call_usage_available"] = bool(known[0]), bool(known[1])
        return value

    def get(self, goal_id: str) -> dict[str, Any] | None:
        with self.run_store._connect(readonly=True) as connection:
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='goals'").fetchone():
                return None
            row = connection.execute("SELECT * FROM goals WHERE id=?", (goal_id,)).fetchone()
            return self._present(connection, row) if row else None

    def for_session(self, session_id: str) -> dict[str, Any] | None:
        with self.run_store._connect(readonly=True) as connection:
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='goals'").fetchone():
                return None
            row = connection.execute(
                "SELECT * FROM goals WHERE session_id=? ORDER BY"
                " CASE WHEN status IN ('completed','cancelled') THEN 1 ELSE 0 END, created_at DESC LIMIT 1",
                (session_id,),
            ).fetchone()
            return self._present(connection, row) if row else None

    def for_run(self, run_id: str) -> dict[str, Any] | None:
        with self.run_store._connect(readonly=True) as connection:
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='goals'").fetchone():
                return None
            row = connection.execute(
                "SELECT goals.* FROM goals JOIN goal_runs ON goals.id=goal_runs.goal_id"
                " WHERE goal_runs.run_id=?", (run_id,),
            ).fetchone()
            return self._present(connection, row) if row else None

    def list(self, *, nonterminal: bool = False) -> list[dict[str, Any]]:
        with self.run_store._connect(readonly=True) as connection:
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='goals'").fetchone():
                return []
            rows = connection.execute(
                "SELECT * FROM goals" + (" WHERE status NOT IN ('completed','cancelled')" if nonterminal else "")
                + " ORDER BY updated_at DESC"
            ).fetchall()
            return [self._present(connection, row) for row in rows]

    def create(self, session_id: str, objective: str, *, execution: dict[str, Any],
               model_call_budget: int | None = None, token_budget: int | None = None) -> dict[str, Any]:
        session_id = _text(session_id, "session_id", 160, required=True)
        objective = _text(objective, "objective", 32_000, required=True)
        execution = _execution(execution)
        calls = _count(model_call_budget, "model_call_budget", optional=True)
        tokens = _count(token_budget, "token_budget", optional=True)
        now, goal_id = time.time(), uuid.uuid4().hex
        try:
            with self._write() as connection:
                connection.execute(
                    "INSERT INTO goals(id,session_id,objective,execution_json,model_call_budget,token_budget,created_at,updated_at)"
                    " VALUES(?,?,?,?,?,?,?,?)", (goal_id, session_id, objective, _json(execution), calls, tokens, now, now),
                )
                return self._present(connection, self._row(connection, goal_id))
        except sqlite3.IntegrityError as error:
            raise GoalError("this chat already has an unfinished goal") from error

    @staticmethod
    def _revision(row: sqlite3.Row, expected: Any, *, required: bool = True) -> None:
        if expected is None and not required:
            return
        if not isinstance(expected, int) or isinstance(expected, bool) or expected != row["revision"]:
            raise GoalError("the goal changed; refresh it before trying again")

    def update(self, goal_id: str, action: str, *, expected_revision: int | None = None,
               **fields: Any) -> dict[str, Any]:
        if action not in {"pause", "resume", "cancel", "edit", "block", "steer", "discard_input"}:
            raise GoalError("unknown goal action")
        with self._write() as connection:
            row = self._row(connection, goal_id)
            self._revision(row, expected_revision, required=action == "edit")
            if row["status"] in TERMINAL:
                if action == "cancel" and row["status"] == "cancelled":
                    return self._present(connection, row)
                raise GoalError("this goal has ended; create a new goal")
            if action == "steer":
                input_id = _text(fields.get("input_id") or uuid.uuid4().hex, "input_id", 160, required=True)
                cursor = connection.execute(
                    "INSERT OR IGNORE INTO goal_inputs(goal_id,input_id,owner_pid,created_at) VALUES(?,?,?,?)",
                    (goal_id, input_id, os.getpid(), time.time()),
                )
                if cursor.rowcount == 0:
                    return self._present(connection, row)
            if action == "discard_input":
                input_id = _text(fields.get("input_id", ""), "input_id", 160, required=True)
                cursor = connection.execute("UPDATE goal_inputs SET consumed=1 WHERE goal_id=? AND input_id=? AND consumed=0", (goal_id, input_id))
                if not cursor.rowcount:
                    return self._present(connection, row)
            updates: dict[str, Any] = {"revision": row["revision"] + 1, "updated_at": time.time()}
            if action not in {"steer", "discard_input"}:
                updates["execution_revision"] = updates["revision"]
            if action == "edit":
                updates["status"] = "paused"
                updates["reason"] = "The goal was edited. Resume it when ready."
                for key in ("objective", "execution", "model_call_budget", "token_budget"):
                    if key not in fields:
                        continue
                    if key == "objective":
                        updates[key] = _text(fields[key], key, 32_000, required=True)
                    elif key == "execution":
                        updates["execution_json"] = _json(_execution(fields[key]))
                    else:
                        updates[key] = _count(fields[key], key, optional=True)
            elif action not in {"steer", "discard_input"}:
                updates["status"] = {"pause": "paused", "resume": "active", "cancel": "cancelled", "block": "blocked"}[action]
                updates["reason"] = _text(fields.get("reason", ""), "reason", 4000)
            if action in {"edit", "steer", "discard_input", "pause", "cancel", "block"}:
                connection.execute("UPDATE goal_runs SET report_json=NULL WHERE goal_id=? AND reconciled=0", (goal_id,))
                automatic_only = " AND EXISTS(SELECT 1 FROM goal_runs WHERE goal_runs.run_id=runs.id AND automatic=1)" if action in {"steer", "discard_input"} else ""
                connection.execute(
                    "UPDATE runs SET state='cancelled',completed_at=?,updated_at=?,queue_position=NULL"
                    " WHERE id=? AND state='queued'" + automatic_only, (time.time(), time.time(), row["current_run_id"]),
                )
            if action == "resume":
                # An explicit resume acknowledges uncertain previous work. Keep
                # its charged usage; never reset an allowance on retry.
                connection.execute(
                    "UPDATE goal_usage SET state='acknowledged',tokens_known=0,model_calls_known=0"
                    " WHERE goal_id=? AND state='reserved'", (goal_id,),
                )
                connection.execute("UPDATE goal_actions SET state='acknowledged' WHERE goal_id=? AND state='started'", (goal_id,))
                updates["no_progress_count"] = 0
            if action == "cancel":
                connection.execute("UPDATE goal_inputs SET consumed=1 WHERE goal_id=?", (goal_id,))
            elif action == "resume":
                from .runstore import _alive
                for pending in connection.execute("SELECT input_id,owner_pid FROM goal_inputs WHERE goal_id=? AND consumed=0", (goal_id,)).fetchall():
                    if not _alive(int(pending["owner_pid"])):
                        connection.execute("UPDATE goal_inputs SET consumed=1 WHERE goal_id=? AND input_id=?", (goal_id, pending["input_id"]))
            connection.execute("UPDATE goals SET " + ",".join(f"{key}=?" for key in updates) + " WHERE id=?",
                               (*updates.values(), goal_id))
            return self._present(connection, self._row(connection, goal_id))

    @staticmethod
    def _binding(connection: sqlite3.Connection, goal_id: str, run_id: str,
                 revision: int | None = None, *, active: bool = False) -> sqlite3.Row:
        row = GoalStore._row(connection, goal_id)
        link = connection.execute("SELECT * FROM goal_runs WHERE goal_id=? AND run_id=?", (goal_id, run_id)).fetchone()
        if link is None:
            raise GoalError("run does not belong to this goal")
        if active and (row["status"] != "active" or row["current_run_id"] != run_id or link["revision"] < row["execution_revision"]):
            raise GoalError("the goal is no longer active for this run")
        if revision is not None and (link["revision"] != revision or row["revision"] != revision):
            raise GoalError("the goal changed while this run was working")
        return row

    def bind(self, goal_id: str, run_id: str, revision: int) -> dict[str, Any]:
        with self.run_store._connect(readonly=True) as connection:
            row = self._binding(connection, goal_id, run_id, active=True)
            link = connection.execute("SELECT revision FROM goal_runs WHERE goal_id=? AND run_id=?", (goal_id, run_id)).fetchone()
            if link["revision"] != revision:
                raise GoalError("the run's goal revision does not match its admission")
            return {**self._present(connection, row), "run_revision": revision}

    def attach_run(self, goal_id: str, run_id: str, revision: int, *, input_id: str | None = None,
                   _connection: sqlite3.Connection | None = None) -> dict[str, Any]:
        with (self._write() if _connection is None else nullcontext(_connection)) as connection:
            row = self._row(connection, goal_id)
            self._revision(row, revision)
            if row["status"] != "active":
                raise GoalError("resume this goal before attaching work")
            existing = connection.execute("SELECT goal_id FROM goal_runs WHERE run_id=?", (run_id,)).fetchone()
            if existing:
                if existing["goal_id"] != goal_id:
                    raise GoalError("the run belongs to another goal")
                return self._present(connection, row)
            prior_run = connection.execute("SELECT state FROM runs WHERE id=?", (row["current_run_id"],)).fetchone()
            if prior_run and prior_run["state"] in LIVE_RUNS:
                raise GoalError("wait for the current goal run to stop before attaching another message")
            if connection.execute("SELECT 1 FROM goal_usage WHERE goal_id=? AND state='reserved' LIMIT 1", (goal_id,)).fetchone() or connection.execute(
                "SELECT 1 FROM goal_actions WHERE goal_id=? AND state='started' AND read_only=0 LIMIT 1", (goal_id,)
            ).fetchone():
                raise GoalError("the previous goal run has uncertain work; review it before resuming")
            run = connection.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
            if run is None or run["session_id"] != row["session_id"]:
                raise GoalError("the run does not belong to this chat")
            manifest = json.loads(run["manifest_json"] or "{}")
            if run["run_kind"] not in {"solo", "team"} or run["schedule_id"] or any(
                manifest.get(key) for key in ("capsule_context", "event_delivery_id", "workflow_execution_id")
            ) or str(run["team_id"] or "").startswith("capsule-"):
                raise GoalError("only ordinary chat runs can attach to a goal")
            ordinal = row["continuation_ordinal"] + 1
            manifest.update(goal_id=goal_id, goal_revision=revision, goal_ordinal=ordinal)
            connection.execute("UPDATE runs SET manifest_json=? WHERE id=?", (_json(manifest), run_id))
            connection.execute("INSERT INTO goal_runs(run_id,goal_id,revision,ordinal,automatic,created_at) VALUES(?,?,?,?,0,?)",
                               (run_id, goal_id, revision, ordinal, time.time()))
            if input_id is None:
                pending = connection.execute("SELECT input_id FROM goal_inputs WHERE goal_id=? AND consumed=0 ORDER BY created_at LIMIT 1", (goal_id,)).fetchone()
                input_id = pending[0] if pending else None
            if input_id:
                connection.execute("UPDATE goal_inputs SET consumed=1 WHERE goal_id=? AND input_id=?", (goal_id, input_id))
            connection.execute("UPDATE goals SET current_run_id=?,continuation_ordinal=?,updated_at=? WHERE id=?",
                               (run_id, ordinal, time.time(), goal_id))
            return self._present(connection, self._row(connection, goal_id))

    def queue_user_run(self, goal_id: str, run_id: str, revision: int, *, session_id: str,
                       input_id: str | None = None, **fields: Any) -> dict[str, Any]:
        """Reserve explicit chat work, bind authority and consume input atomically."""
        with self._write() as connection:
            row = self._row(connection, goal_id)
            self._revision(row, revision)
            if row["session_id"] != session_id or row["status"] != "active":
                raise GoalError("the goal is not active in this chat")
            previous = connection.execute("SELECT session_id FROM runs WHERE id=?", (run_id,)).fetchone()
            if previous:
                link = connection.execute("SELECT goal_id FROM goal_runs WHERE run_id=?", (run_id,)).fetchone()
                if previous["session_id"] != session_id or link is None or link["goal_id"] != goal_id:
                    raise GoalError("the run identifier is already in use")
            else:
                execution = json.loads(row["execution_json"])
                manifest = {**execution, "solo_swarm": execution.get("solo_swarm") is True,
                            "mode": "work", "goal_automatic": False}
                now = time.time()
                position = connection.execute("SELECT COALESCE(MAX(queue_position),0)+1 FROM runs WHERE state='queued'").fetchone()[0]
                connection.execute(
                    "INSERT INTO runs(id,session_id,team_id,team_name,workspace_root,execution_path,owner_pid,state,request,manifest_json,"
                    "created_at,updated_at,run_kind,execution_environment,queue_position,queued_message_id,retry_parent_id,trace_id,root_span_id)"
                    " VALUES(?,?,?,?,?,?,?,'queued',?,?,?,?,?,?,?,?,?,?,?)",
                    (run_id, session_id, str(execution.get("team_id") or ""), str(execution.get("team_name") or ""),
                     execution["workspace_root"],
                     str(execution.get("execution_path") or execution["workspace_root"]),
                     os.getpid(), str(fields.get("request") or "")[:240_000], _json(manifest), now, now,
                     execution["runner"], execution["execution_environment"],
                     position, str(fields.get("message_id") or run_id)[:160], str(fields.get("retry_parent_id") or "")[:160],
                     uuid.uuid4().hex, uuid.uuid4().hex[:16]),
                )
                self.attach_run(goal_id, run_id, revision, input_id=input_id, _connection=connection)
        return self.run_store.run(run_id) or {}

    def claim(self, goal_id: str, expected_revision: int) -> dict[str, Any]:
        previous = self.get(goal_id)
        if previous and previous["current_run_id"]:
            prior_run = self.run_store.run(previous["current_run_id"])
            if prior_run and prior_run["state"] in RUN_TERMINAL:
                self.reconcile_run(goal_id, prior_run["id"], outcome=(
                    "complete" if prior_run["state"] == "completed" else
                    "app_shutdown" if prior_run["state"] == "interrupted" else prior_run["state"]
                ))
        run_id: str | None = None
        with self._write() as connection:
            row = self._row(connection, goal_id)
            self._revision(row, expected_revision)
            current = connection.execute("SELECT state,run_kind,recoverable FROM runs WHERE id=?", (row["current_run_id"],)).fetchone()
            pending = connection.execute("SELECT 1 FROM goal_inputs WHERE goal_id=? AND consumed=0 LIMIT 1", (goal_id,)).fetchone()
            if row["status"] != "active" or pending:
                return {"goal": self._present(connection, row), "run": None}
            if self._unmeasured_budget(connection, row):
                connection.execute("UPDATE goals SET status='blocked',reason=?,updated_at=? WHERE id=?",
                                   ("Provider usage is unavailable, so the saved allowance cannot be enforced.", time.time(), goal_id))
                return {"goal": self._present(connection, self._row(connection, goal_id)), "run": None}
            if current and current["state"] in LIVE_RUNS:
                run_id = row["current_run_id"] if current["state"] == "queued" else None
            elif current and current["run_kind"] == "team" and current["recoverable"] and current["state"] in {"paused", "interrupted"}:
                if self._budget_exhausted(row):
                    connection.execute("UPDATE goals SET status='limit_reached',reason=?,updated_at=? WHERE id=?",
                                       ("The goal usage allowance has been reached.", time.time(), goal_id))
                else:
                    run_id = row["current_run_id"]
                    connection.execute("UPDATE goal_runs SET revision=?,reconciled=0,report_json=NULL WHERE run_id=?",
                                       (row["revision"], run_id))
                    manifest_row = connection.execute("SELECT manifest_json FROM runs WHERE id=?", (run_id,)).fetchone()
                    resumed_manifest = json.loads(manifest_row[0] or "{}")
                    resumed_manifest["goal_revision"] = row["revision"]
                    connection.execute("UPDATE runs SET manifest_json=? WHERE id=?", (_json(resumed_manifest), run_id))
            elif row["current_run_id"] and connection.execute(
                "SELECT 1 FROM goal_runs WHERE run_id=? AND reconciled=0", (row["current_run_id"],)
            ).fetchone():
                return {"goal": self._present(connection, row), "run": None}
            elif self._budget_exhausted(row):
                connection.execute("UPDATE goals SET status='limit_reached',reason=?,updated_at=? WHERE id=?",
                                   ("The goal usage allowance has been reached.", time.time(), goal_id))
            elif not connection.execute(
                "SELECT 1 FROM runs WHERE session_id=? AND state IN (" + ",".join("?" for _ in LIVE_RUNS) + ") LIMIT 1",
                (row["session_id"], *sorted(LIVE_RUNS)),
            ).fetchone() and not connection.execute(
                "SELECT 1 FROM automation_session_leases WHERE session_id=? LIMIT 1", (row["session_id"],)
            ).fetchone():
                run_id = uuid.uuid4().hex
                ordinal, now = row["continuation_ordinal"] + 1, time.time()
                execution = json.loads(row["execution_json"])
                manifest = {**execution, "goal_id": goal_id, "goal_revision": row["revision"],
                            "goal_ordinal": ordinal, "goal_automatic": True, "mode": "work"}
                position = connection.execute("SELECT COALESCE(MAX(queue_position),0)+1 FROM runs WHERE state='queued'").fetchone()[0]
                request = f"Continue the saved goal: {row['objective']}"
                if row["summary"]:
                    request += f"\n\nLatest progress: {row['summary']}"
                if row["next_step"]:
                    request += f"\nNext step: {row['next_step']}"
                connection.execute(
                    "INSERT INTO runs(id,session_id,team_id,team_name,workspace_root,execution_path,owner_pid,state,request,manifest_json,"
                    "created_at,updated_at,run_kind,execution_environment,queue_position,queued_message_id,trace_id,root_span_id)"
                    " VALUES(?,?,?,?,?,?,?,'queued',?,?,?,?,?,?,?,?,?,?)",
                    (run_id, row["session_id"], execution.get("team_id", ""), execution.get("team_name", ""),
                     execution["workspace_root"], execution.get("execution_path") or execution["workspace_root"], os.getpid(), request,
                     _json(manifest), now, now, execution["runner"], execution["execution_environment"], position,
                     run_id, uuid.uuid4().hex, uuid.uuid4().hex[:16]),
                )
                connection.execute("INSERT INTO goal_runs(run_id,goal_id,revision,ordinal,created_at) VALUES(?,?,?,?,?)",
                                   (run_id, goal_id, row["revision"], ordinal, now))
                connection.execute("UPDATE goals SET current_run_id=?,continuation_ordinal=?,updated_at=? WHERE id=?",
                                   (run_id, ordinal, now, goal_id))
            goal = self._present(connection, self._row(connection, goal_id))
        return {"goal": goal, "run": self.run_store.run(run_id) if run_id else None}

    @staticmethod
    def _budget_exhausted(row: sqlite3.Row) -> bool:
        return ((row["model_call_budget"] is not None and row["model_calls"] >= row["model_call_budget"])
                or (row["token_budget"] is not None and row["prompt_tokens"] + row["completion_tokens"] >= row["token_budget"]))

    @staticmethod
    def _unmeasured_budget(connection: sqlite3.Connection, row: sqlite3.Row) -> bool:
        known = connection.execute("SELECT COALESCE(MIN(tokens_known),1),COALESCE(MIN(model_calls_known),1)"
                                   " FROM goal_usage WHERE goal_id=?", (row["id"],)).fetchone()
        return ((row["token_budget"] is not None and not known[0])
                or (row["model_call_budget"] is not None and not known[1]))

    def reserve_usage(self, goal_id: str, run_id: str, call_id: str, *, model_calls: int = 1,
                      prompt_tokens: int = 0, completion_tokens: int = 0) -> dict[str, Any]:
        for key, value in (("model_calls", model_calls), ("prompt_tokens", prompt_tokens), ("completion_tokens", completion_tokens)):
            _count(value, key)
        with self._write() as connection:
            row = self._binding(connection, goal_id, run_id, active=True)
            existing = connection.execute("SELECT * FROM goal_usage WHERE goal_id=? AND run_id=? AND call_id=?",
                                          (goal_id, run_id, call_id)).fetchone()
            if existing:
                return dict(existing)
            if self._unmeasured_budget(connection, row):
                raise GoalError("Provider usage is unavailable, so the saved allowance cannot be enforced.")
            outstanding = connection.execute(
                "SELECT COALESCE(SUM(MAX(reserved_tokens-prompt_tokens-completion_tokens,0)),0) FROM goal_usage"
                " WHERE goal_id=? AND state='reserved'", (goal_id,),
            ).fetchone()[0]
            needed = prompt_tokens + completion_tokens
            if (self._budget_exhausted(row)
                    or (row["model_call_budget"] is not None and row["model_calls"] + model_calls > row["model_call_budget"])
                    or (row["token_budget"] is not None and row["prompt_tokens"] + row["completion_tokens"] + outstanding + needed > row["token_budget"])):
                raise GoalBudgetExceeded("The goal usage allowance cannot admit another model call.")
            connection.execute("INSERT INTO goal_usage(goal_id,run_id,call_id,state,model_calls,reserved_tokens,updated_at)"
                               " VALUES(?,?,?,'reserved',?,?,?)", (goal_id, run_id, call_id, model_calls, needed, time.time()))
            connection.execute("UPDATE goals SET model_calls=model_calls+?,updated_at=? WHERE id=?", (model_calls, time.time(), goal_id))
            return dict(connection.execute("SELECT * FROM goal_usage WHERE goal_id=? AND run_id=? AND call_id=?",
                                           (goal_id, run_id, call_id)).fetchone())

    def _usage(self, goal_id: str, run_id: str, call_id: str, *, model_calls: int,
               prompt_tokens: int, completion_tokens: int, completed: bool,
               tokens_known: bool = True, model_calls_known: bool = True) -> dict[str, Any]:
        for key, value in (("model_calls", model_calls), ("prompt_tokens", prompt_tokens), ("completion_tokens", completion_tokens)):
            _count(value, key)
        with self._write() as connection:
            self._binding(connection, goal_id, run_id)
            prior = connection.execute("SELECT * FROM goal_usage WHERE goal_id=? AND run_id=? AND call_id=?",
                                       (goal_id, run_id, call_id)).fetchone()
            if prior is None:
                raise GoalError("usage must be reserved before a model call")
            # Providers may replay or reorder cumulative counters. Never refund
            # accounted usage, including after an explicit pause or edit.
            counts = (max(prior["model_calls"], model_calls), max(prior["prompt_tokens"], prompt_tokens),
                      max(prior["completion_tokens"], completion_tokens))
            deltas = tuple(new - prior[key] for new, key in zip(counts, ("model_calls", "prompt_tokens", "completion_tokens"), strict=True))
            state = "settled" if completed else prior["state"]
            # Resume can acknowledge interrupted work, but cannot measure it.
            # Only an authoritative final settlement can restore a previously
            # unknown dimension; partial checkpoints remain conservative.
            known_tokens = int(tokens_known) if completed else min(prior["tokens_known"], int(tokens_known))
            known_calls = int(model_calls_known) if completed else min(prior["model_calls_known"], int(model_calls_known))
            connection.execute("UPDATE goal_usage SET model_calls=?,prompt_tokens=?,completion_tokens=?,state=?,updated_at=?,"
                               "tokens_known=?,model_calls_known=?"
                               " WHERE goal_id=? AND run_id=? AND call_id=?",
                               (*counts, state, time.time(), known_tokens, known_calls, goal_id, run_id, call_id))
            connection.execute("UPDATE goals SET model_calls=model_calls+?,prompt_tokens=prompt_tokens+?,"
                               "completion_tokens=completion_tokens+?,updated_at=? WHERE id=?", (*deltas, time.time(), goal_id))
            return dict(connection.execute("SELECT * FROM goal_usage WHERE goal_id=? AND run_id=? AND call_id=?",
                                           (goal_id, run_id, call_id)).fetchone())

    def checkpoint_usage(self, goal_id: str, run_id: str, call_id: str, *, model_calls: int = 1,
                         prompt_tokens: int = 0, completion_tokens: int = 0) -> dict[str, Any]:
        return self._usage(goal_id, run_id, call_id, model_calls=model_calls, prompt_tokens=prompt_tokens,
                           completion_tokens=completion_tokens, completed=False)

    def settle_usage(self, goal_id: str, run_id: str, call_id: str, *, model_calls: int = 1,
                     prompt_tokens: int = 0, completion_tokens: int = 0,
                     tokens_known: bool = True, model_calls_known: bool = True) -> dict[str, Any]:
        return self._usage(goal_id, run_id, call_id, model_calls=model_calls, prompt_tokens=prompt_tokens,
                           completion_tokens=completion_tokens, completed=True,
                           tokens_known=tokens_known, model_calls_known=model_calls_known)

    def start_action(self, goal_id: str, run_id: str, action_id: str, *, tool: str,
                     read_only: bool = False) -> dict[str, Any]:
        with self._write() as connection:
            self._binding(connection, goal_id, run_id, active=True)
            if not read_only:
                connection.execute("UPDATE goal_runs SET report_json=NULL WHERE goal_id=? AND run_id=?", (goal_id, run_id))
            connection.execute("INSERT OR IGNORE INTO goal_actions(goal_id,run_id,action_id,tool,read_only,state,created_at,updated_at)"
                               " VALUES(?,?,?,?,?,'started',?,?)", (goal_id, run_id, action_id, tool, int(read_only), time.time(), time.time()))
            return dict(connection.execute("SELECT * FROM goal_actions WHERE goal_id=? AND run_id=? AND action_id=?",
                                           (goal_id, run_id, action_id)).fetchone())

    def finish_action(self, goal_id: str, run_id: str, action_id: str, *, ok: bool = True) -> dict[str, Any]:
        with self._write() as connection:
            self._binding(connection, goal_id, run_id)
            cursor = connection.execute("UPDATE goal_actions SET state='finished',ok=?,updated_at=?"
                                        " WHERE goal_id=? AND run_id=? AND action_id=?",
                                        (int(ok), time.time(), goal_id, run_id, action_id))
            if not cursor.rowcount:
                raise GoalError("action must be journaled before execution")
            return dict(connection.execute("SELECT * FROM goal_actions WHERE goal_id=? AND run_id=? AND action_id=?",
                                           (goal_id, run_id, action_id)).fetchone())

    def report(self, goal_id: str, run_id: str, revision: int, *, status: str, summary: str,
               evidence: list[str], next_step: str = "", blocker: str = "") -> dict[str, Any]:
        if status not in {"continue", "complete", "blocked"}:
            raise GoalError("goal report status must be continue, complete, or blocked")
        summary = _text(summary, "summary", 16_000, required=True)
        if not isinstance(evidence, list) or len(evidence) > 64:
            raise GoalError("evidence must be a list of at most 64 text items")
        evidence = [_text(item, "evidence", 8000, required=True) for item in evidence]
        if status == "complete" and not evidence:
            raise GoalError("completion requires verification evidence")
        next_step = _text(next_step, "next_step", 16_000, required=status == "continue")
        blocker = _text(blocker, "blocker", 16_000, required=status == "blocked")
        with self._write() as connection:
            row = self._binding(connection, goal_id, run_id, revision, active=True)
            if connection.execute("SELECT reconciled FROM goal_runs WHERE run_id=?", (run_id,)).fetchone()[0]:
                raise GoalError("the run has already been reconciled")
            connection.execute("UPDATE goal_runs SET report_json=? WHERE goal_id=? AND run_id=?",
                               (_json({"status": status, "summary": summary, "evidence": evidence,
                                       "next_step": next_step, "blocker": blocker}), goal_id, run_id))
            return self._present(connection, row)

    def reconcile_run(self, goal_id: str, run_id: str, *, outcome: str = "complete", reason: str = "") -> dict[str, Any]:
        if reason in {"waiting_input", "invalid_goal_report", "goal_unavailable", "app_shutdown", "limit_reached", "usage_unavailable"}:
            outcome = reason
        with self._write() as connection:
            row = self._binding(connection, goal_id, run_id)
            link = connection.execute("SELECT * FROM goal_runs WHERE run_id=?", (run_id,)).fetchone()
            if link["reconciled"]:
                return self._present(connection, row)
            connection.execute("UPDATE goal_runs SET reconciled=1 WHERE run_id=?", (run_id,))
            if row["status"] != "active" or row["current_run_id"] != run_id:
                return self._present(connection, row)
            report = json.loads(link["report_json"]) if link["report_json"] else None
            pending = connection.execute("SELECT 1 FROM goal_inputs WHERE goal_id=? AND consumed=0 LIMIT 1", (goal_id,)).fetchone()
            uncertain = connection.execute("SELECT 1 FROM goal_usage WHERE goal_id=? AND state='reserved' LIMIT 1", (goal_id,)).fetchone()
            uncertain_action = connection.execute("SELECT 1 FROM goal_actions WHERE goal_id=? AND state='started' AND read_only=0 LIMIT 1", (goal_id,)).fetchone()
            unavailable = connection.execute("SELECT COALESCE(MIN(tokens_known),1),COALESCE(MIN(model_calls_known),1)"
                                             " FROM goal_usage WHERE goal_id=?", (goal_id,)).fetchone()
            state, message = "active", ""
            failures = row["no_progress_count"]
            fingerprint = row["progress_fingerprint"]
            if uncertain or uncertain_action:
                state, message = "blocked", "The previous run has an uncertain model call or tool action. Review its work before resuming."
            elif ((row["token_budget"] is not None and not unavailable[0])
                  or (row["model_call_budget"] is not None and not unavailable[1])):
                state, message = "blocked", "Provider usage is unavailable, so the saved allowance cannot be enforced."
            elif row["revision"] != link["revision"]:
                return self._present(connection, row)
            elif pending:
                pass  # The queued user message owns the next dispatch.
            elif outcome == "app_shutdown":
                pass
            elif outcome in {"limit_reached", "token_budget", "budget_exceeded"}:
                state, message = "limit_reached", "The goal usage allowance has been reached."
            elif outcome in {"waiting_input", "invalid_goal_report", "goal_unavailable", "usage_unavailable"}:
                state, message = ("paused" if outcome == "invalid_goal_report" else "blocked"), {
                    "waiting_input": "The goal needs your answer before continuing.",
                    "invalid_goal_report": "The run did not produce a valid goal progress report.",
                    "goal_unavailable": "The saved goal configuration is unavailable.",
                    "usage_unavailable": "The provider did not expose enough usage information to continue safely.",
                }[outcome]
            elif outcome in {"cancel", "cancelled", "stopped", "pause", "paused"}:
                state, message = "paused", reason or "The goal was stopped."
            elif outcome not in {"complete", "completed"}:
                if self._budget_exhausted(row):
                    state, message = "limit_reached", "The goal usage allowance has been reached."
                else:
                    state, message = "paused", reason or "The run stopped at an error or runtime safety limit. Review it before resuming."
            elif report is None:
                failures += 1
                if failures >= 3:
                    state, message = "paused", "Three consecutive turns ended without a goal progress report."
                elif self._budget_exhausted(row):
                    state, message = "limit_reached", "The goal usage allowance has been reached."
            elif report["status"] == "complete":
                state = "completed"
            elif report["status"] == "blocked":
                state, message = "blocked", report["blocker"]
            else:
                fresh = hashlib.sha256(_json([report["summary"], report["evidence"], report["next_step"]]).encode()).hexdigest()
                failures = failures + 1 if fresh == fingerprint else 1
                fingerprint = fresh
                if failures >= 3:
                    state, message = "paused", "Three consecutive turns repeated the same progress report without advancing."
                elif self._budget_exhausted(row):
                    state, message = "limit_reached", "The goal usage allowance has been reached."
            connection.execute("UPDATE goals SET status=?,reason=?,summary=?,evidence_json=?,next_step=?,"
                               "no_progress_count=?,progress_fingerprint=?,updated_at=? WHERE id=?",
                               (state, message, report["summary"] if report and not pending else row["summary"],
                                _json(report["evidence"]) if report and not pending else row["evidence_json"],
                                report["next_step"] if report and not pending else row["next_step"],
                                failures, fingerprint, time.time(), goal_id))
            return self._present(connection, self._row(connection, goal_id))

    def recover(self, lease_active: Callable[[str], bool] | None = None) -> list[dict[str, Any]]:
        """Reconcile stopped runs across the entire goal set, never a UI page."""
        if self.run_store.read_only:
            return self.list()
        from .runstore import _alive
        if lease_active is None:
            from .orchestration import GLOBAL_MODEL_SCHEDULER
            lease_active = GLOBAL_MODEL_SCHEDULER.has_active_lease
        for goal in self.list(nonterminal=True):
            if goal["status"] == "active" and goal["pending_user_input"]:
                with self.run_store._connect(readonly=True) as connection:
                    owners = connection.execute("SELECT owner_pid FROM goal_inputs WHERE goal_id=? AND consumed=0", (goal["id"],)).fetchall()
                if any(not _alive(int(owner[0])) for owner in owners):
                    self.update(goal["id"], "block", reason="The app closed with queued user input that was not sent. Review the conversation and resume when ready.")
                    continue
            run_id = goal["current_run_id"]
            if not run_id:
                continue
            run = self.run_store.run(run_id)
            if run and run["state"] in LIVE_RUNS - {"queued"}:
                with self.run_store._connect(readonly=True) as connection:
                    owner = connection.execute("SELECT owner_pid FROM runs WHERE id=?", (run_id,)).fetchone()
                if owner and not _alive(int(owner[0])) and not lease_active(run_id):
                    with self._write() as connection:
                        connection.execute(
                            "UPDATE runs SET state='interrupted',recoverable=1,recovery_reason=?,updated_at=?"
                            " WHERE id=? AND owner_pid=? AND state=?",
                            ("The goal worker stopped before the run reached a terminal checkpoint.",
                             time.time(), run_id, owner[0], run["state"]),
                        )
                    run = self.run_store.run(run_id)
            if run is None or run["state"] in RUN_TERMINAL:
                self.reconcile_run(goal["id"], run_id,
                                   outcome=("goal_unavailable" if run is None else "complete" if run["state"] == "completed"
                                            else "app_shutdown" if run["state"] == "interrupted" else run["state"]),
                                   reason="The prior goal run was interrupted.")
        return self.list()
