"""Request-owned backend dependencies shared by HTTP and WebSocket routes."""

from fastapi import FastAPI, HTTPException, Request

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService


def service_from_app(application: FastAPI) -> ChatService:
    """Resolve the service owned by one concrete application instance."""
    service: ChatService | None = getattr(application.state, "service", None)
    if service is None:
        raise HTTPException(503, "agent service is not ready")
    return service


def get_service(request: Request) -> ChatService:
    """FastAPI dependency for handlers that accept explicit dependencies."""
    return service_from_app(request.app)


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def _require_capability(name: str) -> None:
    if not capability_enabled(name):
        raise HTTPException(404, f"capability is disabled: {name}")
