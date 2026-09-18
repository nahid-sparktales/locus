"""Request-owned backend dependencies shared by HTTP and WebSocket routes."""

from fastapi import FastAPI, HTTPException, Request

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
