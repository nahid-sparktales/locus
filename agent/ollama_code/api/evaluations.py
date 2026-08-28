"""Evaluation suite CRUD, grading, and execution routes."""

import asyncio
import uuid
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..evaluation_runtime import run_evaluation_suite
from ..evaluations import (
    EvaluationError,
    EvaluationStore,
    compare_results,
    grade_case,
    summarize_results,
)
from ..worktrees import TaskCheckoutStore
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _store(service: ChatService) -> EvaluationStore:
    if not capability_enabled("evaluations"):
        raise HTTPException(404, "capability is disabled: evaluations")
    return EvaluationStore(service.run_store)


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def evaluation_list(
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    return {"suites": _store(service).list_suites(workspace)}


def evaluation_create(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        return {"ok": True, "suite": _store(service).save_suite(body)}
    except EvaluationError as exc:
        raise HTTPException(422, str(exc)) from exc


def evaluation_detail(suite_id: str, service: ServiceDependency) -> dict[str, Any]:
    store = _store(service)
    suite = store.get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    results = store.results(suite_id)
    return {
        "suite": suite,
        "results": results,
        "summary": summarize_results(results),
        "comparison": compare_results(results),
    }


def evaluation_comparison(suite_id: str, service: ServiceDependency) -> dict[str, Any]:
    store = _store(service)
    if store.get_suite(suite_id) is None:
        raise HTTPException(404, "evaluation suite not found")
    return {
        "suite_id": suite_id,
        "configurations": compare_results(store.results(suite_id)),
    }


def evaluation_export(
    suite_id: str,
    service: ServiceDependency,
    include_results: bool = Query(default=False),
) -> dict[str, Any]:
    store = _store(service)
    suite = store.get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    export: dict[str, Any] = {"schema_version": 1, "suite": suite}
    if include_results:
        export["results"] = store.results(suite_id)
    return export


def evaluation_update(
    suite_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        return {"ok": True, "suite": _store(service).save_suite(body, suite_id)}
    except EvaluationError as exc:
        raise HTTPException(422, str(exc)) from exc


def evaluation_delete(suite_id: str, service: ServiceDependency) -> dict[str, Any]:
    if not _store(service).delete_suite(suite_id):
        raise HTTPException(404, "evaluation suite not found")
    return {"ok": True, "id": suite_id}


def evaluation_grade(
    suite_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    suite = _store(service).get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    case_id = str(body.get("case_id") or "")
    case = next((item for item in suite["cases"] if item["id"] == case_id), None)
    if case is None:
        raise HTTPException(404, "evaluation case not found")
    checkout = str(body.get("checkout") or "")
    source_root = Path(suite["workspace_root"]).resolve()
    checkout_path = Path(checkout).resolve()
    if checkout_path != source_root or str(case.get("mode")) != "read_only":
        task_id = str(body.get("task_id") or "")
        task = TaskCheckoutStore.load(task_id) if task_id else None
        if task is None or Path(task.execution_path).resolve() != checkout_path:
            raise HTTPException(422, "checkout is not a managed evaluation task")
    try:
        result = grade_case(
            case,
            checkout,
            str(body.get("output") or ""),
            [str(item) for item in body.get("changed_paths") or []],
        )
    except EvaluationError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"case_id": case_id, **result}


async def evaluation_run(
    suite_id: str,
    request: Request,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    store = _store(service)
    suite = store.get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    manifest = body.get("manifest")
    raw_manifests = body.get("manifests")
    manifests = (
        {
            str(team_id): dict(value)
            for team_id, value in raw_manifests.items()
            if str(team_id) and isinstance(value, dict)
        }
        if isinstance(raw_manifests, dict)
        else {}
    )
    if len(manifests) > 32:
        raise HTTPException(422, "an evaluation run may reference at most 32 teams")
    needs_team = any(
        str(case.get("target") or "team") == "team" for case in suite["cases"]
    )
    missing_team = any(
        str(case.get("target") or "team") == "team"
        and not (
            isinstance(manifest, dict)
            or str(case.get("team_id") or "") in manifests
            or (not str(case.get("team_id") or "") and len(manifests) == 1)
        )
        for case in suite["cases"]
    )
    if needs_team and missing_team:
        raise HTTPException(422, "team evaluation cases require a configured team manifest")
    if not isinstance(manifest, dict):
        manifest = {}
    if service.busy:
        raise _busy_http()
    team_runner = getattr(request.app.state, "evaluation_team_runner", None)
    if not callable(team_runner):
        raise HTTPException(503, "evaluation execution is not configured")
    loop = asyncio.get_running_loop()
    evaluation_id = uuid.uuid4().hex
    if not service.start_turn(
        loop,
        run_evaluation_suite,
        service,
        suite,
        dict(manifest),
        manifests,
        evaluation_id,
        team_runner,
    ):
        raise _busy_http()
    return {"ok": True, "evaluation_id": evaluation_id, "state": "queued"}


def evaluation_cancel(
    evaluation_id: str,
    service: ServiceDependency,
) -> dict[str, Any]:
    if service.active_evaluation_id != evaluation_id:
        raise HTTPException(409, "that evaluation is not currently running")
    service.core.interrupt()
    if service.active_evaluation_core is not None:
        service.active_evaluation_core.interrupt()
    return {"ok": True, "evaluation_id": evaluation_id, "state": "cancelling"}


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/evaluations", evaluation_list, methods=["GET"])
    router.add_api_route("/api/evaluations", evaluation_create, methods=["POST"])
    router.add_api_route("/api/evaluations/{suite_id}", evaluation_detail, methods=["GET"])
    router.add_api_route(
        "/api/evaluations/{suite_id}/comparison", evaluation_comparison, methods=["GET"]
    )
    router.add_api_route(
        "/api/evaluations/{suite_id}/export", evaluation_export, methods=["GET"]
    )
    router.add_api_route("/api/evaluations/{suite_id}", evaluation_update, methods=["PUT"])
    router.add_api_route(
        "/api/evaluations/{suite_id}", evaluation_delete, methods=["DELETE"]
    )
    router.add_api_route(
        "/api/evaluations/{suite_id}/grade", evaluation_grade, methods=["POST"]
    )
    router.add_api_route(
        "/api/evaluations/{suite_id}/run", evaluation_run, methods=["POST"]
    )
    router.add_api_route(
        "/api/evaluations/runs/{evaluation_id}/cancel",
        evaluation_cancel,
        methods=["POST"],
    )
