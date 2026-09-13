"""MCP transport compatibility, durable policy, and explicit local OAuth consent."""
from __future__ import annotations

import json

import pytest

from ollama_code.extensions import (
    ExtensionError,
    ExtensionManager,
    _normalize_mcp_config,
    discover_oauth_metadata,
)


@pytest.mark.parametrize("field,transport,expected", [
    ("transport", "streamable_http", "streamable_http"),
    ("transport", "streamable-http", "streamable_http"),
    ("type", "http", "streamable_http"),
    ("type", "sse", "sse"),
    ("transport", "sse", "sse"),
])
def test_explicit_http_transport_aliases(field, transport, expected):
    config = _normalize_mcp_config({"url": "http://127.0.0.1:35792/mcp", field: transport})
    assert config["transport"] == expected
    assert config["protocol_mode"] == "auto"
    assert config["share_workspace_root"] is False


@pytest.mark.parametrize("config", [
    {"url": "https://example.com/mcp", "transport": "stdio"},
    {"command": "mcp", "transport": "sse"},
    {"url": "https://example.com/mcp", "transport": "websocket"},
    {"command": "mcp", "protocol_mode": "invalid"},
    {"command": "mcp", "share_workspace_root": "true"},
    {"command": "mcp", "resource_access": "invalid"},
    {"command": "mcp", "enabled_resources": "all"},
    {"command": "mcp", "enabled_prompts": [42]},
])
def test_invalid_compatibility_configuration_is_rejected(config):
    with pytest.raises(ExtensionError):
        _normalize_mcp_config(config)


def test_partial_edits_preserve_advanced_configuration_scope_and_credentials(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    saved = manager.upsert_mcp_server({
        "name": "Macuse", "url": "http://127.0.0.1:35792/mcp", "transport": "sse",
        "protocol_mode": "legacy", "share_workspace_root": True,
        "startup_timeout_sec": 45, "tool_timeout_sec": 90,
        "env_vars": ["MACUSE_HINT"], "env_http_headers": {"X-Env": "MACUSE_HEADER"},
        "enabled_global": False, "enabled_workspaces": [str(tmp_path)],
        "disabled_workspaces": [str(tmp_path / "other")], "enabled": False,
        "resource_access": "selected", "enabled_resources": ["docs://{name}"],
        "enabled_prompts": ["review"], "auth": "bearer",
    })
    manager.set_credentials(saved["id"], {"access_token": "test-secret"})
    updated = manager.upsert_mcp_server({"name": "Renamed"}, server_id=saved["id"])
    for key in ("transport", "protocol_mode", "share_workspace_root", "startup_timeout_sec",
                "tool_timeout_sec", "env_vars", "env_http_headers", "enabled_global",
                "enabled_workspaces", "disabled_workspaces", "enabled", "resource_access",
                "enabled_resources", "enabled_prompts"):
        assert updated[key] == saved[key]
    assert manager.credentials(saved["id"])["access_token"] == "test-secret"
    manager.upsert_mcp_server({"url": "http://127.0.0.1:35793/mcp"}, server_id=saved["id"])
    assert manager.credentials(saved["id"]) == {}


def test_header_aliases_are_transient_and_merge_without_case_duplicates(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    saved = manager.upsert_mcp_server({
        "name": "headers", "url": "https://example.com/mcp",
        "headers": {"authorization": "Bearer initial-secret", "X-Token": "header-secret"},
    })
    manager.upsert_mcp_server({"http_headers": {"Authorization": "Bearer updated-secret"}}, saved["id"])
    assert manager.credentials(saved["id"])["headers"] == {
        "Authorization": "Bearer updated-secret", "X-Token": "header-secret",
    }
    persisted = json.dumps(manager._state)
    assert "initial-secret" not in persisted and "updated-secret" not in persisted
    assert "header-secret" not in persisted


def test_resource_policy_overrides_do_not_change_tool_policy_or_empty_semantics(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    saved = manager.upsert_mcp_server({
        "name": "catalog", "command": "mcp", "approval_mode": "ask",
        "enabled_resources": ["docs://one"], "enabled_prompts": ["review"],
    })
    selected = manager.set_mcp_policy(saved["id"], resource_access="selected", enabled_resources=[])
    assert selected["resource_access"] == "selected" and selected["enabled_resources"] == []
    assert selected["approval_mode"] == "ask" and selected["enabled_prompts"] == ["review"]
    manager.set_mcp_policy(saved["id"], "allow", tool_name="read")
    none = manager.set_mcp_policy(saved["id"], resource_access="none", enabled_prompts=[])
    assert none["tool_policies"]["read"] == "allow"
    assert none["enabled_prompts"] == [] and none["resource_access"] == "none"
    restarted = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    assert restarted.mcp_servers()[0]["resource_access"] == "none"


def _local_oauth():
    return {
        "name": "Macuse", "url": "http://127.0.0.1:35792/mcp", "auth": "oauth",
        "oauth": {"issuer": "http://127.0.0.1:35792", "client_id": "locus",
                  "authorization_endpoint": "http://127.0.0.1:35792/authorize",
                  "token_endpoint": "http://127.0.0.1:35792/token", "allow_loopback_http": True},
    }


def test_loopback_oauth_requires_explicit_user_consent_and_same_origin():
    raw = _local_oauth()
    assert _normalize_mcp_config(raw, allow_loopback_oauth=True)["oauth"]["allow_loopback_http"]
    with pytest.raises(ExtensionError, match="issuer"):
        _normalize_mcp_config(raw)  # Plugin configuration cannot grant this exception.
    raw["oauth"]["allow_loopback_http"] = False
    with pytest.raises(ExtensionError, match="issuer"):
        _normalize_mcp_config(raw, allow_loopback_oauth=True)


@pytest.mark.parametrize("url", ["https://example.com/mcp", "http://127.0.0.1:0/mcp", "http://127.0.0.1:35792/mcp#fragment"])
def test_loopback_oauth_opt_in_requires_local_target_even_for_auto_auth(url):
    with pytest.raises(ExtensionError):
        _normalize_mcp_config({"url": url, "auth": "auto", "oauth": {"allow_loopback_http": True}}, allow_loopback_oauth=True)


@pytest.mark.parametrize("endpoint", [
    "http://127.0.0.1:35793/token", "http://localhost:35792/token",
    "https://auth.example/token", "http://remote.example:35792/token",
    "http://user:password@127.0.0.1:35792/token",
])
def test_loopback_oauth_cannot_redirect_credentials_to_another_origin(endpoint):
    raw = _local_oauth()
    raw["oauth"]["token_endpoint"] = endpoint
    with pytest.raises(ExtensionError, match="token_endpoint"):
        _normalize_mcp_config(raw, allow_loopback_oauth=True)


def test_local_oauth_discovery_bypasses_environment_proxies(monkeypatch):
    seen = {}
    class Session:
        trust_env = True
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass
        def get(self, url, **kwargs):
            seen.update(url=url, trust_env=self.trust_env, **kwargs)
            class Response:
                status_code = 200
                content = b"{}"
                def json(self):
                    return _local_oauth()["oauth"]
            return Response()
    monkeypatch.setattr("ollama_code.extensions.requests.Session", Session)
    result = discover_oauth_metadata(_local_oauth(), allow_loopback_oauth=True)
    assert result["oauth"]["token_endpoint"].endswith("/token")
    assert seen["trust_env"] is False and seen["allow_redirects"] is False


def test_editing_oauth_server_without_changing_oauth_does_not_require_network(tmp_path, monkeypatch):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    raw = _local_oauth()
    monkeypatch.setattr("ollama_code.extensions.discover_oauth_metadata", lambda raw, **kwargs: raw)
    saved = manager.upsert_mcp_server(raw)
    manager.set_credentials(saved["id"], {"access_token": "saved-token"})
    def unexpected(*args, **kwargs):
        raise AssertionError("unchanged OAuth settings should not trigger network discovery")
    monkeypatch.setattr("ollama_code.extensions.discover_oauth_metadata", unexpected)
    manager.upsert_mcp_server({"name": "Renamed"}, saved["id"])
    assert manager.credentials(saved["id"])["access_token"] == "saved-token"
