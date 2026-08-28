"""Cross-session context, memory, and skill-observation routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/context-snapshots", handlers.context_snapshots, methods=["GET"])
    router.add_api_route(
        "/api/context-snapshots/{snapshot_id}", handlers.context_snapshot_update, methods=["PUT"]
    )
    router.add_api_route(
        "/api/context-snapshots/{snapshot_id}", handlers.context_snapshot_delete, methods=["DELETE"]
    )
    router.add_api_route(
        "/api/context-snapshots", handlers.context_snapshots_clear, methods=["DELETE"]
    )
    router.add_api_route("/api/skill-observations", handlers.skill_observations, methods=["GET"])
    router.add_api_route(
        "/api/skill-observations/{observation_id}",
        handlers.skill_observation_update,
        methods=["PUT"],
    )
    router.add_api_route(
        "/api/skill-observations/{observation_id}",
        handlers.skill_observation_delete,
        methods=["DELETE"],
    )
    router.add_api_route(
        "/api/skill-observations/export", handlers.skill_observation_export, methods=["GET"]
    )
    router.add_api_route("/api/memory/status", handlers.memory_status, methods=["GET"])
    router.add_api_route("/api/memory", handlers.memory_list, methods=["GET"])
    router.add_api_route("/api/memory", handlers.memory_create, methods=["POST"])
    router.add_api_route("/api/memory", handlers.memory_delete_all, methods=["DELETE"])
    router.add_api_route("/api/memory/{memory_id}", handlers.memory_update, methods=["PUT"])
    router.add_api_route(
        "/api/memory/{memory_id}/approve", handlers.memory_approve, methods=["POST"]
    )
    router.add_api_route("/api/memory/{memory_id}", handlers.memory_delete, methods=["DELETE"])
    router.add_api_route("/api/memory/search", handlers.memory_search, methods=["GET"])
    router.add_api_route("/api/memory/export", handlers.memory_export, methods=["GET"])
    router.add_api_route("/api/memory/import", handlers.memory_import, methods=["POST"])
    router.add_api_route(
        "/api/memory/{memory_id}/feedback", handlers.memory_feedback, methods=["POST"]
    )
    router.add_api_route(
        "/api/memory/maintenance/run", handlers.memory_maintenance, methods=["POST"]
    )
    router.add_api_route("/api/memory/diagnostics", handlers.memory_diagnostics, methods=["GET"])
    router.add_api_route("/api/memory/reprocess", handlers.memory_reprocess, methods=["POST"])
