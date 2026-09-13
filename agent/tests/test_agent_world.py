"""World conversations preserve exact profiles and the ordinary session lifecycle."""
from __future__ import annotations

import asyncio
import uuid
from concurrent.futures import Future

import pytest
from fastapi.testclient import TestClient

from ollama_code import server
from ollama_code.agent_profile_runtime import (
    bounded_profile_configuration,
    parse_solo_profile,
    solo_profile_boundary,
)
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.sessions import SessionMeta, SessionStore


def _profile(**changes):
    return {
        "id": str(uuid.uuid4()), "name": "Reviewer", "model": "fixture",
        "role": "reviewer", "instructions": "Inspect the changed behavior.",
        "access_ceiling": "read_only", "timeout_seconds": 120, "token_limit": 8_192,
        **changes,
    }


def _service(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    return ChatService(core)


def test_detached_session_is_durable_without_disturbing_busy_foreground(tmp_path):
    service = _service(tmp_path)
    previous = service.core.session.session_id
    previous_messages = list(service.core.messages)
    service.agent_future = Future()
    workspace = tmp_path / "project"
    workspace.mkdir()
    profile_id = str(uuid.uuid4())
    with TestClient(server.create_app(chat_service=service)) as client:
        response = client.post("/api/sessions/detached", json={
            "cwd": str(workspace), "title": "Agent World · Reviewer", "agent_profile_id": profile_id,
        })
        assert response.status_code == 200
        session_id = response.json()["session_id"]
        assert session_id != previous
        assert SessionStore.path_for(session_id).is_file()
        metadata = SessionMeta.get(session_id)
        assert metadata["workspace_root"] == str(workspace.resolve())
        assert metadata["agent_profile_id"] == profile_id
        assert metadata["agent_world_profile_id"] == profile_id
        assert metadata["title"] == "Agent World · Reviewer"
        assert service.core.session.session_id == previous
        assert service.core.messages == previous_messages
        assert service.core.cwd == str(tmp_path)
        assert client.get(f"/api/sessions/{session_id}").status_code == 200
        assert client.get(f"/api/sessions/{session_id}").json()["agent_profile_id"] == profile_id
        saved = next(item for item in SessionStore.summaries() if item["id"] == session_id)
        assert saved["agent_profile_id"] == profile_id
        assert saved["title"] == "Agent World · Reviewer"
    service.agent_future.cancel()


@pytest.mark.parametrize("fields", [
    {"cwd": "missing"}, {"title": ""}, {"title": "x" * 121},
    {"agent_profile_id": "not-a-profile"}, {"agent_profile_id": 5},
])
def test_detached_session_rejects_invalid_binding(tmp_path, fields):
    service = _service(tmp_path)
    before = SessionStore.list_sessions()
    with TestClient(server.create_app(chat_service=service)) as client:
        response = client.post("/api/sessions/detached", json={
            "cwd": str(tmp_path), "title": "Reviewer", **fields,
        })
    assert response.status_code == 422
    assert SessionStore.list_sessions() == before


def test_profile_enforces_ceiling_and_stricter_behavior_limits(tmp_path):
    profile = parse_solo_profile(_profile(behavior={
        "capability_policy": {"workspace_read": False, "network": False},
        "runtime_policy": {"timeout_seconds": 60, "max_total_tokens": 4_096},
    }), "fixture")
    configuration = bounded_profile_configuration(profile)
    policy = configuration["capability_policy"]
    assert policy["workspace_read"] is False
    assert policy["workspace_write"] is False
    assert policy["shell"] is False
    assert policy["computer_control"] is False
    assert policy["simulator_control"] is False
    assert policy["network"] is False
    assert configuration["runtime_policy"]["timeout_seconds"] == 60
    assert configuration["runtime_policy"]["max_total_tokens"] == 4_096
    assert configuration["runtime_policy"]["max_output_tokens"] == 8_192
    assert configuration["custom_instructions"] == "Inspect the changed behavior."


def test_workspace_writer_cannot_implicitly_control_computer():
    profile = parse_solo_profile(_profile(access_ceiling="workspace_write"), "fixture")
    policy = bounded_profile_configuration(profile)["capability_policy"]
    assert policy["workspace_write"] is True
    assert policy["computer_control"] is False
    assert policy["simulator_control"] is False


def test_profile_restores_identity_permissions_and_limits_after_error(tmp_path):
    core = _service(tmp_path).core
    core.configure_agent({"display_name": "Original"}, agent_id="original", mode="plan")
    original_config = core.agent_configuration
    original_policy = core.tool_registry.mcp_agent_policy_snapshot()
    profile = parse_solo_profile(_profile(), "fixture")
    with pytest.raises(RuntimeError):
        with solo_profile_boundary(core, profile) as configuration:
            core.configure_agent(configuration, agent_id=profile.id, mode="work")
            assert core.agent_id == profile.id
            assert core.tool_registry.mcp_agent_policy_snapshot()[1:] == ("read_only", "reviewer")
            names = {entry["function"]["name"] for entry in core.tool_registry.schemas()}
            assert "write_file" not in names
            assert core.agent_configuration.runtime_policy.max_total_tokens == 8_192
            raise RuntimeError("provider disconnected")
    assert core.agent_configuration == original_config
    assert core.agent_mode == "plan"
    assert core.agent_id == "original"
    assert core.tool_registry.mcp_agent_policy_snapshot() == original_policy


def test_profile_rejects_model_substitution_and_discards_supplied_routes():
    with pytest.raises(ValueError, match="exact model"):
        parse_solo_profile(_profile(model="other-model"), "fixture")
    profile = parse_solo_profile(_profile(route={"provider": "remote", "api_key": "untrusted"}), "fixture")
    assert profile.route == {}


def test_world_profile_dispatch_preserves_permissions_with_solo_delegation(tmp_path, monkeypatch):
    service = _service(tmp_path)
    calls = []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append((call, args)) or True)
    monkeypatch.setattr(service, "queue_event", lambda event: None)
    profile = _profile()
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Review this", "mode": "work", "agent_profile": profile,
    }))
    assert len(calls) == 1
    call, args = calls[0]
    assert call == server._run_profile_turn
    assert args[4].id == profile["id"]
    forwarded = []
    monkeypatch.setattr(server, "_run_user_turn", lambda *args, **kwargs: forwarded.append((args, kwargs)))
    call(*args)
    assert forwarded[0][1]["solo_swarm_enabled"] is True
    assert forwarded[0][1]["agent_profile"].id == profile["id"]
    assert forwarded[0][0][4]["runtime_policy"]["max_total_tokens"] == 8_192


@pytest.mark.parametrize("overrides", [
    {"team": {}}, {"text": "/reset"},
    {"mode": "plan", "approved_plan": {}},
    {"workflow_outputs": "invalid"}, {"agent_profile": {"name": "Broken"}},
])
def test_profile_dispatch_rejects_conflicting_or_invalid_configuration(tmp_path, monkeypatch, overrides):
    service = _service(tmp_path)
    events = []
    monkeypatch.setattr(service, "start_turn", lambda *args: pytest.fail("must reject before dispatch"))
    monkeypatch.setattr(service, "queue_event", events.append)
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Review this", "mode": "work",
        "agent_profile": _profile(), **overrides,
    }))
    assert events[-1]["type"] == "command_error"


def test_profile_deadline_releases_waiting_approval(tmp_path):
    service = _service(tmp_path)
    decision = Future()
    service.pending_permissions["waiting"] = decision
    server._expire_profile_turn(service)
    assert service.core._interrupt.is_set()
    assert decision.result(timeout=0.1) == "deny"


@pytest.mark.parametrize("metadata_key", ["agent_profile_id", "agent_world_profile_id"])
def test_profile_dispatch_rejects_a_conversation_bound_to_another_resident(tmp_path, monkeypatch, metadata_key):
    service = _service(tmp_path)
    SessionMeta.update(service.core.session.session_id, **{metadata_key: str(uuid.uuid4())})
    events = []
    monkeypatch.setattr(service, "start_turn", lambda *args: pytest.fail("must preserve profile binding"))
    monkeypatch.setattr(service, "queue_event", events.append)
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Review this", "mode": "work", "agent_profile": _profile(),
    }))
    assert events[-1]["type"] == "command_error"
    assert "another agent profile" in events[-1]["message"]


@pytest.mark.parametrize("message", [
    {"type": "user_message", "text": "Review this", "mode": "work"},
    {"type": "retry_last"},
])
def test_world_bound_session_rejects_unprofiled_turns_and_raw_retries(tmp_path, monkeypatch, message):
    service = _service(tmp_path)
    SessionMeta.update(service.core.session.session_id, agent_world_profile_id=str(uuid.uuid4()))
    events = []
    monkeypatch.setattr(service, "start_turn", lambda *args: pytest.fail("must preserve saved profile permissions"))
    monkeypatch.setattr(service, "queue_event", events.append)
    asyncio.run(server._handle_client_message(service, message))
    assert events[-1]["type"] == "command_error"
    assert "profile" in events[-1]["message"]


def test_world_bound_session_accepts_matching_profile_and_rejects_identity_conversion(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = _profile()
    SessionMeta.update(service.core.session.session_id, agent_world_profile_id=profile["id"])
    calls = []
    events = []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append(call) or True)
    monkeypatch.setattr(service, "queue_event", events.append)
    message = {"type": "user_message", "text": "Review this", "mode": "work", "agent_profile": profile}
    asyncio.run(server._handle_client_message(service, message))
    assert calls == [server._run_profile_turn]
    calls.clear()
    asyncio.run(server._handle_client_message(service, {**message, "identity_mode": True}))
    assert not calls
    assert events[-1]["type"] == "command_error"
    assert service.core.identity_mode is False


def test_generic_deployment_profile_metadata_does_not_require_world_payload(tmp_path, monkeypatch):
    service = _service(tmp_path)
    SessionMeta.update(service.core.session.session_id, agent_profile_id="deployed-agent")
    calls = []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append(call) or True)
    monkeypatch.setattr(service, "queue_event", lambda event: None)
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Continue the configured automation", "mode": "work",
        "agent_config": {"display_name": "Deployed Agent"},
    }))
    assert calls == [server._run_user_turn]


@pytest.mark.parametrize("just_chat", [False, True])
def test_profile_runs_through_existing_worker_with_exact_identity(tmp_path, monkeypatch, just_chat):
    service = _service(tmp_path)
    original_configuration = service.core.agent_configuration
    profile = parse_solo_profile(_profile(), "fixture")
    monkeypatch.setattr(server, "_automatic_memory_context", lambda *args, **kwargs: "")
    monkeypatch.setattr(server, "_automatic_continuity_context", lambda *args, **kwargs: "")
    monkeypatch.setattr(server, "_capture_continuity_snapshot", lambda *args, **kwargs: None)
    observed = []

    def run_turn(_text, _decider, **kwargs):
        observed.append(kwargs)
        core = service.core
        assert core.agent_id == profile.id
        assert core.agent_configuration.display_name == "Reviewer"
        assert core.agent_configuration.custom_instructions == profile.instructions
        assert core.agent_configuration.runtime_policy.max_total_tokens == profile.token_limit
        assert core.tool_registry.mcp_agent_policy_snapshot()[1] == "read_only"
        assert (core.tool_ctx.delegate_read_only is None) is just_chat
        core.last_turn_result = {"type": "turn_done", "reason": "complete", "duration_ms": 0}
        core._emit(core.last_turn_result)

    monkeypatch.setattr(service.core, "run_turn", run_turn)
    server._run_profile_turn(service, "Review this", just_chat, [], profile,
                             "ask" if just_chat else "work", "")
    assert len(observed) == 1
    assert observed[0]["allow_tools"] is not just_chat
    assert service.core.agent_id == "primary"
    assert service.core.agent_configuration == original_configuration
    assert service.active_run_id is None


def test_saved_agent_automation_retains_workflow_outputs_and_profile_boundary(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = _profile()
    SessionMeta.update(service.core.session.session_id, agent_world_profile_id=profile["id"])
    calls = []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append((call, args)) or True)
    monkeypatch.setattr(service, "queue_event", lambda event: None)
    outputs = [{"step_id": "lookup", "result": {"price": 120}}]
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Review the alert", "mode": "work",
        "agent_profile": profile, "workflow_outputs": outputs,
    }))
    forwarded = []
    monkeypatch.setattr(server, "_run_user_turn", lambda *args, **kwargs: forwarded.append((args, kwargs)))
    call, args = calls[0]
    call(*args)
    assert forwarded[0][1]["workflow_outputs"] == outputs
    assert forwarded[0][1]["agent_profile"].id == profile["id"]
    assert forwarded[0][0][4]["capability_policy"]["workspace_write"] is False


@pytest.mark.parametrize("mode", ["ask", "work", "plan", "grill"])
def test_saved_agent_accepts_every_native_mode_without_changing_identity(tmp_path, monkeypatch, mode):
    service = _service(tmp_path)
    profile = _profile()
    SessionMeta.update(service.core.session.session_id, agent_world_profile_id=profile["id"])
    calls = []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append((call, args)) or True)
    monkeypatch.setattr(service, "queue_event", lambda event: None)
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Review the task", "mode": mode,
        "conversation_profile_id": profile["id"], "agent_profile": profile,
    }))
    call, args = calls[0]
    forwarded = []
    monkeypatch.setattr(server, "_run_user_turn", lambda *args, **kwargs: forwarded.append((args, kwargs)))
    call(*args)
    assert forwarded[0][0][5] == mode
    assert forwarded[0][1]["agent_profile"].id == profile["id"]
    assert forwarded[0][1]["solo_swarm_enabled"] is (mode != "ask")


def test_saved_agent_implements_approved_plan_with_its_profile(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = _profile()
    calls = []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append((call, args)) or True)
    monkeypatch.setattr(service, "queue_event", lambda event: None)
    plan = {"revision": 1, "summary": "Build the agreed change"}
    asyncio.run(server._handle_client_message(service, {
        "type": "user_message", "text": "Implement the plan", "mode": "work",
        "agent_profile": profile, "approved_plan": plan,
    }))
    forwarded = []
    monkeypatch.setattr(server, "_run_user_turn", lambda *args, **kwargs: forwarded.append((args, kwargs)))
    call, args = calls[0]
    call(*args)
    assert forwarded[0][1]["approved_plan"] == plan
    assert forwarded[0][1]["agent_profile"].id == profile["id"]


@pytest.mark.parametrize("stage", ["plan", "execute", "review", "followup"])
def test_explicit_duo_stage_can_use_a_different_profile_without_rebinding_chat(tmp_path, monkeypatch, stage):
    service = _service(tmp_path)
    owner, specialist = _profile(), _profile()
    SessionMeta.update(service.core.session.session_id, agent_world_profile_id=owner["id"])
    calls, events = [], []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append((call, args)) or True)
    monkeypatch.setattr(service, "queue_event", events.append)
    context = {"stage": stage}
    message = {"type": "user_message", "text": "Continue the capsule", "mode": "plan",
               "agent_profile": specialist, "capsule_context": context}
    asyncio.run(server._handle_client_message(service, message))
    assert not calls
    assert "another agent profile" in events[-1]["message"]
    asyncio.run(server._handle_client_message(service, {**message, "conversation_profile_id": owner["id"]}))
    forwarded = []
    monkeypatch.setattr(server, "_run_user_turn", lambda *args, **kwargs: forwarded.append((args, kwargs)))
    call, args = calls[0]
    call(*args)
    assert forwarded[0][1]["agent_profile"].id == specialist["id"]
    assert forwarded[0][1]["capsule_context"] == context
    assert forwarded[0][1]["solo_swarm_enabled"] is False
    assert SessionMeta.get(service.core.session.session_id)["agent_world_profile_id"] == owner["id"]


def test_saved_agent_team_route_requires_matching_conversation_owner(tmp_path, monkeypatch):
    service = _service(tmp_path)
    owner = _profile()
    SessionMeta.update(service.core.session.session_id, agent_world_profile_id=owner["id"])
    calls, events = [], []
    monkeypatch.setattr(service, "start_turn", lambda _loop, call, *args: calls.append((call, args)) or True)
    monkeypatch.setattr(service, "queue_event", events.append)
    message = {"type": "user_message", "text": "Work together", "mode": "work", "team": {"run_id": "team-run"}}
    for identifier in (None, str(uuid.uuid4())):
        asyncio.run(server._handle_client_message(service, {**message, "conversation_profile_id": identifier}))
        assert not calls
        assert events[-1]["type"] == "command_error"
    asyncio.run(server._handle_client_message(service, {**message, "conversation_profile_id": owner["id"]}))
    assert calls[0][0] == server._run_team_turn
    assert calls[0][1][2] == message["team"]
