from __future__ import annotations

from ollama_code.capabilities import CAPABILITY_ENV, enabled, snapshot
from ollama_code.extensions import ExtensionManager
from ollama_code.tool_registry import ToolRegistry


def test_capability_flags_are_independent_and_default_on(monkeypatch):
    for variable in CAPABILITY_ENV.values():
        monkeypatch.delenv(variable, raising=False)
    assert all(snapshot().values())

    monkeypatch.setenv(CAPABILITY_ENV["evaluations"], "off")
    assert enabled("evaluations") is False
    assert enabled("durable_runs") is True
    assert enabled("unknown") is False


def test_disabled_capabilities_remove_model_tools(tmp_path, monkeypatch):
    monkeypatch.setenv(CAPABILITY_ENV["workspace_knowledge"], "0")
    monkeypatch.setenv(CAPABILITY_ENV["modern_mcp"], "false")
    registry = ToolRegistry(ExtensionManager(str(tmp_path), root=tmp_path / "extensions"))
    names = {item["function"]["name"] for item in registry.schemas()}

    assert "search_workspace_knowledge" not in names
    assert "search_extension_resources" not in names
    assert "load_extension_prompt" not in names
    assert "search_extension_tools" in names
