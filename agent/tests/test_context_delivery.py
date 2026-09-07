"""Offline integration coverage for question outboxes and provider steering."""
from __future__ import annotations

import asyncio
import json
import queue
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest
from test_async_questions import Clock, batch
from test_backend import _core
from test_chatgpt_app_server import FakeManagedRuntime, _managed_core
from test_chatgpt_broker_accounts import BrokerSocket, service_with_helpers

from ollama_code.api.chat_transport import ws_codex_broker
from ollama_code.chat_service import ChatService
from ollama_code.codex_app_server import (
    CodexAppServerError,
    CodexAppServerManager,
    CodexBrokerClient,
)
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.question_service import QuestionService


def connect_outbox(core, store):
    core.context_delivery_source = lambda: store.pending_deliveries("chat", "run")
    core.context_delivery_applied = lambda identifier: store.mark_applied("chat", identifier)
    core.context_delivery_native_sent = lambda identifier, thread_id, client_id: store.mark_native_delivery_sent(
        "chat", identifier, thread_id, client_id,
    )
    core.context_delivery_native_unsent = lambda identifier: store.clear_native_delivery_attempt("chat", identifier)


def answer(store):
    request = store.create("chat", "run", "question-tool", batch())
    store.respond("chat", request["request_id"], "answer", [
        {"id": "q1", "selected": ["remote"]},
    ], response_id="response")
    return store.pending_deliveries("chat", "run")[0]


@pytest.mark.parametrize("provider", ["ollama", "remote"])
def test_question_answer_enters_context_after_unchanged_pending_tool_result(tmp_path, provider):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall("ask_question_async", batch(), "call-1")], done=True),
        ChatResponse(content_parts=["Using the remote cache."], done=True),
    ])
    core.provider = provider
    core.tool_registry.set_ask_question_async_enabled(True)
    core.tool_ctx.ask_question_async = lambda payload: json.dumps(
        store.create("chat", "run", "call-1", payload))
    connect_outbox(core, store)

    def pending():
        records = store.snapshot("chat")
        if records and records[0]["status"] == "pending":
            store.respond("chat", records[0]["request_id"], "answer", [
                {"id": "q1", "selected": ["remote"]},
            ])
        return store.pending_deliveries("chat", "run")

    core.context_delivery_source = pending
    events = []
    core.on_event(events.append)
    core.run_turn("Design the cache.")

    assert core.client.calls == 2
    request = core.client.seen_messages[1]
    tool_index = next(i for i, item in enumerate(request) if item.get("tool_call_id") == "call-1")
    assert json.loads(request[tool_index]["content"])["status"] == "pending"
    assert request[tool_index + 1]["role"] == "user"
    assert "User answer: Remote" in request[tool_index + 1]["content"]
    assert all("_delivery_id" not in item for item in request)
    assert store.snapshot("chat")[0]["delivery_status"] == "applied"
    assert len([item for item in events if item["type"] == "turn_done"]) == 1


def test_context_arriving_at_final_boundary_causes_one_continuation(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(content_parts=["First answer."], done=True),
        ChatResponse(content_parts=["Updated with the user's answer."], done=True),
    ])
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    connect_outbox(core, store)
    finalizations = []

    def before_finalize():
        if not finalizations:
            finalizations.append(answer(store))
        return None

    core.before_finalize = before_finalize
    core.run_turn("Do the independent work.", allow_tools=False)
    assert core.client.calls == 2
    assert "User answer: Remote" in core.client.seen_messages[1][-1]["content"]
    assert store.pending_deliveries("chat") == []
    assert len([item for item in core.messages if item.get("_delivery_id")]) == 1


def test_restored_delivery_marker_recovers_outbox_ack_without_duplicate_context(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    delivery = answer(store)
    core = _core(tmp_path, [])
    connect_outbox(core, store)
    # The transcript append survived a crash immediately before outbox marking.
    core._add_message({"role": "user", "content": delivery["text"],
                       "_delivery_id": delivery["delivery_id"]})
    session_id = core.session.session_id
    core.start_new_session()
    core.resume_session(session_id)
    core._apply_context_deliveries()
    assert len([item for item in core.messages if item.get("_delivery_id") == delivery["delivery_id"]]) == 1
    assert store.pending_deliveries("chat") == []


def test_stop_during_outbox_lookup_prevents_late_applied_context(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    answer(store)
    core = _core(tmp_path, [])
    connect_outbox(core, store)
    events = []
    core.on_event(events.append)

    def raced_lookup():
        deliveries = store.pending_deliveries("chat", "run")
        core.interrupt()
        store.stop("chat")
        return deliveries

    core.context_delivery_source = raced_lookup
    core._apply_context_deliveries()
    assert not any(item.get("_delivery_id") for item in core.messages)
    assert not any(event["type"] == "context_delivery_applied" for event in events)
    assert store.snapshot("chat")[0]["delivery_status"] == "cancelled"


class SteeringRuntime(FakeManagedRuntime):
    """Model-free transport with distinct queue acceptance and item application."""

    def __init__(self, store, mode="event"):
        super().__init__()
        self.store, self.mode = store, mode
        self.submitted = []
        self.active = False
        self.before_tick = None

    def steer_turn(self, thread_id, text, client_message_id):
        pending = self.store.pending_deliveries("chat", "run")
        if client_message_id.startswith("question:"):
            assert pending[0]["native_attempt"]["client_id"] == client_message_id
        if not self.active or self.mode == "no-active":
            raise CodexAppServerError("No active ChatGPT turn to steer")
        self.submitted.append((thread_id, text, client_message_id))
        assert self.store.snapshot("chat")[0]["delivery_status"] == "accepted"
        if self.mode in {"uncertain", "missing"}:
            raise CodexAppServerError("Connection lost after write")
        return {"turnId": "turn-1"}

    def read_thread(self, thread_id):
        assert thread_id == "thread-1"
        items = [] if self.mode == "missing" else [
            {"type": "userMessage", "clientId": item[2]} for item in self.submitted
        ]
        return {"id": thread_id, "turns": [{"items": items}]}

    def run_turn(self, *, text, event_handler, on_tick=None, **_kwargs):
        self.turn_texts.append(text)
        self.active = True
        if len(self.turn_texts) == 1:
            answer(self.store)
            if self.before_tick:
                self.before_tick()
        on_tick()
        if self.mode == "no-active" and len(self.turn_texts) == 1:
            assert all("native_attempt" not in item for item in self.store.pending_deliveries("chat", "run"))
        if self.mode == "event":
            for _, _, identifier in self.submitted:
                for method in ("item/started", "item/completed"):
                    event_handler({"method": method, "params": {
                        "item": {"type": "userMessage", "clientId": identifier},
                    }})
        event_handler({"method": "item/agentMessage/delta", "params": {
            "itemId": f"answer-{len(self.turn_texts)}", "delta": "Work is complete.",
        }})
        self.active = False
        return {"status": "completed"}


@pytest.mark.parametrize("mode", ["event", "history", "uncertain", "no-active"])
def test_native_question_guidance_is_confirmed_once_or_safely_continued(tmp_path, mode):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    runtime = SteeringRuntime(store, mode)
    core = _managed_core(tmp_path, runtime)
    connect_outbox(core, store)
    events = []
    core.on_event(events.append)
    core.run_turn("Do the independent work.", allow_tools=False)
    assert core.last_turn_result["reason"] == "complete"
    assert store.snapshot("chat")[0]["delivery_status"] == "applied"
    assert len([item for item in core.messages if item.get("_delivery_id")]) == 1
    assert len([item for item in events if item["type"] == "context_delivery_applied"]) == 1
    assert len(runtime.submitted) == (0 if mode == "no-active" else 1)
    assert len(runtime.turn_texts) == (2 if mode == "no-active" else 1)
    if mode == "no-active":
        assert "User answer: Remote" in runtime.turn_texts[1]


def test_uncertain_native_guidance_is_not_acknowledged_or_resent_without_evidence(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    runtime = SteeringRuntime(store, "missing")
    core = _managed_core(tmp_path, runtime)
    connect_outbox(core, store)
    core.run_turn("Do the independent work.", allow_tools=False)
    assert core.last_turn_result["reason"] == "error"
    assert store.snapshot("chat")[0]["delivery_status"] == "accepted"
    assert len(runtime.submitted) == 1
    assert len(runtime.turn_texts) == 1
    assert not any(item.get("_delivery_id") for item in core.messages)
    assert store.pending_deliveries("chat", "run")[0]["native_attempt"]["thread_id"] == "thread-1"


@pytest.mark.parametrize("receipt_exists", [True, False])
def test_saved_native_send_receipt_is_reconciled_before_any_retry(tmp_path, receipt_exists):
    clock = Clock()
    store = QuestionService(tmp_path / "questions.sqlite3", clock=clock)
    delivery = answer(store)
    store.mark_native_delivery_sent("chat", delivery["delivery_id"], "old-thread", delivery["delivery_id"])
    restarted = QuestionService(store.path, clock=clock)
    restarted.recover_session("chat")
    restarted.resume("chat", "run")

    class RecoveredRuntime(FakeManagedRuntime):
        def __init__(self):
            super().__init__()
            self.reads = []
            self.steers = []

        def read_thread(self, thread_id):
            self.reads.append(thread_id)
            return {"turns": [{"items": [{"type": "userMessage", "clientId": delivery["delivery_id"]}]}]} if receipt_exists else {}

        def steer_turn(self, *args):
            self.steers.append(args)
            pytest.fail("A saved send attempt must never be submitted again")

    runtime = RecoveredRuntime()
    core = _managed_core(tmp_path, runtime)
    core._chatgpt_thread_id = "new-thread"
    connect_outbox(core, restarted)
    if receipt_exists:
        core._flush_native_guidance(runtime)
        pending = restarted.pending_deliveries("chat")
        assert len(pending) == 1
        assert "native_attempt" not in pending[0]
        assert core._native_guidance[delivery["delivery_id"]]["continuation_only"]
        assert core._native_rehydrated_input == []
        assert not any(item.get("_delivery_id") for item in core.messages)
    else:
        with pytest.raises(RuntimeError, match="unconfirmed"):
            core._flush_native_guidance(runtime)
        assert len(restarted.pending_deliveries("chat")) == 1
        assert not any(item.get("_delivery_id") for item in core.messages)
    assert runtime.reads == ["old-thread"]
    assert not runtime.steers


def test_native_manual_steer_still_applies_alongside_question_outcome(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    runtime = SteeringRuntime(store)
    core = _managed_core(tmp_path, runtime)
    connect_outbox(core, store)
    runtime.before_tick = lambda: core.steer("Also include migration instructions.")
    events = []
    core.on_event(events.append)
    core.run_turn("Do the independent work.", allow_tools=False)
    assert len(runtime.submitted) == 2
    assert len([item for item in events if item["type"] == "steer_applied"]) == 1
    assert len([item for item in events if item["type"] == "context_delivery_applied"]) == 1
    assert store.pending_deliveries("chat") == []


def test_app_server_steer_uses_active_turn_and_correlated_history(monkeypatch):
    manager = CodexAppServerManager(helper_path="/not/executed")
    requests = []

    def request(method, params, **_kwargs):
        requests.append((method, params))
        return {"turnId": "turn-1"} if method == "turn/steer" else {"thread": {"id": "thread-1"}}

    monkeypatch.setattr(manager, "request", request)
    with pytest.raises(CodexAppServerError, match="No active"):
        manager.steer_turn("thread-1", "Follow-up", "delivery-1")
    assert not requests
    manager._active_turns["thread-1"] = "turn-1"
    manager.steer_turn("thread-1", "Follow-up", "delivery-1")
    assert requests[0] == ("turn/steer", {
        "threadId": "thread-1", "expectedTurnId": "turn-1", "clientUserMessageId": "delivery-1",
        "input": [{"type": "text", "text": "Follow-up", "text_elements": []}],
    })
    assert manager.read_thread("thread-1") == {"id": "thread-1"}
    assert requests[-1] == ("thread/read", {"threadId": "thread-1", "includeTurns": True})


@pytest.mark.parametrize("provider", ["ollama", "remote", "chatgpt"])
@pytest.mark.parametrize("outcome", ["answer", "stop"])
def test_core_finalization_waits_for_pending_question_without_spending_calls(tmp_path, provider, outcome):
    if provider == "chatgpt":
        runtime = FakeManagedRuntime()
        core = _managed_core(tmp_path, runtime)
    else:
        core = _core(tmp_path, [
            ChatResponse(content_parts=["Independent work is complete."], done=True),
            ChatResponse(content_parts=["Applied your preference."], done=True),
        ])
        core.provider = provider
    bridge = ChatService(core)
    if provider == "chatgpt":
        core.codex_manager = runtime
    bridge.active_run_id = "run"
    bridge.optional_questions = QuestionService(tmp_path / "pending.sqlite3", clock=Clock())
    request = bridge.optional_questions.create(core.session.session_id, "run", "tool", batch())
    core.context_delivery_source = bridge.pending_context_deliveries
    core.context_delivery_applied = bridge.mark_question_delivery_applied
    entered = threading.Event()
    events = []
    core.on_event(events.append)

    def before_finalize():
        entered.set()
        while not core._interrupt.is_set() and bridge.question_before_finalize():
            core._interrupt.wait(0.01)

    core.before_finalize = before_finalize
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending_turn = executor.submit(core.run_turn, "Finish the independent work.", allow_tools=False)
        assert entered.wait(2)
        try:
            assert not pending_turn.done()
            assert not any(event["type"] == "turn_done" for event in events)
            assert (len(runtime.turn_texts) if provider == "chatgpt" else core.client.calls) == 1
            if outcome == "answer":
                bridge.handle_async_question_response({
                    "request_id": request["request_id"], "action": "answer", "response_id": "answer",
                    "answers": [{"id": "q1", "selected": ["remote"]}],
                })
            else:
                core.interrupt()
                bridge.cancel_all_questions()
            pending_turn.result(timeout=2)
        finally:
            core.interrupt()
    terminal = [event for event in events if event["type"] == "turn_done"]
    assert len(terminal) == 1
    assert terminal[0]["reason"] == ("complete" if outcome == "answer" else "interrupted")
    calls = len(runtime.turn_texts) if provider == "chatgpt" else core.client.calls
    assert calls == (2 if outcome == "answer" else 1)
    if outcome == "answer":
        assert bridge.optional_questions.snapshot(core.session.session_id)[0]["delivery_status"] == "applied"
    bridge.close_codex()
    core.close()


def test_app_server_failed_turn_raises_and_releases_active_turn(monkeypatch):
    manager = CodexAppServerManager(helper_path="/not/executed")
    events = queue.Queue()
    events.put({"method": "turn/completed", "params": {
        "turn": {"id": "turn-1", "status": "failed", "error": {"message": "Provider rejected the turn"}},
    }})
    monkeypatch.setattr(manager, "_subscribe", lambda _thread: events)
    monkeypatch.setattr(manager, "_unsubscribe", lambda _thread, _events: None)
    monkeypatch.setattr(manager, "request", lambda *_args, **_kwargs: {"turn": {"id": "turn-1"}})
    with pytest.raises(CodexAppServerError, match="Provider rejected"):
        manager.run_turn(thread_id="thread-1", text="Work")
    assert manager._active_turns == {}


@pytest.mark.parametrize("raises", [False, True])
def test_failed_native_turn_never_reports_complete_or_loses_known_usage(tmp_path, raises):
    class FailedRuntime(FakeManagedRuntime):
        def run_turn(self, *, event_handler, **_kwargs):
            event_handler({"method": "thread/tokenUsage/updated", "params": {
                "tokenUsage": {"last": {"inputTokens": 12, "outputTokens": 7}},
            }})
            turn = {"status": "failed", "error": {"message": "Provider rejected the turn"}}
            event_handler({"method": "turn/completed", "params": {"turn": turn}})
            if raises:
                raise CodexAppServerError("Provider rejected the turn")
            return turn

    core = _managed_core(tmp_path, FailedRuntime())
    events = []
    core.on_event(events.append)
    core.run_turn("Work", allow_tools=False)
    assert core.last_turn_result["reason"] == "error"
    assert core.last_turn_result["prompt_tokens"] == 12
    assert core.last_turn_result["completion_tokens"] == 7
    assert len([event for event in events if event["type"] == "turn_done"]) == 1
    assert any(event["type"] == "error" and "Provider rejected" in event["message"] for event in events)


def test_same_process_native_retry_reconciles_original_thread_instead_of_resending(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())

    class RetryRuntime(FakeManagedRuntime):
        def __init__(self):
            super().__init__()
            self.submitted = []
            self.reads = []
            self.confirm = False

        def steer_turn(self, thread_id, _text, identifier):
            self.submitted.append((thread_id, identifier))
            raise CodexAppServerError("Connection lost after write")

        def read_thread(self, thread_id):
            self.reads.append(thread_id)
            return {"turns": [{"items": [
                {"type": "userMessage", "clientId": identifier}
                for original_thread, identifier in self.submitted
                if self.confirm and thread_id == original_thread
            ]}]}

        def run_turn(self, *, text, on_tick, event_handler, **_kwargs):
            self.turn_texts.append(text)
            if len(self.turn_texts) == 1:
                answer(store)
            on_tick()
            event_handler({"method": "item/agentMessage/delta", "params": {
                "itemId": f"answer-{len(self.turn_texts)}", "delta": "Work complete.",
            }})
            return {"status": "completed"}

    runtime = RetryRuntime()
    core = _managed_core(tmp_path, runtime)
    connect_outbox(core, store)
    core.run_turn("Work", allow_tools=False)
    assert core.last_turn_result["reason"] == "error"
    assert len(runtime.submitted) == 1
    runtime.confirm = True
    core.run_turn("Resume the task", allow_tools=False)
    assert core.last_turn_result["reason"] == "complete"
    assert runtime.started == ["thread-1", "thread-2"]
    assert len(runtime.submitted) == 1
    assert runtime.reads.count("thread-1") >= 2
    assert store.pending_deliveries("chat") == []
    assert "User answer: Remote" in runtime.turn_texts[-1]


class BoundaryRuntime(FakeManagedRuntime):
    """Keep final-boundary input unconfirmed until a real native receipt."""

    def __init__(self, store, *, fail_first=False, receipt_before_failure=False, emit_receipt=False):
        super().__init__()
        self.store = store
        self.fail_first = fail_first
        self.receipt_before_failure = receipt_before_failure
        self.emit_receipt = emit_receipt
        self.continuations = []
        self.receipts = {}
        self.reads = []
        self.core = None

    def steer_turn(self, *_args):
        raise CodexAppServerError("No active ChatGPT turn to steer")

    def read_thread(self, thread_id):
        self.reads.append(thread_id)
        return {"turns": [{"items": self.receipts.get(thread_id, [])}]}

    def run_turn(self, *, thread_id, text, event_handler, on_tick=None, client_message_id="", **kwargs):
        if client_message_id:
            self.continuations.append((thread_id, client_message_id, text))
            pending = self.store.pending_deliveries("chat")
            assert len(pending) == 1
            assert pending[0]["native_attempt"] == {
                "thread_id": thread_id, "client_id": client_message_id,
                "attempted_at": pending[0]["native_attempt"]["attempted_at"],
            }
            assert not any(item.get("_delivery_id") for item in self.core.messages)
            receipt = {"type": "userMessage", "clientId": client_message_id}
            if not self.fail_first or self.receipt_before_failure:
                self.receipts.setdefault(thread_id, []).append(receipt)
            if self.emit_receipt:
                event_handler({"method": "item/started", "params": {"item": receipt}})
            if self.fail_first:
                self.fail_first = False
                raise CodexAppServerError("Connection lost during continuation")
        if on_tick:
            on_tick()
        return super().run_turn(text=text, event_handler=event_handler, **kwargs)


def answer_at_final_boundary(core, store):
    created = []

    def before_finalize():
        if not created:
            created.append(answer(store))

    core.before_finalize = before_finalize


def test_native_final_boundary_budget_keeps_answer_pending_until_explicit_resume(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    runtime = BoundaryRuntime(store)
    core = _managed_core(tmp_path, runtime)
    runtime.core = core
    connect_outbox(core, store)
    answer_at_final_boundary(core, store)
    core.run_turn("Independent work", allow_tools=False, model_call_limit=1)

    assert core.last_turn_result["reason"] == "model_call_budget"
    assert len(runtime.turn_texts) == 1
    assert not runtime.continuations
    assert store.snapshot("chat")[0]["delivery_status"] == "accepted"
    assert "native_attempt" not in store.pending_deliveries("chat")[0]
    assert not any(item.get("_delivery_id") for item in core.messages)

    # Starting another attempt alone cannot consume the previous attempt's
    # accepted answer. Resume must rebind the durable record explicitly.
    core.context_delivery_source = lambda: store.pending_deliveries("chat", "next-run")
    core.run_turn("Next independent work", allow_tools=False)
    assert core.last_turn_result["reason"] == "complete"
    assert len(runtime.turn_texts) == 2
    assert not runtime.continuations
    assert store.snapshot("chat")[0]["delivery_status"] == "accepted"
    store.resume("chat", "next-run")
    core.run_turn("Resume the accepted answer", allow_tools=False)
    assert core.last_turn_result["reason"] == "complete"
    assert len(runtime.continuations) == 1
    assert "User answer: Remote" in runtime.continuations[0][2]
    assert store.snapshot("chat")[0]["delivery_status"] == "applied"


@pytest.mark.parametrize("restart", [False, "resume", "replace"])
@pytest.mark.parametrize("receipt_exists", [False, True])
def test_failed_native_continuation_reconciles_before_forwarding_and_ack(tmp_path, restart, receipt_exists):
    clock = Clock()
    store = QuestionService(tmp_path / "questions.sqlite3", clock=clock)
    runtime = BoundaryRuntime(store, fail_first=True, receipt_before_failure=receipt_exists)
    core = _managed_core(tmp_path, runtime)
    runtime.core = core
    connect_outbox(core, store)
    answer_at_final_boundary(core, store)
    core.run_turn("Independent work", allow_tools=False)

    assert core.last_turn_result["reason"] == "error"
    assert len(runtime.continuations) == 1
    assert store.snapshot("chat")[0]["delivery_status"] == "accepted"
    assert not any(item.get("_delivery_id") for item in core.messages)
    original_attempt = dict(store.pending_deliveries("chat")[0]["native_attempt"])
    if restart:
        session_id = core.session.session_id
        core.close()
        store = QuestionService(store.path, clock=clock)
        store.recover_session("chat")
        store.resume("chat", "run")
        runtime.store = store
        runtime.reject_resume = restart == "replace"
        core = _managed_core(tmp_path, runtime)
        core.resume_session(session_id)
        runtime.core = core
        connect_outbox(core, store)
    core.run_turn("Resume the task", allow_tools=False)

    assert "thread-1" in runtime.reads
    if receipt_exists:
        assert core.last_turn_result["reason"] == "complete"
        if restart == "resume":
            assert runtime.resumed == ["thread-1"]
            assert len(runtime.continuations) == 1
        else:
            assert [item[0] for item in runtime.continuations] == ["thread-1", "thread-2"]
            assert runtime.continuations[0][2] == runtime.continuations[1][2]
        assert store.snapshot("chat")[0]["delivery_status"] == "applied"
        assert len([item for item in core.messages if item.get("_delivery_id")]) == 1
    else:
        assert core.last_turn_result["reason"] == "error"
        assert len(runtime.continuations) == 1
        assert store.snapshot("chat")[0]["delivery_status"] == "accepted"
        assert store.pending_deliveries("chat")[0]["native_attempt"] == original_attempt
        assert not any(item.get("_delivery_id") for item in core.messages)


def test_native_continuation_receipt_remains_applied_if_later_rpc_fails(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    runtime = BoundaryRuntime(store, fail_first=True, receipt_before_failure=True, emit_receipt=True)
    core = _managed_core(tmp_path, runtime)
    runtime.core = core
    connect_outbox(core, store)
    answer_at_final_boundary(core, store)
    core.run_turn("Independent work", allow_tools=False)
    assert core.last_turn_result["reason"] == "error"
    assert store.snapshot("chat")[0]["delivery_status"] == "applied"
    assert len([item for item in core.messages if item.get("_delivery_id")]) == 1
    core.run_turn("Resume the task", allow_tools=False)
    assert len(runtime.continuations) == 1
    assert "User answer: Remote" in runtime.turn_texts[-1]


def test_native_final_continuation_receipt_applies_every_batched_record_once(tmp_path):
    store = QuestionService(tmp_path / "questions.sqlite3", clock=Clock())
    runtime = BoundaryRuntime(store)
    core = _managed_core(tmp_path, runtime)
    runtime.core = core
    connect_outbox(core, store)
    created = []
    events = []
    core.on_event(events.append)

    def before_finalize():
        if not created:
            created.append(answer(store))
            return "Helper result: the independent check passed."

    core.before_finalize = before_finalize
    core.run_turn("Independent work", allow_tools=False)
    assert core.last_turn_result["reason"] == "complete"
    assert len(runtime.continuations) == 1
    assert "Helper result" in runtime.continuations[0][2]
    assert "User answer: Remote" in runtime.continuations[0][2]
    assert len([item for item in core.messages if item.get("_delivery_id")]) == 2
    assert len([item for item in events if item["type"] == "context_delivery_applied"]) == 2
    assert store.pending_deliveries("chat") == []


def test_app_server_continuation_correlates_turn_start_input(monkeypatch):
    manager = CodexAppServerManager(helper_path="/not/executed")
    events = queue.Queue()
    events.put({"method": "turn/completed", "params": {"turn": {"id": "turn-1", "status": "completed"}}})
    requests = []
    monkeypatch.setattr(manager, "_subscribe", lambda _thread: events)
    monkeypatch.setattr(manager, "_unsubscribe", lambda _thread, _events: None)

    def request(method, params, **_kwargs):
        requests.append((method, params))
        return {"turn": {"id": "turn-1"}}

    monkeypatch.setattr(manager, "request", request)
    manager.run_turn(thread_id="thread-1", text="Question outcome", client_message_id="delivery-1")
    assert requests == [("turn/start", {
        "threadId": "thread-1", "input": [{"type": "text", "text": "Question outcome"}],
        "clientUserMessageId": "delivery-1",
    })]


@pytest.mark.parametrize("client_id", ["question:delivery-1", ""])
def test_broker_preserves_continuation_correlation_and_legacy_signature(monkeypatch, client_id):
    service, helpers = service_with_helpers()

    class Socket:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            pass

        def send(self, request):
            broker_socket = BrokerSocket(service, json.loads(request))
            asyncio.run(ws_codex_broker(broker_socket))
            self.messages = iter(broker_socket.messages)

        def recv(self, **_kwargs):
            return json.dumps(next(self.messages))

    monkeypatch.setattr(CodexBrokerClient, "_connect", lambda _self: Socket())
    client = CodexBrokerClient("ws://unused/broker", "fixture").for_account("work")
    client.run_turn(thread_id="thread", text="Question outcome", client_message_id=client_id)
    arguments = helpers["work"].calls[0][1]
    if client_id:
        assert arguments["client_message_id"] == client_id
    else:
        assert "client_message_id" not in arguments
