from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from ollama_code.api.event_triggers import trigger_create
from ollama_code.api.schedules import schedule_create
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


def test_disabled_workflow_capability_rejects_new_workflow_payloads(monkeypatch):
    monkeypatch.setenv(CAPABILITY_ENV["automation_workflows_v1"], "false")
    service = SimpleNamespace()
    with pytest.raises(HTTPException, match="automation_workflows_v1"):
        schedule_create(service, {"workflow": {"version": 1}})
    with pytest.raises(HTTPException, match="automation_workflows_v1"):
        trigger_create(service, {"runner": "team"})
