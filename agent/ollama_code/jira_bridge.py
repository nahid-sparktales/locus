"""Explicit native board actions through the user's official Atlassian connection."""

import json
from typing import Any
from urllib.parse import urlsplit

from .extensions import ExtensionError

TOOLS = {
    "sites": "getAccessibleAtlassianResources",
    "search": "searchJiraIssuesUsingJql",
    "issue": "getJiraIssue",
    "update": "editJiraIssue",
    "transitions": "listJiraIssueTransitions",
    "transition": "transitionJiraIssue",
}


def jira_action(core: Any, body: dict[str, Any]) -> dict[str, Any]:
    operation = str(body.get("operation") or "")
    if operation not in TOOLS:
        raise ExtensionError("Unsupported Jira board action")
    server_id = str(body.get("server_id") or "")
    server = next((item for item in core.extensions.mcp_servers(str(body.get("workspace") or ""))
                   if item.get("id") == server_id), None)
    if server is None or not server.get("enabled", True) or not server.get("active", True):
        raise ExtensionError("Connect and enable Atlassian before syncing Jira")
    url = urlsplit(str(server.get("url") or ""))
    if (url.scheme != "https" or url.hostname != "mcp.atlassian.com" or url.port not in (None, 443)
            or url.username or url.password or url.path not in ("/v2/mcp", "/v1/mcp", "/v1/mcp/authv2")):
        raise ExtensionError("Jira boards require the official Atlassian connection")
    tool_name = TOOLS[operation]
    policy = (server.get("tool_policies") or {}).get(tool_name) or server.get("approval_mode")
    if isinstance(policy, dict):
        policy = policy.get("approval_mode")
    enabled = server.get("enabled_tools") or []
    if (tool_name in (server.get("disabled_tools") or []) or str(policy).lower() == "disabled"
            or (enabled and tool_name not in enabled)):
        raise ExtensionError("This Jira action is disabled in connection settings")
    arguments = body.get("arguments")
    if not isinstance(arguments, dict) or len(json.dumps(arguments)) > 60_000:
        raise ExtensionError("Invalid Jira board arguments")
    allowed = {"cloudId"}
    if operation == "sites":
        allowed = set()
    elif operation == "search":
        allowed |= {"jql", "nextPageToken", "maxResults", "fields"}
    else:
        allowed |= {"issueIdOrKey"}
        if operation == "issue":
            allowed |= {"fields"}
        elif operation == "update":
            allowed |= {"fields"}
        elif operation == "transition":
            allowed |= {"transition"}
    if set(arguments) - allowed:
        raise ExtensionError("Unsupported Jira board arguments")
    if operation != "sites" and not isinstance(arguments.get("cloudId"), str):
        raise ExtensionError("Choose a Jira site")
    if operation not in ("sites", "search") and not isinstance(arguments.get("issueIdOrKey"), str):
        raise ExtensionError("Choose a Jira issue")
    if operation == "search":
        if not isinstance(arguments.get("jql"), str) or not arguments["jql"].strip():
            raise ExtensionError("Enter a Jira filter")
        arguments = {**arguments, "maxResults": 10}
    if operation == "update":
        fields = arguments.get("fields")
        if not isinstance(fields, dict) or not fields or set(fields) - {"summary", "description"}:
            raise ExtensionError("Only the issue title and description can be published from this board")
    if operation == "transition":
        transition = arguments.get("transition")
        if not isinstance(transition, dict) or set(transition) != {"id"} or not isinstance(transition["id"], str):
            raise ExtensionError("Choose an available Jira status")
    result = core.mcp.call_tool(server_id, TOOLS[operation], arguments,
                               invocation_context={"session_id": "", "run_id": "", "job_id": "", "tool_call_id": ""},
                               output_limit=1_000_000)
    if result.startswith("Error"):
        raise ExtensionError(result[:2000])
    # The shared MCP renderer preserves structuredContent after its text blocks.
    # Prefer that machine-readable result, with plain JSON as the v1 fallback.
    payload = result.rsplit("Structured result:\n", 1)[-1]
    try:
        data = json.loads(payload)
    except (ValueError, TypeError) as exc:
        # A write may return a plain acknowledgement; the native client always
        # reads the issue back before reporting success. Never retry a write.
        if operation in ("update", "transition"):
            return {"data": {"acknowledgement": result[:2000]}}
        raise ExtensionError("Atlassian returned an unreadable result. Reconnect and try again.") from exc
    if isinstance(data, dict) and (data.get("error") or data.get("errors") or data.get("errorMessages")):
        raise ExtensionError("Jira rejected this action: " + json.dumps(data, ensure_ascii=False)[:2000])
    return {"data": data}
