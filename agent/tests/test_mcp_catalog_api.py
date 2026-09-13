"""Settings catalog access shares the selected agent's resource/prompt permissions."""
from __future__ import annotations

from contextlib import nullcontext
from types import SimpleNamespace

import pytest
from fastapi import APIRouter, FastAPI
from fastapi.testclient import TestClient

from ollama_code.api.extensions import register_routes
from ollama_code.extensions import ExtensionManager


@pytest.fixture
def catalog_client(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCUS_CAPABILITY_MODERN_MCP", "1")
    extensions = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    server = extensions.upsert_mcp_server({"name": "catalog", "command": "mcp", "enabled_prompts": ["review"]})
    resource = {"server_id": server["id"], "name": "document", "uri": "docs://{name}", "template": True}
    prompt = {"server_id": server["id"], "name": "review", "arguments": [{"name": "topic"}]}
    state = SimpleNamespace(allowed=True, calls=[], resources=[resource], prompts=[prompt], images=[],
                            content="untrusted preview", completions={"values": ["readme"], "has_more": False})

    def read(server_id, uri, **kwargs):
        state.calls.append(("read", server_id, uri, kwargs["arguments"]))
        kwargs["media_receiver"](state.images)
        return state.content

    def load(server_id, name, arguments, **kwargs):
        state.calls.append(("prompt", server_id, name, arguments))
        kwargs["media_receiver"](state.images)
        return state.content

    def complete(*args):
        state.calls.append(("complete", *args))
        return state.completions

    runtime = SimpleNamespace(
        catalog=lambda server_id: {"server_id": server_id, "resources": [], "templates": [resource], "prompts": [prompt]},
        available_resources=lambda: state.resources,
        available_prompts=lambda: state.prompts,
        read_resource=read, load_prompt=load, complete=complete, refresh=lambda **kwargs: None,
    )
    registry = SimpleNamespace(_user_allows=lambda name: True,
                               _allows_mcp_item=lambda item, category: state.allowed,
                               refresh=lambda: None)
    service = SimpleNamespace(core=SimpleNamespace(mcp=runtime, tool_registry=registry,
                                                   session=SimpleNamespace(session_id="preview-session"),
                                                   extensions=extensions, cwd=str(tmp_path)),
                              state_mutation=nullcontext, queue_event=lambda event: None)
    app = FastAPI()
    app.state.service = service
    router = APIRouter()
    register_routes(router)
    app.include_router(router)
    with TestClient(app) as client:
        yield client, server["id"], state, service


def test_catalog_discovery_does_not_grant_permission(catalog_client):
    client, server_id, state, service = catalog_client
    state.allowed = False
    before = service.core.extensions.mcp_servers()
    response = client.get(f"/api/extensions/mcp/{server_id}/catalog")
    assert response.status_code == 200
    assert response.json()["templates"][0]["uri"] == "docs://{name}"
    assert response.json()["prompts"][0]["name"] == "review"
    assert service.core.extensions.mcp_servers() == before
    assert state.calls == []


@pytest.mark.parametrize("path,body", [
    ("resource", {"uri": "docs://{name}", "arguments": {"name": "readme"}}),
    ("prompt", {"prompt": "review", "arguments": {"topic": "readme"}}),
    ("complete", {"kind": "resource", "name": "docs://{name}", "argument": "name", "value": "read"}),
    ("complete", {"kind": "prompt", "name": "review", "argument": "topic", "value": "read"}),
])
def test_preview_and_completion_require_agent_permission(catalog_client, path, body):
    client, server_id, state, _ = catalog_client
    state.allowed = False
    response = client.post(f"/api/extensions/mcp/{path}", json={"id": server_id, **body})
    assert response.status_code == 403
    assert "profile" in response.json()["detail"]
    assert state.calls == []


def test_preview_cannot_use_unallowed_catalog_identity(catalog_client):
    client, server_id, state, _ = catalog_client
    state.resources = []
    response = client.post("/api/extensions/mcp/resource", json={"id": server_id, "uri": "docs://{name}"})
    assert response.status_code == 403 and state.calls == []


def test_resource_preview_forwards_template_arguments(catalog_client):
    client, server_id, state, _ = catalog_client
    response = client.post("/api/extensions/mcp/resource", json={
        "id": server_id, "uri": "docs://{name}", "arguments": {"name": "read me", "path": ["a", "b"]},
    })
    assert response.status_code == 200
    assert response.json()["content"] == "untrusted preview"
    assert response.json()["attachments"] == []
    assert state.calls == [("read", server_id, "docs://{name}", {"name": "read me", "path": ["a", "b"]})]


def test_prompt_and_completion_forward_arguments(catalog_client):
    client, server_id, state, _ = catalog_client
    response = client.post("/api/extensions/mcp/prompt", json={
        "id": server_id, "prompt": "review", "arguments": {"topic": "code"},
    })
    assert response.json() == {"content": "untrusted preview", "attachments": [], "session_id": "preview-session"}
    response = client.post("/api/extensions/mcp/complete", json={
        "id": server_id, "kind": "prompt", "name": "review", "argument": "topic", "value": "co",
        "context_arguments": {"language": "python"},
    })
    assert response.json() == {"values": ["readme"], "has_more": False}
    assert state.calls[-1] == ("complete", server_id, "prompt", "review", "topic", "co", {"language": "python"})


@pytest.mark.parametrize("kind,identity", [("resource", {"uri": "docs://{name}"}), ("prompt", {"prompt": "review"})])
def test_preview_returns_cached_media_references(catalog_client, monkeypatch, kind, identity):
    client, server_id, state, _ = catalog_client
    state.images = [{"data": "private-base64-image", "mime_type": "image/png"}]
    seen = {}
    def cache(session_id, invocation_id, images):
        seen.update(session_id=session_id, invocation_id=invocation_id, images=images)
        return [{"id": "image-ref", "name": "preview.png", "mime_type": "image/png", "size": 64}]
    monkeypatch.setattr("ollama_code.mcp_media.cache_media", cache)
    response = client.post(f"/api/extensions/mcp/{kind}", json={"id": server_id, **identity})
    assert response.status_code == 200
    assert response.json()["session_id"] == "preview-session"
    assert response.json()["attachments"][0]["id"] == "image-ref"
    assert "private-base64-image" not in response.text
    assert seen["session_id"] == "preview-session" and len(seen["invocation_id"]) == 32


@pytest.mark.parametrize("body", [
    {"kind": "tools", "name": "read"},
    {"kind": "prompt", "name": "review", "argument": "topic", "value": []},
    {"kind": "prompt", "name": "review", "argument": "topic", "context_arguments": {"language": 42}},
])
def test_malformed_completion_does_not_reach_server(catalog_client, body):
    client, server_id, state, _ = catalog_client
    response = client.post("/api/extensions/mcp/complete", json={"id": server_id, **body})
    assert response.status_code == 422 and state.calls == []


def test_runtime_preview_failure_is_an_http_error(catalog_client):
    client, server_id, state, _ = catalog_client
    state.content = "Error: Missing template argument name"
    response = client.post("/api/extensions/mcp/resource", json={"id": server_id, "uri": "docs://{name}"})
    assert response.status_code == 422 and "Missing" in response.json()["detail"]


def test_policy_endpoint_preserves_tool_default_and_saves_empty_selection(catalog_client):
    client, server_id, _, service = catalog_client
    service.core.extensions.set_mcp_policy(server_id, "ask")
    response = client.post("/api/extensions/mcp/policy", json={
        "id": server_id, "resource_access": "selected", "enabled_resources": [], "enabled_prompts": ["review"],
    })
    assert response.status_code == 200
    assert response.json()["approval_mode"] == "ask"
    assert response.json()["resource_access"] == "selected"
    assert response.json()["enabled_resources"] == []
    assert response.json()["enabled_prompts"] == ["review"]


def test_capability_toggle_applies_to_manual_preview(catalog_client, monkeypatch):
    client, server_id, state, _ = catalog_client
    monkeypatch.setenv("LOCUS_CAPABILITY_MODERN_MCP", "0")
    response = client.post("/api/extensions/mcp/resource", json={"id": server_id, "uri": "docs://{name}"})
    assert response.status_code == 403 and state.calls == []


def test_policy_revocation_takes_effect_before_runtime_catalog_refresh(catalog_client):
    client, server_id, state, service = catalog_client
    service.core.extensions.set_mcp_policy(server_id, resource_access="selected", enabled_resources=[], enabled_prompts=[])
    # The runtime intentionally still publishes the old permitted catalog.
    assert state.resources and state.prompts
    resource = client.post("/api/extensions/mcp/resource", json={"id": server_id, "uri": "docs://{name}"})
    prompt = client.post("/api/extensions/mcp/prompt", json={"id": server_id, "prompt": "review"})
    completion = client.post("/api/extensions/mcp/complete", json={
        "id": server_id, "kind": "prompt", "name": "review", "argument": "topic", "value": "test",
    })
    assert resource.status_code == prompt.status_code == completion.status_code == 403
    assert state.calls == []
