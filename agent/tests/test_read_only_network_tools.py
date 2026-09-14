"""A saved read-only agent can fetch evidence without gaining write authority."""
from __future__ import annotations

import pytest

from ollama_code.agent_profile_runtime import parse_solo_profile, solo_profile_boundary
from ollama_code.core import AgentCore, ToolCall


@pytest.mark.parametrize("network", [True, False])
def test_read_only_profile_network_inventory_and_dispatch(tmp_path, monkeypatch, network):
    from ollama_code import tool_registry

    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    core.tool_registry.browser_enabled = True
    profile = parse_solo_profile({
        "id": "weather-reader", "name": "Weather reader", "model": "fixture",
        "role": "generalist", "access_ceiling": "read_only",
        "behavior": {"capability_policy": {"network": network}},
    }, "fixture")
    executed = []
    monkeypatch.setattr(tool_registry, "execute_tool", lambda name, args, ctx:
                        executed.append((name, args)) or "Temperature: 21 C")
    with solo_profile_boundary(core, profile) as configuration:
        core.configure_agent(configuration, mode="work")
        names = {item["function"]["name"] for item in core.tool_registry.schemas()}
        assert ("web_fetch" in names) is network
        assert not names.intersection({"write_file", "edit_file", "apply_patch", "bash"})
        assert not core.tool_registry.is_safe("web_fetch")
        assert not core.tool_registry.browser_tool_allowed("browser_navigate")
        result = core.tool_registry.execute("web_fetch", {"url": "https://weather.example/current"}, core.tool_ctx)
        assert bool(executed) is network
        assert result == ("Temperature: 21 C" if network else
                          "Error: this tool is disabled by the agent's capability settings.")
        writes_before = len(executed)
        assert "disabled" in core.tool_registry.execute("write_file", {}, core.tool_ctx)
        assert len(executed) == writes_before


@pytest.mark.parametrize("decision", ["deny", "once"])
def test_read_only_fetch_keeps_normal_permission_decision(tmp_path, monkeypatch, decision):
    from ollama_code import core as core_module

    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture", "permission_mode": "ask"})
    core.mcp.close()
    core.tool_registry.set_mcp_agent_policy({}, access_ceiling="read_only", role="generalist")
    executed, approvals = [], []
    monkeypatch.setattr(core_module, "execute_tool", lambda *args: executed.append(args) or "Temperature: 21 C")

    def decide(*args):
        approvals.append(args)
        return decision

    result = core._run_tool_call(ToolCall(name="web_fetch", arguments={"url": "https://weather.example/current"}), decide)
    assert len(approvals) == 1 and approvals[0][0] == "web_fetch"
    assert bool(executed) is (decision == "once")
    assert result == ("Temperature: 21 C" if decision == "once" else
                      "Permission denied: the user did not allow running web_fetch. Do not retry the same call; ask the user or propose an alternative.")
