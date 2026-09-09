"""Execution-owned acceptance evidence, independent of model prose and retention.

Only this runtime writes receipts. Check declarations describe what to execute;
they never accept a caller-supplied pass result. All tool work uses AgentCore's
normal permission boundary, including the native-provider route.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any


class TaskStateError(ValueError):
    pass


def encoded(value: Any) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def digest(value: Any) -> str:
    return hashlib.sha256(encoded(value).encode()).hexdigest()


def initialize_schema(connection: sqlite3.Connection) -> None:
    connection.executescript("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS task_records (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS task_evidence (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES task_records(id),
            payload TEXT NOT NULL, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS capsule_attempts (
            id TEXT PRIMARY KEY, capsule_id TEXT NOT NULL, payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        UPDATE schema_meta SET version=14 WHERE singleton=1;
        COMMIT;
    """)


CHECK_SCHEMA = {"type": "object", "properties": {
    "id": {"type": "string"}, "requirement": {"type": "string"},
    "kind": {"type": "string", "enum": ["file_exists", "file_contains", "json_value", "command", "human_review"]},
    "path": {"type": "string"}, "value": {}, "pointer": {"type": "string"},
    "command": {"type": "string"}, "files": {"type": "array", "items": {"type": "string"}},
    "timeout": {"type": "integer"},
}, "required": ["id", "kind", "requirement"], "additionalProperties": False}


def relative_path(value: Any) -> str:
    from .capsules import _relative_file
    return _relative_file(value)


def normalize_checks(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 64:
        raise TaskStateError("Acceptance checks must be a list of at most 64 checks.")
    checks, identifiers = [], set()
    for raw in value:
        if not isinstance(raw, dict) or set(raw) - set(CHECK_SCHEMA["properties"]):
            raise TaskStateError("Unknown acceptance check field.")
        item = dict(raw)
        for key in ("id", "requirement", "kind"):
            if not isinstance(item.get(key), str) or not item[key].strip() or len(item[key]) > 8000:
                raise TaskStateError(f"Each check needs a bounded {key}.")
        if item["id"] in identifiers or len(item["id"]) > 200:
            raise TaskStateError("Acceptance check IDs must be unique and bounded.")
        identifiers.add(item["id"])
        if item["kind"] not in CHECK_SCHEMA["properties"]["kind"]["enum"]:
            raise TaskStateError("Unsupported acceptance check kind.")
        if item["kind"].startswith("file_") or item["kind"] == "json_value":
            item["path"] = relative_path(item.get("path"))
        if item["kind"] == "file_contains" and (not isinstance(item.get("value"), str) or not item["value"]):
            raise TaskStateError("file_contains requires text in value.")
        if item["kind"] == "json_value" and "value" not in item:
            raise TaskStateError("json_value requires an expected value.")
        if not isinstance(item.get("pointer", ""), str):
            raise TaskStateError("JSON pointer must be text.")
        if item["kind"] == "command":
            if not isinstance(item.get("command"), str) or not item["command"].strip() or len(item["command"]) > 20000:
                raise TaskStateError("Command checks require a bounded command.")
            timeout = item.get("timeout", 120)
            if type(timeout) is not int or not 1 <= timeout <= 600:
                raise TaskStateError("Check timeout must be between 1 and 600 seconds.")
            item["timeout"] = timeout
        files = item.get("files", [])
        if not isinstance(files, list) or len(files) > 256:
            raise TaskStateError("Check files must be a bounded list.")
        item["files"] = list(dict.fromkeys(relative_path(path) for path in files))
        if len(encoded(item)) > 50000:
            raise TaskStateError("Acceptance check is too large.")
        checks.append(item)
    return checks


def fingerprints(root: str, files: list[str]) -> dict[str, Any]:
    from .capsules import _fingerprint
    return {path: _fingerprint(Path(root).resolve(), path) for path in sorted(set(files))}


class TaskStateStore:
    def __init__(self, runs: Any):
        self.runs = runs

    def get(self, identifier: str) -> dict[str, Any] | None:
        with self.runs._connect(readonly=True) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='task_records'").fetchone():
                return None
            row = db.execute("SELECT payload FROM task_records WHERE id=?", (identifier,)).fetchone()
            return json.loads(row[0]) if row else None

    def save(self, value: dict[str, Any], *, expected_revision: int | None = None) -> dict[str, Any]:
        if self.runs.read_only:
            raise TaskStateError("Task evidence storage is read-only.")
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload FROM task_records WHERE id=?", (value["id"],)).fetchone()
            if expected_revision is not None and (not row or json.loads(row[0])["revision"] != expected_revision):
                raise TaskStateError("Task requirements changed; refresh before verifying.")
            db.execute("INSERT INTO task_records VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at",
                       (value["id"], encoded(value), time.time()))
        return value

    def ensure(self, identifier: str, *, request: str, revision: int, workspace: str,
               execution: str, session_id: str = "", plan: dict | None = None) -> dict:
        existing = self.get(identifier)
        expected_revision = existing["revision"] if existing else None
        if existing and existing["revision"] > revision:
            raise TaskStateError("A newer task revision already exists.")
        value = existing or {"id": identifier, "schema_version": 1, "original_request": request,
                             "inputs": [], "checks": [], "evidence_ids": [], "verification_status": "pending"}
        if existing and (existing["revision"] != revision or existing["execution_path"] != str(Path(execution).resolve())):
            value = {**value, "verification_status": "pending", "evidence_ids": []}
        if not existing or existing.get("request") != request:
            value["inputs"] = [*value.get("inputs", []), {"revision": revision, "text": request}]
        value.update(revision=revision, request=request, workspace_root=str(Path(workspace).resolve()),
                     execution_path=str(Path(execution).resolve()), session_id=session_id)
        if plan is not None:
            value["plan"] = plan
            value["requirements"] = plan.get("constraints", []) or [request]
        else:
            value["requirements"] = [request]
        return self.save(value, expected_revision=expected_revision)

    def receipts(self, identifier: str) -> list[dict]:
        with self.runs._connect(readonly=True) as db:
            return [json.loads(r[0]) for r in db.execute("SELECT payload FROM task_evidence WHERE task_id=? ORDER BY created_at", (identifier,))]

    def record(self, value: dict, receipts: list[dict], *, expected_revision: int) -> dict:
        if self.runs.read_only:
            raise TaskStateError("Task evidence storage is read-only.")
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload FROM task_records WHERE id=?", (value["id"],)).fetchone()
            if not row or json.loads(row[0])["revision"] != expected_revision:
                raise TaskStateError("Task changed while checks were running.")
            for receipt in receipts:
                db.execute("INSERT INTO task_evidence VALUES(?,?,?,?)", (receipt["id"], value["id"], encoded(receipt), time.time()))
            db.execute("UPDATE task_records SET payload=?,updated_at=? WHERE id=?", (encoded(value), time.time(), value["id"]))
        return value

    def completion(self, identifier: str, *, revision: int | None = None) -> tuple[str, str]:
        value = self.get(identifier)
        if not value:
            return "needs_review", "No recorded acceptance checks are available."
        if revision is not None and value["revision"] != revision:
            return "needs_review", "The requirements changed after verification."
        status = value.get("verification_status", "pending")
        if status == "accepted":
            return "accepted", "Accepted by the user; not machine verified."
        receipts = {r["id"]: r for r in self.receipts(identifier)}
        selected = [receipts[key] for key in value.get("evidence_ids", []) if key in receipts]
        if ({r.get("check_hash") for r in selected} != {digest(c) for c in value.get("checks", [])}
                or any(r.get("revision") != value["revision"] for r in selected)):
            return "needs_review", "The current acceptance checks do not have matching execution evidence."
        for key in value.get("evidence_ids", []):
            receipt = receipts.get(key)
            if not receipt:
                return "needs_review", "Verification evidence is unavailable."
            try:
                if receipt.get("workspace_scope"):
                    from .capsule_progress import workspace_state
                    current = workspace_state(value["execution_path"])
                else:
                    current = fingerprints(value["execution_path"], list(receipt["fingerprints"]))
                if current != receipt["fingerprints"]:
                    return "failed", "Files changed after verification; run the affected checks again."
            except (ValueError, OSError):
                return "needs_review", "Verification inputs are unavailable."
        if status == "passed" and value.get("evidence_ids") and all(r["state"] == "passed" for r in selected):
            return "passed", "All declared acceptance checks passed."
        return status if status in {"failed", "needs_review"} else "needs_review", value.get("verification_reason", "Required checks have not been verified.")


class TaskVerifier:
    def __init__(self, store: TaskStateStore, identifier: str, core: Any, run_id: str, *, parallelism: int | None = None):
        self.store, self.identifier, self.core, self.run_id = store, identifier, core, run_id
        policy = getattr(core, "config", {}).get("parallel_check_policy") or {}
        measured = (policy.get("version") == 1 and policy.get("correctness_equal") is True
                    and policy.get("median_improvement", 0) >= 0.10 and policy.get("p95_regression", 1) <= 0.05)
        self.parallelism = min(max(parallelism if parallelism is not None else 2 if measured else 1, 1), 2)

    def _call(self, call: Any, decider: Any) -> str:
        prior = getattr(self.core, "_verification_running", False)
        self.core._verification_running = True
        try:
            call.call_id = uuid.uuid4().hex
            self.core._verification_tool_started = None
            result = self.core._run_tool_call(call, decider)
            if not call.execution_receipt.get("executed"):
                result = "Permission denied: the acceptance check was not executed. " + result
            self.core.session.append_strict({"type": "verification_observation", "task_id": self.identifier,
                                            "tool": call.name, "result": result, "run_id": self.run_id})
            return result
        finally:
            self.core._verification_running = prior

    def verify(self, checks: list[dict], decider: Any, *, fallback: str = "Review the requested result") -> dict:
        value = self.store.get(self.identifier)
        if value is None:
            raise TaskStateError("Task verification was not initialized.")
        checks = normalize_checks(checks)
        # A completion report can add checks, but cannot silently remove or
        # weaken a previously declared requirement in the same task revision.
        previous = value.get("checks", []) if value.get("checks_revision") == value["revision"] else []
        by_id = {c["id"]: c for c in checks}
        for prior in previous:
            if prior["kind"] == "human_review" and prior["id"] == "required-review":
                continue
            if prior["id"] in by_id and by_id[prior["id"]] != prior:
                raise TaskStateError("A declared check changed. Revise the task or plan before replacing it.")
            if prior["id"] not in by_id:
                checks.append(prior)
        if not checks:
            checks = [{"id": "required-review", "kind": "human_review", "requirement": fallback, "files": []}]
        value = {**value, "checks": checks, "checks_revision": value["revision"], "verification_status": "checking"}
        self.store.save(value, expected_revision=value["revision"])
        self.core._emit({"type": "task_verification", "task_id": self.identifier, "state": "checking"})
        receipts = []
        index = 0
        while index < len(checks):
            batch = []
            while index < len(checks) and checks[index]["kind"] in {"file_exists", "file_contains", "json_value"}:
                batch.append(checks[index])
                index += 1
            if len(batch) > 1 and self.parallelism > 1:
                import copy
                from concurrent.futures import ThreadPoolExecutor
                def worker(check):
                    core = copy.copy(self.core)
                    core.tool_ctx = copy.copy(self.core.tool_ctx)
                    core.tool_ctx.read_files = set(self.core.tool_ctx.read_files)
                    verifier = TaskVerifier(self.store, self.identifier, core, self.run_id, parallelism=1)
                    return verifier._check(check, value, decider)
                with ThreadPoolExecutor(max_workers=self.parallelism, thread_name_prefix="task-check") as pool:
                    receipts.extend(pool.map(worker, batch))
            else:
                receipts.extend(self._check(check, value, decider) for check in batch)
            if index < len(checks):
                receipts.append(self._check(checks[index], value, decider))
                index += 1
        states = {r["state"] for r in receipts}
        status = "failed" if "failed" in states else "needs_review" if "needs_review" in states else "passed"
        value.update(verification_status=status, evidence_ids=[r["id"] for r in receipts],
                     verification_reason="; ".join(r["requirement"] + ": " + r["detail"] for r in receipts if r["state"] != "passed"))
        self.store.record(value, receipts, expected_revision=value["revision"])
        from .task_journal import TaskJournal
        journal = getattr(self.core, "task_journal", None) or TaskJournal.for_owner(self.store.runs, self.identifier)
        journal.run_id = self.run_id
        for receipt in receipts:
            if receipt["state"] == "passed":
                journal.milestone("check_passed", {"check_hash": receipt["check_hash"],
                    "fingerprints": receipt["fingerprints"], "revision": receipt["revision"]})
        self.core._emit({"type": "task_verification", "task_id": self.identifier, "state": status,
                         "reason": value["verification_reason"], "evidence_ids": value["evidence_ids"]})
        return value

    def _check(self, check: dict, value: dict, decider: Any) -> dict:
        from .ollama import ToolCall
        if self.core._interrupt.is_set():
            raise InterruptedError("Verification interrupted")
        files = list(dict.fromkeys([*check.get("files", []), *([check["path"]] if check.get("path") else [])]))
        receipt = {"id": uuid.uuid4().hex, "check_id": check["id"], "check_hash": digest(check),
                   "requirement": check["requirement"], "revision": value["revision"], "run_id": self.run_id,
                   "execution_path": value["execution_path"], "state": "needs_review", "fingerprints": {}}
        try:
            before = fingerprints(value["execution_path"], files)
            kind = check["kind"]
            if kind == "human_review":
                receipt["detail"] = check["requirement"]
            elif kind == "command":
                if not files:
                    from .capsule_progress import workspace_state
                    before = workspace_state(value["execution_path"])
                    receipt["workspace_scope"] = True
                invocation = ToolCall("bash", {"command": check["command"], "timeout": check.get("timeout", 120)})
                result = self._call(invocation, decider)
                observed = invocation.execution_receipt.get("command")
                receipt["tool_invocation_id"] = invocation.execution_receipt["id"]
                if observed and observed.get("command") == check["command"]:
                    receipt["exit_code"] = observed["exit_code"]
                    receipt["state"] = "passed" if observed["exit_code"] == 0 else "failed"
                receipt["detail"] = result[-8000:]
            else:
                # Reading uses the same permission and tool access checks as ordinary work.
                invocation = ToolCall("read_file", {"path": check["path"]})
                result = self._call(invocation, decider)
                receipt["tool_invocation_id"] = invocation.execution_receipt["id"]
                if result.startswith(("Error", "Permission denied")):
                    receipt["state"] = "failed" if not result.startswith("Permission denied") and before[check["path"]]["status"] == "missing" else "needs_review"
                    receipt["detail"] = result[:8000]
                else:
                    target = (Path(value["execution_path"]) / check["path"]).resolve()
                    target.relative_to(Path(value["execution_path"]))
                    passed = target.is_file()
                    if kind == "file_contains":
                        passed = check["value"] in target.read_text()
                    elif kind == "json_value":
                        from .evaluations import _json_pointer
                        passed = _json_pointer(json.loads(target.read_text()), check.get("pointer", "")) == check["value"]
                    receipt["state"] = "passed" if passed else "failed"
                    receipt["detail"] = "Observed file matches the check." if passed else "Observed file does not match the check."
            receipt["fingerprints"] = (workspace_state(value["execution_path"]) if receipt.get("workspace_scope")
                                        else fingerprints(value["execution_path"], files))
            if kind != "command" and receipt["fingerprints"] != before:
                receipt.update(state="needs_review", detail="Input changed during verification.")
        except (ValueError, OSError, KeyError, IndexError, TypeError) as exc:
            receipt.update(state="needs_review", detail=str(exc))
        return receipt
