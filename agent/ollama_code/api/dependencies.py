"""Request-owned backend dependencies shared by HTTP and WebSocket routes."""

from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar

from fastapi import FastAPI, HTTPException, Request

from ..chat_service import ChatService

_NO_REQUEST = object()
_request_service: ContextVar[ChatService | None | object] = ContextVar(
    "request_service", default=_NO_REQUEST
)


def service_from_app(application: FastAPI) -> ChatService:
    """Resolve the service owned by one concrete application instance."""
    service: ChatService | None = getattr(application.state, "service", None)
    if service is None:
        raise HTTPException(503, "agent service is not ready")
    return service


def get_service(request: Request) -> ChatService:
    """FastAPI dependency for handlers that accept explicit dependencies."""
    return service_from_app(request.app)


@contextmanager
def request_service_context(service: ChatService | None) -> Iterator[None]:
    """Expose request state to legacy handlers until their signatures migrate."""
    token = _request_service.set(service)
    try:
        yield
    finally:
        _request_service.reset(token)


def current_service(fallback_app: FastAPI) -> ChatService:
    """Resolve request state, falling back only for direct compatibility calls."""
    service = _request_service.get()
    if service is _NO_REQUEST:
        return service_from_app(fallback_app)
    if service is None:
        raise HTTPException(503, "agent service is not ready")
    return service  # type: ignore[return-value]
