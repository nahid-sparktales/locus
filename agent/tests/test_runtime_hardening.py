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


def test_saved_agent_runtime_uses_profile_route_and_rejects_removed_profile(runtime, monkeypatch):
    import uuid
    from unittest.mock import AsyncMock

    from ollama_code.api.runtime import agent_profiles_update
    from ollama_code.runtime_automation import RuntimeAutomation
    from ollama_code.sessions import SessionMeta

    profile = {"id": str(uuid.uuid4()), "name": "Bob", "model": "exact-model", "role": "generalist",
               "instructions": "Review the event", "access_ceiling": "read_only",
               "timeout_seconds": 120, "token_limit": 8192}
    monkeypatch.setattr(SessionMeta, "get", lambda _: {"agent_profile_id": profile["id"],
                                                     "agent_world_profile_id": profile["id"]})
    runtime.ensure_worker = AsyncMock()
    queued = []
    runtime.enqueue = lambda session, command: queued.append(command)
    runtime.private.set("account:stale", {"provider": "remote", "model": "wrong-model"})
    request = SimpleNamespace(app=runtime.app)
    configuration = {"profile": profile, "provider": {"provider": "ollama", "host": "http://127.0.0.1:11434"}}
    assert agent_profiles_update(request, {"profiles": [configuration]}) == {"ok": True}
    run = {"id": "run", "session_id": "worker", "workspace_root": "/tmp", "request": "Check quote",
           "manifest": {"provider": "remote", "provider_account_id": "stale", "model": "wrong-model",
                        "workflow_outputs": [{"step_id": "quote", "result": "100"}]}}
    coordinator = RuntimeAutomation(runtime)
    asyncio.run(coordinator.queue_run(run))
    assert queued[0]["agent_profile"] == profile
    assert queued[0]["runtime_configuration"]["/api/provider"]["provider"] == "ollama"
    assert queued[0]["runtime_configuration"]["/api/config"] == {"model": "exact-model"}
    assert queued[0]["workflow_outputs"] == run["manifest"]["workflow_outputs"]
    queued.clear()
    agent_profiles_update(request, {"profiles": []})
    asyncio.run(coordinator.queue_run(run))
    assert not queued
    assert runtime.store.worker("worker")["state"] == "waiting_for_locus"
    agent_profiles_update(request, {"profiles": [configuration]})
    asyncio.run(coordinator.queue_run(run))
    assert len(queued) == 1
    queued.clear()
    agent_profiles_update(request, {"profiles": [{"profile": profile, "unavailable": "Account removed"}]})
    asyncio.run(coordinator.queue_run(run))
    assert not queued


def test_saved_agent_runtime_profile_snapshot_validates_before_replacing(runtime):
    from ollama_code.api.runtime import agent_profiles_update

    runtime.private.set("agent-profiles", {"existing": "unchanged"})
    with pytest.raises(HTTPException):
        agent_profiles_update(SimpleNamespace(app=runtime.app), {"profiles": [{"profile": {"id": "bad"}}]})
    assert runtime.private.read()["agent-profiles"] == {"existing": "unchanged"}


@pytest.mark.parametrize(("run_kind", "runner", "adaptive", "accepted"), [
    ("solo", "solo", True, True),
    ("solo", "solo", False, True),
    ("solo", "solo_swarm", True, True),  # Legacy spelling of the Solo runner.
    ("solo", "team", False, False),
    ("team", "solo", False, False),
    ("team", "team", True, False),
])
def test_headless_saved_agent_schedule_checks_runner_not_delegation_marker(
    runtime, monkeypatch, run_kind, runner, adaptive, accepted,
):
    import uuid
    from unittest.mock import AsyncMock

    from ollama_code.api.runtime import agent_profiles_update
    from ollama_code.runtime_automation import RuntimeAutomation
    from ollama_code.sessions import SessionMeta

    profile = {"id": str(uuid.uuid4()), "name": "Weather reader", "model": "default",
               "role": "generalist", "access_ceiling": "read_only",
               "behavior": {"capability_policy": {"network": True}}}
    provider = {"provider": "claude_plan", "account_id": "selected-account"}
    agent_profiles_update(SimpleNamespace(app=runtime.app), {
        "profiles": [{"profile": profile, "provider": provider}],
    })
    monkeypatch.setattr(SessionMeta, "get", lambda _: {"agent_world_profile_id": profile["id"]})
    runtime.ensure_worker = AsyncMock()
    # Exercise the durable background admission queue, with no native app or
    # worker/model execution. This is the manifest emitted for Solo schedules.
    assert not runtime.controller_seen
    runtime.store.state("worker", "waiting_for_locus", "Previously rejected")
    run = {"id": "scheduled-run", "session_id": "worker", "workspace_root": "/tmp",
           "request": "Get the current temperature", "run_kind": run_kind,
           "manifest": {"scheduled": True, "schedule_id": "schedule", "mode": "work",
                        "runner": runner, "solo_swarm": adaptive, "provider": "claude_plan",
                        "model": "stale-model", "provider_account_id": "stale-account"}}
    asyncio.run(RuntimeAutomation(runtime).queue_run(run, keep_running=True))
    runtime.ensure_worker.assert_awaited_once_with("worker", "/tmp", keep_running=True)
    commands = runtime.store.commands("worker")
    assert len(commands) == int(accepted)
    if not accepted:
        worker = runtime.store.worker("worker")
        assert worker["state"] == "waiting_for_locus"
        assert "requires its solo runner" in worker["waiting_reason"]
        return
    command = runtime.private.read()["command:scheduled-run"]
    assert command["agent_profile"] == profile
    assert command["runtime_configuration"]["/api/provider"] == provider
    assert command["runtime_configuration"]["/api/config"] == {"model": "default"}
    assert "team" not in command
    assert command.get("solo_swarm") == ({"enabled": True} if adaptive else None)
    assert runtime.store.worker("worker")["state"] == "idle"


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


@pytest.mark.parametrize("path", ["api/reusable-checks/propose", "api/sessions/worker/task/restore", "api/sessions/worker/task/checks"])
def test_controller_http_disconnect_keeps_durable_admission(runtime, path):
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
        call = asyncio.create_task(proxy('worker', path, request))
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


def test_desktop_disconnect_resets_every_native_broker_and_wait_accepts_them(tmp_path, monkeypatch):
    from ollama_code.chat_service import ChatService
    from ollama_code.core import AgentCore
    from ollama_code.server import _handle_client_message
    monkeypatch.setenv('LOCUS_RUNTIME_CHILD', '1')
    core = AgentCore(cwd=str(tmp_path), model='fixture')
    service = ChatService(core)
    events = []
    service.emit = events.append
    capabilities = ('notes', 'calendar', 'board')
    try:
        for capability in capabilities:
            setattr(core.tool_registry, capability + '_enabled', True)
        asyncio.run(_handle_client_message(service, {'type': 'runtime_desktop_disconnected', 'runtime_broker': True}))
        for capability in capabilities:
            assert getattr(core.tool_registry, capability + '_enabled') is False
        wait = next(s for s in core.tool_registry.schemas() if s['function']['name'] == 'wait_for_locus')
        assert {'calendar', 'board'} <= set(wait['function']['parameters']['properties']['capability']['enum'])
        parity_wait = next(s for s in core.tool_registry.parity_schemas() if s['function']['name'] == 'wait_for_locus')
        assert {'calendar', 'board'} <= set(parity_wait['function']['parameters']['properties']['capability']['enum'])
        for capability in ('calendar', 'board'):
            setattr(core.tool_registry, capability + '_enabled', True)
            assert service.wait_for_locus({'capability': capability, 'reason': 'Update the card'}).startswith('The desktop capability is available')
        output = []
        thread = threading.Thread(target=lambda: output.append(service.wait_for_locus({'capability': 'board', 'reason': 'Move the card to Review'})))
        core.tool_registry.board_enabled = False
        thread.start()
        for _ in range(100):
            if events:
                break
            threading.Event().wait(.01)
        assert events[0] == {'type': 'runtime_waiting_for_locus', 'capability': 'board', 'reason': 'Move the card to Review'}
        asyncio.run(_handle_client_message(service, {'type': 'set_board_control', 'enabled': True, 'runtime_broker': True}))
        thread.join(2)
        assert output and output[0].startswith('Locus reconnected')
        assert core.board_executor == service.execute_board
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
