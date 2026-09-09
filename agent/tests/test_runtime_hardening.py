import asyncio
import threading
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from starlette.requests import Request

from ollama_code.runstore import RunStore
from ollama_code.runtime import RuntimeSupervisor


@pytest.fixture
def runtime(tmp_path):
    service = SimpleNamespace(run_store=RunStore(tmp_path / 'runs.sqlite3'))
    app = SimpleNamespace(state=SimpleNamespace(service=service))
    value = RuntimeSupervisor(app, tmp_path / 'private', port=1)
    app.state.runtime = value
    value.store.save_worker('worker', str(tmp_path), keep_running=True)
    return value


def test_native_claim_is_single_use_even_after_broker_disconnect(runtime):
    event = {'type': 'browser_action_request', 'request_id': 'click', 'tool': 'browser_click'}
    decision = runtime.store.decision('worker', event)
    with pytest.raises(ValueError):
        runtime.store.resolve(decision['id'], decision['fingerprint'], {})
    runtime.store.claim_native('worker', decision['id'], decision['fingerprint'])
    runtime.store.broker_left('worker')
    assert not runtime.store.decisions('worker')
    with pytest.raises(ValueError, match='already claimed'):
        runtime.store.claim_native('worker', decision['id'], decision['fingerprint'])
    assert runtime.store.decisions('worker', include_inflight=True)[0]['state'] == 'uncertain'
    # A late, correlated actual result may reconcile the original operation.
    runtime.store.resolve(decision['id'], decision['fingerprint'], {'result': {'text': 'Clicked'}})


def test_pause_is_persisted_but_controller_detach_does_not_change_it(runtime):
    from ollama_code.api.runtime import resume_runtime
    from ollama_code.api.runtime_deploy import pause_runtime
    request = SimpleNamespace(app=runtime.app)
    asyncio.run(pause_runtime(request))
    reconstructed = RuntimeSupervisor(runtime.app, runtime.root, port=1)
    assert reconstructed.paused
    resume_runtime(request)
    assert not RuntimeSupervisor(runtime.app, runtime.root, port=1).paused


def test_controller_http_disconnect_keeps_durable_admission(runtime):
    from ollama_code.api.runtime import proxy
    async def scenario():
        worker = SimpleNamespace(session_id='worker', active_command='', session_info={})
        runtime.workers['worker'] = worker
        began, release = asyncio.Event(), asyncio.Event()
        async def perform(*args, **kwargs):
            began.set()
            await release.wait()
            return {'ok': True}
        runtime.request = perform
        async def receive():
            return {'type': 'http.request', 'body': b'{}'}
        request = Request({'type': 'http', 'method': 'POST', 'app': runtime.app, 'path': '/', 'query_string': b'', 'headers': []}, receive)
        call = asyncio.create_task(proxy('worker', 'api/reusable-checks/propose', request))
        await began.wait()
        call.cancel()
        with pytest.raises(asyncio.CancelledError):
            await call
        assert worker.active_command
        assert len(runtime.store.commands('worker', 'sent')) == 1
        with pytest.raises(HTTPException) as error:
            await proxy('worker', 'api/reusable-checks/contracts/run/verify', request)
        assert error.value.status_code == 409
        release.set()
        await asyncio.gather(*runtime.controller_operations)
        assert not worker.active_command
        assert len(runtime.store.commands('worker', 'completed')) == 1
    asyncio.run(scenario())


def test_reviewing_interrupted_requests_never_requeues_them(runtime):
    from ollama_code.api.runtime import worker_update
    runtime.store.enqueue('worker', {'request_id': 'one', 'type': 'user_message', 'text': 'Original'})
    runtime.store.command_state('one', 'sent')
    runtime.store.interrupted('worker')
    request = SimpleNamespace(app=runtime.app)
    async def scenario():
        with pytest.raises(HTTPException):
            await worker_update('worker', request, {'action': 'resume'})
        with pytest.raises(HTTPException):
            await worker_update('worker', request, {'action': 'acknowledge_interruption', 'reviewed_command_ids': []})
        await worker_update('worker', request, {'action': 'acknowledge_interruption', 'reviewed_command_ids': ['one']})
        assert not runtime.store.commands('worker')
        assert runtime.store.commands('worker', 'abandoned')[0]['id'] == 'one'
    asyncio.run(scenario())


def test_wait_for_locus_removes_native_tools_and_waits_for_capability(tmp_path, monkeypatch):
    from ollama_code.chat_service import ChatService
    from ollama_code.core import AgentCore
    from ollama_code.server import _handle_client_message
    monkeypatch.setenv('LOCUS_RUNTIME_CHILD', '1')
    core = AgentCore(cwd=str(tmp_path), model='fixture')
    service = ChatService(core)
    events = []
    service.emit = events.append
    core.tool_registry.browser_enabled = True
    try:
        asyncio.run(_handle_client_message(service, {'type': 'runtime_desktop_disconnected', 'runtime_broker': True}))
        assert not core.tool_registry.browser_enabled
        assert 'wait_for_locus' in {s['function']['name'] for s in core.tool_registry.schemas()}
        output = []
        thread = threading.Thread(target=lambda: output.append(service.wait_for_locus({'capability': 'browser', 'reason': 'Inspect the completed page'})))
        thread.start()
        for _ in range(100):
            if events:
                break
            threading.Event().wait(.01)
        assert events[0]['type'] == 'runtime_waiting_for_locus'
        assert not output
        core.tool_registry.browser_enabled = True
        thread.join(2)
        assert output and events[-1]['type'] == 'runtime_capability_ready'
    finally:
        core.interrupt()
        core.mcp.close()
        service.close_codex()


def test_ollama_only_starts_on_loopback_addresses():
    from ollama_code.runtime_providers import RuntimeProviders
    assert RuntimeProviders.local_address('http://localhost:11434') == 'http://127.0.0.1:11434'
    for address in ['https://127.0.0.1:11434', 'http://server:11434', 'http://user:secret@127.0.0.1:11434', 'http://127.0.0.1:80', 'http://127.0.0.1/path']:
        with pytest.raises(ValueError):
            RuntimeProviders.local_address(address)


def test_remote_heartbeats_do_not_form_a_controller_relay_loop(runtime, monkeypatch):
    from ollama_code.api.runtime import heartbeat
    request = SimpleNamespace(app=runtime.app)
    calls = []
    monkeypatch.setattr(runtime.remotes, 'records', lambda: [{'id': 'remote'}])
    monkeypatch.setattr(runtime.remotes, 'request', lambda *args, **kwargs: calls.append(args))
    async def scenario():
        heartbeat(request, {'relayed': True})
        runtime.relay_controller_presence()
        assert not runtime.remote_heartbeats
        heartbeat(request, {})
        runtime.relay_controller_presence()
        await asyncio.gather(*runtime.remote_heartbeats.values())
        assert calls[0][-1] == {'relayed': True}
    asyncio.run(scenario())


def test_private_native_results_never_enter_decision_records(runtime):
    event = {'type': 'identity_context_request', 'request_id': 'private'}
    decision = runtime.store.decision('worker', event)
    runtime.store.claim_native('worker', decision['id'], decision['fingerprint'])
    runtime.store.resolve(decision['id'], decision['fingerprint'], {'type': 'identity_context_result', 'request_id': 'private', 'result': {'text': 'private-vault-content'}})
    with runtime.store.runs._connect(readonly=True) as db:
        response = db.execute('SELECT response FROM runtime_decisions WHERE id=?', (decision['id'],)).fetchone()[0]
    assert 'private-vault-content' not in response
    assert '[private result omitted]' in response


def test_replay_omits_decisions_that_already_have_an_authorized_response(runtime):
    event = {'type': 'permission_request', 'request_id': 'permission', 'tool': 'write_file'}
    decision = runtime.store.decision('worker', event)
    replay = {**event, 'runtime_decision': {'id': decision['id'], 'fingerprint': decision['fingerprint']}, 'runtime_seq': 7}
    assert runtime.restore_decision_event(replay)['type'] == 'permission_request'
    runtime.store.resolve(decision['id'], decision['fingerprint'], {'decision': 'once'})
    restored = runtime.restore_decision_event(replay)
    assert restored['type'] == 'runtime_cursor'
    assert restored['runtime_seq'] == 7
