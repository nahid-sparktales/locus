"""Domain-owned route registration for the Locus backend."""

from types import ModuleType

from fastapi import APIRouter

from . import (
    chat_transport,
    continuity,
    evaluations,
    extensions,
    knowledge,
    providers,
    runs,
    schedules,
    sessions,
    system,
    workspace,
)

_ROUTE_MODULES = (
    system,
    providers,
    continuity,
    knowledge,
    evaluations,
    sessions,
    schedules,
    runs,
    workspace,
    extensions,
    chat_transport,
)


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    """Register direct domain handlers plus explicit compatibility handlers."""
    for route_module in _ROUTE_MODULES:
        if route_module in {extensions, runs}:
            route_module.register_routes(router)
        else:
            route_module.register_routes(router, handlers)
