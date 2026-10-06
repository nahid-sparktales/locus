"""A closed panel stops MCP work before a later external write can start."""
from __future__ import annotations

import asyncio
import json
import threading
import time
from pathlib import Path

from fastapi import FastAPI
from test_plugin_panel_context import panel as panel

from ollama_code.api.dependencies import get_service
from ollama_code.api.extensions import call_extension_plugin_panel_tool_http


def _app(service):
    app = FastAPI()
    app.dependency_overrides[get_service] = lambda: service
    app.add_api_route("/panel-tool", call_extension_plugin_panel_tool_http, methods=["POST"])
    return app


async def _exchange(app, payload):
    events = asyncio.Queue()
    await events.put({"type": "http.request", "body": json.dumps(payload).encode(), "more_body": False})
    sent = []

    async def receive():
        return await events.get()

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "method": "POST", "scheme": "http", "path": "/panel-tool", "raw_path": b"/panel-tool",
             "query_string": b"", "headers": [(b"content-type", b"application/json")],
             "client": ("127.0.0.1", 12345), "server": ("127.0.0.1", 80)}
    return asyncio.create_task(app(scope, receive, send)), events, sent


async def _wait_for(predicate, *, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        await asyncio.sleep(0.01)
    assert predicate(), "The panel request did not reach its expected state."


def test_http_panel_request_preserves_captured_context(panel):
    service, payload, _manager, _runtime = panel

    async def exercise():
        task, _events, sent = await _exchange(_app(service), payload)
        await asyncio.wait_for(task, 10)
        assert sent[0]["status"] == 200
        response = json.loads(next(item["body"] for item in sent if item["type"] == "http.response.body"))
        assert not response["is_error"]
        metadata = json.loads(response["content"])["context"]["com.locus/panel"]
        assert metadata["workspace"] == payload["workspace"]

    asyncio.run(exercise())


def test_http_disconnect_cancels_real_mcp_before_publication(panel, tmp_path):
    service, payload, manager, _runtime = panel
    marker, publish, cancelled = (tmp_path / name for name in ("validation-started", "published", "cancelled"))
    # Replace this fixture's slow tool before its first connection. This models
    # a publication validating before its eventual remote write.
    server = manager._plugin(payload["plugin_id"])["root"]
    source = Path(server) / "server.py"
    source.write_text(source.read_text().replace(
        "    await asyncio.sleep(30)\n    return 'finished'",
        "    try:\n"
        "        await asyncio.sleep(2)\n"
        f"        Path({str(publish)!r}).write_text('published')\n"
        "        return 'finished'\n"
        "    except asyncio.CancelledError:\n"
        f"        Path({str(cancelled)!r}).write_text('cancelled')\n"
        "        raise",
    ))

    async def exercise():
        task, events, sent = await _exchange(_app(service), {
            **payload, "tool": "slow", "arguments": {"marker": str(marker)},
        })
        await _wait_for(marker.exists)
        await events.put({"type": "http.disconnect"})
        await asyncio.wait_for(task, 2)
        assert sent[0]["status"] == 499
        assert manager._active(manager._plugin(payload["plugin_id"]), payload["workspace"])
        await _wait_for(cancelled.exists, timeout=2)
        assert not publish.exists()

    asyncio.run(exercise())


def test_http_handler_cancellation_stops_the_worker(panel, monkeypatch):
    service, payload, _manager, runtime = panel
    started, stopped = threading.Event(), threading.Event()
    calls = []

    def dispatch(_server, _tool, _arguments, **options):
        calls.append(True)
        started.set()
        deadline = time.monotonic() + 5
        while not options["should_stop"]() and time.monotonic() < deadline:
            time.sleep(0.01)
        if options["should_stop"]():
            assert options["server_resolver"]() is None
            stopped.set()
        return "Error: cancelled"

    monkeypatch.setattr(runtime, "call_tool", dispatch)

    async def exercise():
        task, _events, _sent = await _exchange(_app(service), payload)
        await _wait_for(started.is_set)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        await _wait_for(stopped.is_set, timeout=2)
        assert calls == [True]

    asyncio.run(exercise())
