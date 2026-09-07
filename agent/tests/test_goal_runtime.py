"""Goal execution boundaries use fake providers and real durable accounting."""
from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from ollama_code.core import AgentCore
from ollama_code.goal_runtime import (
    GoalRuntime,
    attach_goal_runtime,
    bind_goal_runtime,
    validate_goal_report,
)
from ollama_code.goals import GoalBudgetExceeded, GoalError, GoalStore
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.orchestration import TeamOrchestrator
from ollama_code.runstore import RunStore


def runtime(tmp_path, *, budget=None):
    runs = RunStore(tmp_path / "runs.sqlite3")
    store = GoalStore(runs)
    goal = store.create("session", "Finish and verify the change", model_call_budget=budget,
                        execution={"workspace_root": str(tmp_path), "runner": "solo",
                                   "provider": "ollama", "model": "test",
                                   "execution_environment": "local"})
    claim = store.claim(goal["id"], goal["revision"])
    run = claim["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    return GoalRuntime(store, claim["goal"], run["id"])


def report(status="complete"):
    return {"status": status, "summary": "Implemented and checked", "evidence": ["Tests passed"],
            **({"next_step": "Check the remaining integration"} if status == "continue" else {})}


def core(tmp_path, goal, *, coordinator=True):
    value = AgentCore(cwd=str(tmp_path), config={"model": "test"})
    attach_goal_runtime(value, goal, coordinator=coordinator)
    value._request_messages = lambda: [{"role": "user", "content": "work"}]
    value.chat_options = lambda: None
    return value


def test_provider_request_is_reserved_before_execution_and_settled_once(tmp_path):
    goal = runtime(tmp_path, budget=1)
    agent = core(tmp_path, goal)
    def call(**kwargs):
        assert goal.snapshot()["model_calls"] == 1
        return ChatResponse(content_parts=["done"], prompt_eval_count=21, eval_count=3)
    agent.client = SimpleNamespace(chat_stream=call)
    response = agent._stream_response()
    assert response.content == "done"
    assert goal.snapshot()["prompt_tokens"] == 21
    assert goal.snapshot()["completion_tokens"] == 3
    with pytest.raises(GoalBudgetExceeded):
        agent._stream_response()
    assert goal.snapshot()["model_calls"] == 1


def test_unknown_provider_result_survives_restart_and_cannot_continue(tmp_path):
    goal = runtime(tmp_path)
    agent = core(tmp_path, goal)
    def fail(**kwargs):
        raise RuntimeError("connection lost after dispatch")
    agent.client = SimpleNamespace(chat_stream=fail)
    with pytest.raises(RuntimeError):
        agent._stream_response()
    restored = GoalRuntime(GoalStore(RunStore(goal.store.run_store.path)), goal.snapshot(), goal.run_id)
    assert restored.finish("error")["status"] == "blocked"
    assert restored.snapshot()["model_calls"] == 1


def test_child_cannot_report_parent_goal_even_by_guessing_tool_name(tmp_path):
    goal = runtime(tmp_path)
    child = core(tmp_path, goal, coordinator=False)
    names = {schema["function"]["name"] for schema in child.tool_registry.schemas()}
    assert not names.intersection({"get_goal", "update_goal"})
    result = child._run_tool_call(ToolCall(name="update_goal", arguments=report()), None)
    assert result.startswith("Error:")
    assert goal.finish("complete")["status"] == "active"
    assert goal.snapshot()["no_progress_count"] == 1


def test_native_duplicates_and_replayed_totals_do_not_rebill_history(tmp_path):
    goal = runtime(tmp_path)
    def call(**kwargs):
        for prompt, completion in [(110, 15), (110, 15), (125, 20), (110, 15)]:
            kwargs["event_handler"]({"method": "thread/tokenUsage/updated", "params": {
                "tokenUsage": {"total": {"inputTokens": prompt, "outputTokens": completion},
                               "last": {"inputTokens": 10, "outputTokens": 5}}}})
        return {"status": "completed"}
    goal.run_native(call, thread_id="thread", usage_baseline=(100, 10))
    assert goal.snapshot()["model_calls"] == 2
    assert goal.snapshot()["prompt_tokens"] == 25
    assert goal.snapshot()["completion_tokens"] == 10
    goal.submit_report(report())
    assert goal.finish("complete")["status"] == "completed"


def test_native_missing_usage_does_not_settle_unknown_tokens_as_zero(tmp_path):
    goal = runtime(tmp_path, budget=3)
    goal.run_native(lambda **_: {"status": "completed"}, thread_id="thread")
    goal.submit_report(report())
    assert goal.finish("complete")["status"] == "blocked"
    assert goal.snapshot()["token_usage_available"] is False


def test_mutation_journal_precedes_side_effect_and_unknown_result_blocks(tmp_path, monkeypatch):
    goal = runtime(tmp_path)
    agent = core(tmp_path, goal)
    def execute(name, arguments, context):
        with goal.store.run_store._connect(readonly=True) as connection:
            action = connection.execute("SELECT state FROM goal_actions WHERE goal_id=?", (goal.goal_id,)).fetchone()
        assert action["state"] == "started"
        (tmp_path / "changed.txt").write_text("changed")
        raise RuntimeError("crash after mutation")
    monkeypatch.setattr("ollama_code.core.execute_tool", execute)
    with pytest.raises(RuntimeError):
        agent._run_tool_call(ToolCall(name="write_file", arguments={"path": "changed.txt", "content": "changed"}), lambda *_: "once")
    assert (tmp_path / "changed.txt").exists()
    assert goal.finish("error")["status"] == "blocked"


def test_team_synthesis_repairs_once_uses_writer_evidence_and_returns_answer(tmp_path):
    goal = runtime(tmp_path)
    orchestrator = TeamOrchestrator(lambda _: None, lambda: False)
    orchestrator.goal_runtime = goal
    dispatcher = SimpleNamespace(id="dispatcher")
    prepared = SimpleNamespace(team=SimpleNamespace(id="team", dispatcher_id="dispatcher",
                                                    budget=SimpleNamespace(max_model_calls=5)),
        profiles={"dispatcher": dispatcher}, original_request="Build it", plan=SimpleNamespace(structured=lambda: {}),
        results=[], writer_results=[SimpleNamespace(structured=lambda: {"output": "Verified writer evidence"})],
        run_id=goal.run_id)
    calls = []
    def call(run_id, job, profile, budget, **kwargs):
        calls.append(job)
        identifier = goal.reserve()
        goal.settle(identifier, prompt_tokens=10, completion_tokens=10)
        orchestrator._call_count += 1
        return SimpleNamespace(output="bad" if len(calls) == 1 else json.dumps({"answer": "Done and verified.", "goal": report()}))
    orchestrator._call_agent = call
    assert orchestrator.synthesize(prepared, [], "diff") == "Done and verified."
    assert [job.id for job in calls] == ["synthesis", "synthesis-repair"]
    assert "Verified writer evidence" in calls[0].goal
    assert goal.snapshot()["status"] == "active"
    assert goal.finish("complete")["status"] == "completed"


@pytest.mark.parametrize("value", [report() | {"evidence": []}, report("continue") | {"next_step": ""},
                                   report() | {"status": "maybe"}, report() | {"goal_id": "other"}])
def test_goal_reports_require_evidence_and_trusted_identity(value):
    with pytest.raises(GoalError):
        validate_goal_report(value)


def test_unmetered_provider_without_budget_can_complete(tmp_path):
    goal = runtime(tmp_path)
    goal.run_native(lambda **_: {"status": "completed"}, thread_id="thread")
    goal.submit_report(report())
    assert goal.finish("complete")["status"] == "completed"
    assert goal.snapshot()["token_usage_available"] is False


def test_unanswered_required_wait_survives_restart(tmp_path):
    goal = runtime(tmp_path)
    goal.submit_report(report())
    goal.begin_wait("permission-1", "permission_request")
    restored = GoalRuntime(GoalStore(RunStore(goal.store.run_store.path)), goal.snapshot(), goal.run_id)
    assert restored.finish("app_shutdown")["status"] == "blocked"


def test_later_mutation_invalidates_old_completion_evidence(tmp_path):
    goal = runtime(tmp_path)
    goal.submit_report(report())
    goal.start_action("write-1", "write_file")
    goal.finish_action("write-1", ok=True)
    assert goal.finish("complete")["status"] == "active"


def test_durable_admission_cannot_bind_a_different_chat_worker(tmp_path):
    goal = runtime(tmp_path)
    service = SimpleNamespace(run_store=goal.store.run_store, emit=lambda _: None,
                              core=SimpleNamespace(session=SimpleNamespace(session_id="another-session")))
    with pytest.raises(GoalError, match="different chat"):
        bind_goal_runtime(service, goal.run_id)


def test_queued_input_preserves_execution_but_pause_resume_revokes_old_run(tmp_path):
    goal = runtime(tmp_path)
    agent = core(tmp_path, goal)
    goal.store.update(goal.goal_id, "steer", input_id="queued-input")
    assert agent._should_stop_stream() is False
    goal.store.update(goal.goal_id, "pause")
    goal.store.update(goal.goal_id, "resume")
    goal._checked_at = 0
    assert goal.snapshot()["status"] == "active"
    assert agent._should_stop_stream() is True
    with pytest.raises(GoalError):
        goal.reserve()


def test_team_completion_report_cannot_override_unapproved_review(tmp_path):
    goal = runtime(tmp_path)
    orchestrator = TeamOrchestrator(lambda _: None, lambda: False)
    orchestrator.goal_runtime = goal
    dispatcher = SimpleNamespace(id="dispatcher")
    prepared = SimpleNamespace(team=SimpleNamespace(id="team", dispatcher_id="dispatcher",
                                                    budget=SimpleNamespace(max_model_calls=5)),
        profiles={"dispatcher": dispatcher}, original_request="Build it", plan=SimpleNamespace(structured=lambda: {}),
        results=[], writer_results=[], run_id=goal.run_id)
    review = SimpleNamespace(job_id="review", output='{"verdict":"revise"}',
                             structured=lambda: {"output": '{"verdict":"revise"}'})
    calls = []
    def call(*args, **kwargs):
        calls.append(args[1].id)
        return SimpleNamespace(output=json.dumps({"answer": "All done", "goal": report()}))
    orchestrator._call_agent = call
    assert "needs attention" in orchestrator.synthesize(prepared, [review], "diff")
    assert calls == ["synthesis", "synthesis-repair"]
    assert goal.finish("complete")["status"] == "paused"


def test_goal_completion_event_is_committed_before_terminal_delivery(tmp_path):
    import asyncio

    from ollama_code.chat_service import ChatService

    goal = runtime(tmp_path)
    agent = core(tmp_path, goal)
    service = ChatService(agent)
    service.run_store = goal.store.run_store
    service.active_run_id = goal.run_id
    service.goal_runtime = goal
    goal.submit_report(report())
    async def emit():
        service.loop = asyncio.get_running_loop()
        service.emit({"type": "turn_done", "reason": "complete"})
        snapshot = service.queue.get_nowait()
        terminal = service.queue.get_nowait()
        assert snapshot["type"] == "goal_snapshot"
        assert snapshot["goal"]["status"] == "completed"
        assert terminal["type"] == "turn_done"
        assert terminal["goal_id"] == goal.goal_id
        assert terminal["goal_revision"] == goal.revision
    try:
        asyncio.run(emit())
    finally:
        service.close_codex()


class _GoalProvider:
    host = "http://localhost:11434"
    timeout = 30

    def __init__(self, responses):
        self.responses = list(responses)
        self.tools = []

    def chat_stream(self, model, messages, tools=None, on_token=None, **kwargs):
        self.tools.append({value["function"]["name"] for value in tools or []})
        response = self.responses.pop(0)
        if on_token:
            for part in response.content_parts:
                on_token(part)
        return response

    def context_length(self, model):
        return 32768

    def loaded_context_length(self, model):
        return 32768

    def resident_state(self, model):
        return {"context_length": 32768, "size": 0, "size_vram": 0}


def _goal_response(*, status=None, text="Verified progress."):
    return ChatResponse(content_parts=[text], prompt_eval_count=10, eval_count=5, done=True,
                        tool_calls=[ToolCall(name="update_goal", arguments=report(status), call_id="goal-report")]
                        if status else [])


def test_http_claim_websocket_admission_provider_reports_and_continuation(tmp_path, monkeypatch):
    """Exercise the real chat worker, tools, event pump and durable API together."""
    from fastapi.testclient import TestClient

    from ollama_code import server
    from ollama_code.chat_service import ChatService

    # Ambient recall is independent of goal execution and must not contact an
    # embedding provider in this deterministic transport integration test.
    monkeypatch.setattr(server, "_automatic_memory_context", lambda *_a, **_kw: "")
    monkeypatch.setattr(server, "_automatic_continuity_context", lambda *_a, **_kw: "")
    monkeypatch.setattr(server, "_capture_continuity_snapshot", lambda *_a, **_kw: None)
    agent = AgentCore(cwd=str(tmp_path), config={"model": "test", "max_iterations": 6})
    provider = _GoalProvider([
        _goal_response(text="This ordinary turn ended."),
        _goal_response(status="continue"), _goal_response(),
        _goal_response(status="complete"), _goal_response(text="Everything is verified."),
        _goal_response(text="A regular non-goal reply."),
    ])
    agent.client = provider
    service = ChatService(agent)
    app = server.create_app(chat_service=service)
    session_id = agent.session.session_id
    with TestClient(app) as client, client.websocket_connect("/ws/chat") as socket:
        assert socket.receive_json()["type"] == "session_info"
        created = client.post(f"/api/sessions/{session_id}/goal", json={
            "objective": "Finish the change and verify it", "model_call_budget": 10,
            "execution": {"workspace_root": str(tmp_path), "provider": "ollama", "model": "test", "runner": "solo"},
        })
        assert created.status_code == 200, created.text
        goal = created.json()
        previous = None
        for ordinal, expected_status in enumerate(["active", "active", "completed"], start=1):
            claimed = client.post(f"/api/goals/{goal['id']}/claim", json={"expected_revision": goal["revision"]})
            assert claimed.status_code == 200, claimed.text
            run = claimed.json()["run"]
            assert run is not None and run["state"] == "queued"
            assert run["id"] != previous
            repeated = client.post(f"/api/goals/{goal['id']}/claim", json={"expected_revision": goal["revision"]})
            assert repeated.json()["run"]["id"] == run["id"]
            admitted = client.patch(f"/api/runs/{run['id']}/queue", json={"action": "admit"})
            assert admitted.status_code == 200, admitted.text
            socket.send_json({"type": "user_message", "text": run["request"], "mode": "work",
                              "run_id": run["id"], "request_id": f"request-{ordinal}"})
            events = []
            while not events or events[-1]["type"] != "turn_done":
                events.append(socket.receive_json())
                assert len(events) < 100
            terminal = events[-1]
            assert any(event["type"] == "turn_accepted" and event["request_id"] == f"request-{ordinal}" for event in events)
            assert terminal["reason"] == "complete"
            assert terminal["goal_id"] == goal["id"]
            snapshots = [event for event in events if event["type"] == "goal_snapshot"]
            assert snapshots[-1]["goal"]["status"] == expected_status
            goal = client.get(f"/api/sessions/{session_id}/goal").json()["goal"]
            assert goal["status"] == expected_status
            assert goal["model_calls"] == [1, 3, 5][ordinal - 1]
            assert goal["prompt_tokens"] == goal["model_calls"] * 10
            assert goal["completion_tokens"] == goal["model_calls"] * 5
            assert service.run_store.run(run["id"])["state"] == "completed"
            if ordinal == 1:
                assert goal["no_progress_count"] == 1  # turn completion is not goal completion
            previous = run["id"]
        assert client.post(f"/api/goals/{goal['id']}/claim", json={"expected_revision": goal["revision"]}).json()["run"] is None
        socket.send_json({"type": "retry_last"})
        retry = socket.receive_json()
        while retry["type"] == "session_info":
            retry = socket.receive_json()
        assert retry["type"] == "command_error"
        assert retry["operation"] == "retry_last"
        assert "Goal Resume" in retry["message"]
        assert len(provider.responses) == 1  # no unbudgeted provider replay
        socket.send_json({"type": "user_message", "text": "/retry"})
        slash_retry = socket.receive_json()
        assert slash_retry["type"] == "slash_result"
        assert slash_retry["error"] is True
        assert "Goal Resume" in slash_retry["text"]
        assert len(provider.responses) == 1
        socket.send_json({"type": "user_message", "text": "A regular follow-up", "mode": "work", "request_id": "ordinary"})
        event = socket.receive_json()
        while event["type"] != "turn_done":
            event = socket.receive_json()
        assert "goal_id" not in event
        assert event["reason"] == "complete"
        assert not provider.tools[-1].intersection({"get_goal", "update_goal"})
        assert all({"get_goal", "update_goal"} <= tools for tools in provider.tools[:-1])


def test_classic_mutation_stays_uncertain_until_tool_result_is_durable(tmp_path, monkeypatch):
    goal = runtime(tmp_path)
    agent = core(tmp_path, goal)
    agent.client = _GoalProvider([ChatResponse(
        content_parts=[], prompt_eval_count=10, eval_count=5,
        tool_calls=[ToolCall(name="write_file", arguments={"path": "changed.txt", "content": "changed"}, call_id="write")],
    )])
    append = agent.session.append_strict
    def fail_tool_result(record):
        if record.get("message", {}).get("role") == "tool":
            raise OSError("disk failed after mutation")
        append(record)
    monkeypatch.setattr(agent.session, "append_strict", fail_tool_result)
    with pytest.raises(OSError, match="after mutation"):
        agent.run_turn("Write the change", lambda *_: "once")
    assert (tmp_path / "changed.txt").read_text() == "changed"
    restored = GoalRuntime(GoalStore(RunStore(goal.store.run_store.path)), goal.snapshot(), goal.run_id)
    assert restored.finish("app_shutdown")["status"] == "blocked"


def test_queued_user_input_invalidates_completion_without_interrupting_provider(tmp_path, monkeypatch):
    import threading

    from fastapi.testclient import TestClient

    from ollama_code import server
    from ollama_code.chat_service import ChatService

    monkeypatch.setattr(server, "_automatic_memory_context", lambda *_a, **_kw: "")
    monkeypatch.setattr(server, "_automatic_continuity_context", lambda *_a, **_kw: "")
    monkeypatch.setattr(server, "_capture_continuity_snapshot", lambda *_a, **_kw: None)
    entered, release = threading.Event(), threading.Event()

    class PausingProvider(_GoalProvider):
        def chat_stream(self, *args, **kwargs):
            if len(self.tools) == 1:
                entered.set()
                assert release.wait(5), "test did not release the in-flight request"
                if kwargs["should_stop"]():
                    raise RuntimeError("queued input interrupted an in-flight request")
            return super().chat_stream(*args, **kwargs)

    agent = AgentCore(cwd=str(tmp_path), config={"model": "test", "max_iterations": 8})
    agent.perms.set_mode("bypass")
    provider = PausingProvider([
        _goal_response(status="complete"),
        ChatResponse(content_parts=[], prompt_eval_count=10, eval_count=5,
                     tool_calls=[ToolCall(name="write_file", arguments={"path": "once.txt", "content": "saved"}, call_id="write-once")]),
        _goal_response(status="complete"), _goal_response(text=(
            "The original change is saved in once.txt and its write finished successfully. "
            "The new request is queued and will be considered in the following turn. "
            "All provider requests from this turn have returned their measured usage."
        )),
        _goal_response(status="complete"), _goal_response(text="Additional scenario verified."),
    ])
    agent.client = provider
    service = ChatService(agent)
    app = server.create_app(chat_service=service)
    session_id = agent.session.session_id

    def terminal(socket):
        events = []
        while not events or events[-1]["type"] != "turn_done":
            events.append(socket.receive_json())
            assert len(events) < 100
        return events[-1]

    with TestClient(app) as client, client.websocket_connect("/ws/chat") as socket:
        assert socket.receive_json()["type"] == "session_info"
        goal = client.post(f"/api/sessions/{session_id}/goal", json={
            "objective": "Finish and verify the change", "model_call_budget": 12,
            "execution": {"workspace_root": str(tmp_path), "provider": "ollama", "model": "test", "runner": "solo"},
        }).json()
        run = client.post(f"/api/goals/{goal['id']}/claim", json={"expected_revision": goal["revision"]}).json()["run"]
        assert client.patch(f"/api/runs/{run['id']}/queue", json={"action": "admit"}).status_code == 200
        socket.send_json({"type": "user_message", "text": run["request"], "mode": "work",
                          "run_id": run["id"], "request_id": "initial"})
        try:
            assert entered.wait(5), "provider never reached its second request"
            steered = client.patch(f"/api/goals/{goal['id']}", json={
                "action": "steer", "expected_revision": goal["revision"], "input_id": "queued-input",
            })
            assert steered.status_code == 200, steered.text
            goal = steered.json()
            assert goal["pending_user_input"] is True
            assert goal["execution_revision"] < goal["revision"]
            service.goal_runtime._checked_at = 0  # exercise a fresh control read in the provider
        finally:
            release.set()
        original = terminal(socket)
        assert original["reason"] == "complete"
        assert original["goal"]["status"] == "active"
        assert original["goal"]["pending_user_input"] is True
        assert original["goal"]["model_calls"] == 4
        assert original["goal"]["prompt_tokens"] == 40
        assert (tmp_path / "once.txt").read_text() == "saved"
        with service.run_store._connect(readonly=True) as connection:
            assert connection.execute("SELECT COUNT(*) FROM goal_usage WHERE state='reserved'").fetchone()[0] == 0
            assert connection.execute("SELECT COUNT(*) FROM goal_actions WHERE state='started'").fetchone()[0] == 0
            assert connection.execute("SELECT COUNT(*) FROM goal_actions WHERE tool='write_file'").fetchone()[0] == 1
        queued = client.post("/api/runs/queue", json={
            "run_id": "queued-user-run", "session_id": session_id, "request": "Verify one additional scenario",
            "goal_id": goal["id"], "goal_revision": goal["revision"], "goal_input_id": "queued-input",
        })
        assert queued.status_code == 200, queued.text
        assert client.patch("/api/runs/queued-user-run/queue", json={"action": "admit"}).status_code == 200
        socket.send_json({"type": "user_message", "text": "Verify one additional scenario", "mode": "work",
                          "run_id": "queued-user-run", "request_id": "queued-input"})
        followup = terminal(socket)
        assert followup["reason"] == "complete"
        assert followup["goal_id"] == goal["id"]
        assert followup["goal_revision"] == goal["revision"]
        assert followup["goal"]["status"] == "completed"
        assert followup["goal"]["model_calls"] == 6
        assert followup["goal"]["prompt_tokens"] == 60
        assert followup["goal"]["pending_user_input"] is False
