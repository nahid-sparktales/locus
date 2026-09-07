"""Session-scoped persistent goal controls; model reports are runtime-only."""
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled
from ..chat_service import ChatService
from ..goals import GoalError, GoalStore
from ..session_runtime import session_has_active_run
from ..sessions import SessionMeta, SessionStore
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _store(service: ChatService) -> GoalStore:
    if not enabled("persistent_goals_v1"):
        raise HTTPException(404, "persistent goals are disabled")
    return GoalStore(service.run_store)


def _error(error: GoalError) -> HTTPException:
    return HTTPException(404 if str(error) == "goal not found" else 409, str(error))


def goal_list(service: ServiceDependency, nonterminal: bool = Query(default=False)) -> dict[str, Any]:
    store = _store(service)
    try:
        store.recover()
        return {"goals": store.list(nonterminal=nonterminal)}
    except GoalError as error:
        raise _error(error) from error


def session_goal(service: ServiceDependency, session_id: str) -> dict[str, Any]:
    return {"goal": _store(service).for_session(session_id)}


def goal_create(service: ServiceDependency, session_id: str,
                body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    store = _store(service)
    path = SessionStore.path_for(session_id)
    current = service.core.session.session_id == session_id
    if path is None and not current:
        raise HTTPException(404, "chat not found")
    metadata = SessionMeta.get(session_id)
    from .sessions import _agent_owning_chat
    provenance = SessionStore._summary_record(path) if path else {}
    if (metadata.get("archived") or metadata.get("agent_primary") or metadata.get("agent_trigger_id")
            or metadata.get("identity_mode") or (current and service.core.identity_mode)
            or (provenance or {}).get("identity_mode")
            or _agent_owning_chat(service, session_id)):
        raise HTTPException(409, "open an ordinary unarchived chat to start a goal")
    if (current and service.busy) or session_has_active_run(service.run_store, session_id):
        raise HTTPException(409, "wait for this chat to stop before starting a goal")
    try:
        if not isinstance(body.get("execution"), dict):
            raise GoalError("execution must be an object")
        execution = dict(body["execution"])
        header = SessionStore.header(path) if path else {}
        workspace = str(metadata.get("workspace_root") or header.get("workspace_root") or header.get("cwd") or (service.core.cwd if current else ""))
        execution_path = str(metadata.get("execution_path") or header.get("cwd") or workspace)
        for key, authoritative in (("workspace_root", workspace), ("execution_path", execution_path)):
            if key in execution and Path(str(execution[key])).resolve() != Path(authoritative).resolve():
                raise GoalError(f"{key} must match the chat's saved workspace")
            execution[key] = authoritative
        environment = metadata.get("environment") or {}
        if not isinstance(environment, dict):
            environment = {}
        execution["execution_environment"] = "worktree" if environment.get("type") == "worktree" else "local"
        return store.create(session_id, body.get("objective", ""), execution=execution,
                            model_call_budget=body.get("model_call_budget"), token_budget=body.get("token_budget"))
    except (GoalError, TypeError, ValueError) as error:
        raise _error(error) from error


def goal_update(service: ServiceDependency, goal_id: str,
                body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        fields = {key: value for key, value in body.items() if key not in {"action", "expected_revision"}}
        return _store(service).update(goal_id, str(body.get("action") or ""),
                                      expected_revision=body.get("expected_revision"), **fields)
    except GoalError as error:
        raise _error(error) from error


def goal_claim(service: ServiceDependency, goal_id: str,
               body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        return _store(service).claim(goal_id, body.get("expected_revision"))
    except GoalError as error:
        raise _error(error) from error


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/goals", goal_list, methods=["GET"])
    router.add_api_route("/api/sessions/{session_id}/goal", session_goal, methods=["GET"])
    router.add_api_route("/api/sessions/{session_id}/goal", goal_create, methods=["POST"])
    router.add_api_route("/api/goals/{goal_id}", goal_update, methods=["PATCH"])
    router.add_api_route("/api/goals/{goal_id}/claim", goal_claim, methods=["POST"])
