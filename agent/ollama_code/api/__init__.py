"""Domain-owned route registration for the Locus backend."""

from fastapi import APIRouter

from . import (
    reusable_checks,
    accounting,
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
    runtime,
    runtime_deploy,
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
    event_triggers,
    reusable_checks,
    accounting,
    automation_workflows,
    capsules,
    goals,
    runs,
    runtime,
    runtime_deploy,
    workspace,
    extensions,
    chat_transport,
)


def register_routes(router: APIRouter) -> None:
    """Register routes whose behavior is owned by each domain module."""
    for route_module in _ROUTE_MODULES:
        route_module.register_routes(router)
