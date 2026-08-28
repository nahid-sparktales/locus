"""Workspace knowledge indexing and retrieval routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/knowledge/status", handlers.knowledge_status, methods=["GET"])
    router.add_api_route("/api/knowledge/settings", handlers.knowledge_settings, methods=["POST"])
    router.add_api_route("/api/knowledge/reindex", handlers.knowledge_reindex, methods=["POST"])
    router.add_api_route("/api/knowledge/changes", handlers.knowledge_changes, methods=["POST"])
    router.add_api_route("/api/knowledge/search", handlers.knowledge_search, methods=["GET"])
    router.add_api_route("/api/knowledge/memories", handlers.knowledge_memories, methods=["GET"])
    router.add_api_route(
        "/api/knowledge/memories", handlers.knowledge_memory_create, methods=["POST"]
    )
    router.add_api_route(
        "/api/knowledge/memories/{memory_id}", handlers.knowledge_memory_update, methods=["PUT"]
    )
    router.add_api_route(
        "/api/knowledge/memories/{memory_id}", handlers.knowledge_memory_delete, methods=["DELETE"]
    )
    router.add_api_route("/api/knowledge", handlers.knowledge_delete_all, methods=["DELETE"])
