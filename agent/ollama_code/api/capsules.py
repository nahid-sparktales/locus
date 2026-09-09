"""Task capsule storage and read-only source validation routes."""
import math
import sqlite3
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capsules import CapsuleError, CapsuleStore
from ..chat_service import ChatService
from ..runstore import RunStoreError
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def capsule_store(service: ChatService, workspace_root: str = "") -> CapsuleStore:
    workspace = workspace_root or service.core.workspace_root or service.core.cwd
    return CapsuleStore(workspace)


def _present(service: ChatService, capsule: dict[str, Any]) -> dict[str, Any]:
    """Attach safe usage and conversation links when the durable run still exists."""
    lookup = getattr(getattr(service, "run_store", None), "run", None)
    if not callable(lookup):
        return capsule
    runs = []
    for link in capsule["runs"]:
        try:
            run = lookup(link["run_id"])
        except (RunStoreError, sqlite3.DatabaseError, OSError):
            run = None
        enriched = dict(link)
        if run and run.get("workspace_root") and Path(run["workspace_root"]).resolve() == Path(capsule["workspace_root"]):
            usage = run.get("usage") or {}
            enriched["accounting"] = run.get("accounting")
            enriched["usage"] = {
                key: value for key in ("model_calls", "metered_tokens", "estimated_cost", "prompt_tokens", "completion_tokens")
                if isinstance((value := usage.get(key)), (int, float)) and not isinstance(value, bool)
                and math.isfinite(value) and value >= 0
            }
            if isinstance(run.get("state"), str):
                enriched["state"] = run["state"]
            session_id = run.get("session_id")
            if isinstance(session_id, str) and session_id.strip():
                enriched["session_id"] = session_id
        runs.append(enriched)
    from ..capsule_progress import CapsuleProgressStore
    from ..usage_ledger import UsageLedger
    attempts = [{**attempt, "accounting": UsageLedger(service.run_store).summary(task_id="capsule:" + attempt["id"])} for attempt in CapsuleProgressStore(service.run_store).list(capsule["id"])]
    return {**capsule, "runs": runs, "attempts": attempts}


def _origin_run(service: ChatService, body: dict[str, Any], store: CapsuleStore) -> dict[str, Any] | None:
    run_id = body.get("origin_run_id")
    if not run_id:
        return None
    lookup = getattr(getattr(service, "run_store", None), "run", None)
    if not isinstance(run_id, str) or len(run_id) > 200 or not callable(lookup):
        raise CapsuleError("origin_run_id must identify an available planning run")
    run = lookup(run_id)
    session_id = body.get("origin_session_id") or getattr(getattr(service.core, "session", None), "session_id", None)
    if (
        not run or not run.get("workspace_root")
        or Path(run["workspace_root"]).resolve() != store.root
        or not isinstance(session_id, str) or not session_id or run.get("session_id") != session_id
    ):
        raise CapsuleError("origin run must belong to the source task and capsule workspace")
    return {"run_id": run_id, "state": run["state"]}


def capsule_list(service: ServiceDependency, workspace_root: str = Query(default=""), limit: int = Query(default=100, ge=1, le=500)) -> dict[str, Any]:
    try:
        return {"capsules": [_present(service, c) for c in capsule_store(service, workspace_root).list(limit)]}
    except (CapsuleError, ValueError) as exc:
        raise HTTPException(getattr(exc, "status_code", 409), str(exc)) from exc


def capsule_create(service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        store = capsule_store(service, body.get("workspace_root", ""))
        origin_run = _origin_run(service, body, store)
        return {"capsule": _present(service, store.create(body, origin_run=origin_run))}
    except (CapsuleError, ValueError) as exc:
        raise HTTPException(getattr(exc, "status_code", 409), str(exc)) from exc


def capsule_get(capsule_id: str, service: ServiceDependency, workspace_root: str = Query(default=""), revision: int | None = Query(default=None, ge=1)) -> dict[str, Any]:
    try:
        return {"capsule": _present(service, capsule_store(service, workspace_root).get(capsule_id, revision))}
    except (CapsuleError, ValueError) as exc:
        raise HTTPException(getattr(exc, "status_code", 409), str(exc)) from exc


def capsule_update(capsule_id: str, service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        store = capsule_store(service, body.get("workspace_root", ""))
        if body.get("action") in {"accept", "resolve_action", "resolve_usage"}:
            from ..capsule_progress import CapsuleProgressStore
            capsule = store.get(capsule_id)
            if capsule["revision"] != body.get("expected_revision"):
                raise CapsuleError("The capsule changed; reload before accepting.", 409)
            progress = CapsuleProgressStore(service.run_store)
            if body["action"] == "accept":
                progress.accept(str(body.get("attempt_id") or ""), capsule_id, capsule["revision"])
            elif body["action"] == "resolve_usage":
                progress.resolve_usage(str(body.get("attempt_id") or ""), capsule_id, body.get("usage"))
            else:
                progress.resolve_action(str(body.get("attempt_id") or ""), capsule_id,
                                        body.get("action_id"), body.get("note"))
            return {"capsule": _present(service, capsule)}
        return {"capsule": _present(service, store.update(capsule_id, body, body.get("expected_revision")))}
    except (CapsuleError, ValueError) as exc:
        raise HTTPException(getattr(exc, "status_code", 409), str(exc)) from exc


def capsule_validate(capsule_id: str, service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        return capsule_store(service, body.get("workspace_root", "")).validate(capsule_id, body.get("revision"))
    except (CapsuleError, ValueError) as exc:
        raise HTTPException(getattr(exc, "status_code", 409), str(exc)) from exc


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/capsules", capsule_list, methods=["GET"])
    router.add_api_route("/api/capsules", capsule_create, methods=["POST"])
    router.add_api_route("/api/capsules/{capsule_id}", capsule_get, methods=["GET"])
    router.add_api_route("/api/capsules/{capsule_id}", capsule_update, methods=["PATCH"])
    router.add_api_route("/api/capsules/{capsule_id}/validate", capsule_validate, methods=["POST"])
