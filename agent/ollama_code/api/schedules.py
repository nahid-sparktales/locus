"""Scheduled and companion chat dispatch routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/schedules", handlers.schedule_list, methods=["GET"])
    router.add_api_route("/api/schedules", handlers.schedule_create, methods=["POST"])
    router.add_api_route(
        "/api/schedules/{schedule_id}", handlers.schedule_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}", handlers.schedule_delete, methods=["DELETE"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/occurrences",
        handlers.schedule_occurrence_list,
        methods=["GET"],
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/pause", handlers.schedule_pause, methods=["POST"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/dispatch", handlers.schedule_dispatch, methods=["POST"]
    )
    router.add_api_route("/api/companion/chats", handlers.companion_chat_dispatch, methods=["POST"])
