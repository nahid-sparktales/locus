import json
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from ollama_code.extensions import ExtensionError
from ollama_code.jira_bridge import jira_action
from ollama_code.mcp_runtime import MCPManager


def core_with(result='{"issues": [], "isLast": true}', **changes):
    server = {"id": "jira", "url": "https://mcp.atlassian.com/v2/mcp?tools=all",
              "active": True, "enabled": True, **changes}
    return SimpleNamespace(extensions=SimpleNamespace(mcp_servers=Mock(return_value=[server])),
                           mcp=SimpleNamespace(call_tool=Mock(return_value=result)))


def request(operation="search", **arguments):
    defaults = {"cloudId": "site", "jql": "project = APP"} if operation == "search" else {}
    return {"server_id": "jira", "workspace": "/project", "operation": operation,
            "arguments": {**defaults, **arguments}}


def test_search_uses_exact_workspace_bounded_page_and_no_chat_identity():
    core = core_with()
    assert jira_action(core, request(maxResults=500)) == {"data": {"issues": [], "isLast": True}}
    core.extensions.mcp_servers.assert_called_once_with("/project")
    args, kwargs = core.mcp.call_tool.call_args
    assert args == ("jira", "searchJiraIssuesUsingJql", {"cloudId": "site", "jql": "project = APP", "maxResults": 10})
    assert all(value == "" for value in kwargs["invocation_context"].values())
    assert kwargs["output_limit"] == 1_000_000


@pytest.mark.parametrize("changes", [
    {"enabled": False}, {"active": False},
    {"url": "https://mcp.atlassian.com.evil.test/v2/mcp"},
    {"url": "https://mcp.atlassian.com@evil.test/v2/mcp"},
    {"url": "http://mcp.atlassian.com/v2/mcp"},
    {"url": "https://mcp.atlassian.com:444/v2/mcp"},
    {"disabled_tools": ["searchJiraIssuesUsingJql"]},
    {"enabled_tools": ["getJiraIssue"]},
    {"tool_policies": {"searchJiraIssuesUsingJql": {"approval_mode": "disabled"}}},
])
def test_rejects_wrong_connection_and_disabled_actions(changes):
    core = core_with(**changes)
    with pytest.raises(ExtensionError):
        jira_action(core, request())
    core.mcp.call_tool.assert_not_called()


@pytest.mark.parametrize("body", [
    request("delete"), request("update", cloudId="site", issueIdOrKey="APP-1", fields={"assignee": "other"}),
    request("transition", cloudId="site", issueIdOrKey="APP-1", transition={"id": "3", "other": "x"}),
    request(jql=""), request(url="https://evil.test"),
])
def test_endpoint_is_not_an_arbitrary_tool_proxy(body):
    core = core_with()
    with pytest.raises(ExtensionError):
        jira_action(core, body)
    core.mcp.call_tool.assert_not_called()


def test_structured_results_take_precedence_over_narrative():
    core = core_with('Some text\n\nStructured result:\n{"issues": [], "isLast": true}')
    assert jira_action(core, request())["data"]["issues"] == []


@pytest.mark.parametrize("result", ['Error: uncertain remote write', '{"errors": {"summary": "invalid"}}', '{"errorMessages": ["Forbidden"]}'])
def test_write_errors_surface_without_retry(result):
    core = core_with(result)
    with pytest.raises(ExtensionError):
        jira_action(core, request("update", cloudId="site", issueIdOrKey="APP-1", fields={"summary": "New"}))
    core.mcp.call_tool.assert_called_once()


def test_truncated_read_is_not_treated_as_empty_success():
    core = core_with('{"issues": [')
    with pytest.raises(ExtensionError, match="unreadable"):
        jira_action(core, request())


def test_native_result_budget_preserves_documents_without_expanding_agent_context():
    result = SimpleNamespace(content=[], structured_content={"description": "x" * 40_000}, is_error=False)
    default = MCPManager._format_result(result)
    native = MCPManager._format_result(result, output_limit=1_000_000)
    assert len(default) < len(native)
    assert len(json.loads(native.split("Structured result:\n")[1])["description"]) == 40_000
