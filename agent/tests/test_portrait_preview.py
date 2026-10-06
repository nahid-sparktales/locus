"""Profile previews reuse configured image clients without mutating agent work."""
from __future__ import annotations

import asyncio
import base64
import threading
import uuid

import pytest
from test_backend import FakeResponse
from test_image_generation import PNG, ProviderStub, _ok, _provider_config
from test_image_generation import client as client
from test_plugin_panel_disconnect import _exchange, _wait_for

from ollama_code.api import portrait_preview
from ollama_code.capabilities import CAPABILITY_ENV
from ollama_code.image_generation import ImageGenerationService, ImageProviderError
from ollama_code.tools import ToolContext


def body(**changes):
    return {"request_id": str(uuid.uuid4()), "account_id": "acct-1", "prompt": "A tiny sleepy purple robot", **changes}


def configured(client):
    service = client.app.state.service
    service.image_generation.configure(_provider_config())
    return service


def test_preview_returns_pixels_only_and_does_not_start_work(client, monkeypatch):
    service = configured(client)
    provider = ProviderStub(monkeypatch)
    messages = list(service.core.messages)
    response = client.post("/api/images/portrait", json=body())
    assert response.status_code == 200, response.text
    assert base64.b64decode(response.json()["png_base64"]) == PNG
    assert set(response.json()) == {"png_base64"}
    assert len(provider.calls) == 1
    request = provider.calls[0][1]["json"]
    assert request["size"] == "1024x1024" and request["n"] == 1
    assert "full-body" in request["prompt"]
    assert "transparent" in request["prompt"]
    assert service.core.messages == messages
    assert service.core.tool_ctx.image_generations_this_turn == 0
    assert service.core.tool_ctx.response_parts == {}


def test_missing_or_changed_account_never_calls_provider(client, monkeypatch):
    provider = ProviderStub(monkeypatch)
    assert client.post("/api/images/portrait", json=body()).status_code == 422
    configured(client)
    assert client.post("/api/images/portrait", json=body(account_id="different")).status_code == 422
    assert provider.calls == []


@pytest.mark.parametrize("description", ["", "x" * 2001, "bad\x00prompt", 123])
def test_invalid_prompt_never_calls_provider(client, monkeypatch, description):
    configured(client)
    provider = ProviderStub(monkeypatch)
    assert client.post("/api/images/portrait", json=body(prompt=description)).status_code == 422
    assert provider.calls == []


def test_unsupported_generation_remains_explicit(client, monkeypatch):
    configured(client)
    provider = ProviderStub(monkeypatch)
    monkeypatch.setenv(CAPABILITY_ENV["image_generation_v1"], "0")
    assert client.post("/api/images/portrait", json=body()).status_code == 404
    assert provider.calls == []


def test_rate_limit_is_visible_and_never_automatically_retried(client, monkeypatch):
    configured(client)
    provider = ProviderStub(monkeypatch, [FakeResponse(429, text='{"error":{"message":"rate limited"}}')])
    response = client.post("/api/images/portrait", json=body())
    assert response.status_code == 502
    assert len(provider.calls) == 1
    assert "rate" in response.text.lower()


def test_reject_nonimage_output_without_saving(client, monkeypatch):
    configured(client)
    ProviderStub(monkeypatch, [_ok(b"<svg onload='bad()'/>")])
    assert client.post("/api/images/portrait", json=body()).status_code == 422


def test_cancel_before_provider_dispatch_never_calls_provider(monkeypatch):
    service = ImageGenerationService()
    service.configure(_provider_config())
    provider = ProviderStub(monkeypatch)
    with pytest.raises(ImageProviderError, match="interrupted"):
        service.portrait_preview("robot", "acct-1", ToolContext(should_stop=lambda: True))
    assert provider.calls == []


def test_cancel_unknown_request_is_idempotent(client):
    request = body()
    assert client.post("/api/images/portrait/cancel", json=request).json() == {"ok": True}
    assert client.post("/api/images/portrait/cancel", json=request).json() == {"ok": True}


@pytest.mark.parametrize("disconnect", [True, False], ids=["disconnect", "handler-cancel"])
def test_request_cancellation_stops_existing_provider_context(client, monkeypatch, disconnect):
    service = configured(client)
    started, stopped = threading.Event(), threading.Event()
    def blocking(prompt, account_id, ctx):
        started.set()
        while not ctx.stopped():
            stopped.wait(0.005)
        stopped.set()
        raise ImageProviderError("interrupted")
    monkeypatch.setattr(service.image_generation, "portrait_preview", blocking)
    async def run():
        task, events, sent = await _exchange(client.app, body(), path="/api/images/portrait")
        await _wait_for(started.is_set)
        if disconnect:
            await events.put({"type": "http.disconnect"})
            await asyncio.wait_for(task, 2)
            assert sent[0]["status"] == 499
        else:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await _wait_for(stopped.is_set)
        await _wait_for(lambda: not portrait_preview._pending)
    asyncio.run(run())
    assert stopped.wait(1)
    assert not portrait_preview._pending


def test_timeout_stops_context_without_retry(client, monkeypatch):
    configured(client)
    ProviderStub(monkeypatch)
    monkeypatch.setattr(portrait_preview, "PREVIEW_TIMEOUT_SECONDS", 0)
    response = client.post("/api/images/portrait", json=body())
    assert response.status_code == 504
