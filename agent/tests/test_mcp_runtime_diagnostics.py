"""MCP failures retain actionable, bounded, credential-safe evidence."""
from __future__ import annotations

import asyncio
import builtins
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace

import pytest

from ollama_code.extensions import ExtensionManager
from ollama_code.mcp_diagnostics import ConnectionDiagnostics, exception_causes
from ollama_code.mcp_runtime import MCPManager, _http_headers, _validated_form_content


def configured(tmp_path, values):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    server = manager.upsert_mcp_server({"name": "macuse-fixture", **values})
    events = []
    return manager, server, MCPManager(manager, events.append), events


def test_nested_exception_causes_are_bounded_and_redacted():
    leaf = ConnectionRefusedError(61, "Connection refused at http://user:password@127.0.0.1:35792/mcp?token=private")
    outer = RuntimeError("All connection attempts failed; Bearer super-secret")
    outer.__cause__ = leaf
    group_type = getattr(builtins, "ExceptionGroup", None)
    if group_type is None:
        pytest.skip("Exception groups require Python 3.11")
    group = group_type("transport", [outer, outer])
    diagnostic = ConnectionDiagnostics({"name": "Macuse", "url": "http://127.0.0.1:35792/mcp"}, {"access_token": "super-secret"})
    state, error, details = diagnostic.failure(group)
    serialized = json.dumps(details)
    assert state == "error"
    assert "No MCP server accepted" in error
    assert len(details["causes"]) == 2
    assert all(secret not in serialized for secret in ("super-secret", "password@", "token=private"))
    assert any("35729" in hint for hint in details["hints"])
    leaf.__cause__ = outer
    assert len(exception_causes(outer)) == 2


def test_header_precedence_is_case_insensitive(monkeypatch):
    monkeypatch.setenv("EXTRA_HEADER", "environment")
    headers = _http_headers({"http_headers": {"authorization": "literal", "X-Test": "literal"},
                             "env_http_headers": {"x-test": "EXTRA_HEADER"}},
                            {"headers": {"X-TEST": "stored"}, "access_token": "token"}, "/tmp")
    assert {key.lower(): value for key, value in headers.items()} == {"x-test": "stored", "authorization": "Bearer token"}
    assert len(headers) == 2


def test_invalid_protocol_input_does_not_expose_payload():
    from mcp import types
    from pydantic import ValidationError
    with pytest.raises(ValidationError) as caught:
        types.ImageContent.model_validate({"type": "image", "data": "private-image-payload"})
    causes = exception_causes(caught.value)
    assert "private-image-payload" not in json.dumps(causes)
    assert "mimeType" in causes[0]


def test_refused_local_endpoint(tmp_path):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    _, server, runtime, _ = configured(tmp_path, {"url": f"http://127.0.0.1:{port}/mcp"})
    try:
        response = runtime.probe(server["id"])
        assert response["status"]["state"] == "error"
        assert "accepted a connection" in response["status"]["error"]
        assert any("ConnectionRefusedError" in cause for cause in response["status"]["diagnostics"]["causes"])
    finally:
        runtime.close()


@pytest.mark.parametrize("code", [401, 403, 404, 405])
def test_http_status_survives_sdk_generic_error(tmp_path, code):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = b'{"error":"private body must not be exposed"}'
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    manager, server, runtime, events = configured(tmp_path, {"url": f"http://127.0.0.1:{http.server_port}/mcp"})
    manager.set_credentials(server["id"], {"access_token": "private-token"})
    try:
        status = runtime.probe(server["id"])["status"]
        assert status["diagnostics"]["http_status"] == code
        assert status["diagnostics"]["auth_present"] is True
        assert status["state"] == ("needs_auth" if code in {401, 403} else "error")
        assert "private-token" not in json.dumps(events)
        assert "private body" not in json.dumps(events)
    finally:
        runtime.close()
        http.shutdown()
        http.server_close()
        thread.join(timeout=2)


def test_missing_stdio_executable(tmp_path):
    _, server, runtime, _ = configured(tmp_path, {"command": str(tmp_path / "not-installed")})
    try:
        status = runtime.probe(server["id"])["status"]
        assert "could not be found" in status["error"]
        assert status["diagnostics"]["transport"] == "stdio"
        assert not runtime._clients
    finally:
        runtime.close()


def test_stdio_failure_keeps_bounded_stderr_without_secrets(tmp_path):
    script = tmp_path / "failure.py"
    script.write_text("import sys\nsys.stderr.write('x'*200000+'\\nAuthorization: Bearer private-token\\nmissing configuration file\\n')\nsys.stderr.flush()\nraise SystemExit(7)\n")
    manager, server, runtime, events = configured(tmp_path, {"command": sys.executable, "args": [str(script)]})
    manager.set_credentials(server["id"], {"env": {"TOKEN": "private-token"}})
    try:
        status = runtime.probe(server["id"])["status"]
        stderr = status["diagnostics"]["stderr_tail"]
        assert "missing configuration file" in stderr
        assert len(stderr) <= 16384
        assert "private-token" not in json.dumps(events)
        assert all(owner["diagnostics"].stderr.closed for owner in runtime._owners.values())
    finally:
        runtime.close()


def test_attempt_timeout_cleans_up_and_retry_clears_diagnostics(tmp_path):
    script = tmp_path / "server.py"
    script.write_text("import time\ntime.sleep(30)\n")
    manager, server, runtime, _ = configured(tmp_path, {"command": sys.executable, "args": [str(script)], "startup_timeout_sec": 1})
    try:
        status = runtime.probe(server["id"])["status"]
        assert "timed out" in status["error"]
        assert status["diagnostics"]["stage"] == "connect_initialize"
        assert not runtime._clients
        script.write_text("from mcp.server import MCPServer\ns=MCPServer('empty')\ns.run('stdio')\n")
        manager.upsert_mcp_server({"startup_timeout_sec": 5}, server_id=server["id"])
        result = runtime.probe(server["id"])
        assert result["status"]["state"] == "connected"
        assert result["status"]["diagnostics"] is None
        assert result["tools"] == []
    finally:
        runtime.close()


def test_json_schema_form_validation():
    schema = {"type": "object", "properties": {
        "count": {"type": "integer", "minimum": 1, "maximum": 5},
        "choices": {"type": "array", "items": {"type": "string", "enum": ["a", "b"]}, "uniqueItems": True},
        "label": {"type": "string", "minLength": 2, "maxLength": 4},
    }, "required": ["count"]}
    assert _validated_form_content(schema, {"count": 2, "choices": ["a"]})
    for content in ({"count": True}, {"count": 0}, {"count": "2"}, {"count": 2, "label": "x"},
                    {"count": 2, "choices": ["a", "a"]}, {"count": 2, "choices": ["c"]}):
        assert _validated_form_content(schema, content) is None
    assert _validated_form_content({"$ref": "https://example.com/schema"}, {}) is None


def test_resource_templates_keep_permission_identity_and_invalidate_cache(tmp_path):
    from mcp import types
    from mcp.client.subscriptions import ResourceUpdated
    manager, server, runtime, _ = configured(tmp_path, {"command": "unused"})
    server = {**server, "resource_access": "selected", "enabled_resources": ["demo://items/{key}"]}
    calls = []

    async def read_resource(uri, **kwargs):
        calls.append(uri)
        return SimpleNamespace(contents=[SimpleNamespace(text="resource value", mime_type="text/plain")], ttl_ms=10000)

    client = SimpleNamespace(read_resource=read_resource, session=SimpleNamespace(protocol_version="2025-11-25"),
                             server_capabilities=types.ServerCapabilities(resources=types.ResourcesCapability(subscribe=False)))
    record = {"client": client, "server": server, "resources": [], "prompts": [], "tools": [],
              "all_resources": [{"server_id": server["id"], "uri": "demo://items/{key}", "name": "items", "template": True}],
              "all_prompts": [], "resource_links": {}, "subscriptions": set(), "warnings": [],
              "diagnostics": ConnectionDiagnostics(server, {})}
    runtime._clients[server["id"]] = record
    runtime._filter_catalogs(record)

    async def exercise():
        assert "Missing template arguments" in await runtime._read_resource(server["id"], "demo://items/{key}")
        assert "not present" in await runtime._read_resource(server["id"], "demo://items/hello")
        assert "Unknown" in await runtime._read_resource(server["id"], "demo://items/{key}", {"key": "x", "other": "x"})
        assert "resource value" in await runtime._read_resource(server["id"], "demo://items/{key}", {"key": "hello world"})
        assert calls == ["demo://items/hello%20world"]
        await runtime._read_resource(server["id"], "demo://items/{key}", {"key": "hello world"})
        assert len(calls) == 1
        await runtime._handle_change(server["id"], ResourceUpdated(uri="demo://items/hello%20world"))
        await runtime._read_resource(server["id"], "demo://items/{key}", {"key": "hello world"})
        assert len(calls) == 2
    try:
        asyncio.run(exercise())
    finally:
        runtime._clients.clear()
        runtime.close()


def test_template_pagination_failure_does_not_discard_resources(tmp_path):
    from mcp import types
    _, server, runtime, _ = configured(tmp_path, {"command": "unused"})

    async def list_resources(**kwargs):
        return types.ListResourcesResult(resources=[types.Resource(uri="demo://text", name="text")])

    async def list_templates(**kwargs):
        raise ValueError("templates unavailable")

    client = SimpleNamespace(list_resources=list_resources, list_resource_templates=list_templates,
                             server_capabilities=types.ServerCapabilities(resources=types.ResourcesCapability()))
    runtime._clients[server["id"]] = {"server": server, "client": client, "diagnostics": ConnectionDiagnostics(server, {}),
                                      "all_prompts": [], "resource_links": {}, "warnings": []}
    try:
        asyncio.run(runtime._load_catalogs(server["id"]))
        catalog = runtime.catalog(server["id"])
        assert [item["uri"] for item in catalog["resources"]] == ["demo://text"]
        assert "templates unavailable" in runtime._clients[server["id"]]["warnings"][0]
    finally:
        runtime._clients.clear()
        runtime.close()


def test_real_legacy_sse_transport(tmp_path):
    import subprocess
    import time
    script = tmp_path / "sse_server.py"
    script.write_text("from mcp.server import MCPServer\nimport sys\ns=MCPServer('sse-fixture')\n@s.tool()\ndef greet() -> str:\n return 'hello'\ns.run('sse', host='127.0.0.1', port=int(sys.argv[1]))\n")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    process = subprocess.Popen([sys.executable, str(script), str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, server, runtime, _ = configured(tmp_path, {"url": f"http://127.0.0.1:{port}/sse", "transport": "sse", "protocol_mode": "legacy"})
    try:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.05)
        runtime.refresh()
        assert runtime.status(server["id"])["state"] == "connected", runtime.status(server["id"])
        assert "hello" in runtime.call_tool(server["id"], "greet", {})
        runtime.reconnect(server["id"])
        assert runtime.status(server["id"])["state"] == "connected"
    finally:
        runtime.close()
        process.terminate()
        process.wait(timeout=5)


@pytest.mark.parametrize("protocol_mode", ["auto", "legacy"])
def test_real_resource_and_prompt_server(tmp_path, protocol_mode):
    script = tmp_path / "catalog_server.py"
    script.write_text(
        "from mcp.server import MCPServer\ns=MCPServer('catalog')\n"
        "@s.resource('demo://greeting/{name}')\ndef greeting(name: str) -> str:\n return 'hello '+name\n"
        "@s.prompt()\ndef summarize(topic: str) -> str:\n return 'Summarize '+topic\n"
        "s.run('stdio')\n"
    )
    _, server, runtime, _ = configured(tmp_path, {
        "command": sys.executable, "args": [str(script)], "protocol_mode": protocol_mode,
        "enabled_prompts": ["summarize"],
    })
    try:
        runtime.refresh()
        assert runtime.status(server["id"])["state"] == "connected", runtime.status(server["id"])
        catalog = runtime.catalog(server["id"])
        assert catalog["templates"][0]["uri"] == "demo://greeting/{name}"
        assert catalog["prompts"][0]["enabled"] is True
        assert "hello Locus" in runtime.read_resource(server["id"], "demo://greeting/{name}", {"name": "Locus"})
        assert "Summarize testing" in runtime.load_prompt(server["id"], "summarize", {"topic": "testing"})
        assert "allowlisted" in runtime.load_prompt(server["id"], "unknown", {})
        assert runtime.complete(server["id"], "resource", "demo://greeting/{name}", "name", "L")["values"] == []
    finally:
        runtime.close()


def test_modern_subscription_end_invalidates_cache_without_disconnect(tmp_path):
    from contextlib import asynccontextmanager

    from mcp import types
    from mcp.client.subscriptions import ResourceUpdated
    _, server, runtime, _ = configured(tmp_path, {"command": "unused"})
    server_id = server["id"]

    class Subscription:
        honored = SimpleNamespace(resource_subscriptions=["demo://text"])

        async def __aiter__(self):
            yield ResourceUpdated(uri="demo://text")

    @asynccontextmanager
    async def listen(**kwargs):
        yield Subscription()

    client = SimpleNamespace(listen=listen, session=SimpleNamespace(protocol_version="2026-07-28"),
                             server_capabilities=types.ServerCapabilities(resources=types.ResourcesCapability()))
    record = {"client": client, "server": server, "subscriptions": {"demo://text"},
              "diagnostics": ConnectionDiagnostics(server, {}), "warnings": [], "tools": [], "resources": [], "prompts": []}
    runtime._clients[server_id] = record
    runtime._resource_cache[(server_id, "demo://text")] = (float('inf'), "stale")

    async def exercise():
        record["listener"] = asyncio.current_task()
        await runtime._listen(server_id)
        assert not runtime._resource_cache
        assert not record["subscriptions"]
        assert runtime.status(server_id)["state"] == "connected"
        assert "ended live updates" in record["warnings"][-1]
    try:
        asyncio.run(exercise())
    finally:
        runtime._clients.clear()
        runtime.close()


@pytest.mark.parametrize("interruption", ["deadline", "cancel"])
def test_discovery_deadline_and_cancel_release_stdio(tmp_path, monkeypatch, interruption):
    script = tmp_path / "empty.py"
    script.write_text("from mcp.server import MCPServer\ns=MCPServer('empty')\ns.run('stdio')\n")
    _, server, runtime, _ = configured(tmp_path, {"command": sys.executable, "args": [str(script)], "startup_timeout_sec": 30})

    # Exercise the real deadline callback only once discovery has started.
    # A one-second wall-clock deadline can instead expire while the subprocess
    # imports the SDK, which tests initialization failure rather than discovery.
    call_later = runtime._loop.call_later
    deadline_callbacks = []

    def capture_startup_deadline(delay, callback, *args, **kwargs):
        if not deadline_callbacks and delay == server["startup_timeout_sec"]:
            deadline_callbacks.append(lambda: callback(*args))
        return call_later(delay, callback, *args, **kwargs)

    async def slow_tools(server_id):
        assert deadline_callbacks, "The connection owner must arm its startup deadline"
        if interruption == "deadline":
            deadline_callbacks[0]()
        else:
            asyncio.current_task().cancel()
        await asyncio.Future()

    monkeypatch.setattr(runtime._loop, "call_later", capture_startup_deadline)
    monkeypatch.setattr(runtime, "_load_tools", slow_tools)
    try:
        response = runtime.probe(server["id"])
        assert response["status"]["diagnostics"]["stage"] == "tools"
        assert ("timed out" if interruption == "deadline" else "was cancelled") in response["status"]["error"]
        assert not runtime._clients
        assert not runtime._owners
    finally:
        runtime.close()


@pytest.mark.parametrize(("error", "summary"), [
    (PermissionError("Permission denied"), "permission"),
    (socket.gaierror("Name resolution failed"), "hostname could not be resolved"),
    (RuntimeError("TLS certificate validation failed"), "secure connection"),
    (ValueError("Unexpected protocol message"), "incompatible protocol response"),
    (asyncio.CancelledError(), "was cancelled"),
])
def test_actionable_failure_categories(error, summary):
    diagnostic = ConnectionDiagnostics({"url": "https://example.test/mcp"}, {})
    _, message, details = diagnostic.failure(error)
    assert summary in message
    assert details["hints"]


def test_permission_changes_retain_complete_catalog_and_returned_links(tmp_path):
    script = tmp_path / "link_server.py"
    script.write_text(
        "from mcp.server import MCPServer\nfrom mcp import types\ns=MCPServer('links')\n"
        "@s.tool()\ndef discover() -> list[types.ResourceLink]:\n"
        " return [types.ResourceLink(type='resource_link',name='returned',uri='demo://returned')]\n"
        "s.run('stdio')\n"
    )
    manager, server, runtime, _ = configured(tmp_path, {"command": sys.executable, "args": [str(script)]})
    server_id = server["id"]
    try:
        runtime.refresh()
        assert runtime.status(server_id)["state"] == "connected"
        owner = runtime._owners[server_id]
        runtime.call_tool(server_id, "discover", {}, invocation_context={"tool_call_id": "original-call"})
        assert runtime.catalog(server_id)["resources"][0]["source_tool_call_id"] == "original-call"
        manager.set_mcp_policy(server_id, "disabled", tool_name="discover", resource_access="selected", enabled_resources=["demo://returned"])
        runtime.refresh()
        assert runtime._owners[server_id] is owner
        assert runtime.available_tools() == []
        catalog = runtime.catalog(server_id)
        assert catalog["tools"][0]["name"] == "discover"
        assert catalog["tools"][0]["enabled"] is False
        assert catalog["resources"][0]["enabled"] is True
        assert catalog["resources"][0]["source_tool_call_id"] == "original-call"
        manager.set_mcp_policy(server_id, "annotations", tool_name="discover")
        runtime.refresh()
        assert runtime.available_tools()[0]["name"] == "discover"
        assert runtime._owners[server_id] is owner
        manager.set_mcp_policy(server_id, resource_access="none")
        assert "access was disabled" in runtime.read_resource(server_id, "demo://returned")
    finally:
        runtime.close()


def test_retry_does_not_invoke_a_tool_removed_during_reconnect(tmp_path, monkeypatch):
    _, server, runtime, _ = configured(tmp_path, {"command": "unused"})
    server_id = server["id"]
    calls = []

    async def failed_call(*args, **kwargs):
        calls.append("original")
        raise ConnectionError("Connection closed")

    async def replacement_call(*args, **kwargs):
        calls.append("replacement")

    async def disconnect(server_id):
        runtime._clients.pop(server_id, None)

    async def connect(server):
        runtime._clients[server_id] = {"client": SimpleNamespace(call_tool=replacement_call), "tools": []}

    runtime._clients[server_id] = {"server": server, "client": SimpleNamespace(call_tool=failed_call),
                                  "tools": [{"name": "read", "annotations": {"readOnlyHint": True}}]}
    monkeypatch.setattr(runtime, "_disconnect", disconnect)
    monkeypatch.setattr(runtime, "_connect", connect)
    try:
        result = asyncio.run(runtime._call_tool(server_id, "read", {}))
        assert "changed during reconnect" in result
        assert calls == ["original"]
    finally:
        runtime._clients.clear()
        runtime.close()


def test_task_cancellation_failure_preserves_remote_state(tmp_path):
    _, server, runtime, events = configured(tmp_path, {"command": "unused"})
    server_id = server["id"]
    persisted = []
    runtime.task_store = SimpleNamespace(upsert_mcp_task=lambda *args, **kwargs: persisted.append(kwargs))

    async def request(request, *args, **kwargs):
        if request.method == "tools/call":
            return SimpleNamespace(task=SimpleNamespace(task_id="remote-task", status="working", status_message="", poll_interval=5000))
        raise ConnectionError("Cancellation connection closed")

    record = {"server": server, "client": SimpleNamespace(session=SimpleNamespace(send_request=request))}
    runtime._clients[server_id] = record

    async def exercise():
        operation = asyncio.create_task(runtime._call_task(record, {"server_id": server_id, "name": "work"}, {}))
        await asyncio.sleep(0)
        operation.cancel()
        with pytest.raises(asyncio.CancelledError):
            await operation
        assert persisted[-1]["state"] == "working"
        assert "could not be confirmed" in persisted[-1]["status_message"]
        assert events[-1]["type"] == "mcp_task_progress"
    try:
        asyncio.run(exercise())
    finally:
        runtime._clients.clear()
        runtime.close()


def test_cancelled_connection_closes_owned_resources(tmp_path):
    import time
    script = tmp_path / "pending.py"
    script.write_text("import time\ntime.sleep(30)\n")
    _, server, runtime, _ = configured(tmp_path, {"command": sys.executable, "args": [str(script)]})
    runtime._ensure_started()
    future = asyncio.run_coroutine_threadsafe(runtime._connect(server), runtime._loop)
    try:
        deadline = time.monotonic() + 5
        owner = None
        while time.monotonic() < deadline:
            owner = runtime._owners.get(server["id"])
            if owner and owner["diagnostics"].stderr:
                break
            time.sleep(.01)
        assert owner and owner["diagnostics"].stderr
        future.cancel()
        while not owner["task"].done() and time.monotonic() < deadline:
            time.sleep(.01)
        assert owner["task"].done()
        assert owner["diagnostics"].stderr.closed
        assert not runtime._clients
        assert "was cancelled" in runtime.status(server["id"])["error"]
    finally:
        runtime.close()


def test_recovered_task_links_keep_original_invocation(tmp_path):
    from mcp import types
    _, server, runtime, _ = configured(tmp_path, {"command": "unused"})
    server_id = server["id"]
    task = {"id": "remote-task", "server_id": server_id, "tool_name": "discover",
            "run_id": "original-run", "tool_call_id": "original-call"}
    runtime.task_store = SimpleNamespace(upsert_mcp_task=lambda *args, **kwargs: None, mcp_task=lambda task_id: task)

    async def request(request, *args, **kwargs):
        if request.method == "tasks/get":
            return SimpleNamespace(status="completed", status_message="")
        return types.CallToolResult(content=[types.ResourceLink(type="resource_link", name="result", uri="demo://recovered")])

    runtime._clients[server_id] = {"server": server, "client": SimpleNamespace(session=SimpleNamespace(send_request=request))}
    try:
        response = asyncio.run(runtime._lookup_task(task, include_payload=True))
        assert "demo://recovered" in response["result"]
        link = runtime.catalog(server_id)["resources"][0]
        assert link["source_tool"] == "discover"
        assert link["source_tool_call_id"] == "original-call"
    finally:
        runtime._clients.clear()
        runtime.close()


def test_returned_link_to_listed_resource_preserves_single_catalog_identity(tmp_path):
    _, server, runtime, _ = configured(tmp_path, {"command": "unused"})
    item = {"uri": "demo://shared", "name": "listed", "template": False}
    record = {"server": server, "all_resources": [item], "resource_links": {
        "demo://shared": {**item, "name": "linked", "source_tool": "read", "source_tool_call_id": "original-call"},
    }}
    try:
        runtime._filter_catalogs(record)
        resources = runtime.catalog(server["id"])["resources"]
        assert len(resources) == 1
        assert resources[0]["name"] == "listed"
        assert resources[0]["source_tool_call_id"] == "original-call"
    finally:
        runtime.close()


@pytest.mark.parametrize("modern", [False, True])
def test_catalog_updates_refresh_only_changed_catalog_and_invalidate_reads(tmp_path, monkeypatch, modern):
    from mcp import types
    from mcp.client import subscriptions
    _, server, runtime, _ = configured(tmp_path, {"command": "unused"})
    server_id = server["id"]
    runtime._clients[server_id] = {"server": server, "client": SimpleNamespace(server_capabilities=types.ServerCapabilities()),
                                  "tools": [], "resources": [], "prompts": []}
    calls = []

    async def tools_changed(server_id):
        calls.append("tools")

    async def catalogs_changed(server_id, **kwargs):
        calls.append(kwargs)

    monkeypatch.setattr(runtime, "_load_tools", tools_changed)
    monkeypatch.setattr(runtime, "_load_catalogs", catalogs_changed)
    event_types = (subscriptions.ToolsListChanged, subscriptions.PromptsListChanged, subscriptions.ResourcesListChanged) if modern else (
        types.ToolListChangedNotification, types.PromptListChangedNotification, types.ResourceListChangedNotification,
    )

    async def exercise():
        for event_type in event_types:
            await runtime._handle_change(server_id, event_type())
        assert calls == ["tools", {"resources": False, "prompts": True}, {"resources": True, "prompts": False}]
        assert not runtime._resource_cache
    runtime._resource_cache[(server_id, "demo://cached")] = (float("inf"), "stale")
    try:
        asyncio.run(exercise())
    finally:
        runtime._clients.clear()
        runtime.close()
