"""Durable session helpers with run-scoped execution and isolated edit results.

Provider implementations are injected. The manager never shares an AgentCore,
credentials, mutable tool context, or provider conversation between helpers.
"""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from . import paths
from .worktrees import (
    TaskCheckoutStore,
    WorktreeError,
    apply_helper_integration,
    execution_snapshot,
    fork_execution,
    freeze_helper_result,
    is_git_workspace,
    prepare_helper_integration,
)

MAX_ACTIVE = 3
MAX_NEW_PER_RUN = 6
MAX_CALLS = 24
MAX_TOKENS = 250_000
SLICE_CALLS = 8
ACTIVE_STATES = {"queued", "running", "stopping"}


def _bounded_value(value: Any, budget: int, *, text_limit: int = 2_000) -> Any:
    """Bound nested evidence by serialized size, depth and item count."""
    remaining = budget
    def visit(item: Any, depth: int) -> Any:
        nonlocal remaining
        if remaining < 16 or depth > 5:
            return None
        remaining -= 8
        if isinstance(item, str):
            item = item[:text_limit]
            if len(json.dumps(item, ensure_ascii=False)) > remaining:
                item = item[:max(0, (remaining - 2) // 6)]
            remaining -= len(json.dumps(item, ensure_ascii=False))
            return item
        if isinstance(item, dict):
            result = {}
            for key, child in list(item.items())[:40]:
                if remaining < 32:
                    break
                key = str(key)[:128]
                remaining -= len(key) + 4
                result[key] = visit(child, depth + 1)
            return result
        if isinstance(item, (list, tuple)):
            result = []
            for child in item[:20]:
                if remaining < 16:
                    break
                result.append(visit(child, depth + 1))
            return result
        return item if isinstance(item, (int, float, bool)) or item is None else str(item)[:128]
    return visit(value, 0)


class CollaborationError(RuntimeError):
    pass


@dataclass(frozen=True)
class WorkerSpec:
    agent_id: str
    session_id: str
    run_id: str
    execution_path: str
    mode: str
    context: dict[str, Any]
    checkpoint: dict[str, Any]
    label: str
    tools: list[str] | None = None


class WorkerRuntime(Protocol):
    def run(self, prompt: str, *, max_calls: int, should_stop: Callable[[], bool],
            drain_messages: Callable[[], list[dict[str, Any]]],
            on_usage: Callable[[dict[str, int]], None],
            on_checkpoint: Callable[[dict[str, Any]], None]) -> dict[str, Any]: ...
    # mailbox_ack_seq acknowledges applied input, never merely drained input.
    # Save through on_checkpoint before any uncertain native delivery attempt.
    def snapshot(self) -> dict[str, Any]: ...
    def interrupt(self) -> None: ...
    def close(self) -> None: ...


class CollaborationStore:
    """Authoritative state, unlike the best-effort run activity log."""
    def __init__(self, path: Path | None = None):
        self.path = Path(path or paths.APP_DIR / "collaboration.sqlite3")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        with self.connect() as db:
            db.executescript("""
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS helpers (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS mailbox (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                agent_id TEXT NOT NULL, direction TEXT NOT NULL, payload TEXT NOT NULL,
                delivered INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS receipts (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS attempts (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL);
            """)
        self.path.chmod(0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    def get(self, table: str, identifier: str) -> dict[str, Any] | None:
        if table not in {"helpers", "runs", "receipts", "attempts"}:
            raise ValueError("invalid collaboration table")
        with self.lock, self.connect() as db:
            row = db.execute(f"SELECT payload FROM {table} WHERE id=?", (identifier,)).fetchone()
        return json.loads(row[0]) if row else None

    def put(self, table: str, value: dict[str, Any]) -> None:
        if table not in {"helpers", "runs", "receipts", "attempts"}:
            raise ValueError("invalid collaboration table")
        encoded = json.dumps(value, ensure_ascii=False)
        with self.lock, self.connect() as db:
            db.execute(f"INSERT INTO {table}(id,session_id,payload) VALUES(?,?,?) "
                       "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                       (value["id"], value["session_id"], encoded))

    def helpers(self, session_id: str, *, limit: int | None = None) -> list[dict[str, Any]]:
        with self.lock, self.connect() as db:
            query = "SELECT payload FROM helpers WHERE session_id=?"
            args: list[Any] = [session_id]
            if limit is None:
                query += " ORDER BY rowid"
            else:
                query += (" ORDER BY CASE WHEN json_extract(payload, '$.state') IN "
                          "('queued','running','stopping') THEN 0 ELSE 1 END, "
                          "json_extract(payload, '$.updated_at') DESC, rowid DESC LIMIT ?")
                args.append(limit)
            rows = db.execute(query, args).fetchall()
        return [json.loads(row[0]) for row in rows]

    def helper_count(self, session_id: str) -> int:
        with self.lock, self.connect() as db:
            return int(db.execute("SELECT COUNT(*) FROM helpers WHERE session_id=?", (session_id,)).fetchone()[0])

    def message(self, session: str, agent: str, direction: str, payload: dict[str, Any]) -> int:
        with self.lock, self.connect() as db:
            cursor = db.execute("INSERT INTO mailbox(session_id,agent_id,direction,payload) VALUES(?,?,?,?)",
                                (session, agent, direction, json.dumps(payload)))
            return int(cursor.lastrowid)

    def messages(self, session: str, *, agent: str | None = None, direction: str = "parent",
                 after: int = 0, consume: bool = False) -> list[dict[str, Any]]:
        with self.lock, self.connect() as db:
            query = "SELECT * FROM mailbox WHERE session_id=? AND direction=? AND seq>?"
            args: list[Any] = [session, direction, after]
            if agent:
                query += " AND agent_id=?"
                args.append(agent)
            if consume:
                query += " AND delivered=0"
            rows = db.execute(query + " ORDER BY seq LIMIT 100", args).fetchall()
            if consume:
                db.executemany("UPDATE mailbox SET delivered=1 WHERE seq=?", [(r["seq"],) for r in rows])
        return [{**json.loads(r["payload"]), "seq": r["seq"], "agent_id": r["agent_id"]} for r in rows]

    def reset_unacknowledged(self, session: str, agent: str, acknowledged: int) -> None:
        with self.lock, self.connect() as db:
            db.execute("UPDATE mailbox SET delivered=0 WHERE session_id=? AND agent_id=? "
                       "AND direction='worker' AND seq>?", (session, agent, acknowledged))


class SoloCollaborationManager:
    def __init__(self, *, session_id: str, run_id: str, execution_path: str,
                 worker_factory: Callable[[WorkerSpec], WorkerRuntime],
                 emit: Callable[[dict[str, Any]], None], store: CollaborationStore | None = None,
                 workspace_root: str | None = None, should_stop: Callable[[], bool] | None = None,
                 plan_mode: bool = False, mutation_lock: Any | None = None):
        self.store = store or CollaborationStore()
        self.session_id, self.run_id = session_id, run_id
        self.execution_path = str(Path(execution_path).resolve())
        self.workspace_root = workspace_root or self.execution_path
        self.worker_factory, self.emit = worker_factory, emit
        self.should_stop = should_stop or (lambda: False)
        self.plan_mode = plan_mode
        self._guard = threading.RLock()
        self._changed = threading.Condition(self._guard)
        self.mutation_lock = mutation_lock or threading.RLock()
        self._pool = ThreadPoolExecutor(max_workers=MAX_ACTIVE, thread_name_prefix="locus-helper")
        self._futures: dict[str, Any] = {}
        self._runtimes: dict[str, WorkerRuntime] = {}
        self._stops: dict[str, threading.Event] = {}
        self._closed = False
        with self.store.lock:
            existing = self.store.get("runs", run_id)
            if existing and existing["session_id"] != session_id:
                raise CollaborationError("run belongs to another session")
            if not existing:
                self.store.put("runs", {"id": run_id, "session_id": session_id, "new_helpers": 0,
                    "model_calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "reserved_calls": 0})
            for helper in self.store.helpers(session_id):
                if helper["state"] in ACTIVE_STATES and not self._owner_alive(helper.get("owner_pid")):
                    helper.update(state="interrupted", reason="process_restarted", owner_pid=None)
                    self._save(helper)
                    previous = self.store.get("runs", helper.get("run_id", ""))
                    if previous:
                        previous["reserved_calls"] = 0
                        self.store.put("runs", previous)

    @staticmethod
    def _owner_alive(pid: Any) -> bool:
        if not isinstance(pid, int):
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    @property
    def usage(self) -> dict[str, int]:
        run = self.store.get("runs", self.run_id) or {}
        return {"model_calls": run.get("model_calls", 0), "prompt_tokens": run.get("prompt_tokens", 0),
                "completion_tokens": run.get("completion_tokens", 0),
                "delegated_tokens": run.get("prompt_tokens", 0) + run.get("completion_tokens", 0)}

    def _save(self, helper: dict[str, Any]) -> None:
        helper["revision"] = int(helper.get("revision", 0)) + 1
        helper["updated_at"] = time.time()
        self.store.put("helpers", helper)
        if helper.get("attempt_id"):
            attempt = {key: helper[key] for key in (
                "session_id", "run_id", "agent_id", "state", "mode", "generation", "attempt",
                "current_prompt", "checkpoint", "task_id", "result", "attempt_usage", "reason", "output",
                "updated_at", "execution_path") if key in helper}
            attempt["id"] = helper["attempt_id"]
            self.store.put("attempts", attempt)
        try:
            self.emit({"type": "solo_collaboration_snapshot", "run_id": self.run_id,
                       "session_id": self.session_id, **self.list_agents()})
        except Exception:
            pass

    def _helper(self, agent_id: str) -> dict[str, Any]:
        helper = self.store.get("helpers", agent_id)
        if not helper or helper["session_id"] != self.session_id:
            raise CollaborationError("helper was not found in this session")
        return helper

    @staticmethod
    def _public(helper: dict[str, Any], *, full: bool = False) -> dict[str, Any]:
        excluded = {"context", "checkpoint", "owner_pid", "tools", "attempt_usage",
                    "output", "goal", "current_prompt", "result", "prior_result"}
        value = _bounded_value({key: child for key, child in helper.items() if key not in excluded}, 4_000)
        for key in ("goal", "current_prompt"):
            if key in helper:
                value[key] = str(helper[key])[:4_000 if full else 2_000]
        for key in ("result", "prior_result"):
            if key in helper:
                value[key] = _bounded_value(helper[key], 6_000 if full else 4_000)
        if "output" in helper:
            value["output"] = str(helper["output"])[:96_000 if full else 8_000]
        private = {"context", "checkpoint", "owner_pid", "tools", "attempt_usage"}
        if value != {key: child for key, child in helper.items() if key not in private}:
            value["details_truncated"] = True
        return value

    def read(self, agent_id: str) -> dict[str, Any]:
        return {"ok": True, "agent": self._public(self._helper(agent_id), full=True)}

    def list_agents(self) -> dict[str, Any]:
        total = self.store.helper_count(self.session_id)
        return {"ok": True, "agents": [self._public(h) for h in self.store.helpers(self.session_id, limit=100)],
                "total": total, "truncated": total > 100, "usage": self.usage}

    def _event(self, kind: str, helper: dict[str, Any], **extra: Any) -> None:
        event = {"type": kind, "run_id": self.run_id, "session_id": self.session_id,
                 "agent_id": helper["id"], "job_id": helper["id"], "node_id": f"/root/{helper['id']}",
                 "parent_node_id": "/root", "depth": 1, "agent_name": helper["label"],
                 "role": "writer" if helper["mode"] == "edit" else "researcher",
                 "execution_engine": "locus_managed", "state": helper["state"], **extra}
        # Observers do not own execution authority.
        try:
            self.emit(event)
        except Exception:
            pass

    def spawn(self, task: str, *, label: str = "Helper", mode: str = "research",
              context: dict[str, Any] | None = None, tools: list[str] | None = None) -> dict[str, Any]:
        if mode not in {"research", "edit"} or not task.strip() or len(task) > 120_000:
            raise CollaborationError("helper requires a bounded task and research or edit mode")
        if self.plan_mode and mode == "edit":
            raise CollaborationError("Plan mode permits research helpers only")
        if mode == "edit" and not is_git_workspace(self.execution_path):
            return {"ok": False, "code": "isolation_unavailable",
                    "error": "Editing helpers require a Git checkout; the root can make these edits."}
        with self._guard, self.store.lock:
            if self._closed:
                raise CollaborationError("parent run is closed")
            run = self.store.get("runs", self.run_id)
            if run["new_helpers"] >= MAX_NEW_PER_RUN:
                raise CollaborationError("this run reached its six-new-helper limit")
            identifier = uuid.uuid4().hex
            helper = {"id": identifier, "agent_id": identifier, "session_id": self.session_id,
                      "run_id": self.run_id, "label": label[:160], "goal": task, "mode": mode,
                      "state": "idle", "generation": 0, "attempt": 0, "revision": 0,
                      "context": context or {}, "checkpoint": {}, "tools": tools,
                      "result": None, "execution_path": self.execution_path, "owner_pid": None}
            run["new_helpers"] += 1
            self.store.put("runs", run)
            self._save(helper)
            self._event("agent_spawned", helper, goal=task)
        return self.followup(identifier, task)

    def send_message(self, agent_id: str, text: str) -> dict[str, Any]:
        with self._changed:
            helper = self._helper(agent_id)
            if not text.strip() or len(text) > 120_000:
                raise CollaborationError("message must be nonempty and bounded")
            seq = self.store.message(self.session_id, agent_id, "worker", {"text": text, "run_id": self.run_id})
            self._changed.notify_all()
            return {"ok": True, "agent_id": agent_id, "state": helper["state"], "seq": seq}

    def send_parent_message(self, agent_id: str, text: str) -> dict[str, Any]:
        """Worker-to-root findings or requests; never user-role steering."""
        with self._changed:
            helper = self._helper(agent_id)
            if self._closed or helper["run_id"] != self.run_id or helper["state"] not in ACTIVE_STATES:
                raise CollaborationError("only an active helper attempt can message its owning root")
            if not text.strip() or len(text) > 120_000:
                raise CollaborationError("message must be nonempty and bounded")
            seq = self.store.message(self.session_id, agent_id, "parent",
                                     {"type": "message", "text": text, "run_id": self.run_id})
            self._event("agent_message", helper, text=text, seq=seq)
            self._changed.notify_all()
            return {"ok": True, "seq": seq}

    def followup(self, agent_id: str, text: str) -> dict[str, Any]:
        if not text.strip() or len(text) > 120_000:
            raise CollaborationError("follow-up must be nonempty and bounded")
        with self._changed:
            if self._closed:
                raise CollaborationError("parent run is closed")
            helper = self._helper(agent_id)
            if helper["state"] in ACTIVE_STATES:
                if helper["run_id"] != self.run_id:
                    raise CollaborationError("helper is still active under another parent run")
                result = self.send_message(agent_id, text)
                helper["followup_pending"] = True
                self._save(helper)
                return result
            helper.update(state="queued", run_id=self.run_id, owner_pid=os.getpid(),
                          attempt=helper["attempt"] + 1, attempt_usage={}, followup_pending=False,
                          current_prompt=text)
            helper["attempt_id"] = f"{self.run_id}:{agent_id}:{helper['attempt']}"
            self.store.reset_unacknowledged(self.session_id, agent_id, helper.get("mailbox_ack_seq", 0))
            self._save(helper)
            stop = threading.Event()
            self._stops[agent_id] = stop
            self._futures[agent_id] = self._pool.submit(self._run, agent_id, text, stop)
            self._changed.notify_all()
            return {"ok": True, **self._public(helper)}

    def resume(self, agent_id: str, prompt: str = "Continue the assigned task from the saved state.") -> dict[str, Any]:
        helper = self._helper(agent_id)
        previous = str(helper.get("current_prompt") or helper.get("goal") or "")
        return self.followup(agent_id, f"{prompt}\n\nSaved assignment:\n{previous}"[:120_000])

    def interrupt(self, agent_id: str) -> dict[str, Any]:
        with self._changed:
            helper = self._helper(agent_id)
            if helper["state"] in ACTIVE_STATES:
                if helper["run_id"] != self.run_id:
                    raise CollaborationError("helper is still active under another parent run")
                self._stops.get(agent_id, threading.Event()).set()
                runtime = self._runtimes.get(agent_id)
                if runtime:
                    runtime.interrupt()
                helper["state"] = "stopping"
                self._save(helper)
            self._changed.notify_all()
            return {"ok": True, **self._public(helper)}

    def _workspace(self, helper: dict[str, Any]) -> None:
        if helper["mode"] != "edit":
            helper["execution_path"] = self.execution_path
            return
        result = helper.get("result") or {}
        previous_parent = helper.get("parent_execution_path")
        if helper.get("task_id") and previous_parent and previous_parent != self.execution_path:
            # Carry the old patch as evidence into a fresh generation; never
            # relabel an old checkout as if it came from this new destination.
            if not result:
                previous = TaskCheckoutStore.load(helper["task_id"])
                if previous is not None:
                    result = freeze_helper_result(previous, uuid.uuid4().hex)
                    helper["result"] = result
            result.update(state="conflict", error="parent execution checkout changed")
        if helper.get("task_id") and result.get("state") not in {"integrated", "conflict"}:
            # Pending work belongs to this baseline until accepted or reconciled.
            task = TaskCheckoutStore.load(helper["task_id"])
            if task is None:
                raise CollaborationError("saved helper workspace is unavailable; preserve its result and create a new helper")
            if not Path(task.execution_path).is_dir():
                task = TaskCheckoutStore.restore(task.id)
            task.state = "running"
            task.save()
            if result:
                result["state"] = "superseded"
            return
        with self.mutation_lock:
            task, baseline = fork_execution(self.execution_path, f"helper-{helper['id']}-{helper['generation'] + 1}")
            task.state = "running"
            task.save()
        helper["generation"] += 1
        helper["task_id"] = task.id
        helper["parent_baseline"] = baseline
        helper["parent_execution_path"] = self.execution_path
        helper["execution_path"] = str(Path(task.execution_path) / baseline["cwd_relative"])
        if result:
            helper["prior_result"] = result
            helper["result"] = None

    def _run(self, agent_id: str, prompt: str, stop: threading.Event) -> None:
        runtime = None
        allowance = 0
        reserved = False
        attempt_usage = {"model_calls": 0, "prompt_tokens": 0, "completion_tokens": 0}
        state, reason, output = "failed", "worker_failed", ""
        evidence: list[Any] = []
        validation: Any = []
        def stopping() -> bool:
            return stop.is_set() or self.should_stop() or self.usage["delegated_tokens"] >= MAX_TOKENS
        def on_usage(value: dict[str, int]) -> None:
            with self._guard, self.store.lock:
                run = self.store.get("runs", self.run_id)
                for key in attempt_usage:
                    observed = max(int(value.get(key, attempt_usage[key])), attempt_usage[key])
                    run[key] += observed - attempt_usage[key]
                    attempt_usage[key] = observed
                self.store.put("runs", run)
                helper = self._helper(agent_id)
                helper["attempt_usage"] = dict(attempt_usage)
                self._save(helper)
                if attempt_usage["model_calls"] >= allowance or self.usage["delegated_tokens"] >= MAX_TOKENS:
                    stop.set()
        def drain_messages() -> list[dict[str, Any]]:
            return self.store.messages(self.session_id, agent=agent_id, direction="worker", consume=True)
        def on_checkpoint(checkpoint: dict[str, Any]) -> None:
            with self._guard:
                helper = self._helper(agent_id)
                helper["checkpoint"] = checkpoint
                helper["mailbox_ack_seq"] = max(helper.get("mailbox_ack_seq", 0),
                                               int(checkpoint.get("mailbox_ack_seq") or 0))
                self._save(helper)
        try:
            with self._guard, self.store.lock:
                helper = self._helper(agent_id)
                run = self.store.get("runs", self.run_id)
                allowance = min(SLICE_CALLS, max(MAX_CALLS - run["model_calls"] - run["reserved_calls"], 0))
                if not allowance or stopping():
                    state = "interrupted" if stop.is_set() or self.should_stop() else "paused"
                    reason = "interrupted" if state == "interrupted" else "delegated_budget"
                    return
                run["reserved_calls"] += allowance
                self.store.put("runs", run)
                reserved = True
                self._workspace(helper)
                helper.update(state="running", allowance=allowance)
                self._save(helper)
            spec = WorkerSpec(agent_id, self.session_id, self.run_id, helper["execution_path"],
                              helper["mode"], {**helper["context"], "prior_result": helper.get("prior_result")},
                              helper.get("checkpoint") or {}, helper["label"], helper.get("tools"))
            runtime = self.worker_factory(spec)
            with self._guard:
                self._runtimes[agent_id] = runtime
            self._event("agent_job_started", helper, goal=prompt, attempt_id=f"{self.run_id}:{agent_id}:{helper['attempt']}")
            result = runtime.run(prompt, max_calls=allowance, should_stop=stopping,
                drain_messages=drain_messages,
                on_usage=on_usage, on_checkpoint=on_checkpoint)
            on_usage(result.get("usage") or {})
            output = str(result.get("output") or result.get("findings") or "")[:120_000]
            evidence = list(result.get("evidence") or [])[:100]
            validation = result.get("validation") or result.get("checks") or []
            reason = str(result.get("reason") or "complete")
            state = "idle" if reason in {"complete", "completed"} else "paused"
            if reason in {"interrupted", "cancelled"}:
                state = "interrupted"
            if stop.is_set() and reason not in {"complete", "completed"}:
                state = "interrupted" if attempt_usage["model_calls"] < allowance else "paused"
            on_checkpoint(runtime.snapshot())
        except Exception as exc:
            reason, output = "worker_failed", str(exc)[:8_000]
        finally:
            if runtime:
                try:
                    on_checkpoint(runtime.snapshot())
                except Exception:
                    pass
                try:
                    runtime.close()
                except Exception:
                    pass
            with self._changed, self.store.lock:
                run = self.store.get("runs", self.run_id)
                run["reserved_calls"] = max(run["reserved_calls"] - (allowance if reserved else 0), 0)
                self.store.put("runs", run)
                helper = self._helper(agent_id)
                helper.update(state=state, reason=reason, output=output, owner_pid=None)
                if helper.get("task_id"):
                    task = TaskCheckoutStore.load(helper["task_id"])
                    if task is not None and Path(task.execution_path).is_dir():
                        try:
                            frozen = freeze_helper_result(task, uuid.uuid4().hex)
                            helper["result"] = {**frozen, "generation": helper["generation"],
                                "state": "ready" if state == "idle" else "partial",
                                "parent_execution_path": helper.get("parent_execution_path", self.execution_path),
                                "worker_state": state, "evidence": evidence, "validation": validation}
                        except (WorktreeError, OSError) as exc:
                            helper["result_error"] = str(exc)
                self._save(helper)
                if helper.get("task_id"):
                    task = TaskCheckoutStore.load(helper["task_id"])
                    if task is not None:
                        task.state = "completed" if state == "idle" else state
                        task.save()
                self._runtimes.pop(agent_id, None)
                self.store.message(self.session_id, agent_id, "parent", {
                    "type": "completed", "state": state, "output": output, "run_id": self.run_id,
                    "result": helper.get("result"), "attempt": helper["attempt"]})
                self._event("agent_job_completed", helper, result={
                    "job_id": agent_id, "agent_name": helper["label"], "output": output,
                    "node_id": f"/root/{agent_id}", "parent_node_id": "/root", "depth": 1,
                    **attempt_usage}, usage=self.usage)
                self._changed.notify_all()
                remaining = self.usage
                pending = self.store.messages(self.session_id, agent=agent_id,
                    direction="worker", after=helper.get("mailbox_ack_seq", 0))
                if (helper.get("followup_pending") and not self._closed and not self.should_stop()
                        and pending
                        and state != "interrupted" and remaining["model_calls"] < MAX_CALLS
                        and remaining["delegated_tokens"] < MAX_TOKENS):
                    self.followup(agent_id, "Apply the queued follow-up instructions and continue.")

    def wait(self, agent_ids: list[str] | None = None, *, after_cursor: int = 0,
             timeout_ms: int = 60_000) -> dict[str, Any]:
        if agent_ids is not None and (not isinstance(agent_ids, list) or len(agent_ids) > 100):
            raise CollaborationError("wait accepts at most 100 helper IDs")
        ids = set(agent_ids or [])
        for identifier in ids:
            self._helper(identifier)
        deadline = time.monotonic() + max(0, min(timeout_ms, 60_000)) / 1_000
        with self._changed:
            while True:
                messages = self.store.messages(self.session_id, after=after_cursor)
                selected = [m for m in messages if not ids or m["agent_id"] in ids]
                agents = ([self._helper(identifier) for identifier in ids] if ids else
                          self.store.helpers(self.session_id, limit=100))
                if selected or not any(h["state"] in ACTIVE_STATES for h in agents) or stopping_now(self) or time.monotonic() >= deadline:
                    bounded_messages = [_bounded_value({
                        **{key: m[key] for key in ("seq", "agent_id", "run_id", "type", "state", "attempt") if key in m},
                        **m}, 12_000, text_limit=8_000) for m in selected]
                    return {"ok": True, "messages": bounded_messages,
                            "cursor": max([after_cursor, *[m["seq"] for m in messages]]),
                            "agents": [self._public(h) for h in agents], "usage": self.usage}
                self._changed.wait(min(max(deadline - time.monotonic(), 0), 0.25))

    def integrate(self, agent_id: str, result_id: str) -> dict[str, Any]:
        with self._guard, self.mutation_lock:
            helper = self._helper(agent_id)
            result = helper.get("result") or {}
            if result.get("result_id") != result_id:
                raise CollaborationError("helper result changed; review the current result")
            receipt_id = f"{agent_id}:{result_id}"
            previous = self.store.get("receipts", receipt_id)
            if previous:
                if previous["state"] == "integrated":
                    return {"ok": True, "already_integrated": True, "receipt": previous}
                if previous["state"] in {"prepared", "uncertain"}:
                    # Reconcile a journal interrupted between filesystem and
                    # SQLite commits. Inspection never repeats the mutation.
                    try:
                        observed = execution_snapshot(previous["execution_root"])
                    except (WorktreeError, OSError) as exc:
                        previous.update(state="uncertain", error=str(exc))
                    else:
                        if observed["repository_identity"] != previous["repository_identity"]:
                            previous.update(state="uncertain", error="parent repository identity changed")
                        elif observed["tree"] == previous["after_tree"]:
                            previous["state"] = "integrated"
                            self.store.put("receipts", previous)
                            result["state"] = "integrated"
                            self._save(helper)
                            return {"ok": True, "already_integrated": True, "recovered": True, "receipt": previous}
                        elif observed["tree"] == previous["before_tree"]:
                            previous.update(state="not_applied", error="No integration changes are present. Review and retry explicitly.")
                        else:
                            previous.update(state="uncertain", error="Parent matches neither the recorded before nor after tree; reconcile before retrying.")
                    self.store.put("receipts", previous)
                    return {"ok": False, "code": "integration_not_applied" if previous["state"] == "not_applied"
                            else "integration_uncertain", "receipt": previous}
            if helper["state"] in ACTIVE_STATES or result.get("state") != "ready":
                raise CollaborationError("helper must be idle with a reviewed frozen result")
            if result["parent_execution_path"] != self.execution_path:
                raise CollaborationError("parent execution checkout changed; refresh the helper first")
            try:
                prepared = prepare_helper_integration(result, self.execution_path)
            except WorktreeError as exc:
                result.update(state="conflict", error=str(exc))
                self._save(helper)
                self._event("agent_worktree_conflict", helper, message=str(exc))
                return {"ok": False, "code": "conflict", "error": str(exc), "result": result}
            receipt = {**prepared, "id": receipt_id, "session_id": self.session_id,
                       "run_id": self.run_id, "agent_id": agent_id, "result_id": result_id,
                       "state": "prepared", "created_at": time.time()}
            self.store.put("receipts", receipt)
            try:
                apply_helper_integration(result, receipt)
                observed = execution_snapshot(self.execution_path)
                if observed["tree"] != receipt["after_tree"]:
                    raise WorktreeError("parent changed during integration; inspect before continuing")
                receipt["state"] = "integrated"
                self.store.put("receipts", receipt)
                result["state"] = "integrated"
                self._save(helper)
                self._event("agent_worktree_integrated", helper, paths=result["paths"])
                return {"ok": True, "receipt": receipt, "paths": result["paths"]}
            except Exception as exc:
                receipt.update(state="uncertain", error=str(exc))
                self.store.put("receipts", receipt)
                return {"ok": False, "code": "integration_uncertain", "receipt": receipt}

    def finish_run(self) -> None:
        """Quiesce children before the parent terminal boundary; retain handles."""
        with self._guard:
            self._closed = True
            for helper in self.store.helpers(self.session_id):
                if helper["run_id"] == self.run_id and helper["state"] in ACTIVE_STATES:
                    self.interrupt(helper["id"])
        self._pool.shutdown(wait=True)

    close = finish_run


def stopping_now(manager: SoloCollaborationManager) -> bool:
    return manager._closed or manager.should_stop()
