"""Chat session and folder organization routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/sessions", handlers.sessions, methods=["GET"])
    router.add_api_route("/api/chat-folders", handlers.chat_folders, methods=["GET"])
    router.add_api_route("/api/chat-folders", handlers.chat_folder_create, methods=["POST"])
    router.add_api_route(
        "/api/chat-folders/{folder_id}", handlers.chat_folder_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/chat-folders/{folder_id}", handlers.chat_folder_delete, methods=["DELETE"]
    )
    router.add_api_route("/api/sessions/search", handlers.sessions_search, methods=["GET"])
    router.add_api_route("/api/sessions/new", handlers.session_new, methods=["POST"])
    router.add_api_route("/api/sessions", handlers.sessions_clear, methods=["DELETE"])
    router.add_api_route("/api/sessions/{session_id}", handlers.session_delete, methods=["DELETE"])
    router.add_api_route("/api/sessions/restore", handlers.sessions_restore, methods=["POST"])
    router.add_api_route("/api/sessions/{session_id}", handlers.session_detail, methods=["GET"])
    router.add_api_route(
        "/api/sessions/{session_id}/export-data", handlers.session_export_data, methods=["GET"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/organization",
        handlers.session_organization_update,
        methods=["PATCH"],
    )
    router.add_api_route(
        "/api/sessions/{session_id}/organization", handlers.session_organization, methods=["GET"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/duplicate", handlers.session_duplicate, methods=["POST"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}", handlers.session_metadata_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/resume", handlers.session_resume, methods=["POST"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/handoff", handlers.session_handoff, methods=["POST"]
    )
