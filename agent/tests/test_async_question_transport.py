"""Exercise question cards over the authenticated native/mobile chat protocol."""
from __future__ import annotations

import json
import time
from concurrent.futures import Future

import test_backend
from test_async_questions import Clock, batch
from test_backend import drain

from ollama_code.question_service import QuestionService

client = test_backend.client


def test_optional_question_protocol_preserves_drafts_and_acknowledgements_on_reconnect(client):
    service = client.app.state.service
    clock = Clock()
    service.optional_questions = QuestionService(service.optional_questions.path, clock=clock)
    with client.websocket_connect("/ws/chat") as socket:
        assert socket.receive_json()["type"] == "session_info"
        socket.send_json({"type": "set_question_capability", "version": 1,
                          "async_questions_v1": True, "enabled": True})
        capability = drain(socket)
        assert any(event["type"] == "question_capability" and event["enabled"] for event in capability)
        pending = json.loads(service.ask_user_question_async(batch(2)))
        request_id = pending["request_id"]
        assert pending["status"] == "pending"
        drain(socket)
        socket.send_json({"type": "question_editing", "request_id": request_id,
                          "editor_id": "mobile-device-a", "active": True})
        assert drain(socket)[-1]["requests"][0]["paused"]
        response = {"type": "question_async_response", "request_id": request_id,
                    "response_id": "mobile-response", "action": "answer",
                    "answers": [{"id": "q1", "text": "Use the shared cache."}]}
        socket.send_json(response)
        acknowledgements = drain(socket)
        ack = next(event for event in acknowledgements if event["type"] == "question_async_response_ack")
        assert ack["accepted"]
        assert ack["request"]["status"] == "pending"
    assert not service.core._interrupt.is_set()
    clock.advance(20)
    with client.websocket_connect("/ws/chat") as socket:
        assert socket.receive_json()["type"] == "session_info"
        replayed = socket.receive_json()
        assert replayed["type"] == "question_async_snapshot"
        request = replayed["requests"][0]
        assert request["status"] == "pending"
        assert request["remaining_ms"] == 40_000
        assert not request["paused"]
        assert request["questions"][0]["answer"]["text"] == "Use the shared cache."
        socket.send_json(response)
        replay_ack = next(event for event in drain(socket) if event["type"] == "question_async_response_ack")
        assert replay_ack["accepted"] == ack["accepted"]
        assert replay_ack["response_id"] == ack["response_id"]
        assert replay_ack["request"]["remaining_ms"] == 40_000
        assert not replay_ack["request"]["paused"]


def test_disconnected_long_running_tool_does_not_own_the_question_deadline(client):
    service = client.app.state.service
    clock = Clock()
    service.optional_questions = QuestionService(service.optional_questions.path, clock=clock)
    # A blocked model/tool never reaches a model boundary during this test.
    running = Future()
    service.turn_future = running
    legacy_question = Future()
    service.pending_questions["required-card"] = legacy_question
    with client.websocket_connect("/ws/chat") as socket:
        socket.receive_json()
        socket.send_json({"type": "set_question_capability", "enabled": True, "version": 1})
        drain(socket)
        pending = json.loads(service.ask_user_question_async(batch()))
        drain(socket)
        clock.advance(20)
        socket.send_json({"type": "question_editing", "request_id": pending["request_id"], "active": True})
        drain(socket)
    assert legacy_question.result() == {"action": "cancel", "answers": []}
    assert not service.core._interrupt.is_set()
    assert not running.done()
    saved = service.optional_questions.snapshot(service.core.session.session_id)[0]
    assert saved["status"] == "pending" and not saved["paused"]
    assert saved["remaining_ms"] == 40_000
    clock.advance(40)
    # Inspect without ticking: only the service timer can resolve this deadline.
    until = time.monotonic() + 2
    while time.monotonic() < until:
        saved = service.optional_questions.snapshot(service.core.session.session_id)[0]
        if saved["status"] == "defaulted":
            break
        time.sleep(0.01)
    assert saved["status"] == "defaulted"
    assert saved["delivery_status"] == "accepted"
    assert not service.core._interrupt.is_set()
    assert not running.done()
    with client.websocket_connect("/ws/chat") as socket:
        socket.receive_json()
        replay = socket.receive_json()
        assert replay["requests"][0]["status"] == "defaulted"
    running.set_result(None)


def test_explicit_stop_cancels_question_and_timer_over_transport(client):
    service = client.app.state.service
    clock = Clock()
    service.optional_questions = QuestionService(service.optional_questions.path, clock=clock)
    with client.websocket_connect("/ws/chat") as socket:
        socket.receive_json()
        socket.send_json({"type": "set_question_capability", "enabled": True, "version": 1})
        drain(socket)
        pending = json.loads(service.ask_user_question_async(batch()))
        drain(socket)
        socket.send_json({"type": "interrupt"})
        drain(socket)
        clock.advance(600)
        assert service.question_snapshot()["requests"][0]["status"] == "cancelled"
        socket.send_json({"type": "question_async_response", "request_id": pending["request_id"],
                          "response_id": "late-mobile", "action": "skip", "answers": []})
        ack = next(event for event in drain(socket) if event["type"] == "question_async_response_ack")
        assert not ack["accepted"]
        assert service.pending_context_deliveries() == []


def test_legacy_replacement_cannot_inherit_async_or_helper_capabilities(client):
    service = client.app.state.service
    with client.websocket_connect("/ws/chat") as socket:
        socket.receive_json()
        socket.send_json({"type": "set_question_capability", "async_questions_v1": True,
                          "collaboration_v1": True})
        drain(socket)
        assert service.async_questions_enabled and service.collaboration_enabled
        pending = json.loads(service.ask_user_question_async(batch()))
        assert pending["status"] == "pending"
        drain(socket)
        running = Future()
        service.turn_future = running
    with client.websocket_connect("/ws/chat") as legacy_socket:
        assert legacy_socket.receive_json()["type"] == "session_info"
        replay = legacy_socket.receive_json()
        assert replay["requests"][0]["request_id"] == pending["request_id"]
        assert replay["requests"][0]["status"] == "pending"
        assert not service.async_questions_enabled
        assert not service.collaboration_enabled
        assert "ask_question_async" not in {
            schema["function"]["name"] for schema in service.core.tool_registry.schemas()
        }
        assert service.ask_user_question_async(batch()).startswith("Error: optional question cards are unavailable")
        assert not running.done() and not service.core._interrupt.is_set()
        legacy_socket.send_json({"type": "set_question_capability", "async_questions_v1": True,
                                 "collaboration_v1": True})
        drain(legacy_socket)
        assert service.async_questions_enabled and service.collaboration_enabled
        assert service.question_snapshot()["requests"][0]["status"] == "pending"
    running.set_result(None)
