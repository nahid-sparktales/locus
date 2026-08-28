"""System health, tool, permission, service, and configuration routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/health", handlers.health, methods=["GET"])
    router.add_api_route("/api/tools", handlers.list_tools, methods=["GET"])
    router.add_api_route("/api/services", handlers.background_service_list, methods=["GET"])
    router.add_api_route("/api/services", handlers.background_service_start, methods=["POST"])
    router.add_api_route(
        "/api/services/{name}", handlers.background_service_stop, methods=["DELETE"]
    )
    router.add_api_route("/api/permissions", handlers.get_permissions, methods=["GET"])
    router.add_api_route("/api/permissions", handlers.set_permissions, methods=["POST"])
    router.add_api_route("/api/config", handlers.get_config, methods=["GET"])
    router.add_api_route("/api/config", handlers.post_config, methods=["POST"])
    router.add_api_route("/api/context/reload", handlers.reload_project_context, methods=["POST"])
