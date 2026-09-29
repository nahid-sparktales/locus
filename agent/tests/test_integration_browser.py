"""Portable install, per-account ChatGPT apps, and Google adapters."""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import pytest

from ollama_code import chatgpt_apps
from ollama_code.codex_app_server import (
    CodexAppServerError,
    CodexAppServerManager,
    CodexThreadOptions,
)
from ollama_code.extensions import ExtensionManager, parse_plugin
from ollama_code.google_workspace_mcp import GoogleWorkspace, segment
from ollama_code.mcp_runtime import MCPManager


def portable(root):
    root.mkdir(parents=True)
    (root / 'plugin.json').write_text(json.dumps({
        '$schema': 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
        'name': 'portable', 'description': 'A portable fixture', 'version': '1.0.0',
        'extensions': {'com.openai': {'name': 'wrong', 'skills': '../escape',
                                    'mcpServers': '../escape.json', 'interface': {'displayName': 'Portable UI'}}},
    }))
    (root / 'mcp.json').write_text(json.dumps({'mcpServers': {'portable': {'url': 'https://example.com/mcp'}}}))
    skill = root / 'skills' / 'fixture'
    skill.mkdir(parents=True)
    (skill / 'SKILL.md').write_text('---\nname: fixture\ndescription: Portable skill\n---\nUse this skill.')
    return root


def test_portable_install_and_restart_preserve_components(tmp_path):
    market = tmp_path / 'market'
    plugin = portable(market / 'plugins/portable')
    parsed = parse_plugin(plugin)
    assert parsed['name'] == 'portable'
    assert parsed['display_name'] == 'Portable UI'
    assert parsed['skills'][0]['name'] == 'fixture'
    assert parsed['mcp_servers'][0]['url'] == 'https://example.com/mcp'
    directory = market / '.agents/plugins'
    directory.mkdir(parents=True)
    (directory / 'marketplace.json').write_text(json.dumps({'name': 'Portable fixture', 'plugins': [
        {'name': 'portable', 'source': {'source': 'local', 'path': './plugins/portable'}}]}))
    manager = ExtensionManager(str(tmp_path), root=tmp_path / 'state')
    source = manager.add_marketplace(str(market))
    trust = manager.inspect_catalog_plugin(source['id'], 'portable')
    installed = manager.install_plugin(source['id'], 'portable', expected_digest=trust['digest'])
    reloaded = ExtensionManager(str(tmp_path), root=tmp_path / 'state')
    assert any(p['id'] == installed['id'] for p in reloaded.snapshot()["plugins"])
    assert any(s['name'] == 'fixture' for s in reloaded.skills())


class AppsManager:
    available = True
    def __init__(self, home):
        self.codex_home = home
        self.calls = []
        self.pages = [{'data': [{'id': 'calendar', 'name': 'Calendar', 'isAccessible': True,
                       'logoUrl': 'javascript:bad', 'installUrl': 'https://evil.com/connect'}], 'nextCursor': 'next'},
                      {'data': [{'id': 'drive', 'name': 'Drive', 'isAccessible': False,
                       'installUrl': 'https://chatgpt.com/apps/drive'}]}]
    def account(self):
        return {'account': {'type': 'chatgpt'}}
    def request(self, method, params):
        self.calls.append((method, params))
        if method == 'app/list':
            return self.pages[bool(params.get('cursor'))]
        if method == 'app/installed':
            return {'apps': [{'id': 'calendar', 'enabled': True, 'callable': True}]}
        return {}


def test_chatgpt_catalog_paginates_filters_links_and_scopes_selection(tmp_path):
    manager = AppsManager(tmp_path / 'account-one')
    result = chatgpt_apps.catalog(manager)
    assert [app['id'] for app in result['apps']] == ['calendar', 'drive']
    assert result['apps'][0]['logo_url'] is None and result['apps'][0]['install_url'] is None
    assert result['apps'][0]['callable'] is True
    chatgpt_apps.set_enabled(manager, 'calendar', True)
    assert chatgpt_apps.selected_apps(manager.codex_home) == ['calendar']
    assert chatgpt_apps.selected_apps(tmp_path / 'account-two') == []
    config = next(params for method, params in manager.calls if method == 'config/batchWrite')
    assert config['edits'][1]['value']['_default'] == {'enabled': False}
    assert config['edits'][1]['value']['calendar']['default_tools_approval_mode'] == 'prompt'
    with pytest.raises(ValueError, match='Connect'):
        chatgpt_apps.set_enabled(manager, 'drive', True)
    chatgpt_apps.set_enabled(manager, 'calendar', False)
    assert chatgpt_apps.selected_apps(manager.codex_home) == []


def test_chatgpt_catalog_signed_out_and_repeated_cursor(tmp_path):
    manager = AppsManager(tmp_path)
    manager.account = lambda: {'account': None}
    assert chatgpt_apps.catalog(manager)['status'] == 'signed_out'
    assert manager.calls == []
    manager.account = lambda: {'account': {'type': 'chatgpt'}}
    manager.pages[1]['nextCursor'] = 'next'
    with pytest.raises(CodexAppServerError, match='repeated'):
        chatgpt_apps.catalog(manager)


def test_chatgpt_apps_never_remember_approval_or_accept_arbitrary_questions():
    def question(identifier):
        return {'id': identifier, 'options': [{'label': label} for label in
                  ['Allow', 'Allow for this session', "Allow and don't ask me again", 'Cancel']]}
    params = {'questions': [question('mcp_tool_call_approval_123'), question('random')]}
    assert chatgpt_apps.approval_answers(params, True) == {'answers': {
        'mcp_tool_call_approval_123': {'answers': ['Allow']}, 'random': {'answers': ['Cancel']}}}
    assert chatgpt_apps.approval_answers(params, False)['answers']['mcp_tool_call_approval_123'] == {'answers': ['Cancel']}


def test_chatgpt_saved_app_policy_survives_home_rewrite(tmp_path):
    (tmp_path / 'locus-apps.json').write_text('["calendar"]')
    manager = CodexAppServerManager(codex_home=tmp_path, helper_path='/unused')
    manager._prepare_home()
    import tomllib
    config = tomllib.loads((tmp_path / 'config.toml').read_text())
    assert config['apps']['calendar']['approvals_reviewer'] == 'user'
    assert config['apps']['_default']['enabled'] is False
    assert config['features']['tool_call_mcp_elicitation'] is False
    options = CodexThreadOptions(app_ids=('calendar',))
    assert manager.thread_config(options)['apps']['calendar']['default_tools_approval_mode'] == 'prompt'
    assert manager.thread_config()['features']['apps'] is False


@pytest.mark.parametrize('kind, expected', [('calendar', {'list_calendars', 'list_events', 'get_event', 'create_event', 'update_event', 'delete_event'}),
                                           ('drive', {'search_files', 'read_file'})])
def test_bundled_google_adapters_use_real_stdio_without_signin(tmp_path, kind, expected):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / 'state')
    server = manager.materialize_mcp_preset('google-' + kind)
    assert server['enabled_global'] is False
    assert server['command'] == sys.executable
    assert Path(server['args'][0]).is_file()
    assert manager.materialize_mcp_preset('google-' + kind)['id'] == server['id']
    manager.upsert_mcp_server({**server, 'enabled_global': True}, server_id=server['id'])
    runtime = MCPManager(manager)
    try:
        runtime.refresh(wait=True)
        tools = runtime.available_tools()
        assert {tool['name'] for tool in tools} == expected
        for tool in tools:
            assert tool['annotations']['readOnlyHint'] == (not tool['name'].startswith(('create', 'update', 'delete')))
        read = 'list_calendars' if kind == 'calendar' else 'search_files'
        assert 'Connect your Google account' in runtime.call_tool(server['id'], read, {})
    finally:
        runtime.close()


def test_google_refresh_path_and_no_redirect_or_write_retry():
    calls = []
    class Response:
        status_code = 200
        def json(self): return {'access_token': 'fresh', 'expires_in': 3600}
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def iter_content(self, size): yield b'{"items":[]}'
    class HTTP:
        def post(self, url, **kwargs):
            calls.append(('refresh', url, kwargs))
            return Response()
        def request(self, method, url, **kwargs):
            calls.append((method, url, kwargs))
            return Response()
    google = GoogleWorkspace({'refresh_token': 'fixture', 'client_id': 'fixture'}, HTTP())
    assert google.request('GET', 'calendar/v3/users/me/calendarList', params={'pageToken': ''}) == {'items': []}
    assert calls[0][1] == 'https://oauth2.googleapis.com/token'
    assert calls[1][2]['headers'] == {'Authorization': 'Bearer fresh'}
    assert calls[1][2]['params'] == {}
    assert all(call[2]['allow_redirects'] is False for call in calls)
    assert segment('name@example.com/a') == 'name%40example.com%2Fa'
    with pytest.raises(ValueError):
        segment('..')
    with pytest.raises(ValueError):
        google.request('GET', 'https://evil.com/')
    google.http.request = lambda *a, **k: (_ for _ in ()).throw(ConnectionError('uncertain write'))
    with pytest.raises(ConnectionError):
        google.request('POST', 'calendar/v3/calendars/primary/events')
    assert google.credentials['access_token'] == 'fresh'
    assert float(google.credentials['expires_at']) > time.time()
