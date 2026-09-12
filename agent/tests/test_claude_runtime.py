"""Claude subscription contract tests: no network or paid model calls."""
import asyncio
from types import SimpleNamespace

import pytest

from ollama_code import claude_runtime as runtime
from ollama_code.api import claude
from ollama_code.capabilities import enabled
from ollama_code.core import AgentCore
from ollama_code.orchestration import AgentProfile, _validate_route
from ollama_code.schedules import SCHEDULE_PROVIDERS


def msg(kind, **fields):
    return type(kind, (), {})(**{}) if not fields else type(kind, (), fields)()


@pytest.fixture
def manager(monkeypatch, tmp_path):
    monkeypatch.setattr(runtime, 'APP_DIR', tmp_path)
    value = runtime.ClaudeManager('account-a')
    monkeypatch.setattr(value, '_ready', lambda: None)
    return value


@pytest.fixture
def sdk(monkeypatch):
    import claude_agent_sdk
    captured = SimpleNamespace(options=[], prompts=[], calls=[], resume=[], interrupt=0,
                               response=[], tool_reply=None, tool_input={'path': 'README.md'}, fail=False, result_error=False)

    class Client:
        def __init__(self, *, options):
            captured.options.append(options)
            self.options = options

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_):
            return False

        async def query(self, prompt):
            captured.prompts.append([item async for item in prompt])

        async def get_server_info(self):
            return {'models': [{'value': 'entitled-model', 'displayName': 'Entitled model'}]}

        async def interrupt(self):
            captured.interrupt += 1

        async def receive_response(self):
            if captured.fail:
                raise RuntimeError('transport closed')
            yield msg('SystemMessage', subtype='init', data={'session_id': 'sdk-session'})
            if captured.calls:
                captured.tool_reply = await captured.calls[0].handler(captured.tool_input)
            for value in captured.response:
                yield value
            yield msg('ResultMessage', session_id='sdk-session', usage={'input_tokens': 5,
                      'cache_read_input_tokens': 3, 'output_tokens': 2}, is_error=captured.result_error,
                      errors=[], structured_output=None)

    def server(*, name, tools):
        captured.calls = tools
        return {'type': 'sdk', 'name': name, 'instance': object()}
    monkeypatch.setattr(claude_agent_sdk, 'ClaudeSDKClient', Client)
    monkeypatch.setattr(claude_agent_sdk, 'create_sdk_mcp_server', server)
    return captured


def test_public_capability_is_on_by_default_and_can_be_disabled(monkeypatch):
    monkeypatch.delenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', raising=False)
    assert enabled('claude_plan_v1')
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '0')
    assert not enabled('claude_plan_v1')


@pytest.mark.parametrize('identifier', ['', '../escape', '/tmp/home', '.hidden', 'a/b', None])
def test_account_ids_cannot_escape_home(identifier):
    with pytest.raises(ValueError):
        runtime.claude_home_for_account(identifier)


def test_environment_overrides_sdk_inheritance(monkeypatch, tmp_path):
    for key in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
                'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'LOCUS_CODEX_BROKER_TOKEN'):
        monkeypatch.setenv(key, 'must-not-reach-sdk')
    env = runtime.subscription_environment(tmp_path)
    assert env['CLAUDE_CONFIG_DIR'] == str(tmp_path)
    assert all(value != 'must-not-reach-sdk' for value in env.values())
    assert env['ANTHROPIC_API_KEY'] == ''
    assert env['CLAUDE_CODE_USE_BEDROCK'] == ''


def test_account_rejects_console_billing(manager, monkeypatch):
    monkeypatch.setattr(manager, '_auth', lambda _: {'loggedIn': True, 'authMethod': 'api_key'})
    assert manager.account()['account'] is None
    monkeypatch.setattr(manager, '_auth', lambda _: {'loggedIn': True, 'authMethod': 'claude.ai', 'email': 'person@example.com'})
    assert manager.account()['account']['type'] == 'claude_plan'


def test_logout_and_auth_refresh_stay_in_selected_account(manager, monkeypatch):
    other = runtime.ClaudeManager('account-b')
    calls = []
    def command(args, **kwargs):
        calls.append((args, kwargs['env']['CLAUDE_CONFIG_DIR']))
        return SimpleNamespace(returncode=0, stdout='{"loggedIn": false}')
    monkeypatch.setattr(runtime.subprocess, 'run', command)
    manager.logout()
    assert manager.account()['account'] is None
    assert [call[0][-1] for call in calls] == ['logout', 'status']
    assert all(call[1] == str(manager.home) for call in calls)
    assert not other.home.exists()


def test_cancel_login_terminates_only_selected_attempt(manager):
    stopped = []
    process = SimpleNamespace(poll=lambda: None, terminate=lambda: stopped.append('terminate'),
                              wait=lambda **_: stopped.append('wait'))
    manager._login = ('selected', process)
    with pytest.raises(runtime.ClaudeRuntimeError, match='Unknown'):
        manager.cancel_login('another')
    assert not stopped
    manager.cancel_login('selected')
    assert stopped == ['terminate', 'wait']
    assert manager._login is None


def test_auth_timeout_is_actionable_and_retryable(manager, monkeypatch):
    def timeout(*args, **kwargs):
        raise runtime.subprocess.TimeoutExpired('claude', 30)
    monkeypatch.setattr(runtime.subprocess, 'run', timeout)
    with pytest.raises(runtime.ClaudeRuntimeError, match='Refresh the account'):
        manager.account()
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *_, **__: SimpleNamespace(returncode=0,
        stdout='{"loggedIn": true, "authMethod": "claude.ai"}'))
    assert manager.account()['account']['type'] == 'claude_plan'


@pytest.mark.parametrize(('error', 'guidance'), [('authentication_failed', 'sign in again'),
                                                ('rate_limit', 'limit resets')])
def test_runtime_account_errors_provide_recovery_guidance(manager, sdk, error, guidance):
    sdk.result_error = True
    sdk.response = [msg('AssistantMessage', content=[], error=error)]
    notifications = []
    manager.add_listener(notifications.append)
    thread = manager.start_thread(model='default', cwd='/workspace')
    result = manager.run_turn(thread_id=thread, text='hello')
    assert result['status'] == 'failed'
    assert guidance in result['error']['message']
    assert notifications[0]['params']['account_id'] == 'account-a'
    if error == 'rate_limit':
        assert manager.usage()['status'] == 'rejected'
        assert manager.usage().get('utilization') is None


def test_locus_tools_and_images_use_sdk_with_no_native_tools(manager, sdk):
    schema = {'type': 'function', 'function': {'name': 'read_file', 'description': 'Read',
              'parameters': {'type': 'object', 'properties': {'path': {'type': 'string'}}}}}
    thread = manager.start_thread(model='default', cwd='/workspace', base_instructions='Locus instructions', tools=[schema])
    calls = []
    manager.run_turn(thread_id=thread, text='read', tool_handler=lambda *args: calls.append(args) or 'contents',
        input_items=[{'type': 'text', 'text': 'read'}, {'type': 'image', 'url': 'data:image/png;base64,YQ=='}])
    options = sdk.options[-1]
    assert options.tools == []
    assert options.setting_sources == [] and options.strict_mcp_config
    assert options.allowed_tools == ['mcp__locus__read_file']
    assert options.model is None
    assert options.system_prompt == 'Locus instructions'
    assert asyncio.run(options.can_use_tool('Bash', {}, None)).behavior == 'deny'
    assert calls[0][0:2] == ('read_file', {'path': 'README.md'})
    assert sdk.tool_reply['content'][0]['text'] == 'contents'
    assert sdk.prompts[0][0]['message']['content'][1]['source']['media_type'] == 'image/png'


def test_streaming_and_complete_messages_are_not_duplicated(manager, sdk):
    sdk.response = [
        msg('StreamEvent', event={'type': 'message_start', 'message': {'id': 'm'}}),
        msg('StreamEvent', event={'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text'}}),
        msg('StreamEvent', event={'type': 'content_block_delta', 'index': 0, 'delta': {'text': 'Hello'}}),
        msg('AssistantMessage', content=[msg('TextBlock', text='Hello')]),
    ]
    thread = manager.start_thread(model='default', cwd='/workspace')
    events = []
    manager.run_turn(thread_id=thread, text='hi', event_handler=events.append, client_message_id='delivery')
    assert [e['params']['delta'] for e in events if e['method'] == 'item/agentMessage/delta'] == ['Hello']
    assert manager.read_thread(thread)['thread']['turns'][0]['items'][0]['clientId'] == 'delivery'
    manager.run_turn(thread_id=thread, text='follow up', event_handler=events.append)
    assert sdk.options[-1].resume == 'sdk-session'
    assert manager._load(thread)['input'] == 16


def test_model_discovery_never_uses_api_catalog(manager, sdk):
    assert manager.models()[0]['model'] == 'entitled-model'


def test_uncertain_turn_is_never_replayed(manager, sdk):
    sdk.fail = True
    thread = manager.start_thread(model='default', cwd='/workspace')
    with pytest.raises(runtime.ClaudeRuntimeError, match='transport closed'):
        manager.run_turn(thread_id=thread, text='edit')
    sdk.fail = False
    with pytest.raises(runtime.ClaudeRuntimeError, match='uncertain'):
        manager.resume_thread(thread, model='default', cwd='/workspace')
    with pytest.raises(runtime.ClaudeRuntimeError, match='uncertain'):
        manager.run_turn(thread_id=thread, text='retry')
    assert len(sdk.options) == 1


def test_sessions_cannot_cross_accounts(manager):
    thread = manager.start_thread(model='default', cwd='/workspace')
    other = runtime.ClaudeManager('account-b')
    with pytest.raises(runtime.ClaudeRuntimeError, match='unavailable'):
        other.resume_thread(thread, model='default', cwd='/workspace')
    assert manager.home != other.home


def test_unknown_usage_is_not_zero(manager, monkeypatch):
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '1')
    monkeypatch.setattr(claude, 'account_payload', lambda *_: {'status': 'signed_in'})
    service = SimpleNamespace(claude_for=lambda _: manager)
    result = claude.usage(service, 'account-a')
    assert result['observed_at'] is None
    assert result['rate_limits']['rateLimits']['primary'] is None


def test_selection_is_atomic_and_keeps_api_accounts_separate(manager, monkeypatch, tmp_path):
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '1')
    core = AgentCore(cwd=str(tmp_path), config={'provider': 'ollama', 'model': 'local'})
    monkeypatch.setattr(manager, 'account', lambda: {'account': None})
    with pytest.raises(ValueError, match='Sign in'):
        core.use_claude_plan(account_id='account-a', model='default', account_label='Claude', manager=manager)
    assert core.provider == 'ollama'
    monkeypatch.setattr(manager, 'account', lambda: {'account': {'type': 'claude_plan'}})
    core.use_claude_plan(account_id='account-a', model='default', account_label='Claude', manager=manager)
    assert core.provider == 'claude_plan' and core.account_id == 'account-a'
    assert not core.chatgpt_parity_active(True)
    assert core.config['remote_api_key'] == ''
    assert core.ensure_model() is None


def test_scheduled_and_team_routes_are_subscription_only():
    assert 'claude_plan' in SCHEDULE_PROVIDERS
    route = {'provider': 'claude_plan', 'account_id': 'account-a'}
    _validate_route(route, 'Claude')
    profile = AgentProfile.parse({'id': 'a', 'name': 'Claude', 'model': 'default', 'route': route, 'metering': 'metered'})
    assert profile.metering == 'self_hosted'
    assert profile.input_cost_per_million == profile.output_cost_per_million == 0
    with pytest.raises(Exception, match='credentials'):
        _validate_route({**route, 'api_key': 'not-allowed'}, 'Claude')


def test_no_tools_mode_and_interruption(manager, sdk):
    thread = manager.start_thread(model='default', cwd='/workspace')
    manager.run_turn(thread_id=thread, text='hello')
    assert sdk.options[-1].mcp_servers == {}
    assert sdk.options[-1].allowed_tools == []
    sdk.prompts.clear()
    stopped = manager.run_turn(thread_id=thread, text='hello', should_interrupt=lambda: True)
    assert stopped['status'] == 'interrupted'
    assert not sdk.prompts
    assert not manager._load(thread)['uncertain']


def test_invalid_image_is_rejected_before_query(manager, sdk):
    thread = manager.start_thread(model='default', cwd='/workspace')
    with pytest.raises(runtime.ClaudeRuntimeError, match='validated image'):
        manager.run_turn(thread_id=thread, text='read', input_items=[{'type': 'image', 'url': 'https://example.com/image.png'}])
    assert not sdk.prompts
    assert not manager._load(thread)['uncertain']


def test_tool_failure_returns_an_error_without_reexecution(manager, sdk):
    thread = manager.start_thread(model='default', cwd='/workspace', tools=[{
        'name': 'read_file', 'parameters': {'type': 'object', 'properties': {}}}])
    calls = []
    def fail(*args):
        calls.append(args)
        raise ValueError('not permitted')
    manager.run_turn(thread_id=thread, text='read', tool_handler=fail)
    assert len(calls) == 1
    assert sdk.tool_reply['isError']


def test_subscription_routes_reject_secrets_and_disabled_capability(monkeypatch):
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as error:
        claude.select_claude(SimpleNamespace(), {'account_id': 'a', 'api_key': 'secret'})
    assert error.value.status_code == 422
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '0')
    with pytest.raises(HTTPException) as error:
        claude.manager_for(SimpleNamespace(), 'a')
    assert error.value.status_code == 404


def test_broker_pins_the_claude_account_without_changing_chatgpt():
    broker = runtime.ClaudeBrokerClient('ws://localhost/ws/internal/codex', 'fixture')
    first, second = broker.for_account('one'), broker.for_account('two')
    assert first._request('account')['claude_account_id'] == 'one'
    assert second._request('account')['claude_account_id'] == 'two'
    assert first._request('turn_run')['provider'] == 'claude_plan'
    assert broker._home_id is None


def test_claude_task_keeps_plan_permission_checks(manager, sdk, monkeypatch, tmp_path):
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '1')
    monkeypatch.setattr(manager, 'account', lambda: {'account': {'type': 'claude_plan'}})
    core = AgentCore(cwd=str(tmp_path), config={'provider': 'ollama', 'model': 'local', 'agent_mode': 'plan'})
    core.use_claude_plan(account_id='account-a', model='default', account_label='Claude', manager=manager)
    core.agent_mode = 'plan'
    sdk.tool_input = {'path': 'README.md', 'content': 'must not be written'}
    writes = []
    results = []
    core.tool_registry.schemas = lambda: [{'type': 'function', 'function': {'name': 'write_file', 'description': 'write',
        'parameters': {'type': 'object', 'properties': {'path': {'type': 'string'}}}}}]
    # The adapter must call the very same permission boundary as other providers.
    original = core._run_tool_call
    def record(call, decider):
        writes.append(call.name)
        result = original(call, decider)
        results.append(result)
        return result
    monkeypatch.setattr(core, '_run_tool_call', record)
    core.run_turn('Inspect only', lambda *_: 'once')
    assert writes == ['write_file']
    assert 'Plan mode' in results[0]
    assert not (tmp_path / 'README.md').exists()
    assert core.provider == 'claude_plan'


def test_disabled_saved_claude_route_does_not_break_backend_health(monkeypatch):
    from ollama_code.api.system import health
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '0')
    service = SimpleNamespace(core=SimpleNamespace(provider='claude_plan', account_id='account-a', host='claude_plan://managed', model='default'))
    state = health(service)
    assert state['ok'] is True
    assert state['ollama'] is False
    assert 'not enabled' in state['error']


def test_swarm_keeps_selected_claude_transport(manager, monkeypatch, tmp_path):
    from ollama_code.solo_swarm import snapshot_route
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '1')
    monkeypatch.setattr(manager, 'account', lambda: {'account': {'type': 'claude_plan'}})
    core = AgentCore(cwd=str(tmp_path), config={'provider': 'ollama', 'model': 'local'})
    core.use_claude_plan(account_id='account-a', model='default', account_label='Claude', manager=manager)
    route = snapshot_route(core, core.codex_manager)
    assert route.provider == 'claude_plan'
    assert route.client is manager
    assert not route.native_web_search


def test_compaction_uses_claude_without_task_tools(manager, sdk, monkeypatch, tmp_path):
    from claude_agent_sdk import TextBlock

    from ollama_code.context_preservation import summarize_section
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '1')
    monkeypatch.setattr(manager, 'account', lambda: {'account': {'type': 'claude_plan'}})
    core = AgentCore(cwd=str(tmp_path), config={'provider': 'ollama', 'model': 'local'})
    core.use_claude_plan(account_id='account-a', model='default', account_label='Claude', manager=manager)
    sdk.response = [msg('AssistantMessage', content=[TextBlock(text='Preserved decisions and constraints')])]
    response = summarize_section(core, [{'role': 'system', 'content': 'Summarize'},
                                         {'role': 'user', 'content': 'Prior history'}])
    assert response.content == 'Preserved decisions and constraints'
    assert response.prompt_eval_count == 8
    assert sdk.options[-1].tools == []
    assert sdk.options[-1].mcp_servers == {}


def test_fork_does_not_share_claude_runtime_session(manager, sdk, monkeypatch, tmp_path):
    from claude_agent_sdk import TextBlock
    monkeypatch.setenv('LOCUS_CAPABILITY_CLAUDE_PLAN_V1', '1')
    monkeypatch.setattr(manager, 'account', lambda: {'account': {'type': 'claude_plan'}})
    core = AgentCore(cwd=str(tmp_path), config={'provider': 'ollama', 'model': 'local'})
    core.use_claude_plan(account_id='account-a', model='default', account_label='Claude', manager=manager)
    sdk.response = [msg('AssistantMessage', content=[TextBlock(text='Answer')])]
    core.run_turn('First question', allow_tools=False)
    original = core._chatgpt_thread_id
    core.session = core._new_session_store()
    core.run_turn('Follow-up in a fork', allow_tools=False)
    assert core._chatgpt_thread_id != original
    assert sdk.options[-1].resume is None
