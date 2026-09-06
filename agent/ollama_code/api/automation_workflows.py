"""Authenticated loopback API for workflow validation and durable execution."""
from __future__ import annotations

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..automation_workflows import (
    WorkflowValidationError,
    simulate_workflow,
    validate_workflow,
)
from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..runstore import RunStoreError
from ..sessions import SessionStore
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _require_capability() -> None:
    if not capability_enabled("automation_workflows_v1"):
        raise HTTPException(404, "capability is disabled: automation_workflows_v1")


def _allowed_connections(body: dict[str, Any]) -> set[str] | None:
    raw = body.get("allowed_connection_ids")
    if raw is None:
        return None
    if not isinstance(raw, list):
        raise HTTPException(422, "allowed_connection_ids must be an array")
    return {str(item) for item in raw}


def workflow_validate(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    del service
    _require_capability()
    try:
        workflow = validate_workflow(
            body.get("workflow"), allowed_connection_ids=_allowed_connections(body)
        )
    except WorkflowValidationError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"valid": True, "workflow": workflow}


def workflow_simulate(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    del service
    _require_capability()
    trigger = body.get("trigger")
    mocks = body.get("mock_outputs")
    if trigger is not None and not isinstance(trigger, dict):
        raise HTTPException(422, "trigger must be an object")
    if mocks is not None and not isinstance(mocks, dict):
        raise HTTPException(422, "mock_outputs must be an object")
    try:
        return simulate_workflow(
            body.get("workflow"), trigger=trigger, mock_outputs=mocks,
            allowed_connection_ids=_allowed_connections(body),
        )
    except WorkflowValidationError as exc:
        raise HTTPException(422, str(exc)) from exc


def execution_list(
    service: ServiceDependency,
    automation_kind: str = Query(default=""),
    automation_id: str = Query(default=""),
    limit: int = Query(default=100, ge=1, le=500),
) -> dict[str, Any]:
    _require_capability()
    return {
        "executions": service.run_store.automation_executions(
            automation_kind=automation_kind, automation_id=automation_id, limit=limit
        ),
        "read_only": service.run_store.read_only,
    }


def attention_list(
    service: ServiceDependency,
    limit: int = Query(default=500, ge=1, le=1_000),
    run_id: str = "",
    workflow_execution_id: str = "",
) -> dict[str, Any]:
    all_items = _attention_items(service, run_id=run_id, workflow_execution_id=workflow_execution_id)
    return {
        "items": all_items[:limit],
        "unresolved_count": len(all_items),
        "read_only": service.run_store.read_only,
    }


def _orphaned_recovery(item: dict[str, Any]) -> bool:
    return (
        item.get("kind") == "recoverable_run"
        and bool(item.get("run_id"))
        and SessionStore.path_for(str(item.get("session_id") or "")) is None
    )


def _attention_items(
    service: ChatService, *, run_id: str = "", workflow_execution_id: str = ""
) -> list[dict[str, Any]]:
    items = service.run_store.attention_items(
        limit=1_000, run_id=run_id, workflow_execution_id=workflow_execution_id
    )
    projected: list[dict[str, Any]] = []
    for item in items:
        if _orphaned_recovery(item):
            item = {
                **item,
                "detail": "The original chat was deleted. Clear this recovery item.",
                "actions": ["clear"],
                "unavailable": True,
            }
        projected.append(item)
    return projected


def _clear_recoveries(
    service: ChatService, *, run_id: str = ""
) -> dict[str, Any]:
    items = [
        item for item in _attention_items(service)
        if item.get("kind") == "recoverable_run"
        and (
            (bool(run_id) and item.get("run_id") == run_id)
            or (not run_id and _orphaned_recovery(item))
        )
    ]
    if run_id and not items:
        raise HTTPException(409, "that run no longer needs recovery")
    try:
        cleared = service.run_store.discard_recoverable_runs([
            str(item["run_id"]) for item in items
        ])
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc
    if run_id and run_id not in cleared:
        raise HTTPException(409, "that recovery has already changed")
    return {
        "ok": True,
        "cleared_count": len(cleared),
        "cleared_run_ids": cleared,
    }


def attention_clear(run_id: str, service: ServiceDependency) -> dict[str, Any]:
    return _clear_recoveries(service, run_id=run_id)


def attention_clear_unavailable(service: ServiceDependency) -> dict[str, Any]:
    return _clear_recoveries(service)


def execution_detail(execution_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability()
    execution = service.run_store.automation_execution(execution_id)
    if execution is None:
        raise HTTPException(404, "automation execution not found")
    return execution


def _queue_agent_action(service: ChatService, action: dict[str, Any]) -> dict[str, Any]:
    if action.get("action") != "run_agent":
        return action
    execution = action.get("execution")
    step = action.get("step")
    if not isinstance(execution, dict) or not isinstance(step, dict):
        raise HTTPException(500, "workflow action is incomplete")
    settings = execution.get("settings")
    settings = settings if isinstance(settings, dict) else {}
    attempts = execution.get("attempts")
    if not isinstance(attempts, list):
        detailed = service.run_store.automation_execution(str(execution["id"])) or {}
        attempts = detailed.get("attempts") if isinstance(detailed.get("attempts"), list) else []
    attempt_number = 1 + sum(
        1 for item in attempts
        if isinstance(item, dict) and item.get("step_id") == step.get("id")
    )
    run_id = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"locus:workflow-step:{execution['id']}:{step['id']}:{attempt_number}",
    ).hex
    runner = str(settings.get("runner") or "solo")
    step_connections = step.get("allowed_connection_ids")
    inherited_connections = settings.get("action_connection_ids")
    effective_connections = (
        inherited_connections if step_connections is None else step_connections
    )
    manifest = {
        "automation_workflow": True,
        "workflow_execution_id": execution["id"],
        "workflow_step_id": step["id"],
        "workflow_step_attempt": attempt_number,
        "workflow_outputs": step.get("outputs") or [],
        "action_connection_ids": effective_connections or [],
        "mode": step.get("mode") or "work",
        "runner": runner,
        "solo_swarm": runner != "team",
        "provider": settings.get("provider") or "ollama",
        "provider_account_id": settings.get("provider_account_id") or "",
        "model": settings.get("model") or "",
        "automation_kind": execution.get("automation_kind"),
        "automation_id": execution.get("automation_id"),
        "occurrence_id": execution.get("occurrence_id"),
    }
    if execution.get("automation_kind") == "event":
        manifest.update({
            "event_triggered": True,
            "event_trigger_id": execution.get("automation_id"),
            "event_delivery_id": execution.get("occurrence_id"),
        })
    if execution.get("automation_kind") == "schedule":
        manifest.update({
            "scheduled": True,
            "schedule_id": execution.get("automation_id"),
        })
    try:
        run = service.run_store.queue_run(
            run_id,
            session_id=str(execution.get("session_id") or ""),
            team_id=str(settings.get("team_id") or ""),
            team_name=str(settings.get("team_name") or ""),
            workspace_root=str(settings.get("workspace_root") or ""),
            execution_path=str(
                settings.get("execution_path") or settings.get("workspace_root") or ""
            ),
            request=str(action.get("prompt") or ""),
            run_kind="team" if runner == "team" else "solo",
            execution_environment=str(settings.get("execution_environment") or "local"),
            manifest=manifest,
            schedule_id=(
                str(execution.get("automation_id") or "")
                if execution.get("automation_kind") == "schedule" else ""
            ),
            occurrence_id=str(execution.get("occurrence_id") or ""),
            scheduled_for=settings.get("scheduled_for"),
        )
        bound = service.run_store.bind_automation_step_run(
            str(execution["id"]), str(step["id"]), run_id
        )
    except RunStoreError as exc:
        try:
            service.run_store.set_state(run_id, "cancelled", recoverable=False)
        except (RunStoreError, KeyError):
            pass
        try:
            service.run_store.fail_automation_step(str(execution["id"]), str(exc))
        except RunStoreError:
            pass
        raise HTTPException(409, str(exc)) from exc
    return {**action, "execution": bound, "run": run}


def _sync_origin(service: ChatService, action: dict[str, Any]) -> dict[str, Any]:
    execution = action.get("execution") if isinstance(action, dict) else None
    if not isinstance(execution, dict):
        return action
    state = str(execution.get("state") or "")
    if state not in {"completed", "cancelled", "failed", "running"}:
        return action
    origin_state = "queued" if state == "running" else state
    occurrence_id = str(execution.get("occurrence_id") or "")
    attempts = execution.get("attempts")
    last_run_id = ""
    if isinstance(attempts, list):
        for attempt in attempts:
            if isinstance(attempt, dict) and attempt.get("run_id"):
                last_run_id = str(attempt["run_id"])
    run_id = str(execution.get("current_run_id") or last_run_id)
    try:
        if execution.get("automation_kind") == "event":
            service.run_store.finish_event_dispatch(
                occurrence_id,
                state=origin_state,
                run_id=run_id,
                error=str(execution.get("error") or "") if state == "failed" else "",
            )
        elif execution.get("automation_kind") == "schedule":
            service.run_store.finish_schedule_occurrence(
                occurrence_id,
                state=origin_state,
                session_id=str(execution.get("session_id") or ""),
                run_id=run_id,
                error=str(execution.get("error") or "") if state == "failed" else "",
            )
    except RunStoreError:
        # The execution is authoritative. Origin history synchronization is
        # best-effort and never repeats a completed model or connector action.
        pass
    return action


def start_execution(
    service: ChatService,
    *,
    automation_kind: str,
    automation_id: str,
    occurrence_id: str,
    session_id: str,
    workflow: dict[str, Any],
    trigger: dict[str, Any],
    settings: dict[str, Any],
) -> dict[str, Any]:
    """Create an immutable snapshot and queue its first Agent step."""
    try:
        execution, created = service.run_store.create_automation_execution(
            automation_kind=automation_kind, automation_id=automation_id,
            occurrence_id=occurrence_id, session_id=session_id, workflow=workflow,
            trigger=trigger, settings=settings,
        )
        if not created:
            return {"action": "existing", "execution": execution}
        action = service.run_store.advance_automation_execution(str(execution["id"]))
        return _sync_origin(service, _queue_agent_action(service, action))
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc


def execution_complete_step(
    execution_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability()
    result = body.get("result")
    if result is not None and not isinstance(result, dict):
        raise HTTPException(422, "result must be an object")
    try:
        action = service.run_store.complete_automation_step(
            execution_id, run_id=str(body.get("run_id") or ""), result=result,
            error=str(body.get("error") or ""),
        )
        return _sync_origin(service, _queue_agent_action(service, action))
    except (RunStoreError, WorkflowValidationError) as exc:
        status = 404 if str(exc) == "automation execution not found" else 409
        raise HTTPException(status, str(exc)) from exc


def execution_approve(execution_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability()
    try:
        return _sync_origin(service, _queue_agent_action(
            service, service.run_store.decide_automation_approval(
                execution_id, approve=True
            )
        ))
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc


def execution_reject(execution_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability()
    try:
        return _sync_origin(
            service,
            service.run_store.decide_automation_approval(execution_id, approve=False),
        )
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc


def execution_retry(execution_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability()
    try:
        return _sync_origin(service, _queue_agent_action(
            service, service.run_store.retry_automation_step(execution_id)
        ))
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc


def execution_cancel(execution_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability()
    try:
        return _sync_origin(
            service, service.run_store.cancel_automation_execution(execution_id)
        )
    except RunStoreError as exc:
        raise HTTPException(409, str(exc)) from exc


def register_routes(router: APIRouter) -> None:
    router.add_api_route(
        "/api/automation-workflows/validate", workflow_validate, methods=["POST"]
    )
    router.add_api_route(
        "/api/automation-workflows/simulate", workflow_simulate, methods=["POST"]
    )
    router.add_api_route(
        "/api/automation-executions", execution_list, methods=["GET"]
    )
    router.add_api_route("/api/attention", attention_list, methods=["GET"])
    router.add_api_route(
        "/api/attention/clear-unavailable",
        attention_clear_unavailable,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/attention/{run_id}/clear", attention_clear, methods=["POST"]
    )
    router.add_api_route(
        "/api/automation-executions/{execution_id}", execution_detail, methods=["GET"]
    )
    router.add_api_route(
        "/api/automation-executions/{execution_id}/complete-step",
        execution_complete_step, methods=["POST"],
    )
    router.add_api_route(
        "/api/automation-executions/{execution_id}/approve",
        execution_approve, methods=["POST"],
    )
    router.add_api_route(
        "/api/automation-executions/{execution_id}/reject",
        execution_reject, methods=["POST"],
    )
    router.add_api_route(
        "/api/automation-executions/{execution_id}/retry",
        execution_retry, methods=["POST"],
    )
    router.add_api_route(
        "/api/automation-executions/{execution_id}/cancel",
        execution_cancel, methods=["POST"],
    )


__all__ = ["register_routes", "start_execution"]
