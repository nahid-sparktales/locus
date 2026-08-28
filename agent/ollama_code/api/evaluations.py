"""Evaluation suite CRUD, grading, and execution routes."""

from pathlib import Path
from types import ModuleType
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
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


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
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
        "/api/evaluations/{suite_id}/run", handlers.evaluation_run, methods=["POST"]
    )
    router.add_api_route(
        "/api/evaluations/runs/{evaluation_id}/cancel",
        handlers.evaluation_cancel,
        methods=["POST"],
    )
