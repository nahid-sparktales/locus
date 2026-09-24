"""Extension marketplace, plugin, skill, and MCP routes."""

from collections.abc import Callable
from contextlib import AbstractContextManager
from typing import Annotated, Any, TypeVar
from uuid import uuid4

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
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
    def upsert() -> dict[str, Any]:
        server_id = str(body.get("id") or "")
        if server_id and not any(
            server.get("id") == server_id and server.get("origin") == "user"
            for server in service.core.extensions.mcp_servers()
        ):
            raise ExtensionError("standalone MCP server not found")
        return service.core.extensions.upsert_mcp_server(body, server_id=server_id)
    return _mutate(
        service,
        upsert,
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
            str(body["mode"]) if "mode" in body else None,
            tool_name=str(body.get("tool") or ""),
            resource_access=str(body["resource_access"]) if "resource_access" in body else None,
            enabled_resources=body.get("enabled_resources"),
            enabled_prompts=body.get("enabled_prompts"),
        ),
        "mcp_policy_changed",
        refresh_mcp=True,
    )


def get_extension_mcp_catalog(server_id: str, service: ServiceDependency) -> dict[str, Any]:
    """Management discovery does not grant any resource or prompt access."""
    try:
        return service.core.mcp.catalog(server_id)
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def _mcp_preview_item(service: ChatService, server_id: str, name: str, kind: str) -> dict[str, Any]:
    registry = service.core.tool_registry
    tool = "read_extension_resource" if kind == "resource" else "load_extension_prompt"
    if not capability_enabled("modern_mcp") or not registry._user_allows(tool):
        raise HTTPException(403, "MCP resources and prompts are disabled by capability settings")
    values = service.core.mcp.available_resources() if kind == "resource" \
        else service.core.mcp.available_prompts()
    key = "uri" if kind == "resource" else "name"
    item = next((item for item in values if item.get("server_id") == server_id
                 and item.get(key) == name), None)
    server = next((server for server in service.core.extensions.mcp_servers(service.core.cwd)
                   if server.get("id") == server_id), None)
    # Policy saves reconnect asynchronously. Recheck durable policy here so
    # a previously published catalog cannot outlive a revocation.
    server_allowed = bool(server and server.get("active", True) and server.get("enabled", True))
    if server_allowed and item is not None:
        if kind == "resource":
            allowed = set(server.get("enabled_resources") or [])
            mode = server.get("resource_access") or ("selected" if allowed else "all")
            server_allowed = mode == "all" or (mode == "selected" and bool(
                {item.get("uri"), item.get("name")} & allowed
            ))
        else:
            server_allowed = name in (server.get("enabled_prompts") or [])
    if not server_allowed:
        raise HTTPException(403, f"The MCP server policy does not allow this {kind}")
    if item is None or not registry._allows_mcp_item(
        item, "resources" if kind == "resource" else "prompts"
    ):
        raise HTTPException(403, f"The current agent profile does not allow this MCP {kind}")
    return item


def _mcp_arguments(body: dict[str, Any], field: str = "arguments") -> dict[str, Any]:
    value = body.get(field, {})
    if not isinstance(value, dict) or len(value) > 100 or any(
        not isinstance(key, str) or not key or len(key) > 500 for key in value
    ):
        raise HTTPException(422, f"{field} must be an object with at most 100 named values")
    return value


def _mcp_preview(service: ChatService, operation: Callable[[], T]) -> T:
    # Keep the selected agent and its permissions stable during a preview.
    try:
        with service.state_mutation():
            return operation()
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def read_extension_mcp_resource(
    service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    def read() -> dict[str, Any]:
        server_id, uri = str(body.get("id") or ""), str(body.get("uri") or "")
        _mcp_preview_item(service, server_id, uri, "resource")
        attachments: list[dict[str, Any]] = []
        content = service.core.mcp.read_resource(
            server_id, uri, arguments=_mcp_arguments(body), media_receiver=attachments.extend,
        )
        if content.startswith("Error:"):
            raise HTTPException(422, content)
        session_id = str(getattr(getattr(service.core, "session", None), "session_id", ""))
        references: list[dict[str, Any]] = []
        if attachments:
            from ..mcp_media import cache_media
            try:
                references = cache_media(session_id, uuid4().hex, attachments)
            except (OSError, ValueError):
                content += "\n\nImage previews could not be saved."
        return {"content": content, "attachments": references, "session_id": session_id}
    return _mcp_preview(service, read)


def load_extension_mcp_prompt(
    service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    def load() -> dict[str, Any]:
        server_id, name = str(body.get("id") or ""), str(body.get("prompt") or "")
        _mcp_preview_item(service, server_id, name, "prompt")
        session_id = str(getattr(getattr(service.core, "session", None), "session_id", ""))
        attachments: list[dict[str, Any]] = []
        content = service.core.mcp.load_prompt(
            server_id, name, _mcp_arguments(body), media_receiver=attachments.extend,
        )
        if content.startswith("Error:"):
            raise HTTPException(422, content)
        references: list[dict[str, Any]] = []
        if attachments:
            from ..mcp_media import cache_media
            try:
                references = cache_media(session_id, uuid4().hex, attachments)
            except (OSError, ValueError):
                content += "\n\nImage previews could not be saved."
        return {"content": content, "attachments": references, "session_id": session_id}
    return _mcp_preview(service, load)


def complete_extension_mcp_argument(
    service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    def complete() -> dict[str, Any]:
        kind = str(body.get("kind") or "")
        if kind not in {"resource", "prompt"}:
            raise HTTPException(422, "kind must be resource or prompt")
        server_id, name = str(body.get("id") or ""), str(body.get("name") or "")
        _mcp_preview_item(service, server_id, name, kind)
        argument, value = body.get("argument"), body.get("value", "")
        if not isinstance(argument, str) or not argument or len(argument) > 500 \
                or not isinstance(value, str) or len(value) > 8_192:
            raise HTTPException(422, "Completion requires a named argument and a text value")
        context = _mcp_arguments(body, "context_arguments")
        if any(not isinstance(value, str) or len(value) > 8_192 for value in context.values()):
            raise HTTPException(422, "context_arguments values must be strings")
        return service.core.mcp.complete(server_id, kind, name, argument, value, context)
    return _mcp_preview(service, complete)


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


def get_extension_plugin_settings(
    service: ServiceDependency, plugin_id: str = Query(..., max_length=300),
) -> dict[str, Any]:
    try:
        return service.core.extensions.plugin_settings(plugin_id)
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


def set_extension_plugin_settings(
    service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        return service.core.extensions.set_plugin_settings(
            str(body.get("plugin_id") or ""), body.get("values"),
            expected_revision=str(body.get("revision") or ""),
        )
    except ExtensionError as exc:
        status = 409 if "changed elsewhere" in str(exc) else 422
        raise HTTPException(status, str(exc)) from exc


def call_extension_plugin_panel_tool(
    service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Let a plugin's own window call its own MCP tools, and nothing else."""
    plugin_id, tool = str(body.get("plugin_id") or ""), str(body.get("tool") or "")
    arguments = _mcp_arguments(body)
    manager = service.core.extensions
    try:
        record = manager._plugin(plugin_id)
        panels = [item for item in manager._plugin_view(record).get("panels") or []
                  if "plugin.tools" in item["capabilities"]]
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc
    if not panels:
        raise HTTPException(403, "this plugin has no window that may call its tools")
    servers = [
        server for server in manager.mcp_servers(service.core.cwd)
        if server.get("origin") == "plugin" and server.get("plugin_id") == record.get("id")
        and server.get("active", True) and server.get("enabled", True)
    ]
    if not servers:
        raise HTTPException(409, "the plugin is not enabled for this project")
    for server in servers:
        content = service.core.mcp.call_tool(str(server["id"]), tool, arguments)
        if not content.startswith("Error: MCP tool is no longer available"):
            return {"content": content, "is_error": content.startswith("Error:")}
    raise HTTPException(404, f"the plugin has no tool named {tool}")


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
        ("/api/extensions/plugins/settings", get_extension_plugin_settings, ["GET"]),
        ("/api/extensions/plugins/settings", set_extension_plugin_settings, ["POST"]),
        ("/api/extensions/plugins/panel-tool", call_extension_plugin_panel_tool, ["POST"]),
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
        ("/api/extensions/mcp/{server_id:path}/catalog", get_extension_mcp_catalog, ["GET"]),
        ("/api/extensions/mcp/resource", read_extension_mcp_resource, ["POST"]),
        ("/api/extensions/mcp/prompt", load_extension_mcp_prompt, ["POST"]),
        ("/api/extensions/mcp/complete", complete_extension_mcp_argument, ["POST"]),
        ("/api/extensions/mcp/test", test_extension_mcp, ["POST"]),
        ("/api/extensions/mcp/reconnect", reconnect_extension_mcp, ["POST"]),
        ("/api/extensions/mcp/{server_id:path}", delete_extension_mcp, ["DELETE"]),
    )
    for path, endpoint, methods in routes:
        router.add_api_route(path, endpoint, methods=methods)
