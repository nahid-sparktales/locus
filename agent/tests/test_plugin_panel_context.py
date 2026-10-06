"""Project-bound plugin windows use the existing runtime without changing chats."""
from __future__ import annotations

import asyncio
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from test_extensions import _marketplace, _panel_plugin

from ollama_code.api.extensions import call_extension_plugin_panel_tool
from ollama_code.extensions import ExtensionManager
from ollama_code.mcp_runtime import MCPManager, _substitute


@pytest.fixture
def panel(tmp_path):
    workspace = tmp_path / "original"
    workspace.mkdir()
    other = tmp_path / "selected"
    other.mkdir()
    market = tmp_path / "market"
    plugin = _panel_plugin(market / "plugins/fixture", server={
        "command": "${LOCUS_PYTHON}", "args": ["-B", "${PLUGIN_ROOT}/server.py"],
        "env_vars": ["PYTHONPATH"], "protocol_mode": "legacy",
    })
    manifest_path = plugin / ".codex-plugin/plugin.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["locus"]["panels"].append({
        "id": "other", "title": "Other", "entrypoint": "ui/index.html", "version": 1,
        "capabilities": ["plugin.tools"], "tools": ["other_secret"],
    })
    manifest_path.write_text(json.dumps(manifest))
    (plugin / "server.py").write_text(
        "import asyncio, json\n"
        "from pathlib import Path\n"
        "from mcp.server import MCPServer\n"
        "from mcp.server.mcpserver import Context\n"
        "from mcp.types import ToolAnnotations\n"
        "server = MCPServer('panel-fixture')\n"
        "@server.tool(annotations=ToolAnnotations(readOnlyHint=True), structured_output=False)\n"
        "def status(ctx: Context, size: int = 0) -> str:\n"
        "    return json.dumps({'context': ctx.request_context.meta, 'text': 'x' * size})\n"
        "@server.tool()\n"
        "def decide() -> str:\n"
        "    return 'decided'\n"
        "@server.tool()\n"
        "def other_secret() -> str:\n"
        "    return 'other'\n"
        "@server.tool()\n"
        "async def slow(marker: str) -> str:\n"
        "    Path(marker).write_text('started')\n"
        "    await asyncio.sleep(30)\n"
        "    return 'finished'\n"
        "server.run('stdio')\n"
    )
    _marketplace(market, plugin)
    manager = ExtensionManager(str(other), root=tmp_path / "state")
    source = manager.add_marketplace(str(market))
    inspection = manager.inspect_catalog_plugin(source["id"], "fixture")
    installed = manager.install_plugin(source["id"], "fixture", scope="workspace",
                                       workspace=str(workspace), expected_digest=inspection["digest"])
    runtime = MCPManager(manager)
    service = SimpleNamespace(core=SimpleNamespace(cwd=str(other), extensions=manager, mcp=runtime))
    request = {"plugin_id": installed["id"], "tool": "status", "arguments": {},
               "workspace": str(workspace), "panel_id": "workflows", "digest": installed["digest"]}
    yield service, request, manager, runtime
    runtime.close()


def test_bundled_interpreter_substitution():
    assert _substitute("${LOCUS_PYTHON}", {}, "/workspace") == sys.executable


@pytest.mark.parametrize("message", ["Error executing tool fixture: unavailable", "Unavailable", "Error: unavailable"])
def test_sdk_tool_errors_always_keep_the_panel_error_prefix(message):
    result = SimpleNamespace(content=[SimpleNamespace(type="text", text=message)], is_error=True)
    formatted = MCPManager._format_result(result)
    assert formatted.startswith("Error:")
    assert not formatted.startswith("Error: Error:")


def test_original_project_panel_works_while_another_chat_is_selected(panel):
    service, request, manager, runtime = panel
    selected = service.core.cwd
    response = call_extension_plugin_panel_tool(service, request)
    assert not response["is_error"], response
    context = json.loads(response["content"])["context"]["com.locus/panel"]
    assert context == {"version": 1, "workspace": request["workspace"],
                       "pluginId": request["plugin_id"], "panelId": "workflows", "digest": request["digest"]}
    assert manager.cwd == selected == service.core.cwd
    runtime._publish_tools()
    assert runtime.available_tools() == []  # The selected project's agent gains no tools.
    with pytest.raises(HTTPException) as rejected:
        call_extension_plugin_panel_tool(service, {**request, "workspace": selected})
    assert rejected.value.status_code == 409
    # A normal refresh may drop the connection; the original window reconnects.
    runtime.refresh()
    assert not call_extension_plugin_panel_tool(service, request)["is_error"]


def test_panel_context_validation_and_hidden_tool_isolation(panel):
    service, request, manager, runtime = panel
    for values, expected in [
        ({**request, "digest": "stale"}, 409),
        ({**request, "panel_id": "missing"}, 403),
        ({**request, "tool": "other_secret"}, 403),
        ({**request, "workspace": "relative"}, 422),
        ({key: value for key, value in request.items() if key != "digest"}, 422),
        ({**request, "arguments": {"text": "x" * (256 * 1024)}}, 413),
    ]:
        with pytest.raises(HTTPException) as rejected:
            call_extension_plugin_panel_tool(service, values)
        assert rejected.value.status_code == expected
    assert call_extension_plugin_panel_tool(service, {**request, "tool": "decide"})["content"].startswith("decided")
    assert not call_extension_plugin_panel_tool(service, request)["is_error"]  # Public tool remains allowed.


def test_legacy_panel_and_large_json_response(panel):
    service, request, manager, runtime = panel
    manager.set_plugin_enabled(request["plugin_id"], True, scope="global")
    legacy = {key: request[key] for key in ("plugin_id", "tool", "arguments")}
    response = call_extension_plugin_panel_tool(service, {**legacy, "arguments": {"size": 50_000}})
    assert not response["is_error"], response
    result = json.loads(response["content"])
    assert len(result["text"]) == 50_000
    assert not (result["context"] or {}).get("com.locus/panel")
    overflow = call_extension_plugin_panel_tool(service, {**request, "arguments": {"size": 1_000_001}})
    assert overflow["is_error"] and "exceeds the 1,000,000-character panel limit" in overflow["content"]
    assert "xxxx" not in overflow["content"]


def test_panel_revalidates_when_disabled_or_replaced_before_dispatch(panel, monkeypatch):
    service, request, manager, runtime = panel
    calls = []

    def dispatch(_server, _tool, _arguments, **options):
        assert options["server_resolver"]() is not None
        assert options["should_stop"]() is False
        manager.set_plugin_enabled(request["plugin_id"], False, scope="workspace", workspace=request["workspace"])
        assert options["server_resolver"]() is None
        assert options["should_stop"]() is True
        calls.append(True)
        return "Error: cancelled"

    monkeypatch.setattr(runtime, "call_tool", dispatch)
    assert call_extension_plugin_panel_tool(service, request)["is_error"]
    assert calls == [True]
    manager.set_plugin_enabled(request["plugin_id"], True, scope="workspace", workspace=request["workspace"])
    manager._plugin(request["plugin_id"])["digest"] = "replacement"
    with pytest.raises(HTTPException) as rejected:
        call_extension_plugin_panel_tool(service, request)
    assert rejected.value.status_code == 409


def test_disabling_plugin_cancels_an_in_flight_panel_call(panel, tmp_path):
    service, request, manager, _runtime = panel
    marker = tmp_path / "started"
    with ThreadPoolExecutor(max_workers=1) as executor:
        result = executor.submit(call_extension_plugin_panel_tool, service, {
            **request, "tool": "slow", "arguments": {"marker": str(marker)},
        })
        deadline = time.monotonic() + 10
        while not marker.exists() and not result.done() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert marker.exists(), result.result(timeout=1) if result.done() else "MCP did not dispatch"
        manager.set_plugin_enabled(request["plugin_id"], False, scope="workspace", workspace=request["workspace"])
        response = result.result(timeout=2)
        assert response["is_error"] and "cancelled" in response["content"]


@pytest.mark.parametrize("read_only, revoked", [(True, False), (False, False), (True, True)])
def test_retry_uses_captured_server_and_metadata_only_for_read_operations(tmp_path, read_only, revoked):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    runtime = MCPManager(manager)
    calls = []
    valid = True
    tool = {"name": "operation", "annotations": {"readOnlyHint": read_only, "idempotentHint": True}}
    server = {"id": "plugin:fixture:fixture", "tool_timeout_sec": 1}
    meta = {"com.locus/panel": {"workspace": "/original"}}

    class Client:
        async def call_tool(self, _name, _arguments, **kwargs):
            nonlocal valid
            calls.append(kwargs.get("meta"))
            if len(calls) == 1:
                if revoked:
                    valid = False
                raise RuntimeError("connection lost")
            return SimpleNamespace(content=[SimpleNamespace(type="text", text="ok")], is_error=False)

    async def connect(configuration):
        assert configuration is server
        runtime._clients[server["id"]] = {"client": Client(), "server": server, "tools": [tool]}

    async def disconnect(_identifier):
        runtime._clients.clear()

    runtime._connect = connect
    runtime._disconnect = disconnect
    runtime._register_resource_links = lambda *_args: None
    try:
        result = asyncio.run(runtime._call_tool(server["id"], "operation", {}, request_meta=meta,
                                                server_resolver=lambda: server if valid else None))
        if read_only and not revoked:
            assert result == "ok" and calls == [meta, meta]
        else:
            assert len(calls) == 1 and result.startswith("Error:")
            assert ("was not retried" in result) if not read_only else ("disabled" in result)
    finally:
        runtime.close()


def test_task_required_panel_tool_preserves_metadata_and_output_bound(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    runtime = MCPManager(manager)
    server = {"id": "plugin:fixture:fixture", "tool_timeout_sec": 1}
    tool = {"name": "operation", "server_id": server["id"], "task_support": "required"}
    metadata = {"com.locus/panel": {"workspace": "/original"}}

    class Session:
        async def send_request(self, request, _response_type, **_kwargs):
            if request.method == "tools/call":
                assert request.params.meta == metadata
                return SimpleNamespace(task=SimpleNamespace(task_id="task", status="completed", status_message=""))
            return SimpleNamespace(content=[SimpleNamespace(type="text", text="x" * 101)], is_error=False)

    async def connect(_server):
        runtime._clients[server["id"]] = {"client": SimpleNamespace(session=Session()),
                                           "server": server, "tools": [tool]}

    runtime._connect = connect
    runtime._register_resource_links = lambda *_args: None
    try:
        result = asyncio.run(runtime._call_tool(
            server["id"], "operation", {}, request_meta=metadata,
            server_resolver=lambda: server, output_limit=100, reject_output_overflow=True,
        ))
        assert result.startswith("Error:") and "100-character panel limit" in result
    finally:
        runtime.close()
