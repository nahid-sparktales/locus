"""A closed panel stops MCP work before a later external write can start."""
from __future__ import annotations

import asyncio
import json
import socket
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import uvicorn
from fastapi.testclient import TestClient
from test_plugin_panel_context import panel as panel

from ollama_code import server as server_mod

TOKEN = "panel-test-token"
PANEL_PATH = "/api/extensions/plugins/panel-tool"


def _app(service):
    return server_mod.create_app(chat_service=service, auth_token=TOKEN)


async def _exchange(app, payload, *, path=PANEL_PATH):
    events = asyncio.Queue()
    await events.put({"type": "http.request", "body": json.dumps(payload).encode(), "more_body": False})
    sent = []

    async def receive():
        return await events.get()

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "method": "POST", "scheme": "http", "path": path, "raw_path": path.encode(),
             "query_string": b"", "headers": [(b"content-type", b"application/json"),
                                                 (b"x-locus-token", TOKEN.encode())],
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


def _publication_tool(panel, tmp_path):
    _service, payload, manager, _runtime = panel
    marker, publish, cancelled, release = (tmp_path / name for name in (
        "validation-started", "published", "cancelled", "release-validation"))
    # Replace this fixture's slow tool before its first connection. This models
    # a publication validating before its eventual remote write.
    server = manager._plugin(payload["plugin_id"])["root"]
    source = Path(server) / "server.py"
    source.write_text(source.read_text().replace(
        "Path(marker).write_text('started')",
        "with Path(marker).open('a') as handle: handle.write('started\\n')",
    ).replace(
        "    await asyncio.sleep(30)\n    return 'finished'",
        "    try:\n"
        f"        while not Path({str(release)!r}).exists():\n"
        "            await asyncio.sleep(0.01)\n"
        f"        Path({str(publish)!r}).write_text('published')\n"
        "        return 'finished'\n"
        "    except asyncio.CancelledError:\n"
        f"        Path({str(cancelled)!r}).write_text('cancelled')\n"
        "        raise",
    ))
    return marker, publish, cancelled, release


def test_http_disconnect_cancels_real_mcp_before_publication(panel, tmp_path):
    service, payload, manager, _runtime = panel
    marker, publish, cancelled, release = _publication_tool(panel, tmp_path)

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
        release.touch()
        assert not publish.exists()
        assert marker.read_text().splitlines() == ["started"]

    asyncio.run(exercise())


@contextmanager
def _serve(app):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    # This fixture service needs no application startup/shutdown; the actual
    # routes, auth and complete HTTP middleware stack are still exercised.
    server = uvicorn.Server(uvicorn.Config(app, log_level="critical", lifespan="off",
                                          timeout_graceful_shutdown=2))
    worker = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    worker.start()
    try:
        deadline = time.monotonic() + 10
        while not server.started and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.started, "HTTP fixture did not start"
        yield port
    finally:
        server.should_exit = True
        worker.join(timeout=5)
        listener.close()
        assert not worker.is_alive(), "HTTP fixture did not stop"


def test_production_tcp_disconnect_cancels_before_deferred_write(panel, tmp_path):
    service, payload, _manager, _runtime = panel
    marker, publish, cancelled, release = _publication_tool(panel, tmp_path)
    with _serve(_app(service)) as port:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            body = json.dumps({**payload, "tool": "slow", "arguments": {"marker": str(marker)}}).encode()
            headers = (f"POST {PANEL_PATH} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                       f"Content-Type: application/json\r\nX-Locus-Token: {TOKEN}\r\n"
                       f"Content-Length: {len(body)}\r\n\r\n").encode()
            client.sendall(headers + body)
            asyncio.run(_wait_for(marker.exists))
            client.shutdown(socket.SHUT_RDWR)
        try:
            asyncio.run(_wait_for(cancelled.exists, timeout=2))
        finally:
            # Validation remains gated until the server confirms cancellation;
            # a slow host cannot accidentally publish before the disconnect.
            release.touch()
        assert not publish.exists()
        assert marker.read_text().splitlines() == ["started"]


def test_production_normal_completion_runs_write_once(panel, tmp_path):
    service, payload, _manager, _runtime = panel
    marker, publish, cancelled, release = _publication_tool(panel, tmp_path)

    async def exercise():
        task, _events, sent = await _exchange(_app(service), {
            **payload, "tool": "slow", "arguments": {"marker": str(marker)},
        })
        await _wait_for(marker.exists)
        release.touch()
        await asyncio.wait_for(task, 5)
        assert sent[0]["status"] == 200
        assert publish.exists() and not cancelled.exists()
        assert marker.read_text().splitlines() == ["started"]

    asyncio.run(exercise())


def test_production_panel_guards_reject_before_dispatch(panel, monkeypatch):
    service, payload, _manager, runtime = panel
    calls = []
    monkeypatch.setattr(runtime, "call_tool", lambda *args, **kwargs: calls.append(args))
    app = _app(service)
    client = TestClient(app)
    assert client.post(PANEL_PATH, json=payload).status_code == 401
    assert client.post(PANEL_PATH, json=payload, headers={"x-locus-token": "wrong"}).status_code == 401
    headers = {"x-locus-token": TOKEN}
    assert client.post(PANEL_PATH, json=payload, headers={**headers, "origin": "https://untrusted.example"}).status_code == 403
    app.state.runtime = SimpleNamespace(maintenance=True)
    assert client.post(PANEL_PATH, json=payload, headers=headers).status_code == 409
    monkeypatch.setattr(server_mod, "MAX_HTTP_BODY_BYTES", 1)
    limited = TestClient(_app(service))
    assert limited.post(PANEL_PATH, json=payload, headers=headers).status_code == 413
    assert calls == []


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
