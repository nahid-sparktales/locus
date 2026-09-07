"""Optional-question lifecycle tests use only fake clocks and local SQLite."""
from __future__ import annotations

import asyncio
import concurrent.futures
import json

import pytest

from ollama_code.question_service import QuestionError, QuestionService, normalize_questions


class Clock:
    def __init__(self):
        self.value = 1_000.0

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


def batch(count=1):
    return {"questions": [{
        "id": f"q{index + 1}", "header": "Storage", "question": "Where should the cache live?",
        "options": [{"id": "local", "label": "Local", "description": "Stored on this Mac"},
                    {"id": "remote", "label": "Remote", "description": "Shared across devices"}],
        "recommended_option_ids": ["local"],
    } for index in range(count)]}


@pytest.fixture
def service(tmp_path):
    clock = Clock()
    return QuestionService(tmp_path / "questions.sqlite3", clock=clock, owner_id="worker-a"), clock


def create(service, count=1):
    store, _ = service
    return store.create("chat-a", "run-a", "tool-a", batch(count))


def test_public_tool_schema_recommendation_normalizes_to_displayed_default():
    from ollama_code.collaboration_tools import ASK_QUESTION_ASYNC_SCHEMA

    question_schema = ASK_QUESTION_ASYNC_SCHEMA["function"]["parameters"]["properties"]["questions"]["items"]
    assert "recommendation" in question_schema["required"]
    choices = normalize_questions({"questions": [{
        "id": "format", "question": "Which file format?", "recommendation": "PDF",
        "options": [{"label": "PDF"}, {"label": "Markdown"}],
    }]})
    assert choices[0]["recommended_option_ids"] == ["o1"]
    assert choices[0]["recommended_text"] == ""
    text_question = normalize_questions({"questions": [{
        "id": "name", "question": "What should the file be called?",
        "recommendation": "Meeting notes",
    }]})
    assert text_question[0]["recommended_text"] == "Meeting notes"
    with pytest.raises(QuestionError, match="displayed choice label"):
        normalize_questions({"questions": [{
            "id": "format", "question": "Which file format?", "recommendation": "HTML",
            "options": [{"label": "PDF"}, {"label": "Markdown"}],
        }]})


def test_async_question_returns_pending_and_freezes_recommendation(service):
    store, _ = service
    payload = batch()
    request = store.create("chat-a", "run-a", "tool-a", payload)
    payload["questions"][0]["recommended_option_ids"] = ["remote"]
    assert request["status"] == "pending"
    assert request["remaining_ms"] == 60_000
    assert store.snapshot("chat-a")[0]["questions"][0]["recommended_option_ids"] == ["local"]
    assert store.pending_deliveries("chat-a") == []
    with pytest.raises(QuestionError, match="already has"):
        create(service)


def test_timer_defaults_once_and_never_claims_user_approval(service):
    store, clock = service
    request = create(service)
    clock.advance(59.999)
    assert store.tick("chat-a")[0]["status"] == "pending"
    clock.advance(.001)
    resolved = store.tick("chat-a")[0]
    assert resolved["status"] == "defaulted"
    assert resolved["questions"][0]["answer"]["source"] == "timeout"
    deliveries = store.pending_deliveries("chat-a", "run-a")
    assert len(deliveries) == 1
    assert "No user answer or approval" in deliveries[0]["text"]
    assert store.tick("chat-a")[0]["delivery_status"] == "accepted"
    assert store.mark_applied("chat-a", deliveries[0]["delivery_id"])
    assert store.mark_applied("chat-a", deliveries[0]["delivery_id"])
    assert store.pending_deliveries("chat-a") == []
    assert store.snapshot("chat-a")[0]["applied_at"] == clock()
    late = store.respond("chat-a", request["request_id"], "answer", [
        {"id": "q1", "selected": ["remote"]},
    ])
    assert not late["accepted"]
    assert late["request"]["status"] == "defaulted"


def test_editing_lease_renews_then_expires_without_lost_time(service):
    store, clock = service
    request = create(service)
    clock.advance(20)
    paused = store.editing("chat-a", request["request_id"], "desktop", True)
    assert paused["remaining_ms"] == 40_000
    assert paused["paused"] and paused["deadline_at"] is None
    for _ in range(12):
        clock.advance(5)
        assert store.editing("chat-a", request["request_id"], "desktop", True)["remaining_ms"] == 40_000
    clock.advance(20)
    resumed = store.tick("chat-a")[0]
    assert not resumed["paused"]
    assert resumed["remaining_ms"] == 35_000
    clock.advance(35)
    assert store.tick("chat-a")[0]["status"] == "defaulted"


def test_editing_release_and_multiple_clients_are_independent(service):
    store, clock = service
    request = create(service)
    store.editing("chat-a", request["request_id"], "desktop", True)
    store.editing("chat-a", request["request_id"], "mobile", True)
    clock.advance(5)
    result = store.editing("chat-a", request["request_id"], "desktop", False)
    assert result["paused"]
    result = store.editing("chat-a", request["request_id"], "mobile", False)
    assert not result["paused"]
    assert result["remaining_ms"] == 60_000
    clock.advance(60)
    assert store.tick("chat-a")[0]["status"] == "defaulted"


def test_partial_answers_survive_skip_and_defaulting(service):
    store, _ = service
    request = create(service, 3)
    answered = store.respond("chat-a", request["request_id"], "answer", [
        {"id": "q1", "selected": ["Remote"], "text": "My choice"},
    ], response_id="first")
    assert answered["accepted"]
    assert answered["request"]["status"] == "pending"
    assert store.pending_deliveries("chat-a") == []
    skipped = store.respond("chat-a", request["request_id"], "skip", [], response_id="skip")
    assert skipped["accepted"]
    questions = skipped["request"]["questions"]
    assert questions[0]["answer"]["source"] == "user"
    assert questions[0]["answer"]["selected"] == ["Remote"]
    assert [q["answer"]["source"] for q in questions[1:]] == ["skip", "skip"]
    assert skipped["request"]["status"] == "skipped"
    assert len(store.pending_deliveries("chat-a")) == 1


def test_response_retry_ack_is_idempotent_even_after_finalization(service):
    store, _ = service
    request = create(service)
    first = store.respond("chat-a", request["request_id"], "answer", [
        {"id": "q1", "selected": ["remote"]},
    ], response_id="response-a")
    assert store.respond("chat-a", request["request_id"], "answer", [], response_id="response-a") == first
    assert len(store.pending_deliveries("chat-a")) == 1
    with pytest.raises(QuestionError, match="belong"):
        store.respond("another-chat", request["request_id"], "answer", [], response_id="response-a")


def test_stale_device_cannot_overwrite_committed_partial_answer(service):
    store, _ = service
    request = create(service, 2)
    store.respond("chat-a", request["request_id"], "answer", [
        {"id": "q1", "selected": ["remote"]},
    ], response_id="device-a")
    with pytest.raises(QuestionError, match="already answered"):
        store.respond("chat-a", request["request_id"], "answer", [
            {"id": "q1", "selected": ["local"]},
            {"id": "q2", "text": "Should not commit half an invalid batch"},
        ], response_id="device-b")
    saved = store.snapshot("chat-a")[0]
    assert saved["questions"][0]["answer"]["selected"] == ["Remote"]
    assert saved["questions"][1]["answer"] is None


def test_superseding_irrelevant_questions_never_defaults_or_delivers(service):
    store, clock = service
    request = create(service, 2)
    store.respond("chat-a", request["request_id"], "answer", [{"id": "q1", "text": "Keep local"}])
    with pytest.raises(QuestionError, match="belong"):
        store.supersede("another-chat", request["request_id"], "No longer relevant")
    result = store.supersede("chat-a", request["request_id"], "The cache was removed from scope.")
    assert result["status"] == "superseded"
    assert result["questions"][0]["answer"]["text"] == "Keep local"
    assert result["questions"][1]["answer"] is None
    assert result["delivery_id"] is None
    assert not store.pending_deliveries("chat-a")
    clock.advance(600)
    assert store.tick("chat-a")[0]["status"] == "superseded"
    assert store.supersede("chat-a", request["request_id"], "Repeated request")["superseded_reason"] == result["superseded_reason"]
    assert not store.respond("chat-a", request["request_id"], "skip", [])["accepted"]
    assert create(service)["status"] == "pending"


def test_supersede_and_timeout_have_one_atomic_winner(service):
    store, clock = service
    request = create(service)
    clock.advance(60)

    def supersede():
        try:
            return store.supersede("chat-a", request["request_id"], "No longer relevant")
        except QuestionError:
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(store.tick, "chat-a"), executor.submit(supersede)]
        for future in futures:
            future.result()
    saved = store.snapshot("chat-a")[0]
    assert saved["status"] in {"superseded", "defaulted"}
    assert len(store.pending_deliveries("chat-a")) == int(saved["status"] == "defaulted")


def test_answer_skip_and_timeout_races_have_one_outcome(service):
    store, clock = service
    request = create(service)
    clock.advance(60)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        operations = [executor.submit(store.tick, "chat-a"),
                      executor.submit(store.respond, "chat-a", request["request_id"], "skip", []),
                      executor.submit(store.respond, "chat-a", request["request_id"], "answer",
                                      [{"id": "q1", "selected": ["remote"]}])]
        results = [item.result() for item in operations]
    assert len(results) == 3
    assert len(store.pending_deliveries("chat-a")) == 1
    assert store.snapshot("chat-a")[0]["status"] == "defaulted"


def test_two_devices_cannot_replace_an_accepted_batch(service):
    store, _ = service
    request = create(service)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(store.respond, "chat-a", request["request_id"], "answer",
                                   [{"id": "q1", "selected": [choice]}], response_id=choice)
                   for choice in ("local", "remote")]
        results = [future.result() for future in futures]
    assert sum(result["accepted"] for result in results) == 1
    assert len(store.pending_deliveries("chat-a")) == 1


def test_stop_cancels_defaulting_and_accepted_delivery(service):
    store, clock = service
    create(service)
    store.stop("chat-a")
    clock.advance(100)
    assert store.tick("chat-a")[0]["status"] == "cancelled"
    assert store.pending_deliveries("chat-a") == []
    request = create(service)
    store.respond("chat-a", request["request_id"], "skip", [])
    delivery = store.pending_deliveries("chat-a")[0]
    store.stop("chat-a")
    assert store.pending_deliveries("chat-a") == []
    assert not store.mark_applied("chat-a", delivery["delivery_id"])


def test_restart_suspends_remaining_clock_until_explicit_resume(service):
    store, clock = service
    request = create(service)
    clock.advance(20)
    store.editing("chat-a", request["request_id"], "mobile", True)
    restarted = QuestionService(store.path, clock=clock, owner_id="worker-b")
    clock.advance(500)
    restarted.recover_session("chat-a")
    recovered = restarted.tick("chat-a")[0]
    assert recovered["status"] == "suspended"
    assert recovered["remaining_ms"] == 40_000
    restarted.resume("chat-a", "run-b")
    clock.advance(40)
    assert restarted.tick("chat-a")[0]["status"] == "defaulted"
    assert restarted.pending_deliveries("chat-a", "run-a") == []
    assert len(restarted.pending_deliveries("chat-a", "run-b")) == 1


def test_reconnect_snapshot_and_delivery_survive_store_reopen(service):
    store, clock = service
    request = create(service, 2)
    store.respond("chat-a", request["request_id"], "answer", [{"id": "q1", "text": "My own answer"}], response_id="saved")
    store.stop("chat-a", suspend=True)
    reconnected = QuestionService(store.path, clock=clock, owner_id="worker-b")
    reconnected.recover_session("chat-a")
    assert reconnected.snapshot("chat-a")[0]["questions"][0]["answer"]["text"] == "My own answer"
    reconnected.resume("chat-a", "run-b")
    reconnected.respond("chat-a", request["request_id"], "skip", [])
    after_crash = QuestionService(store.path, clock=clock, owner_id="worker-c")
    assert len(after_crash.pending_deliveries("chat-a", "run-b")) == 1


def test_native_send_intent_survives_crash_and_explicit_run_rebind(service):
    store, clock = service
    request = create(service)
    store.respond("chat-a", request["request_id"], "skip", [])
    delivery_id = store.pending_deliveries("chat-a")[0]["delivery_id"]
    assert store.mark_native_delivery_sent("chat-a", delivery_id, "thread-a", delivery_id)
    restarted = QuestionService(store.path, clock=clock, owner_id="worker-b")
    restarted.recover_session("chat-a")
    assert restarted.pending_deliveries("chat-a", "run-b") == []
    with pytest.raises(QuestionError, match="Resume the task"):
        restarted.resume("chat-a", "")
    restarted.resume("chat-a", "run-b")
    delivery = restarted.pending_deliveries("chat-a", "run-b")[0]
    assert delivery["origin_run_id"] == "run-a"
    assert delivery["native_attempt"] == {
        "thread_id": "thread-a", "client_id": delivery_id, "attempted_at": clock(),
    }
    with pytest.raises(QuestionError, match="reconciled"):
        restarted.mark_native_delivery_sent("chat-a", delivery_id, "other-thread", delivery_id)
    assert restarted.clear_native_delivery_attempt("chat-a", delivery_id)
    assert "native_attempt" not in restarted.pending_deliveries("chat-a", "run-b")[0]
    restarted.stop("chat-a")
    assert not restarted.mark_native_delivery_sent("chat-a", delivery_id, "thread-a", delivery_id)


def test_timer_cannot_resume_without_an_active_consumer(tmp_path):
    from ollama_code.chat_service import ChatService
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={})
    bridge = ChatService(core)
    clock = Clock()
    bridge.optional_questions = QuestionService(tmp_path / "question.sqlite3", clock=clock)
    bridge.optional_questions.create(core.session.session_id, "old-run", "tool", batch())
    bridge.optional_questions.stop(core.session.session_id, suspend=True)
    assert bridge.resume_async_questions()["type"] == "error"
    clock.advance(600)
    assert bridge.question_snapshot()["requests"][0]["status"] == "suspended"
    bridge.active_run_id = "new-run"
    resumed = bridge.resume_async_questions()
    assert resumed["requests"][0]["run_id"] == "new-run"
    clock.advance(60)
    assert len(bridge.pending_context_deliveries()) == 1
    core.close()


def test_service_shutdown_stops_timer_and_preserves_restart_countdown(tmp_path):
    from ollama_code.chat_service import ChatService
    from ollama_code.core import AgentCore

    async def scenario():
        core = AgentCore(cwd=str(tmp_path), config={})
        bridge = ChatService(core)
        clock = Clock()
        bridge.optional_questions = QuestionService(tmp_path / "question.sqlite3", clock=clock)
        bridge.loop = asyncio.get_running_loop()
        bridge.ws = object()
        bridge.async_questions_enabled = True
        bridge.ask_user_question_async(batch())
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        timer = bridge._question_timer
        assert timer is not None and not timer.done()
        clock.advance(20)
        bridge.close_question_timer()
        await asyncio.gather(timer, return_exceptions=True)
        assert timer.done()
        clock.advance(600)
        assert bridge.question_snapshot()["requests"][0]["status"] == "suspended"
        assert bridge.question_snapshot()["requests"][0]["remaining_ms"] == 40_000
        bridge.close_codex()
        core.close()

    asyncio.run(scenario())


def test_wall_clock_change_does_not_change_countdown(tmp_path):
    wall, mono = Clock(), Clock()
    store = QuestionService(tmp_path / "clock.sqlite3", clock=wall, monotonic=mono)
    store.create("chat", "run", "tool", batch())
    wall.advance(10_000)
    mono.advance(5)
    assert store.tick("chat")[0]["remaining_ms"] == 55_000


def test_invalid_answer_does_not_consume_or_reset_clock(service):
    store, clock = service
    request = create(service)
    clock.advance(20)
    with pytest.raises(QuestionError):
        store.respond("chat-a", request["request_id"], "answer", [{"id": "q1", "selected": "local"}])
    clock.advance(20)
    assert store.tick("chat-a")[0]["remaining_ms"] == 20_000


@pytest.mark.parametrize("payload", [
    {"questions": []}, batch(4),
    {"questions": [{"question": "Name?"}]},
    {"questions": [{"question": "Your password?", "recommended_text": "anything"}]},
])
def test_invalid_optional_questions_fail_before_creation(service, payload):
    store, _ = service
    with pytest.raises(QuestionError):
        store.create("chat-a", "run-a", "tool-a", payload)
    assert store.snapshot("chat-a") == []


def test_chat_bridge_returns_pending_without_waiting(tmp_path):
    from ollama_code.chat_service import ChatService
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={})
    bridge = ChatService(core)
    bridge.ws = object()
    bridge.async_questions_enabled = True
    events = []
    bridge.emit = events.append
    result = json.loads(bridge.ask_user_question_async(batch()))
    assert result["status"] == "pending"
    assert bridge.pending_questions == {}
    assert events[-1]["type"] == "question_async_snapshot"
    bridge.cancel_all_questions()
    assert bridge.question_snapshot()["requests"][0]["status"] == "cancelled"
    core.close()
