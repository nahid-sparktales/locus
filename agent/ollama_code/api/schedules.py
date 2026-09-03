"""Scheduled and companion chat dispatch routes."""

import re
import uuid
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..runstore import RunStoreError
from ..schedules import timezone as schedule_timezone
from ..sessions import SessionMeta, SessionStore
from ..worktrees import (
    TaskCheckout,
    TaskCheckoutStore,
    WorktreeError,
    is_git_workspace,
)
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _require_capability(name: str) -> None:
    if not capability_enabled(name):
        raise HTTPException(404, f"capability is disabled: {name}")


def _schedule_workspace(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(422, "workspace_root is required")
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise HTTPException(422, "the scheduled workspace is no longer available")
    return str(path)


def _validate_schedule_payload(
    value: dict[str, Any],
    *,
    existing: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = dict(value)
    if "workspace_root" in payload:
        payload["workspace_root"] = _schedule_workspace(payload["workspace_root"])
    workspace_root = str(
        payload.get("workspace_root")
        or (existing or {}).get("workspace_root")
        or ""
    )
    environment = str(
        payload.get("execution_environment")
        or (existing or {}).get("execution_environment")
        or "local"
    )
    if environment == "worktree" and (
        not workspace_root or not is_git_workspace(workspace_root)
    ):
        raise HTTPException(422, "scheduled worktrees require a Git repository")
    return payload


def _scheduled_chat_title(schedule: dict[str, Any], scheduled_for: float) -> str:
    zone = schedule_timezone(str(schedule["timezone"]))
    value = datetime.fromtimestamp(scheduled_for, zone).strftime("%b %d, %Y %H:%M")
    return f"{schedule['name']} · {value.replace(' 0', ' ')}"


def _companion_chat_title(prompt: str) -> str:
    first_line = " ".join(prompt.split())
    return (first_line[:72].rstrip() or "Mobile chat") + " · Mobile"


def _dispatch_companion_chat(
    service: ChatService,
    body: dict[str, Any],
) -> dict[str, Any]:
    """Create a durable mobile run without changing the active session."""
    store = service.run_store
    request_id = str(body.get("request_id") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", request_id):
        raise HTTPException(422, "request_id is required")
    run_id = uuid.uuid5(uuid.NAMESPACE_URL, f"locus:companion:{request_id}").hex
    existing = store.run(run_id)
    if existing is not None:
        return {"ok": True, "claimed": False, "run": existing}

    prompt = str(body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(422, "prompt is required")
    if len(prompt) > 240_000:
        raise HTTPException(413, "prompt is too large")
    mode = str(body.get("mode") or "work").strip().lower()
    # "build" is the retired GSD mode, kept so existing schedule rows still load.
    if mode not in {"ask", "work", "plan", "grill", "build"}:
        raise HTTPException(422, "mode must be ask, work, plan, or grill")

    requested_session_id = str(body.get("session_id") or "").strip()
    task: TaskCheckout | None = None
    if requested_session_id:
        path = SessionStore.path_for(requested_session_id)
        if path is None:
            raise HTTPException(404, "chat not found")
        session_id = requested_session_id
        header = SessionStore.header(path)
        meta = SessionMeta.get(session_id)
        workspace_root = str(meta.get("workspace_root") or header.get("cwd") or "")
        if not workspace_root or not Path(workspace_root).is_dir():
            raise HTTPException(409, "the chat workspace is unavailable")
        execution_path = str(meta.get("execution_path") or workspace_root)
        environment = (
            "worktree"
            if str((meta.get("environment") or {}).get("type")) == "worktree"
            else "local"
        )
        provider = str(header.get("provider") or body.get("provider") or "ollama")
        account = str(header.get("account") or body.get("provider_account_id") or "")
        model = str(header.get("model") or body.get("model") or "")
    else:
        workspace_root = _schedule_workspace(body.get("workspace_root"))
        environment = str(body.get("execution_environment") or "local")
        if environment not in {"local", "worktree"}:
            raise HTTPException(422, "execution_environment must be local or worktree")
        if environment == "worktree" and not is_git_workspace(workspace_root):
            raise HTTPException(422, "mobile worktrees require a Git repository")
        provider = str(body.get("provider") or "ollama").strip().lower()
        if provider not in {"ollama", "remote", "chatgpt"}:
            raise HTTPException(422, "provider is unavailable")
        account = str(body.get("provider_account_id") or "").strip()
        model = str(body.get("model") or "").strip()
        if not model:
            raise HTTPException(422, "model is required")
        session = SessionStore(workspace_root, model, provider, account)
        session_id = session.session_id
        execution_path = workspace_root
        metadata: dict[str, Any] = {
            "title": _companion_chat_title(prompt),
            "workspace_root": workspace_root,
            "execution_path": workspace_root,
            "environment": {"type": "local", "isolation": "local"},
            "created_by": "companion",
        }
        if environment == "worktree":
            try:
                task = TaskCheckoutStore.create(
                    workspace_root,
                    run_id,
                    session_id=session_id,
                )
            except WorktreeError as exc:
                raise HTTPException(409, str(exc)) from exc
            execution_path = task.execution_path
            metadata.update(
                {
                    "workspace_root": task.workspace_root,
                    "execution_path": task.execution_path,
                    "task": task.as_dict(),
                    "environment": {
                        "type": "worktree",
                        "isolation": "managed_worktree",
                        "worktree_id": task.id,
                        "starting_ref": task.starting_ref,
                    },
                }
            )
        SessionMeta.update(session_id, **metadata)

    manifest = {
        "companion": True,
        "mode": mode,
        "runner": "solo",
        "provider": provider,
        "provider_account_id": account,
        "model": model,
    }
    try:
        run = store.queue_run(
            run_id,
            session_id=session_id,
            workspace_root=workspace_root,
            execution_path=execution_path,
            request=prompt,
            run_kind="solo",
            execution_environment=environment,
            manifest=manifest,
        )
    except (OSError, RunStoreError) as exc:
        if task is not None:
            try:
                TaskCheckoutStore.cleanup(task.id)
            except WorktreeError:
                pass
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "claimed": True, "run": run}


def _dispatch_schedule(
    service: ChatService,
    schedule_id: str,
    *,
    trigger: str,
    request_id: str = "",
) -> dict[str, Any]:
    store = service.run_store
    try:
        schedule, occurrence, claimed = store.claim_schedule_occurrence(
            schedule_id,
            trigger=trigger,
            request_id=request_id,
        )
    except RunStoreError as exc:
        status = 404 if str(exc) == "schedule not found" else 409
        raise HTTPException(status, str(exc)) from exc

    if not claimed:
        run_id = str(occurrence.get("run_id") or "")
        run = store.run(run_id) if run_id else None
        if run is None:
            raise HTTPException(409, "this schedule occurrence is already being dispatched")
        return {
            "ok": True,
            "claimed": False,
            "schedule": schedule,
            "occurrence": occurrence,
            "run": run,
        }

    task: TaskCheckout | None = None
    session_id = ""
    run_id = str(occurrence["id"])
    try:
        workspace_root = _schedule_workspace(schedule["workspace_root"])
        environment = str(schedule["execution_environment"])
        if environment == "worktree" and not is_git_workspace(workspace_root):
            raise WorktreeError("scheduled worktrees require a Git repository")

        session = SessionStore(
            workspace_root,
            str(schedule["model"]),
            str(schedule["provider"]),
            str(schedule.get("provider_account_id") or ""),
        )
        session_id = session.session_id
        execution_path = workspace_root
        metadata: dict[str, Any] = {
            "title": _scheduled_chat_title(
                schedule,
                float(occurrence["scheduled_for"]),
            ),
            "workspace_root": workspace_root,
            "execution_path": workspace_root,
            "environment": {"type": "local", "isolation": "local"},
            "schedule_id": schedule_id,
            "occurrence_id": occurrence["id"],
        }
        if environment == "worktree":
            task = TaskCheckoutStore.create(
                workspace_root,
                str(occurrence["id"]),
                session_id=session_id,
            )
            execution_path = task.execution_path
            metadata.update(
                {
                    "workspace_root": task.workspace_root,
                    "execution_path": task.execution_path,
                    "task": task.as_dict(),
                    "environment": {
                        "type": "worktree",
                        "isolation": "managed_worktree",
                        "worktree_id": task.id,
                        "starting_ref": task.starting_ref,
                    },
                }
            )
        if schedule["runner"] == "team":
            metadata["team"] = {
                "id": schedule.get("team_id"),
                "name": schedule.get("team_name"),
            }
        SessionMeta.update(session_id, **metadata)

        manifest = {
            "scheduled": True,
            "schedule_id": schedule_id,
            "occurrence_id": occurrence["id"],
            "mode": schedule["mode"],
            "runner": schedule["runner"],
            # `solo_swarm` is the durable compatibility marker for a Solo run
            # that may delegate. All Solo schedules are adaptive now.
            "solo_swarm": schedule["runner"] != "team",
            "provider": schedule["provider"],
            "provider_account_id": schedule.get("provider_account_id") or "",
            "model": schedule["model"],
            "timezone": schedule["timezone"],
        }
        run = store.queue_run(
            run_id,
            session_id=session_id,
            team_id=str(schedule.get("team_id") or ""),
            team_name=str(schedule.get("team_name") or ""),
            workspace_root=workspace_root,
            execution_path=execution_path,
            request=str(schedule["prompt"]),
            run_kind="team" if schedule["runner"] == "team" else "solo",
            execution_environment=environment,
            manifest=manifest,
            schedule_id=schedule_id,
            occurrence_id=str(occurrence["id"]),
            scheduled_for=float(occurrence["scheduled_for"]),
        )
        occurrence = store.finish_schedule_occurrence(
            str(occurrence["id"]),
            state="queued",
            session_id=session_id,
            run_id=run_id,
        )
        return {
            "ok": True,
            "claimed": True,
            "schedule": store.schedule(schedule_id),
            "occurrence": occurrence,
            "run": run,
        }
    except (HTTPException, WorktreeError, OSError, RunStoreError) as exc:
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        if task is not None:
            try:
                TaskCheckoutStore.cleanup(task.id)
            except WorktreeError:
                pass
        try:
            store.finish_schedule_occurrence(
                str(occurrence["id"]),
                state="failed",
                session_id=session_id,
                error=str(detail),
            )
            if isinstance(exc, (HTTPException, WorktreeError)):
                store.pause_schedule(schedule_id, str(detail))
        except RunStoreError:
            pass
        status = exc.status_code if isinstance(exc, HTTPException) else 409
        raise HTTPException(status, str(detail)) from exc


def schedule_list(service: ServiceDependency) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    return {"schedules": store.schedules(), "read_only": store.read_only}


def schedule_create(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return service.run_store.create_schedule(_validate_schedule_payload(body))
    except RunStoreError as exc:
        raise HTTPException(422, str(exc)) from exc


def schedule_update(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    existing = store.schedule(schedule_id)
    if existing is None:
        raise HTTPException(404, "schedule not found")
    try:
        return store.update_schedule(
            schedule_id,
            _validate_schedule_payload(body, existing=existing),
        )
    except RunStoreError as exc:
        status = 404 if str(exc) == "schedule not found" else 422
        raise HTTPException(status, str(exc)) from exc


def schedule_delete(schedule_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        service.run_store.delete_schedule(schedule_id)
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc
    return {"ok": True, "id": schedule_id}


def schedule_occurrence_list(
    schedule_id: str,
    service: ServiceDependency,
    limit: int = Query(default=20, ge=1, le=100),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    if store.schedule(schedule_id) is None and not store.schedule_occurrences(
        schedule_id,
        limit=1,
    ):
        raise HTTPException(404, "schedule not found")
    return {"occurrences": store.schedule_occurrences(schedule_id, limit=limit)}


def schedule_pause(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return service.run_store.pause_schedule(
            schedule_id,
            str(body.get("reason") or "The schedule needs attention."),
        )
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


def schedule_dispatch(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    trigger = str(body.get("trigger") or "manual")
    if trigger not in {"due", "manual"}:
        raise HTTPException(422, "trigger must be due or manual")
    return _dispatch_schedule(
        service,
        schedule_id,
        trigger=trigger,
        request_id=str(body.get("request_id") or ""),
    )


def companion_chat_dispatch(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Internal loopback API used only by the authenticated native gateway."""
    _require_capability("durable_runs")
    return _dispatch_companion_chat(service, body)


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/schedules", schedule_list, methods=["GET"])
    router.add_api_route("/api/schedules", schedule_create, methods=["POST"])
    router.add_api_route(
        "/api/schedules/{schedule_id}", schedule_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}", schedule_delete, methods=["DELETE"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/occurrences",
        schedule_occurrence_list,
        methods=["GET"],
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/pause", schedule_pause, methods=["POST"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/dispatch", schedule_dispatch, methods=["POST"]
    )
    router.add_api_route(
        "/api/companion/chats", companion_chat_dispatch, methods=["POST"]
    )


__all__ = ["register_routes"]
