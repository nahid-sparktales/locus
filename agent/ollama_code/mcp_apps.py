"""MCP Apps resources and per-view authority for the native, sandboxed host."""
from __future__ import annotations

import base64
import hashlib
import json
import time
import uuid
from typing import Any

from .capabilities import enabled as capability_enabled
from .extensions import ExtensionError

MIME = "text/html;profile=mcp-app"
MAX_HTML = 2 * 1024 * 1024


def ui_metadata(value: Any) -> dict[str, Any]:
    meta = getattr(value, "meta", None) or getattr(value, "_meta", None) or {}
    if not isinstance(meta, dict):
        return {}
    ui = meta.get("ui") if isinstance(meta.get("ui"), dict) else {}
    uri = ui.get("resourceUri") or meta.get("openai/outputTemplate") or meta.get("ui/resourceUri")
    visibility = ui.get("visibility", ["model", "app"])
    visibility = [item for item in visibility if isinstance(item, str) and item in {"model", "app"}] if isinstance(visibility, list) else []
    return {"resource_uri": uri if isinstance(uri, str) and uri.startswith("ui://") and len(uri) < 2048 else None,
            "visibility": visibility}


def resource_payload(result: Any, uri: str) -> dict[str, Any]:
    for item in result.contents:
        if str(item.uri) != uri or item.mime_type not in {MIME, "text/html+skybridge"}:
            continue
        html = getattr(item, "text", None)
        if html is None:
            try:
                html = base64.b64decode(item.blob, validate=True).decode("utf-8")
            except (ValueError, UnicodeError) as exc:
                raise ExtensionError("Invalid MCP app HTML") from exc
        if not isinstance(html, str) or len(html.encode()) > MAX_HTML:
            raise ExtensionError("MCP app HTML exceeds the 2 MiB limit")
        meta = getattr(item, "meta", None) or {}
        meta = meta if isinstance(meta, dict) else {}
        ui = meta.get("ui") if isinstance(meta.get("ui"), dict) else {}
        return {"html": html, "csp": ui["csp"] if isinstance(ui.get("csp"), dict) else {}, "resource_uri": uri}
    raise ExtensionError("The server did not return a supported MCP app resource")


def _context(core: Any) -> str:
    policy = core.tool_registry.mcp_agent_policy_snapshot()
    return hashlib.sha256(json.dumps([str(core.cwd), core.session.session_id, core.agent_mode, policy], sort_keys=True).encode()).hexdigest()


def allowed_tool(core: Any, server_id: str, name: str, *, app: bool = True) -> dict[str, Any]:
    if not capability_enabled("modern_mcp") or not core.tool_registry._user_allows("search_extension_tools"):
        raise ExtensionError("MCP is disabled in capability settings")
    servers = core.extensions.mcp_servers(core.cwd)
    server = next((s for s in servers if s["id"] == server_id and s.get("active", True) and s.get("enabled", True)), None)
    if not server:
        raise ExtensionError("This connection is disabled for the current project")
    tools = core.mcp.catalog(server_id).get("tools", [])
    tool = next((t for t in tools if t["name"] == name), None)
    if not tool or not tool.get("enabled") or tool.get("panel_only"):
        raise ExtensionError("This tool is unavailable or disabled")
    if app and "app" not in tool.get("ui", {}).get("visibility", ["model", "app"]):
        raise ExtensionError("This tool is not available to interactive apps")
    # Recheck durable server policy: async reconnect may leave an old catalog.
    permitted = server.get("enabled_tools") or []
    policies = server.get("tool_policies") or {}
    policy = policies.get(name) or server.get("approval_mode")
    if isinstance(policy, dict):
        policy = policy.get("approval_mode")
    if (permitted and name not in permitted) or name in (server.get("disabled_tools") or []) or policy == "disabled":
        raise ExtensionError("Tool access has been revoked")
    _, ceiling, role = core.tool_registry.mcp_agent_policy_snapshot()
    annotations = tool.get("annotations") or {}
    if (core.agent_mode in {"plan", "grill"} or ceiling == "read_only" or role in {"dispatcher", "reviewer"}) and (
        annotations.get("readOnlyHint") is not True or annotations.get("destructiveHint") is True
    ):
        raise ExtensionError("This agent currently has read-only access")
    qualified = next((key for key, t in core.tool_registry._mcp_by_qualified.items()
                      if t["server_id"] == server_id and t["name"] == name), name)
    if not core.tool_registry._allows_mcp_item(tool, "tools", qualified=qualified) or not core.tool_registry._user_allows(qualified):
        raise ExtensionError("The current agent does not have access to this tool")
    return tool


def open_app(core: Any, server_id: str, name: str, call_id: str = "") -> dict[str, Any]:
    tool = allowed_tool(core, server_id, name, app=False)
    uri = (tool.get("ui") or {}).get("resource_uri")
    if not uri:
        raise ExtensionError("This tool has no interactive app")
    payload = core.mcp.app_resource(server_id, uri)
    views = getattr(core, "_mcp_app_views", {})
    views = {key: value for key, value in views.items() if time.monotonic() - value["created"] < 3600}
    if len(views) >= 32:
        views.pop(next(iter(views)))
    identifier = uuid.uuid4().hex
    views[identifier] = {"server_id": server_id, "tool": name, "context": _context(core),
                         "created": time.monotonic(), "resource_uri": uri, "schema_digest": tool.get("schema_digest"),
                         "server_fingerprint": tool.get("server_fingerprint")}
    core._mcp_app_views = views
    output = core.mcp.app_result(server_id, name, call_id)
    if output.get("session_id") != core.session.session_id:
        output = {}
    return {**payload, "id": identifier, "server_id": server_id, "tool": name,
            "title": tool.get("title") or name, "input": output.get("input", {}), "result": output.get("result", {"content": []})}


def call_app(core: Any, view_id: str, name: str, arguments: dict[str, Any], confirmed: bool) -> dict[str, Any]:
    view = getattr(core, "_mcp_app_views", {}).get(view_id)
    if not view or time.monotonic() - view["created"] > 3600 or view["context"] != _context(core):
        raise ExtensionError("This app view expired or its agent changed. Reopen it from the conversation.")
    source = allowed_tool(core, view["server_id"], view["tool"], app=False)
    if (source.get("schema_digest") != view["schema_digest"]
            or source.get("server_fingerprint") != view["server_fingerprint"]
            or source.get("ui", {}).get("resource_uri") != view["resource_uri"]):
        raise ExtensionError("The app changed. Reopen it to review the new version.")
    tool = allowed_tool(core, view["server_id"], name)
    if not confirmed:
        raise ExtensionError("An interactive tool call requires native confirmation")
    if len(json.dumps(arguments).encode()) > 256 * 1024:
        raise ExtensionError("App arguments are too large")
    from jsonschema import validate
    # A server-provided schema must not cause the validator to fetch external URLs.
    def local_refs(value: Any) -> None:
        if isinstance(value, dict):
            if any(key in value and (not isinstance(value[key], str) or not value[key].startswith("#"))
                   for key in ("$ref", "$dynamicRef", "$recursiveRef")):
                raise ExtensionError("App tool schemas must use local references")
            for child in value.values():
                local_refs(child)
        elif isinstance(value, list):
            for child in value:
                local_refs(child)
    local_refs(tool["input_schema"])
    validate(arguments, tool["input_schema"])
    call_id = uuid.uuid4().hex
    content = core.mcp.call_tool(view["server_id"], name, arguments,
                                 invocation_context={"call_id": call_id, "session_id": core.session.session_id})
    output = core.mcp.app_result(view["server_id"], name, call_id)
    return output.get("result") or {"content": [{"type": "text", "text": content}], "isError": content.startswith("Error:")}
