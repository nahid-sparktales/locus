"""Repeated agent route setup must retain discovery without retaining old grants."""
from __future__ import annotations

from types import SimpleNamespace

import pytest

from ollama_code.api.providers import _apply_provider
from ollama_code.core import AgentCore


def _remote(core, **changes):
    request = {
        "base_url": "https://fixture.example/v1",
        "api_key": "fixture-key", "model": "fixture:model", "auth_style": "bearer",
        "account_id": "fixture-account", "account_label": "Fixture", "lists_models": True,
        "context_window_tokens": 8192, "published_context_window": 16384,
        "reasoning_effort": "medium",
    }
    core.use_remote(**(request | changes))


def test_same_remote_route_retains_client_discovery_and_context(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={})
    _remote(core)
    client = core.client
    client._discovered = True
    core.context_limit = 8192
    core._trained_window_for = core.model

    _remote(core, base_url="https://fixture.example/v1/", api_key=None)

    assert core.client is client
    assert core.client._discovered is True
    assert core.context_limit == 8192
    assert core._trained_window_for == core.model
    core.close()


def test_repeated_remote_setup_does_not_repeat_metadata_requests(tmp_path, monkeypatch):
    core = AgentCore(cwd=str(tmp_path), config={})
    requests = []

    def models(url, **kwargs):
        requests.append(url)
        return SimpleNamespace(status_code=200, json=lambda: {
            "data": [{"id": "fixture:model", "context_length": 16384}],
        })

    monkeypatch.setattr("ollama_code.remote.requests.get", models)
    for _ in range(4):
        _remote(core)
        core.client.discover_windows()
    assert requests == ["https://fixture.example/v1/models"]
    core.close()


@pytest.mark.parametrize("changes", [
    {"base_url": "https://other.example/v1"},
    {"api_key": "replacement-key"},
    {"api_key": ""},
    {"model": "different:model"},
    {"auth_style": "anthropic"},
    {"account_id": "different-account"},
    {"account_label": "Updated name"},
    {"lists_models": False},
    {"context_window_tokens": 32768},
    {"published_context_window": 65536},
    {"reasoning_effort": "high"},
])
def test_changed_remote_setting_rebuilds_client(tmp_path, changes):
    core = AgentCore(cwd=str(tmp_path), config={})
    _remote(core)
    client = core.client
    _remote(core, **changes)
    assert core.client is not client
    if "api_key" in changes:
        assert core.client.api_key == changes["api_key"]
    core.close()


def test_same_remote_selection_still_validates_transport(tmp_path, monkeypatch):
    core = AgentCore(cwd=str(tmp_path), config={})
    _remote(core)
    client = core.client

    def reject(*args):
        raise ValueError("credential transport rejected")

    monkeypatch.setattr("ollama_code.core.validate_remote_url", reject)
    with pytest.raises(ValueError, match="credential transport rejected"):
        _remote(core)
    assert core.client is client
    core.close()


def test_remote_verify_still_checks_identical_route(tmp_path, monkeypatch):
    core = AgentCore(cwd=str(tmp_path), config={})
    core.use_remote("https://fixture.example/v1", api_key="fixture-key", model="fixture:model")
    client = core.client
    checked = []
    monkeypatch.setattr(client, "check", lambda: checked.append(True))
    service = SimpleNamespace(core=core, resolve_context_limit_soon=lambda: None)

    _apply_provider(service, {"provider": "remote", "base_url": "https://fixture.example/v1",
                              "api_key": "fixture-key", "model": "fixture:model", "verify": True})

    assert core.client is client
    assert checked == [True]
    core.close()


def test_same_ollama_selection_retains_client_and_learned_window(tmp_path, monkeypatch):
    core = AgentCore(cwd=str(tmp_path), model="fixture:model", config={})
    core.use_ollama("http://127.0.0.1:11434")
    client = core.client
    core.context_limit = 8192
    core._trained_window_for = core.model
    bypasses = []
    monkeypatch.setattr("ollama_code.core.proxy.ensure_no_proxy_host", bypasses.append)

    core.use_ollama("http://127.0.0.1:11434/")

    assert core.client is client
    assert core.context_limit == 8192
    assert core._trained_window_for == core.model
    assert bypasses == ["http://127.0.0.1:11434"]
    core.close()


@pytest.mark.parametrize("changes", [
    {"host": "http://127.0.0.1:11435"},
    {"context_window_tokens": 8192},
])
def test_changed_ollama_settings_invalidate_client(tmp_path, changes):
    core = AgentCore(cwd=str(tmp_path), model="fixture:model", config={})
    core.use_ollama("http://127.0.0.1:11434")
    client = core.client
    core.context_limit = 32768
    core.use_ollama(**changes)
    assert core.client is not client
    assert core.context_limit == 0
    core.close()
