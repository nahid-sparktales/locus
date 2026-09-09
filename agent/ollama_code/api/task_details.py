"""Unified task projection; execution controls retain their existing owners."""
import copy
import json
import uuid
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException

from ..chat_service import ChatService
from ..file_history import FileHistory
from ..goals import GoalStore
from ..runstore import ACTIVE_NONRECOVERABLE_STATES, SCHEMA_VERSION
from ..session_runtime import session_has_active_run
from ..sessions import SessionMeta
from ..task_journal import TaskJournal
from ..task_state import TaskStateStore, TaskVerifier
from ..usage_ledger import UsageLedger, UsageLimitError
from .dependencies import get_service

Service = Annotated[ChatService, Depends(get_service)]


def _context(service, session_id):
    if SessionMeta.get(session_id).get("identity_mode") or (service.core.session.session_id == session_id and service.core.identity_mode):
        raise HTTPException(404, "Task details are unavailable for private Identity chats.")
    with service.run_store._connect(readonly=True) as db:
        row = db.execute("SELECT id FROM runs WHERE session_id=? ORDER BY created_at DESC LIMIT 1", (session_id,)).fetchone()
    journal = TaskJournal.for_owner(service.run_store, "session:" + session_id)
    if row:
        run = service.run_store.run(row[0])
    else:
        # A saved plan/goal is a task even before the first execution. Project
        # it without creating a run, claiming a goal, or admitting work.
        plan = journal.snapshot().get("plan") or {}
        goal = GoalStore(service.run_store).for_session(session_id)
        root = (plan.get("approval_reference") or {}).get("execution_path")
        execution = (goal or {}).get("execution") or {}
        root = root or execution.get("execution_path") or execution.get("workspace_root")
        if not root:
            raise HTTPException(404, "This task has no saved plan or execution yet.")
        run = {"id": "", "workspace_root": root, "execution_path": root,
               "state": "planned", "request": (goal or {}).get("objective") or plan.get("title", "Saved task"), "manifest": {}}
    if (run.get("manifest") or {}).get("identity_mode"):
        raise HTTPException(404, "Task details are unavailable for private Identity chats.")
    journal.run_id = run["id"]
    return journal, run


def _workspace_busy(service, session_id, root):
    """Restoration must also respect other chats writing this checkout."""
    active = sorted(ACTIVE_NONRECOVERABLE_STATES | {"waiting_dispatch_approval"})
    with service.run_store._connect(readonly=True) as db:
        rows = db.execute(f"SELECT session_id,execution_path,workspace_root FROM runs WHERE state IN ({','.join('?' for _ in active)})", active).fetchall()
    return any(r["session_id"] == session_id or Path(r["execution_path"] or r["workspace_root"]).resolve() == root for r in rows) or (
        service.busy and (service.core.session.session_id == session_id or Path(service.core.cwd).resolve() == root))


def _outputs(snapshot, history, files):
    plan = snapshot.get("plan") or {}
    paths = {c["path"] for c in files}
    paths.update(p for p in plan.get("files", []) if isinstance(p, str))
    for step in plan.get("step_details", []):
        paths.update(p for p in step.get("outputs", []) if isinstance(p, str))
    result = []
    for path in sorted(paths)[:4096]:
        item = {"path": path}
        try:
            target = history.target(path)
            item["state"] = "present" if target.is_file() else "missing"
        except (ValueError, OSError) as exc:
            item.update(state="unavailable", reason=str(exc))
        result.append(item)
    return result


def task_detail(session_id: str, service: Service):
    journal, run = _context(service, session_id)
    snapshot = journal.snapshot()
    history = FileHistory(journal, run.get("execution_path") or run["workspace_root"])
    goal = GoalStore(service.run_store).for_session(session_id)
    if goal and goal["status"] in {"completed", "cancelled"} and run["id"] and (
        (run.get("manifest") or {}).get("goal_id") != goal["id"] and goal.get("current_run_id") != run["id"]
    ):
        goal = None
    verification = TaskStateStore(service.run_store).get("work:" + journal.task_id)
    state, blocker = run.get("state", "unknown"), run.get("recovery_reason") or ""
    if state == "completed" and (run.get("manifest") or {}).get("mode") in {"plan", "grill"}:
        state = "planned"
        blocker = "Review and approve the saved plan before starting execution."
    if goal:
        state, blocker = goal["status"], goal.get("reason", "")
    capsule = (run.get("manifest") or {}).get("capsule") or (run.get("manifest") or {}).get("capsule_context")
    capsule_record, attempts = None, []
    if capsule and capsule.get("id"):
        from ..capsule_progress import CapsuleProgressStore
        from ..capsules import CapsuleStore
        attempts = CapsuleProgressStore(service.run_store).list(capsule["id"])
        try:
            capsule_record = {**CapsuleStore(run["workspace_root"]).get(capsule["id"]), "attempts": attempts}
            snapshot["plan"] = capsule_record["plan"]
        except (ValueError, OSError):
            blocker = "The saved capsule is unavailable. Restore its workspace before continuing."
        if attempts:
            state, blocker = attempts[0]["state"], attempts[0].get("reason", "")
    if verification and not goal and not capsule:
        verified, reason = TaskStateStore(service.run_store).completion(verification["id"])
        reference = (snapshot.get("plan") or {}).get("approval_reference")
        if reference and reference["revision"] != verification["revision"]:
            verified, reason = "needs_review", "The saved plan changed. Approve its current revision before continuing."
        verification = {**verification, "current_status": verified, "current_reason": reason}
        if verified != "passed":
            blocker = reason
    with service.run_store._connect(readonly=True) as db:
        original = db.execute("SELECT request FROM runs WHERE session_id=? AND request<>'' ORDER BY created_at LIMIT 1", (session_id,)).fetchone()
        exclusions = [json.loads(r[0]) for r in db.execute("SELECT payload FROM task_observations WHERE task_id=? AND kind='restoration_exclusion' ORDER BY created_at DESC LIMIT 20", (journal.task_id,))]
        recovery = [{"token": r["id"], "state": r["state"], "created_at": r["created_at"],
                     "paths": json.loads(r["payload"]).get("selected", [])} for r in db.execute(
            "SELECT id,state,payload,created_at FROM task_restorations WHERE task_id=? AND state IN ('applying','needs_recovery','completed','recovered') ORDER BY created_at DESC LIMIT 50", (journal.task_id,))
            if json.loads(r["payload"]).get("root") == str(history.root)]
        reviews = [json.loads(r[0]) for r in db.execute("SELECT payload FROM task_observations WHERE task_id=? AND kind='review' ORDER BY created_at DESC LIMIT 1", (journal.task_id,))]
        accepted = db.execute("SELECT payload FROM task_observations WHERE task_id=? AND kind='accepted' ORDER BY created_at DESC LIMIT 1", (journal.task_id,)).fetchone()
    if accepted and not goal and not capsule and json.loads(accepted[0]).get("run_id") == run["id"] and json.loads(accepted[0]).get("revision") == history.revision() - 1:
        state, blocker = "accepted", "Accepted by you; machine verification remains separate."
    for review in reviews:
        from ..capsule_progress import workspace_state
        try:
            review["current"] = review.get("files") == workspace_state(str(history.root))
            if review.get("execution_path") and review["execution_path"] != str(history.root):
                review["current"] = False
            if review.get("approved_plan") and review["approved_plan"] != (snapshot.get("plan") or {}).get("approval_reference"):
                review["current"] = False
            if review.get("capsule_id"):
                from ..capsules import CapsuleStore
                current = CapsuleStore(run["workspace_root"]).get(review["capsule_id"])
                if current["revision"] != review.get("capsule_revision"):
                    review["current"] = False
        except (ValueError, OSError):
            review["current"] = False
    can_retry = bool(verification and verification.get("checks") and not goal and not capsule
        and (snapshot.get("plan") or {}).get("approval_reference", {}).get("revision", verification["revision"]) == verification["revision"]
        and all(c["kind"] in {"file_exists", "file_contains", "json_value"} for c in verification["checks"]))
    busy = _workspace_busy(service, session_id, history.root)
    kind = "capsule" if capsule else "goal" if goal else "work"
    settled = state in {"completed", "failed", "interrupted", "paused", "accepted", "needs_review", "blocked", "cancelled"}
    attempt = attempts[0] if attempts else {}
    unresolved = bool(attempt.get("uncertain_action") or attempt.get("pending_usage"))
    actions = []
    if not busy:
        actions.append("restore")
        if kind == "work" and run["id"] and settled:
            actions.append("run_again")
            if state != "accepted":
                actions.append("accept")
            if run.get("recoverable"):
                actions.append("resume")
            if can_retry:
                actions.append("retry_checks")
        elif kind == "capsule" and capsule_record:
            actions.append("recipe")
            if settled and not unresolved:
                actions.append("run_again")
                if attempt and state != "completed":
                    actions.extend(["resume", "retry_checks"])
                if state == "needs_review" and attempt.get("revision") == capsule_record["revision"]:
                    actions.append("accept")
        elif kind == "goal":
            if state in {"paused", "blocked", "needs_review", "budget_exhausted"}:
                actions.append("resume")
            if state == "needs_review":
                actions.append("accept")
    files = history.changes()
    recovery_history = [{"run_id": r["id"], "state": r["state"], "reason": r.get("recovery_reason") or "",
                         "created_at": r["created_at"]} for r in service.run_store.list_runs(session_id=session_id, limit=50)]
    return {**snapshot, "session_id": session_id, "request": original[0] if original else run.get("request", ""),
            "state": state, "run_id": run["id"], "execution_path": str(history.root),
            "goal": goal, "capsule": capsule_record, "owner_kind": kind, "actions": actions,
            "interface_version": 1, "schema_version": SCHEMA_VERSION,
            "verification": verification,
            "can_retry_checks": can_retry,
            "usage": UsageLedger(journal).summary(), "files": files, "outputs": _outputs(snapshot, history, files),
            "recovery_history": recovery_history,
            "revision": history.revision(), "restorations": recovery, "reviews": reviews, "exclusions": exclusions,
            "blocker": blocker}


def task_limit(session_id: str, service: Service, body: dict[str, Any] = Body(default_factory=dict)):
    journal, _ = _context(service, session_id)
    try:
        UsageLedger(journal).set_limit(body.get("amount"))
        return {"ok": True}
    except (ValueError, UsageLimitError) as exc:
        raise HTTPException(422, str(exc)) from exc


def task_reconcile_usage(session_id: str, service: Service, body: dict[str, Any] = Body(default_factory=dict)):
    journal, _ = _context(service, session_id)
    from ..usage_ledger import UsageLimitError
    try:
        UsageLedger(journal).reconcile(str(body.get("id") or ""), amount=body.get("amount"), note=body.get("note", ""))
        return {"ok": True}
    except (ValueError, UsageLimitError) as exc:
        raise HTTPException(409, str(exc)) from exc


def task_restore(session_id: str, service: Service, body: dict[str, Any] = Body(default_factory=dict)):
    with service.core._task_write_lock:
        return _restore(session_id, service, body)


def _restore(session_id, service, body):
    journal, run = _context(service, session_id)
    history = FileHistory(journal, run.get("execution_path") or run["workspace_root"])
    if _workspace_busy(service, session_id, history.root):
        raise HTTPException(409, "Stop active tasks in this execution location before restoring files.")
    try:
        action = body.get("action", "preview")
        if action == "preview":
            ids = body.get("change_ids")
            if not isinstance(ids, list) or any(not isinstance(i, str) for i in ids):
                raise ValueError("Select file changes to preview.")
            return history.preview(ids)
        if action == "apply":
            if not isinstance(body.get("selected_paths"), list) or not isinstance(body.get("fingerprints"), dict):
                raise ValueError("Select files from a restoration preview.")
            return history.apply(str(body.get("token") or ""), body["selected_paths"], body.get("revision"), body["fingerprints"])
        if action == "recover":
            return history.recover(str(body.get("token") or ""))
        raise ValueError("Unknown restoration action.")
    except (ValueError, OSError) as exc:
        raise HTTPException(409, str(exc)) from exc


def task_accept(session_id: str, service: Service, body: dict[str, Any] = Body(default_factory=dict)):
    journal, run = _context(service, session_id)
    if session_has_active_run(service.run_store, session_id) or (service.core.session.session_id == session_id and service.busy):
        raise HTTPException(409, "Stop the task before accepting its result.")
    detail = task_detail(session_id, service)
    if detail["owner_kind"] != "work":
        raise HTTPException(409, "Use the Goal or Capsule acceptance control for this task.")
    if "accept" not in detail["actions"]:
        raise HTTPException(409, "This task has no inactive execution result to accept.")
    history = FileHistory(journal, run.get("execution_path") or run["workspace_root"])
    if type(body.get("revision")) is not int or history.revision() != body["revision"]:
        raise HTTPException(409, "The task changed. Refresh the result before accepting it.")
    journal.observe(uuid.uuid4().hex, "accepted", {"run_id": run["id"], "revision": body["revision"], "machine_verified": False})
    return {"ok": True}


def task_retry_checks(session_id: str, service: Service, body: dict[str, Any] = Body(default_factory=dict)):
    """Explicit safe-check action; arbitrary commands keep the execution route."""
    journal, run = _context(service, session_id)
    history = FileHistory(journal, run.get("execution_path") or run["workspace_root"])
    if service.core.session.session_id != session_id or service.core.cwd != str(history.root):
        raise HTTPException(409, "Open this task's execution location before retrying its checks.")
    with service.core._task_write_lock:
        if service.busy or session_has_active_run(service.run_store, session_id):
            raise HTTPException(409, "Stop the active task before retrying checks.")
        if type(body.get("revision")) is not int or history.revision() != body["revision"]:
            raise HTTPException(409, "The task changed. Refresh its checks.")
        details = task_detail(session_id, service)
        if not details["can_retry_checks"]:
            raise HTTPException(409, "Use Resume for checks that require the task's execution controls.")
        core = copy.copy(service.core)
        core.tool_ctx = copy.copy(service.core.tool_ctx)
        core.tool_ctx.read_files = set()
        core.task_journal = journal
        core.capsule_runtime = core.goal_runtime = None
        core.helper_allowed_tools = {"read_file"}
        verification = details["verification"]
        result = TaskVerifier(TaskStateStore(service.run_store), verification["id"], core, run["id"]).verify(verification["checks"], lambda *_: "deny")
        journal.observe(uuid.uuid4().hex, "checks_retried", {"verification_status": result["verification_status"], "evidence_ids": result["evidence_ids"]})
        return {"ok": True, "verification": result}


def register_routes(router: APIRouter):
    router.add_api_route("/api/sessions/{session_id}/task", task_detail, methods=["GET"])
    router.add_api_route("/api/sessions/{session_id}/task/limit", task_limit, methods=["POST"])
    router.add_api_route("/api/sessions/{session_id}/task/usage", task_reconcile_usage, methods=["POST"])
    router.add_api_route("/api/sessions/{session_id}/task/restore", task_restore, methods=["POST"])
    router.add_api_route("/api/sessions/{session_id}/task/accept", task_accept, methods=["POST"])
    router.add_api_route("/api/sessions/{session_id}/task/checks", task_retry_checks, methods=["POST"])
