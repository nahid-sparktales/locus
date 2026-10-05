"""Deferred regression checks for reviewed suite snapshots and cancellation admission."""
from concurrent.futures import Future
from threading import Event, RLock
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from ollama_code.api import memory_learning
from ollama_code.chat_service import ChatService
from ollama_code.task_state import digest


def test_suite_approval_rejects_a_changed_displayed_snapshot(monkeypatch):
    suite = {"id": "suite", "cases": [{"prompt": "Original"}]}
    displayed = digest(suite)
    suite["cases"][0]["prompt"] = "Changed after display"
    service = SimpleNamespace(run_store=None, core=SimpleNamespace(workspace_root="/workspace", cwd="/workspace"))
    monkeypatch.setattr(memory_learning, "_context", lambda *_: (SimpleNamespace(engine=None), None, "agent"))
    monkeypatch.setattr(memory_learning, "_procedure", lambda *_: SimpleNamespace(version=1))
    monkeypatch.setattr(memory_learning.EvaluationStore, "get_suite", lambda *_: suite)
    with pytest.raises(HTTPException) as exc:
        memory_learning.approve_evaluation("procedure", service, {
            "approved": True, "expected_version": 1, "suite_id": "suite",
            "expected_suite_fingerprint": displayed, "negative_case_ids": ["negative"]})
    assert exc.value.status_code == 409


def test_suite_review_exposes_only_current_workspace_with_fingerprint(monkeypatch):
    suite = {"id": "suite", "cases": []}
    service = SimpleNamespace(run_store=None, core=SimpleNamespace(workspace_root="/owned", cwd="/checkout"))
    access = SimpleNamespace(grants=SimpleNamespace(projects={"owned-hash"}))
    monkeypatch.setattr(memory_learning, "_context", lambda *_: (None, access, "agent"))
    def listing(_store, workspace):
        assert workspace == "/owned"
        return [suite]
    monkeypatch.setattr(memory_learning.EvaluationStore, "list_suites", listing)
    assert memory_learning.procedure_evaluation_suites(service) == {
        "suites": [{"suite": suite, "fingerprint": digest(suite)}]}


def test_new_cancellation_survives_worker_admission():
    interrupt = Event()
    interrupt.set()  # Stop from the previous turn.
    service = SimpleNamespace(_state_guard=RLock(), _state_mutating=False, turn_future=None,
        _terminal_events=0, core=SimpleNamespace(_interrupt=interrupt))
    future = Future()
    def submit(_executor, _call, *_args):
        assert not interrupt.is_set()
        interrupt.set()  # Stop arrives after admission but before worker execution.
        return future
    assert ChatService.start_turn(service, SimpleNamespace(run_in_executor=submit), lambda: None,
                                  reset_interrupt=True)
    assert interrupt.is_set()


def test_rejected_admission_does_not_clear_running_turn_cancellation():
    interrupt = Event()
    interrupt.set()
    service = SimpleNamespace(_state_guard=RLock(), _state_mutating=True, turn_future=None,
        core=SimpleNamespace(_interrupt=interrupt))
    assert not ChatService.start_turn(service, None, lambda: None, reset_interrupt=True)
    assert interrupt.is_set()
