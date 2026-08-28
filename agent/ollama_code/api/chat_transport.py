"""Authenticated WebSocket transports for chat and Codex workers."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_websocket_route("/ws/internal/codex", handlers.ws_codex_broker)
    router.add_api_websocket_route("/ws/chat", handlers.ws_chat)
