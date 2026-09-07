"""Verify the desktop capability handshake reaches the real Solo entry point."""

from __future__ import annotations

import test_backend
from test_backend import FakeClient, drain
from test_collaboration import FakeRuntime

from ollama_code.collaboration import CollaborationStore
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.server import _run_user_turn

client = test_backend.client


def test_reconnect_only_replays_bounded_helpers_from_the_requested_session(client):
    service = client.app.state.service
    session_id = service.core.session.session_id
    store = CollaborationStore()
    for index in range(103):
        store.put("helpers", {
            "id": f"helper-{index}", "session_id": session_id,
            "run_id": "previous-run", "label": "Inspect files", "state": "idle",
            "revision": 1, "updated_at": index, "goal": "g" * 8_000,
            "output": "o" * 100_000, "checkpoint": {"messages": ["private worker context"]},
        })
    store.put("helpers", {"id": "another-task", "session_id": "other-session",
                          "state": "running", "updated_at": 999})
    with client.websocket_connect("/ws/chat") as socket:
        socket.receive_json()
        socket.send_json({"type": "set_question_capability", "collaboration_v1": True,
                          "async_questions_v1": True})
        snapshot = next(event for event in drain(socket)
                        if event["type"] == "solo_collaboration_snapshot")
        assert snapshot["session_id"] == session_id
        assert snapshot["total"] == 103 and snapshot["truncated"]
        assert len(snapshot["agents"]) == 100
        assert snapshot["agents"][0]["id"] == "helper-102"
        assert all(len(helper["goal"]) <= 2_000 and len(helper["output"]) <= 8_000
                   and "checkpoint" not in helper for helper in snapshot["agents"])
        assert store.get("helpers", "helper-102")["output"] == "o" * 100_000


def test_negotiated_solo_turn_launches_helper_and_closes_owned_execution(client, monkeypatch):
    service = client.app.state.service
    starts = []

    def runtime_factory(_service, spec, _lock, **_kwargs):
        starts.append(spec)
        return FakeRuntime(spec)

    monkeypatch.setattr("ollama_code.collaboration_bridge.AgentWorkerRuntime", runtime_factory)
    service.core.client = FakeClient([
        ChatResponse(tool_calls=[ToolCall("spawn_agent", {
            "task": "Inspect the independent fixture", "mode": "research",
        })], done=True),
        ChatResponse(content_parts=["Root inspection complete."], done=True),
        ChatResponse(content_parts=["Helper result collected."], done=True),
    ])
    with client.websocket_connect("/ws/chat") as socket:
        socket.receive_json()
        assert not service.collaboration_enabled
        socket.send_json({"type": "set_question_capability", "collaboration_v1": True})
        drain(socket)
        _run_user_turn(service, "Use one helper while inspecting another component.", False)
        events = drain(socket, limit=100)
        availability = next(event for event in events if event["type"] == "delegation_availability")
        assert availability["available"] and availability["policy_version"] == "balanced-v2"
        assert "spawn_agent" in availability["tool_names"]
        assert len(starts) == 1
        assert starts[0].execution_path == service.core.cwd
        completions = [event for event in events if event["type"] == "turn_done"]
        assert len(completions) == 1 and completions[0]["reason"] == "complete"
        assert service.active_collaboration is None
        assert service.core.tool_ctx.collaboration is None
        assert all(helper["state"] not in {"queued", "running", "stopping"}
                   for helper in CollaborationStore().helpers(service.core.session.session_id))
