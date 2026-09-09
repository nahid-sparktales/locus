"""Domain-owned route registration for the Locus backend."""

from fastapi import APIRouter

from . import (
    automation_workflows,
    capsules,
    chat_transport,
    continuity,
    evaluations,
    event_triggers,
    extensions,
    goals,
    knowledge,
    providers,
    runs,
    schedules,
    sessions,
    system,
    task_details,
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
    event_triggers,
    automation_workflows,
    capsules,
    goals,
    task_details,
    runs,
    workspace,
    extensions,
    chat_transport,
)


def register_routes(router: APIRouter) -> None:
    """Register routes whose behavior is owned by each domain module."""
    for route_module in _ROUTE_MODULES:
        route_module.register_routes(router)
