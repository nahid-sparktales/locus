"""Evaluation suite and evaluation-run routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/evaluations", handlers.evaluation_list, methods=["GET"])
    router.add_api_route("/api/evaluations", handlers.evaluation_create, methods=["POST"])
    router.add_api_route("/api/evaluations/{suite_id}", handlers.evaluation_detail, methods=["GET"])
    router.add_api_route(
        "/api/evaluations/{suite_id}/comparison", handlers.evaluation_comparison, methods=["GET"]
    )
    router.add_api_route(
        "/api/evaluations/{suite_id}/export", handlers.evaluation_export, methods=["GET"]
    )
    router.add_api_route("/api/evaluations/{suite_id}", handlers.evaluation_update, methods=["PUT"])
    router.add_api_route(
        "/api/evaluations/{suite_id}", handlers.evaluation_delete, methods=["DELETE"]
    )
    router.add_api_route(
        "/api/evaluations/{suite_id}/grade", handlers.evaluation_grade, methods=["POST"]
    )
    router.add_api_route(
        "/api/evaluations/{suite_id}/run", handlers.evaluation_run, methods=["POST"]
    )
    router.add_api_route(
        "/api/evaluations/runs/{evaluation_id}/cancel", handlers.evaluation_cancel, methods=["POST"]
    )
