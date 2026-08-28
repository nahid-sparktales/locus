"""Provider selection, model discovery, and ChatGPT account routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/provider", handlers.get_provider, methods=["GET"])
    router.add_api_route(
        "/api/model-router/decision", handlers.model_router_decision, methods=["POST"]
    )
    router.add_api_route("/api/model-router/sample", handlers.model_router_sample, methods=["POST"])
    router.add_api_route("/api/chatgpt/account", handlers.chatgpt_account, methods=["GET"])
    router.add_api_route("/api/chatgpt/login/start", handlers.chatgpt_login_start, methods=["POST"])
    router.add_api_route(
        "/api/chatgpt/login/cancel", handlers.chatgpt_login_cancel, methods=["POST"]
    )
    router.add_api_route("/api/chatgpt/logout", handlers.chatgpt_logout, methods=["POST"])
    router.add_api_route("/api/chatgpt/models", handlers.chatgpt_models, methods=["GET"])
    router.add_api_route("/api/chatgpt/usage", handlers.chatgpt_usage, methods=["GET"])
    router.add_api_route("/api/provider", handlers.set_provider, methods=["POST"])
    router.add_api_route("/api/models", handlers.models, methods=["GET"])
