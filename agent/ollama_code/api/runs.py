"""Run, orchestration, task, usage, and MCP task routes."""

import asyncio
import os
import re
import signal
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request

from ..capabilities import enabled as capability_enabled
from ..chat_service import AgentBusyError, ChatService
from ..extensions import ExtensionError
from ..orchestration import (
    OrchestrationError,
    orchestration_fingerprint,
    parse_manifest,
)
from ..runstore import RunStoreError
from ..session_runtime import session_has_active_run
from ..sessions import SessionMeta, SessionStore
from ..telemetry import TelemetryError, send_otlp
from ..tools import truncate_output
from ..worktrees import TaskCheckout, TaskCheckoutStore, WorktreeError
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]
TeamTurnRunner = Callable[..., None]


def _get_team_runner(request: Request) -> TeamTurnRunner:
    runner = getattr(request.app.state, "evaluation_team_runner", None)
    if not callable(runner):
        raise HTTPException(503, "team execution is not ready")
    return runner


TeamRunnerDependency = Annotated[TeamTurnRunner, Depends(_get_team_runner)]


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def _require_capability(name: str) -> None:
    if not capability_enabled(name):
        raise HTTPException(404, f"capability is disabled: {name}")


def mcp_task_list(
    service: ServiceDependency,
    run_id: str = Query(default=""),
    nonterminal: bool = Query(default=False),
) -> dict[str, Any]:
    _require_capability("modern_mcp")
    return {
        "tasks": service.run_store.mcp_tasks(
            run_id=run_id,
            nonterminal=nonterminal,
        )
    }


def mcp_task_lookup(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    _require_capability("modern_mcp")
    try:
        return {"ok": True, **service.core.mcp.lookup_task(task_id)}
    except ExtensionError as exc:
        raise HTTPException(409, str(exc)) from exc


def mcp_task_cancel(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    _require_capability("modern_mcp")
    try:
        return {"ok": True, **service.core.mcp.cancel_task(task_id)}
    except ExtensionError as exc:
        raise HTTPException(409, str(exc)) from exc


def _require_task_idle(service: ChatService, task: TaskCheckout) -> None:
    if task.session_id and session_has_active_run(service.run_store, task.session_id):
        raise HTTPException(409, "wait for this chat to stop before changing its checkout")


# ------------------------------------------------------- Durable orchestrations


def usage_summary(
    service: ServiceDependency, since: float = Query(default=0.0, ge=0.0)
) -> dict[str, Any]:
    """Spend and token rollups over data already on disk — a view, not a bill."""
    _require_capability("durable_runs")
    return service.run_store.usage_summary(since=since)


def orchestration_list(
    service: ServiceDependency,
    session_id: str = Query(default="", max_length=160),
    states: str = Query(default="", max_length=500),
    workspace: str = Query(default="", max_length=4_000),
    cursor: float = Query(default=0.0, ge=0.0),
    limit: int = Query(default=100, ge=1, le=500),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    if session_id and not store.list_runs(session_id=session_id, limit=1):
        path = SessionStore.path_for(session_id)
        if path is not None:
            snapshot = SessionStore.agent_activity(path)
            header = SessionStore.header(path)
            store.import_legacy_snapshot(
                session_id,
                snapshot,
                workspace_root=str(header.get("cwd") or ""),
            )
    return {
        "runs": store.list_runs(
            session_id=session_id,
            states=[item.strip() for item in states.split(",") if item.strip()],
            workspace=workspace,
            cursor=cursor,
            limit=limit,
        ),
        "read_only": store.read_only,
    }


def run_queue(
    service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("durable_runs")
    session_id = str(body.get("session_id") or "")
    if not session_id:
        raise HTTPException(422, "session_id is required")
    run_id = str(body.get("run_id") or uuid.uuid4().hex)
    return service.run_store.queue_run(
        run_id,
        session_id=session_id,
        message_id=str(body.get("message_id") or ""),
        team_id=str(body.get("team_id") or ""),
        team_name=str(body.get("team_name") or ""),
        workspace_root=str(body.get("workspace_root") or ""),
        execution_path=str(body.get("execution_path") or ""),
        request=str(body.get("request") or ""),
        run_kind=str(body.get("run_kind") or "solo"),
        execution_environment=str(body.get("execution_environment") or "local"),
        retry_parent_id=str(body.get("retry_parent_id") or ""),
        manifest={"solo_swarm": body.get("solo_swarm") is True},
    )


def run_queue_update(
    service: ServiceDependency, run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    try:
        action = str(body.get("action") or "")
        if action == "admit":
            service.run_store.admit(run_id)
            return service.run_store.run(run_id) or {}
        return service.run_store.reorder_queue(run_id, action)
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc


def run_retry(service: ServiceDependency, run_id: str) -> dict[str, Any]:
    store = service.run_store
    original = store.run(run_id)
    if original is None:
        raise HTTPException(404, f"run not found: {run_id}")
    if original["state"] not in {"failed", "interrupted", "cancelled", "paused"}:
        raise HTTPException(409, "only stopped runs can be retried")
    retry_id = uuid.uuid4().hex
    return store.queue_run(
        retry_id,
        session_id=str(original.get("session_id") or ""),
        team_id=str(original.get("team_id") or ""),
        team_name=str(original.get("team_name") or ""),
        workspace_root=str(original.get("workspace_root") or ""),
        execution_path=str(original.get("execution_path") or ""),
        request=str(original.get("request") or ""),
        run_kind=str(original.get("run_kind") or "solo"),
        execution_environment=str(original.get("execution_environment") or "local"),
        retry_parent_id=run_id,
        manifest=original.get("manifest") if isinstance(original.get("manifest"), dict) else None,
        schedule_id=str(original.get("schedule_id") or ""),
        occurrence_id=str(original.get("occurrence_id") or ""),
        scheduled_for=original.get("scheduled_for"),
    )


def orchestration_detail(service: ServiceDependency, run_id: str) -> dict[str, Any]:
    _require_capability("durable_runs")
    value = service.run_store.run(run_id)
    if value is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    return value


def orchestration_update(
    service: ServiceDependency, run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("durable_runs")
    if not isinstance(body.get("pinned"), bool):
        raise HTTPException(422, "pinned must be a boolean")
    try:
        return service.run_store.set_pinned(run_id, bool(body["pinned"]))
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


def orchestration_events(
    service: ServiceDependency,
    run_id: str,
    after_seq: int = Query(default=0, ge=0),
    limit: int = Query(default=5_000, ge=1, le=10_000),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    if store.run(run_id) is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    events = store.events(run_id, after_seq=after_seq, limit=limit)
    return {
        "run_id": run_id,
        "after_seq": after_seq,
        "events": events,
        "last_seq": int(events[-1].get("seq") or after_seq) if events else after_seq,
    }


def orchestration_export(
    service: ServiceDependency,
    run_id: str,
    include_content: bool = Query(default=False),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return service.run_store.export(run_id, include_content=include_content)
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


def orchestration_otlp(
    service: ServiceDependency, run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return send_otlp(
            service.run_store,
            run_id,
            str(body.get("endpoint") or ""),
            authorization=str(body.get("authorization") or ""),
            include_content=bool(body.get("include_content")),
        )
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc
    except TelemetryError as exc:
        raise HTTPException(422, str(exc)) from exc


def orchestration_pause(service: ServiceDependency, run_id: str) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service
    if svc.active_run_id != run_id or not svc.busy:
        raise HTTPException(409, "that orchestration is not actively running")
    svc.pause_requested = True
    svc.run_store.set_state(
        run_id,
        "pausing",
        recoverable=False,
        reason="Waiting for the next safe boundary before pausing.",
    )
    svc.core.interrupt()
    svc.interrupt_parallel_writers()
    svc.deny_all_pending()
    svc.cancel_all_computer_actions()
    svc.cancel_all_simulator_actions()
    svc.cancel_all_browser_actions()
    svc.cancel_all_notes_actions()
    svc.cancel_all_wallet_actions()
    svc.cancel_dispatch_decisions()
    svc.cancel_all_mcp_inputs()
    svc.emit(
        {
            "type": "orchestration_pause_requested",
            "run_id": run_id,
            "state": "pausing",
        }
    )
    return {"ok": True, "run_id": run_id, "state": "pausing"}


def orchestration_cancel(service: ServiceDependency, run_id: str) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service
    record = svc.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    terminal_states = {"cancelled", "completed", "failed", "interrupted", "discarded"}
    if str(record.get("state") or "") in terminal_states:
        return {"ok": True, "run_id": run_id, "state": str(record["state"])}
    if svc.active_run_id != run_id or not svc.busy:
        owner = str(record.get("worker_id") or "")
        if owner and owner != svc.worker_id:
            raise HTTPException(409, "that orchestration is active in another worker")
        raise HTTPException(409, "that orchestration is not actively running")
    svc.pause_requested = False
    svc.cancel_requested_runs.add(run_id)
    svc.core.interrupt()
    svc.interrupt_parallel_writers()
    svc.deny_all_pending()
    svc.cancel_all_computer_actions()
    svc.cancel_all_simulator_actions()
    svc.cancel_all_browser_actions()
    svc.cancel_all_notes_actions()
    svc.cancel_all_wallet_actions()
    svc.cancel_dispatch_decisions()
    svc.cancel_all_mcp_inputs()
    svc.run_store.set_state(run_id, "cancelled", recoverable=False)
    return {"ok": True, "run_id": run_id, "state": "cancelled"}


def orchestration_discard(service: ServiceDependency, run_id: str) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service
    record = svc.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    if str(record.get("state") or "") in {
        "queued",
        "dispatching",
        "running",
        "reviewing",
        "pausing",
        "waiting_dispatch_approval",
        "waiting_permission",
        "waiting_computer",
    }:
        raise HTTPException(409, "stop the active orchestration before discarding it")
    if svc.active_run_id == run_id and svc.busy:
        raise HTTPException(409, "stop the active orchestration before discarding it")
    try:
        return {"ok": True, "run": svc.run_store.discard(run_id)}
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


def orchestration_reconcile_worker_exit(
    service: ServiceDependency, run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    """Promote a run to recoverable only after its recorded worker exited."""
    _require_capability("recovery_controls")
    svc = service
    record = svc.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    reported_worker = str(body.get("worker_id") or "")
    recorded_worker = str(record.get("worker_id") or "")
    if reported_worker and recorded_worker and reported_worker != recorded_worker:
        return record
    # This endpoint is called from the native Process termination handler.
    # RunStore still verifies that the recorded owner PID is gone; once it is,
    # a lease left behind by that dead process must not delay recovery for the
    # scheduler's full expiry window.
    svc.run_store.mark_abandoned()
    updated = svc.run_store.run(run_id)
    if updated is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    return updated


def orchestration_dispatch_decision(
    service: ServiceDependency, run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("adaptive_routing")
    action = str(body.get("action") or "cancel")
    if action not in {"run", "redispatch", "cancel"}:
        raise HTTPException(422, "action must be run, redispatch, or cancel")
    decision: dict[str, Any] = {"action": action}
    if isinstance(body.get("plan"), dict):
        decision["plan"] = body["plan"]
    if not service.answer_dispatch(run_id, decision):
        raise HTTPException(409, "that dispatch plan is no longer waiting")
    return {"ok": True, "run_id": run_id, "action": action}


async def _resume_orchestration(
    service: ChatService,
    team_runner: TeamTurnRunner,
    run_id: str,
    body: dict[str, Any],
    *,
    action: str,
) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service
    record = svc.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    if not record.get("recoverable") or str(record.get("state") or "") not in {
        "paused",
        "interrupted",
    }:
        raise HTTPException(409, "that orchestration is not in a recoverable state")
    if svc.busy:
        raise _busy_http()
    manifest = body.get("manifest")
    if not isinstance(manifest, dict):
        raise HTTPException(422, "resume requires the current in-memory team manifest")
    manifest = dict(manifest)
    same_run_actions = {"resume", "retry", "reassign", "run_with_locus"}
    if action in same_run_actions:
        manifest["run_id"] = run_id
    else:
        manifest["run_id"] = uuid.uuid4().hex
    checkpoint = record.get("checkpoint")
    if action in same_run_actions:
        if not isinstance(checkpoint, dict):
            raise HTTPException(409, "this run has no stable checkpoint to resume")
        manifest["_resume"] = checkpoint.get("state") or {}
        manifest["_resume_from_run_id"] = run_id
    if action == "run_with_locus":
        team_value = manifest.get("team")
        if not isinstance(team_value, dict):
            raise HTTPException(422, "the current team definition is required")
        team_value = dict(team_value)
        policy = team_value.get("swarm_policy")
        policy = dict(policy) if isinstance(policy, dict) else {}
        policy.update({"version": 1, "engine": "locus_managed"})
        team_value["swarm_policy"] = policy
        manifest["team"] = team_value
    if action == "retry":
        job_id = str(body.get("job_id") or "")
        if not job_id:
            raise HTTPException(422, "job_id is required")
        manifest["_retry_job"] = job_id
    if action == "reassign":
        job_id = str(body.get("job_id") or "")
        agent_id = str(body.get("agent_id") or "")
        if not job_id or not agent_id:
            raise HTTPException(422, "job_id and agent_id are required")
        manifest["_reassign"] = {"job_id": job_id, "agent_id": agent_id}
    task_id = str(record.get("task_id") or "")
    source_task = TaskCheckoutStore.load(task_id) if task_id else None
    if action in {*same_run_actions, "replay"} and task_id and source_task is None:
        raise HTTPException(409, "the managed checkout for this run is missing")
    checkpoint_state = (
        checkpoint.get("state")
        if isinstance(checkpoint, dict) and isinstance(checkpoint.get("state"), dict)
        else {}
    )
    expected_baseline = str(checkpoint_state.get("baseline_tree") or "")
    if (
        source_task is not None
        and expected_baseline
        and source_task.baseline_tree != expected_baseline
    ):
        raise HTTPException(409, "the managed checkout no longer matches its recovery baseline")
    task = source_task
    if action == "replay" and source_task is not None:
        task = TaskCheckoutStore.replay(source_task, str(manifest["run_id"]))
    elif action == "duplicate":
        task = None
        svc.current_task = None
        try:
            svc.core.leave_task_checkout(str(record.get("workspace_root") or ""))
        except ValueError as exc:
            raise HTTPException(409, str(exc)) from exc
    if task is not None:
        svc.current_task = task
        svc.core.enter_task_checkout(task.execution_path, task.workspace_root, task.as_dict())
    request_text = str(record.get("request") or "")
    if not request_text:
        raise HTTPException(409, "the original request is unavailable")
    loop = asyncio.get_running_loop()
    if not svc.start_turn(loop, team_runner, svc, request_text, manifest):
        raise _busy_http()
    return {
        "ok": True,
        "action": action,
        "source_run_id": run_id,
        "run_id": str(manifest["run_id"]),
        "state": "queued",
    }


async def orchestration_resume(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return await _resume_orchestration(service, team_runner, run_id, body, action="resume")


async def orchestration_run_with_locus(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Explicitly move a paused OpenAI-native run onto Locus-managed execution."""
    record = service.run_store.run(run_id)
    checkpoint = record.get("checkpoint") if isinstance(record, dict) else None
    state = checkpoint.get("state") if isinstance(checkpoint, dict) else None
    if not isinstance(state, dict) or state.get("fallback_action") != "run_with_locus":
        raise HTTPException(409, "this run is not waiting for an engine fallback")
    return await _resume_orchestration(service, team_runner, run_id, body, action="run_with_locus")


def orchestration_recovery_assessment(
    service: ServiceDependency, run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    """Validate reusable state without making a provider call or changing the run."""
    _require_capability("recovery_controls")
    record = service.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    repairs: list[str] = []
    if not record.get("recoverable") or str(record.get("state") or "") not in {
        "paused",
        "interrupted",
    }:
        repairs.append("This run is not paused or interrupted at a recoverable checkpoint.")
    checkpoint = record.get("checkpoint")
    state = checkpoint.get("state") if isinstance(checkpoint, dict) else None
    if record.get("legacy"):
        repairs.append("Legacy imported runs are inspectable but not replayable.")
    if not isinstance(state, dict):
        repairs.append("No stable checkpoint is available.")
        state = {}
    task_id = str(record.get("task_id") or "")
    task = TaskCheckoutStore.load(task_id) if task_id else None
    if task_id and task is None:
        repairs.append("The managed checkout is missing.")
    expected_baseline = str(state.get("baseline_tree") or "")
    if task is not None and expected_baseline and task.baseline_tree != expected_baseline:
        repairs.append("The private task baseline changed.")
    manifest = body.get("manifest")
    if not isinstance(manifest, dict):
        repairs.append("The current team profiles and credentials are required.")
    else:
        try:
            _, team, profiles, _ = parse_manifest(manifest)
            expected = str(state.get("orchestration_fingerprint") or "")
            if not expected or expected == "unavailable":
                repairs.append("The checkpoint has no verifiable team fingerprint.")
            elif orchestration_fingerprint(team, profiles) != expected:
                repairs.append("The team or profile configuration changed.")
        except OrchestrationError as exc:
            repairs.append(str(exc))
    reusable = [
        str(result.get("job_id") or "")
        for result in state.get("results") or []
        if isinstance(result, dict) and str(result.get("job_id") or "")
    ]
    return {
        "run_id": run_id,
        "can_resume": not repairs,
        "repair_checklist": repairs,
        "reusable_job_ids": reusable,
        "writer_continuation": bool(task is not None),
    }


async def orchestration_retry_job(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    job_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return await _resume_orchestration(
        service, team_runner, run_id, {**body, "job_id": job_id}, action="retry"
    )


def orchestration_stop_agent_branch(
    service: ServiceDependency, run_id: str, node_id: str
) -> dict[str, Any]:
    """Stop one active read-only subtree while sibling branches keep running."""
    _require_capability("recovery_controls")
    svc = service
    if svc.active_run_id != run_id or svc.active_orchestrator is None or not svc.busy:
        raise HTTPException(409, "that agent branch is not actively running")
    known = svc.active_orchestrator.stop_branch(run_id, node_id)
    return {
        "ok": True,
        "run_id": run_id,
        "node_id": node_id,
        "state": "stopping",
        "known": known,
    }


async def orchestration_retry_agent_branch(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    node_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Retry a paused branch under its existing durable node identity."""
    return await _resume_orchestration(
        service,
        team_runner,
        run_id,
        {**body, "job_id": node_id},
        action="retry",
    )


async def orchestration_reassign_job(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    job_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return await _resume_orchestration(
        service, team_runner, run_id, {**body, "job_id": job_id}, action="reassign"
    )


async def orchestration_replay(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return await _resume_orchestration(service, team_runner, run_id, body, action="replay")


async def orchestration_duplicate(
    service: ServiceDependency,
    team_runner: TeamRunnerDependency,
    run_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return await _resume_orchestration(service, team_runner, run_id, body, action="duplicate")


def task_detail(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    """Return task metadata and its complete baseline-relative binary patch."""
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    try:
        patch, tree = task.patch()
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {
        "ok": True,
        "task": task.as_dict(),
        "tree": tree,
        "patch": patch,
        "patch_bytes": len(patch.encode("utf-8", errors="surrogateescape")),
    }


def task_landing_preflight(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    try:
        _require_task_idle(service, task)
        return task.landing_preflight()
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


_LANDING_CHECK_LOCK = threading.Lock()
_LANDING_CHECK_PROCESSES: dict[str, subprocess.Popen[bytes]] = {}
_LANDING_CHECK_CANCELLED: set[str] = set()


def task_landing_checks(
    service: ServiceDependency, task_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    """Run only explicit commands in the managed checkout and persist bounded evidence."""
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    raw = body.get("commands")
    if not isinstance(raw, list) or not 1 <= len(raw) <= 8:
        raise HTTPException(422, "commands must contain between one and eight entries")
    commands = [str(item).strip() for item in raw]
    if any(not item or len(item) > 500 for item in commands):
        raise HTTPException(422, "each check command must contain 1 to 500 characters")
    try:
        _require_task_idle(service, task)
        preflight = task.landing_preflight()
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc
    requested_run_id = str(body.get("run_id") or "")
    run_id = (
        requested_run_id
        if re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", requested_run_id)
        else uuid.uuid4().hex
    )
    store = service.run_store
    store.start_run(
        run_id,
        session_id=task.session_id or "",
        workspace_root=task.workspace_root,
        execution_path=task.execution_path,
        task_id=task.id,
        request="Landing checks",
        state="running",
        run_kind="verification",
        execution_environment="worktree",
    )
    store.append_event(
        run_id,
        {
            "type": "landing_checks_started",
            "state": "running",
            "tree": preflight["tree"],
            "command_count": len(commands),
        },
    )
    results: list[dict[str, Any]] = []
    passed = True
    for index, command in enumerate(commands):
        started = time.monotonic()
        with _LANDING_CHECK_LOCK:
            cancelled = run_id in _LANDING_CHECK_CANCELLED
        if cancelled:
            results.append(
                {
                    "index": index,
                    "command": command,
                    "exit_code": None,
                    "output": "",
                    "truncated": False,
                    "duration_ms": 0,
                    "state": "cancelled",
                }
            )
            passed = False
            break
        try:
            with tempfile.TemporaryFile() as output_file:
                process = subprocess.Popen(
                    ["/bin/zsh", "-lc", command],
                    cwd=task.execution_path,
                    stdout=output_file,
                    stderr=subprocess.STDOUT,
                    env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
                    start_new_session=True,
                )
                with _LANDING_CHECK_LOCK:
                    _LANDING_CHECK_PROCESSES[run_id] = process
                try:
                    exit_code = process.wait(timeout=600)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    raise
                finally:
                    with _LANDING_CHECK_LOCK:
                        _LANDING_CHECK_PROCESSES.pop(run_id, None)
                output_file.seek(0, os.SEEK_END)
                output_size = output_file.tell()
                output_file.seek(0)
                output_bytes = output_file.read(1_000_001)
            output = output_bytes.decode("utf-8", errors="replace")
            truncated = output_size > 1_000_000
            output = truncate_output(output, 1_000_000)
            with _LANDING_CHECK_LOCK:
                cancelled = run_id in _LANDING_CHECK_CANCELLED
            item = {
                "index": index,
                "command": command,
                "exit_code": exit_code,
                "output": output,
                "truncated": truncated,
                "duration_ms": int((time.monotonic() - started) * 1_000),
                "state": "cancelled" if cancelled else ("passed" if exit_code == 0 else "failed"),
            }
        except subprocess.TimeoutExpired:
            item = {
                "index": index,
                "command": command,
                "exit_code": None,
                "output": "",
                "truncated": False,
                "duration_ms": int((time.monotonic() - started) * 1_000),
                "state": "timed_out",
            }
        except OSError:
            item = {
                "index": index,
                "command": command,
                "exit_code": None,
                "output": "The check process could not be started.",
                "truncated": False,
                "duration_ms": int((time.monotonic() - started) * 1_000),
                "state": "failed",
            }
        results.append(item)
        store.append_event(run_id, {"type": "landing_check_completed", **item})
        if item["state"] != "passed":
            passed = False
            break
    cancelled_run = any(item["state"] == "cancelled" for item in results)
    final_state = "cancelled" if cancelled_run else ("completed" if passed else "failed")
    store.append_event(
        run_id,
        {
            "type": "orchestration_completed",
            "state": final_state,
            "tree": preflight["tree"],
            "passed": passed,
        },
    )
    store.set_state(run_id, final_state, recoverable=False)
    with _LANDING_CHECK_LOCK:
        _LANDING_CHECK_PROCESSES.pop(run_id, None)
        _LANDING_CHECK_CANCELLED.discard(run_id)
    return {
        "ok": passed,
        "run_id": run_id,
        "state": final_state,
        "tree": preflight["tree"],
        "passed": passed,
        "results": results,
    }


def run_cancel(service: ServiceDependency, run_id: str) -> dict[str, Any]:
    """Cancel a queued run or an executing landing check without guessing its owner."""
    with _LANDING_CHECK_LOCK:
        process = _LANDING_CHECK_PROCESSES.get(run_id)
        if process is not None:
            _LANDING_CHECK_CANCELLED.add(run_id)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            return {"ok": True}
    run = service.run_store.run(run_id)
    if run is None:
        raise HTTPException(404, f"run not found: {run_id}")
    if run["state"] == "queued":
        service.run_store.reorder_queue(run_id, "cancel")
    elif run["state"] not in {"completed", "failed", "cancelled", "discarded"}:
        service.run_store.set_state(run_id, "cancelled", recoverable=False)
    return {"ok": True}


def task_land(
    service: ServiceDependency, task_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    destination = str(body.get("destination") or "")
    expected_tree = str(body.get("expected_tree") or "")
    check_run_id = str(body.get("check_run_id") or "")
    check_tree = ""
    checks_passed = False
    override = bool(body.get("override_failed_checks"))
    try:
        _require_task_idle(service, task)
        preflight = task.landing_preflight()
        if not expected_tree or expected_tree != preflight["tree"]:
            raise WorktreeError("the worktree changed; review the refreshed diff before landing")
        if check_run_id:
            store = service.run_store
            check_run = store.run(check_run_id)
            if (
                check_run is None
                or check_run.get("run_kind") != "verification"
                or check_run.get("task_id") != task.id
            ):
                raise WorktreeError("the supplied check evidence does not belong to this worktree")
            completion = next(
                (
                    event
                    for event in reversed(store.events(check_run_id))
                    if event.get("type") == "orchestration_completed"
                    and "tree" in event
                    and "passed" in event
                ),
                None,
            )
            if completion is None:
                raise WorktreeError("the supplied check evidence is incomplete")
            check_tree = str(completion.get("tree") or "")
            checks_passed = bool(completion.get("passed"))
        if check_tree and check_tree != expected_tree:
            raise WorktreeError("the check result is stale for the current worktree")
        if not checks_passed and not override:
            raise WorktreeError("checks have not passed; confirm Land Anyway to continue")
        if destination == "local":
            result = task.apply()
            result.update({"destination": "local", "override_failed_checks": override})
        elif destination == "branch":
            result = task.land_branch(
                str(body.get("branch") or ""), str(body.get("commit_message") or "")
            )
            result["override_failed_checks"] = override
        else:
            raise HTTPException(422, "destination must be local or branch")
        task.landing_source_tree = preflight["base_tree"]
        task.landing_check_run_id = check_run_id or None
        task.landing_checks_passed = checks_passed
        task.landing_override = override
        task.save()
        if task.session_id:
            SessionMeta.update(task.session_id, task=task.as_dict())
        run_id = str(body.get("source_run_id") or "")
        if run_id and service.run_store.run(run_id) is not None:
            service.run_store.append_event(
                run_id,
                {
                    "type": "worktree_landed",
                    "destination": destination,
                    "tree": expected_tree,
                    "commit": result.get("commit"),
                    "check_run_id": check_run_id or None,
                    "checks_passed": checks_passed,
                    "override_failed_checks": override,
                },
            )
        return {"task": task.as_dict(), **result}
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def task_apply(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    """Apply only after a complete dry run; leave source changes unstaged."""
    svc = service
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    _require_task_idle(service, task)
    try:
        with svc.state_mutation():
            result = task.apply()
            if svc.current_task and svc.current_task.id == task.id:
                svc.current_task = task
                svc.core.task_metadata = task.as_dict()
            svc.queue_event(
                {
                    "type": "task_applied",
                    "task": task.as_dict(),
                    **result,
                }
            )
            return {"task": task.as_dict(), **result}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def task_create_branch(
    service: ServiceDependency,
    task_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Turn a detached managed worktree into an explicitly named branch."""
    branch = body.get("branch")
    if not isinstance(branch, str):
        raise HTTPException(422, "branch must be a string")
    try:
        existing = TaskCheckoutStore.load(task_id)
        if existing is None:
            raise HTTPException(404, f"task not found: {task_id}")
        _require_task_idle(service, existing)
        task = TaskCheckoutStore.create_branch(task_id, branch)
        if task.session_id:
            SessionMeta.update(task.session_id, task=task.as_dict())
        return {"ok": True, "task": task.as_dict()}
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def task_snapshot(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    try:
        existing = TaskCheckoutStore.load(task_id)
        if existing is None:
            raise HTTPException(404, f"task not found: {task_id}")
        _require_task_idle(service, existing)
        result = TaskCheckoutStore.snapshot_and_remove(task_id)
        task = TaskCheckoutStore.load(task_id)
        if task is not None and task.session_id:
            SessionMeta.update(task.session_id, task=task.as_dict())
        return result
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def task_restore(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    try:
        existing = TaskCheckoutStore.load(task_id)
        if existing is None:
            raise HTTPException(404, f"task not found: {task_id}")
        _require_task_idle(service, existing)
        task = TaskCheckoutStore.restore(task_id)
        if task.session_id:
            SessionMeta.update(task.session_id, task=task.as_dict())
        return {"ok": True, "task": task.as_dict()}
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def task_cleanup(service: ServiceDependency, task_id: str) -> dict[str, Any]:
    """Archive a managed checkout behind a restorable Git snapshot."""
    svc = service
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    _require_task_idle(service, task)
    if svc.busy:
        raise _busy_http()
    try:
        with svc.state_mutation():
            if svc.current_task and svc.current_task.id == task_id:
                svc.core.leave_task_checkout(task.workspace_root)
                svc.current_task = None
            result = TaskCheckoutStore.snapshot_and_remove(task_id)
            if task.session_id:
                SessionMeta.update(task.session_id, task=result["task"])
            return result
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/mcp/tasks", mcp_task_list, methods=["GET"])
    router.add_api_route("/api/mcp/tasks/{task_id}/lookup", mcp_task_lookup, methods=["POST"])
    router.add_api_route("/api/mcp/tasks/{task_id}/cancel", mcp_task_cancel, methods=["POST"])
    router.add_api_route("/api/usage/summary", usage_summary, methods=["GET"])
    router.add_api_route("/api/runs", orchestration_list, methods=["GET"])
    router.add_api_route("/api/orchestrations", orchestration_list, methods=["GET"])
    router.add_api_route("/api/runs/queue", run_queue, methods=["POST"])
    router.add_api_route("/api/runs/{run_id}/queue", run_queue_update, methods=["PATCH"])
    router.add_api_route("/api/runs/{run_id}/retry", run_retry, methods=["POST"])
    router.add_api_route("/api/runs/{run_id}", orchestration_detail, methods=["GET"])
    router.add_api_route("/api/orchestrations/{run_id}", orchestration_detail, methods=["GET"])
    router.add_api_route("/api/runs/{run_id}", orchestration_update, methods=["PATCH"])
    router.add_api_route("/api/orchestrations/{run_id}", orchestration_update, methods=["PATCH"])
    router.add_api_route("/api/runs/{run_id}/events", orchestration_events, methods=["GET"])
    router.add_api_route(
        "/api/orchestrations/{run_id}/events", orchestration_events, methods=["GET"]
    )
    router.add_api_route("/api/runs/{run_id}/export", orchestration_export, methods=["GET"])
    router.add_api_route(
        "/api/orchestrations/{run_id}/export", orchestration_export, methods=["GET"]
    )
    router.add_api_route("/api/runs/{run_id}/otlp", orchestration_otlp, methods=["POST"])
    router.add_api_route("/api/orchestrations/{run_id}/otlp", orchestration_otlp, methods=["POST"])
    router.add_api_route(
        "/api/orchestrations/{run_id}/pause", orchestration_pause, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/cancel", orchestration_cancel, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/discard", orchestration_discard, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/reconcile-worker-exit",
        orchestration_reconcile_worker_exit,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/dispatch-decision",
        orchestration_dispatch_decision,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/resume", orchestration_resume, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/run-with-locus",
        orchestration_run_with_locus,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/recovery-assessment",
        orchestration_recovery_assessment,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/jobs/{job_id}/retry",
        orchestration_retry_job,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/agents/{node_id:path}/stop",
        orchestration_stop_agent_branch,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/agents/{node_id:path}/retry",
        orchestration_retry_agent_branch,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/jobs/{job_id}/reassign",
        orchestration_reassign_job,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/replay", orchestration_replay, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/duplicate", orchestration_duplicate, methods=["POST"]
    )
    router.add_api_route("/api/tasks/{task_id}", task_detail, methods=["GET"])
    router.add_api_route(
        "/api/tasks/{task_id}/landing/preflight", task_landing_preflight, methods=["GET"]
    )
    router.add_api_route("/api/tasks/{task_id}/checks", task_landing_checks, methods=["POST"])
    router.add_api_route("/api/runs/{run_id}/cancel", run_cancel, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/landing", task_land, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/apply", task_apply, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/branch", task_create_branch, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/snapshot", task_snapshot, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/restore", task_restore, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}", task_cleanup, methods=["DELETE"])
