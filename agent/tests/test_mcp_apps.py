"""Exercise real MCP Apps negotiation and revocation, not just a UI flag."""
from __future__ import annotations

import sys
from types import SimpleNamespace

import pytest
from jsonschema import ValidationError
from mcp.types import ReadResourceResult, TextResourceContents, Tool

from ollama_code.extensions import ExtensionError, ExtensionManager
from ollama_code.mcp_apps import (
    MAX_HTML,
    MIME,
    allowed_tool,
    call_app,
    open_app,
    resource_payload,
    ui_metadata,
)
from ollama_code.mcp_runtime import MCPManager
from ollama_code.tool_registry import ToolRegistry


@pytest.fixture
def app_core(tmp_path):
    script = tmp_path / 'app.py'
    script.write_text('''from mcp.server import MCPServer
from mcp.server.apps import Apps, ResourceCsp
from mcp.types import ToolAnnotations, CallToolResult, TextContent
apps=Apps()
@apps.tool(resource_uri="ui://fixture/app.html", annotations=ToolAnnotations(readOnlyHint=True))
def show(value: str) -> CallToolResult:
    return CallToolResult(content=[TextContent(type="text", text=value)], structuredContent={"value": value})
@apps.tool(resource_uri="ui://fixture/app.html", visibility=["app"], annotations=ToolAnnotations(readOnlyHint=False))
def edit(value: str) -> CallToolResult:
    return CallToolResult(content=[TextContent(type="text", text=value)], structuredContent={"value": value})
apps.add_html_resource("ui://fixture/app.html", "<!doctype html><p>Interactive fixture</p>", csp=ResourceCsp(resource_domains=["https://cdn.example.com"]))
MCPServer("fixture", extensions=[apps]).run("stdio")
''')
    manager = ExtensionManager(str(tmp_path), root=tmp_path / 'state')
    server = manager.upsert_mcp_server({'name': 'fixture', 'command': sys.executable, 'args': [str(script)]})
    events = []
    runtime = MCPManager(manager, emit=events.append)
    runtime.context_provider = lambda: {'session_id': 'session-one'}
    runtime.refresh(wait=True)
    registry = ToolRegistry(manager, runtime)
    registry.begin_turn('app test', str(tmp_path))
    core = SimpleNamespace(cwd=str(tmp_path), session=SimpleNamespace(session_id='session-one'),
                           agent_mode='work', extensions=manager, mcp=runtime, tool_registry=registry,
                           events=events, server_id=server['id'])
    try:
        yield core
    finally:
        runtime.close()


def test_real_mcp_app_resource_result_and_app_only_tool(app_core):
    core = app_core
    assert {t['name'] for t in core.mcp.available_tools()} == {'show'}
    assert 'hello' in core.mcp.call_tool(core.server_id, 'show', {'value': 'hello'}, invocation_context={'tool_call_id': 'call-one'})
    assert any(e.get('type') == 'mcp_app_available' and e['call_id'] == 'call-one' for e in core.events)
    doc = open_app(core, core.server_id, 'show', 'call-one')
    assert doc['input'] == {'value': 'hello'}
    assert doc['result']['structuredContent'] == {'value': 'hello'}
    assert doc['csp']['resourceDomains'] == ['https://cdn.example.com']
    with pytest.raises(ExtensionError, match='confirmation'):
        call_app(core, doc['id'], 'edit', {'value': 'new'}, False)
    with pytest.raises(ValidationError):
        call_app(core, doc['id'], 'edit', {'wrong': 'new'}, True)
    assert call_app(core, doc['id'], 'edit', {'value': 'new'}, True)['structuredContent'] == {'value': 'new'}
    # A different conversation cannot retrieve this conversation's tool payload.
    core.session.session_id = 'session-two'
    assert open_app(core, core.server_id, 'show', 'call-one')['result'] == {'content': []}
    with pytest.raises(ExtensionError, match='expired'):
        call_app(core, doc['id'], 'edit', {'value': 'bad'}, True)


def test_app_rechecks_capability_agent_and_durable_server_policy(app_core, monkeypatch):
    core = app_core
    doc = open_app(core, core.server_id, 'show')
    monkeypatch.setenv('LOCUS_CAPABILITY_MODERN_MCP', '0')
    with pytest.raises(ExtensionError, match='disabled'):
        allowed_tool(core, core.server_id, 'show')
    monkeypatch.delenv('LOCUS_CAPABILITY_MODERN_MCP')
    core.tool_registry.set_user_capability_policy({'mcp': False})
    with pytest.raises(ExtensionError, match='disabled'):
        allowed_tool(core, core.server_id, 'edit')
    core.tool_registry.set_user_capability_policy({})
    core.tool_registry.set_mcp_agent_policy({'server_ids': ['*'], 'tools': ['*']}, access_ceiling='read_only')
    assert allowed_tool(core, core.server_id, 'show')
    with pytest.raises(ExtensionError, match='read-only'):
        allowed_tool(core, core.server_id, 'edit')
    with pytest.raises(ExtensionError, match='expired'):
        call_app(core, doc['id'], 'edit', {'value': 'bad'}, True)
    core.tool_registry.set_mcp_agent_policy(None)
    # No runtime refresh: the old tool catalog must not outlive a policy save.
    server = next(s for s in core.extensions.mcp_servers() if s['id'] == core.server_id)
    core.extensions.upsert_mcp_server({**server, 'disabled_tools': ['edit']}, server_id=core.server_id)
    with pytest.raises(ExtensionError, match='revoked'):
        allowed_tool(core, core.server_id, 'edit')


def test_mcp_app_resource_mime_bounds_and_malformed_metadata():
    tool = Tool(name='test', inputSchema={}, _meta={'ui': {'visibility': [None, {}, 'app'], 'resourceUri': 'file:///secret'}})
    assert ui_metadata(tool) == {'resource_uri': None, 'visibility': ['app']}
    def payload(text, mime=MIME):
        return ReadResourceResult(contents=[TextResourceContents(uri='ui://fixture/app.html', text=text, mimeType=mime)])
    with pytest.raises(ExtensionError, match='supported'):
        resource_payload(payload('x', 'text/html'), 'ui://fixture/app.html')
    with pytest.raises(ExtensionError, match='2 MiB'):
        resource_payload(payload('x' * (MAX_HTML + 1)), 'ui://fixture/app.html')
