"""Extension marketplace, plugin, skill, and MCP routes."""

from collections.abc import Callable
from contextlib import AbstractContextManager
from typing import Annotated, Any, TypeVar

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..chat_service import AgentBusyError, ChatService
from ..extensions import ExtensionError
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]
T = TypeVar("T")


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def _extension_failure(exc: ExtensionError) -> HTTPException:
    return HTTPException(422, str(exc))


def _extension_snapshot(service: ChatService) -> dict[str, Any]:
    snapshot = service.core.extensions.snapshot()
    statuses = {item["id"]: item for item in service.core.mcp.statuses()}
    for server in snapshot["mcp_servers"]:
        server.update(statuses.get(str(server.get("id"))) or {})
        server["has_credentials"] = bool(
            service.core.extensions.credentials(str(server.get("id") or ""))
        )
    snapshot["pending_updates"] = sum(
        1 for plugin in snapshot["plugins"] if plugin.get("update_available")
    )
    return snapshot


def _announce_extensions(service: ChatService, reason: str) -> None:
    service.core.tool_registry.refresh()
    service.queue_event({"type": "extensions_changed", "reason": reason})


def _mutate(
    service: ChatService,
    operation: Callable[[], T],
    reason: str,
    *,
    refresh_mcp: bool = False,
) -> T:
    """Run one extension mutation under the service-wide state lock."""
    try:
        context: AbstractContextManager[None] = service.state_mutation()
        with context:
            value = operation()
            if refresh_mcp:
                service.core.mcp.refresh(wait=False)
            _announce_extensions(service, reason)
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def get_extensions(service: ServiceDependency) -> dict[str, Any]:
    return _extension_snapshot(service)


def get_extension_catalog(
    service: ServiceDependency,
    query: str = Query("", max_length=500),
    marketplace_id: str = Query("", max_length=200),
) -> dict[str, Any]:
    return {
        "entries": service.core.extensions.catalog(query, marketplace_id),
        "marketplace_id": marketplace_id,
    }


def inspect_extension_plugin(
    service: ServiceDependency,
    marketplace_id: str = Query(..., max_length=200),
    plugin: str = Query(..., max_length=200),
) -> dict[str, Any]:
    try:
        return service.core.extensions.inspect_catalog_plugin(marketplace_id, plugin)
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def add_extension_marketplace(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        value = service.core.extensions.add_marketplace(
            str(body.get("source") or ""),
            name=str(body.get("name") or ""),
            ref=str(body.get("ref") or ""),
            sparse_paths=[str(value) for value in body.get("sparse_paths") or []],
        )
        _announce_extensions(service, "marketplace_added")
        return value
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def refresh_extension_marketplace(
    marketplace_id: str, service: ServiceDependency
) -> dict[str, Any]:
    try:
        value = service.core.extensions.refresh_marketplace(marketplace_id)
        _announce_extensions(service, "marketplace_refreshed")
        return value
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def delete_extension_marketplace(
    marketplace_id: str, service: ServiceDependency
) -> dict[str, Any]:
    try:
        service.core.extensions.remove_marketplace(marketplace_id)
        _announce_extensions(service, "marketplace_removed")
        return {"ok": True}
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def install_extension_plugin(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.install_plugin(
            str(body.get("marketplace_id") or ""),
            str(body.get("plugin") or body.get("name") or ""),
            scope=str(body.get("scope") or "global"),
            workspace=str(body.get("workspace") or service.core.cwd),
            expected_digest=str(body.get("expected_digest") or ""),
        ),
        "plugin_installed",
        refresh_mcp=True,
    )


def enable_extension_plugin(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.set_plugin_enabled(
            str(body.get("id") or ""),
            bool(body.get("enabled", True)),
            scope=str(body.get("scope") or "global"),
            workspace=str(body.get("workspace") or service.core.cwd),
        ),
        "plugin_activation_changed",
        refresh_mcp=True,
    )


def update_extension_plugin(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.update_plugin(
            str(body.get("id") or ""),
            expected_digest=str(body.get("expected_digest") or ""),
        ),
        "plugin_updated",
        refresh_mcp=True,
    )


def rollback_extension_plugin(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.rollback_plugin(str(body.get("id") or "")),
        "plugin_rolled_back",
        refresh_mcp=True,
    )


def uninstall_extension_plugin(
    plugin_id: str, service: ServiceDependency
) -> dict[str, Any]:
    def uninstall() -> dict[str, bool]:
        service.core.extensions.uninstall_plugin(plugin_id)
        return {"ok": True}

    return _mutate(
        service, uninstall, "plugin_uninstalled", refresh_mcp=True
    )


def import_extension_skill(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.import_skill(
            str(body.get("source") or ""),
            scope=str(body.get("scope") or "global"),
            workspace=str(body.get("workspace") or service.core.cwd),
        ),
        "skill_imported",
    )


def enable_extension_skill(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.set_skill_enabled(
            str(body.get("id") or ""),
            bool(body.get("enabled", True)),
            scope=str(body.get("scope") or "global"),
            workspace=str(body.get("workspace") or service.core.cwd),
        ),
        "skill_activation_changed",
    )


def remove_extension_skill(
    skill_id: str, service: ServiceDependency
) -> dict[str, Any]:
    def remove() -> dict[str, bool]:
        service.core.extensions.remove_skill(skill_id)
        return {"ok": True}

    return _mutate(service, remove, "skill_removed")


def upsert_extension_mcp(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.upsert_mcp_server(
            body, server_id=str(body.get("id") or "")
        ),
        "mcp_saved",
        refresh_mcp=True,
    )


def materialize_extension_mcp_preset(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.materialize_mcp_preset(
            str(body.get("id") or ""),
            project_ref=str(body.get("project_ref") or ""),
        ),
        "mcp_preset_materialized",
        refresh_mcp=True,
    )


def enable_extension_mcp(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.set_mcp_enabled(
            str(body.get("id") or ""),
            bool(body.get("enabled", True)),
            scope=str(body.get("scope") or "global"),
            workspace=str(body.get("workspace") or service.core.cwd),
        ),
        "mcp_activation_changed",
        refresh_mcp=True,
    )


def set_extension_mcp_credentials(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    server_id = str(body.get("id") or "")
    values = body.get("credentials") if isinstance(body.get("credentials"), dict) else {}
    try:
        service.core.extensions.set_credentials(server_id, values)
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc
    service.core.mcp.refresh(wait=False)
    service.queue_event({"type": "mcp_credential_refresh", "server_id": server_id})
    return {"ok": True, "id": server_id, "has_credentials": bool(values)}


def set_extension_mcp_policy(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _mutate(
        service,
        lambda: service.core.extensions.set_mcp_policy(
            str(body.get("id") or ""),
            str(body.get("mode") or "annotations"),
            tool_name=str(body.get("tool") or ""),
        ),
        "mcp_policy_changed",
        refresh_mcp=True,
    )


def test_extension_mcp(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        return service.core.mcp.probe(str(body.get("id") or ""))
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def reconnect_extension_mcp(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    server_id = str(body.get("id") or "")
    try:
        with service.state_mutation():
            service.core.mcp.reconnect(server_id, wait=True)
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc
    service.core.tool_registry.refresh()
    return {
        "status": service.core.mcp.status(server_id),
        "tools": [
            item
            for item in service.core.tool_registry.metadata()
            if item.get("server_id") == server_id
        ],
    }


def delete_extension_mcp(
    server_id: str, service: ServiceDependency
) -> dict[str, Any]:
    def remove() -> dict[str, bool]:
        service.core.extensions.remove_mcp_server(server_id)
        return {"ok": True}

    return _mutate(service, remove, "mcp_removed", refresh_mcp=True)


def register_routes(router: APIRouter) -> None:
    routes = (
        ("/api/extensions", get_extensions, ["GET"]),
        ("/api/extensions/catalog", get_extension_catalog, ["GET"]),
        ("/api/extensions/catalog/trust", inspect_extension_plugin, ["GET"]),
        ("/api/extensions/marketplaces", add_extension_marketplace, ["POST"]),
        (
            "/api/extensions/marketplaces/{marketplace_id}/refresh",
            refresh_extension_marketplace,
            ["POST"],
        ),
        (
            "/api/extensions/marketplaces/{marketplace_id}",
            delete_extension_marketplace,
            ["DELETE"],
        ),
        ("/api/extensions/plugins/install", install_extension_plugin, ["POST"]),
        ("/api/extensions/plugins/enable", enable_extension_plugin, ["POST"]),
        ("/api/extensions/plugins/update", update_extension_plugin, ["POST"]),
        ("/api/extensions/plugins/rollback", rollback_extension_plugin, ["POST"]),
        (
            "/api/extensions/plugins/{plugin_id:path}",
            uninstall_extension_plugin,
            ["DELETE"],
        ),
        ("/api/extensions/skills/import", import_extension_skill, ["POST"]),
        ("/api/extensions/skills/enable", enable_extension_skill, ["POST"]),
        ("/api/extensions/skills/{skill_id:path}", remove_extension_skill, ["DELETE"]),
        ("/api/extensions/mcp", upsert_extension_mcp, ["POST"]),
        (
            "/api/extensions/mcp/presets/materialize",
            materialize_extension_mcp_preset,
            ["POST"],
        ),
        ("/api/extensions/mcp/enable", enable_extension_mcp, ["POST"]),
        (
            "/api/extensions/mcp/credentials",
            set_extension_mcp_credentials,
            ["POST"],
        ),
        ("/api/extensions/mcp/policy", set_extension_mcp_policy, ["POST"]),
        ("/api/extensions/mcp/test", test_extension_mcp, ["POST"]),
        ("/api/extensions/mcp/reconnect", reconnect_extension_mcp, ["POST"]),
        ("/api/extensions/mcp/{server_id:path}", delete_extension_mcp, ["DELETE"]),
    )
    for path, endpoint, methods in routes:
        router.add_api_route(path, endpoint, methods=methods)
