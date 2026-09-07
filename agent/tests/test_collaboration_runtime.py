from __future__ import annotations

import copy
import json
import threading
import time
from concurrent.futures import Future
from types import SimpleNamespace

import pytest

from ollama_code.chat_service import ChatService
from ollama_code.codex_app_server import CodexThreadOptions
from ollama_code.collaboration import WorkerSpec
from ollama_code.collaboration_bridge import AgentWorkerRuntime, CollaborationBridge
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.orchestration import ModelCallScheduler
from ollama_code.tools import ToolContext, execute_tool


def service(path, provider="ollama"):
    core = AgentCore(
        cwd=str(path),
        config={
            "model": "fixture",
            "provider": provider,
            "chatgpt_model": "fixture",
            "remote_model": "fixture",
            "remote_base_url": "https://api.example.invalid/v1",
        },
    )
    core.configure_agent(None)
    events = []
    return SimpleNamespace(
        core=core,
        codex=SimpleNamespace(supports_parity=True),
        run_store=None,
        emit=events.append,
        events=events,
        decide=lambda *_: "deny",
        collaboration_scheduler=ModelCallScheduler(),
        _execute_background_service=lambda _: "unused",
        pending_context_deliveries=lambda: [],
        mark_question_delivery_applied=lambda _: None,
        question_before_finalize=lambda: False,
    )


def worker(svc, path, checkpoint=None, mode="research", tools=None):
    return AgentWorkerRuntime(
        svc,
        WorkerSpec(
            "helper", "session", "run", str(path), mode, {}, checkpoint or {}, "Helper", tools
        ),
        threading.RLock(),
    )


def run(runtime, messages=None, **kwargs):
    inbox = list(messages or [])

    def drain():
        values = list(inbox)
        inbox.clear()
        return values

    return runtime.run(
        "Continue",
        max_calls=8,
        should_stop=lambda: False,
        drain_messages=drain,
        on_usage=lambda _: None,
        **kwargs,
    )


def test_native_send_checkpoint_precedes_transport_and_unconfirmed_send_is_not_replayed(tmp_path):
    svc = service(tmp_path, "chatgpt")
    checkpoints, sends = [], []

    def steer(thread_id, text, client_id):
        saved = checkpoints[-1]
        assert saved["mailbox_ack_seq"] == 0
        assert saved["mailbox_pending"][client_id]["native_attempt"]["thread_id"] == thread_id
        sends.append(client_id)
        raise OSError("transport acknowledgment lost")

    svc.codex.steer_turn = steer
    svc.codex.read_thread = lambda _: {}
    runtime = worker(svc, tmp_path)

    def first_turn(*_, **__):
        runtime.core._chatgpt_thread_id = "original-thread"
        runtime.core._flush_native_guidance(runtime.core.codex_manager)
        runtime.core.interrupt()
        runtime.core.last_turn_result = {"reason": "interrupted"}

    runtime.core.run_turn = first_turn
    result = run(
        runtime,
        [{"seq": 7, "text": "Check the changed requirement"}],
        on_checkpoint=lambda value: checkpoints.append(copy.deepcopy(value)),
    )
    assert result["reason"] == "interrupted"
    checkpoint = runtime.snapshot()
    assert checkpoint["mailbox_ack_seq"] == 0
    assert checkpoint["native_guidance"]["helper-mail-7"]["sent"]
    runtime.close()

    resumed = worker(svc, tmp_path, checkpoint)
    resumed.core.run_turn = lambda *_, **__: pytest.fail("must reconcile before calling the model")
    try:
        with pytest.raises(RuntimeError, match="unconfirmed native delivery"):
            run(resumed)
        assert sends == ["helper-mail-7"]
        assert resumed.snapshot()["mailbox_ack_seq"] == 0
    finally:
        resumed.close()

    svc.codex.read_thread = lambda _: {"turns": [{"clientUserMessageId": "helper-mail-7"}]}
    confirmed = worker(svc, tmp_path, checkpoint)

    def confirmed_turn(*_, **__):
        assert confirmed.snapshot()["mailbox_ack_seq"] == 7
        confirmed.core.last_turn_result = {"reason": "complete"}
        confirmed.core.messages.append({"role": "assistant", "content": "Confirmed"})

    confirmed.core.run_turn = confirmed_turn
    try:
        assert run(confirmed)["output"] == "Confirmed"
        assert sum(m.get("_delivery_id") == "helper-mail-7" for m in confirmed.core.messages) == 1
        assert sends == ["helper-mail-7"]
    finally:
        confirmed.close()


def test_out_of_order_confirmation_does_not_skip_pending_mail(tmp_path):
    runtime = worker(service(tmp_path), tmp_path)
    snapshots = []

    def turn(*_, **__):
        pending = runtime.core.context_delivery_source()
        runtime.core._record_context_delivery(pending[1]["delivery_id"], pending[1]["text"])
        assert runtime.snapshot()["mailbox_ack_seq"] == 0
        runtime.core._record_context_delivery(pending[0]["delivery_id"], pending[0]["text"])
        runtime.core.last_turn_result = {"reason": "complete"}

    runtime.core.run_turn = turn
    try:
        run(
            runtime,
            [{"seq": 3, "text": "first"}, {"seq": 8, "text": "second"}],
            on_checkpoint=snapshots.append,
        )
        assert [s["mailbox_ack_seq"] for s in snapshots] == [0, 8]
        assert runtime.snapshot()["mailbox_pending"] == {}
    finally:
        runtime.close()


def test_native_helper_cannot_reconfigure_shared_account_or_enable_native_tools(tmp_path):
    svc = service(tmp_path, "chatgpt")
    options = []
    original = CodexThreadOptions(native_prompt=True, web_search=True)
    svc.codex.thread_defaults = original
    svc.codex.set_thread_defaults = lambda _: pytest.fail("helper changed shared account defaults")
    svc.codex.start_thread = lambda **kwargs: options.append(kwargs["options"]) or "child-thread"
    svc.codex.resume_thread = lambda thread_id, **kwargs: (
        options.append(kwargs["options"]) or thread_id
    )

    def native_turn(**_):
        assert svc.collaboration_scheduler.active_count == 1
        return {"status": "completed"}

    svc.codex.run_turn = native_turn
    runtime = worker(svc, tmp_path)
    try:
        transport = runtime.core.codex_manager
        transport.set_thread_defaults(original)
        transport.start_thread(model="fixture", cwd=str(tmp_path), tools=[], options=original)
        transport.resume_thread(
            "child-thread", model="fixture", cwd=str(tmp_path), options=original
        )
        transport.run_turn(thread_id="child-thread", text="Read")
        assert options == [CodexThreadOptions(), CodexThreadOptions()]
        assert svc.codex.thread_defaults is original
        assert svc.collaboration_scheduler.active_count == 0
    finally:
        runtime.close()


@pytest.mark.parametrize("provider", ["ollama", "remote"])
def test_ordinary_provider_client_and_model_lease_are_independent(tmp_path, monkeypatch, provider):
    svc = service(tmp_path, provider)
    client_type = type(svc.core.client)

    def chat_stream(client, **_):
        assert client is not svc.core.client
        assert svc.collaboration_scheduler.active_count == 1
        return "response"

    monkeypatch.setattr(client_type, "chat_stream", chat_stream)
    runtime = worker(svc, tmp_path)
    try:
        assert runtime.core.client.chat_stream(model="fixture") == "response"
        assert svc.collaboration_scheduler.active_count == 0
        assert runtime.core.config is not svc.core.config
        assert runtime.core.perms is not svc.core.perms
    finally:
        runtime.close()


def test_helper_window_learning_does_not_save_global_configuration(tmp_path, monkeypatch):
    svc = service(tmp_path)
    runtime = worker(svc, tmp_path)
    monkeypatch.setattr(
        "ollama_code.core.save_config", lambda _: pytest.fail("helper saved root configuration")
    )
    before = copy.deepcopy(svc.core.config)
    try:
        runtime.core.remember_model_window("fixture", 16000)
        runtime.core.remember_window_cap("fixture", 8000)
        assert runtime.core.remembered_model_window("fixture") == 16000
        assert svc.core.config == before
    finally:
        runtime.close()


def test_native_brokers_and_background_services_use_helper_context(tmp_path):
    parent, child = tmp_path / "parent", tmp_path / "child"
    parent.mkdir()
    child.mkdir()
    svc = service(parent)

    def computer(service_view, tool, arguments, request_id):
        service_view.core.messages.append({"role": "user", "content": "helper screenshot"})
        service_view.emit({"type": "computer_action_request", "request_id": request_id})
        return "observed"

    def background(service_view, arguments):
        return {"workspace": service_view.core.execution_path, "cwd": arguments["cwd"]}

    svc.core.computer_executor = computer.__get__(svc, type(svc))
    svc._execute_background_service = background.__get__(svc, type(svc))
    runtime = worker(svc, child, mode="edit")
    try:
        assert runtime.core.computer_executor("computer_get_state", {}, "call") == "observed"
        assert runtime.core.messages[-1]["content"] == "helper screenshot"
        assert all(m.get("content") != "helper screenshot" for m in svc.core.messages)
        assert svc.events[-1]["agent_id"] == "helper"
        assert svc.events[-1]["session_id"] == "session"
        assert runtime.core.tool_ctx.background_service({"action": "start"}) == {
            "workspace": str(child),
            "cwd": str(child),
        }
        assert runtime.core.tool_ctx.background_service({"cwd": str(parent)}).startswith("Error:")
    finally:
        runtime.close()


def test_failed_followup_does_not_return_previous_attempt_answer(tmp_path):
    checkpoint = {
        "messages": [
            {"role": "user", "content": "old task"},
            {"role": "assistant", "content": "old finding"},
        ],
        "execution_path": str(tmp_path),
    }
    runtime = worker(service(tmp_path), tmp_path, checkpoint)

    def failed(prompt, *_args, **_kwargs):
        runtime.core.messages.append({"role": "user", "content": prompt})
        runtime.core.last_turn_result = {"reason": "error"}

    runtime.core.run_turn = failed
    try:
        result = run(runtime)
        assert result["reason"] == "error"
        assert result["output"] == ""
    finally:
        runtime.close()


def test_helper_restricts_tools_to_parent_capabilities_and_explicit_subset(tmp_path):
    svc = service(tmp_path)
    svc.core.tool_registry.set_user_capability_policy({"workspace_write": False, "network": False})
    runtime = worker(svc, tmp_path, mode="edit", tools=["write_file", "web_fetch", "read_file"])
    try:
        assert runtime.core.helper_allowed_tools == {"read_file"}
        assert runtime.core._run_tool_call(
            ToolCall("write_file", {"path": "bad", "content": "x"}), svc.decide
        ).startswith("Error:")
        assert not (tmp_path / "bad").exists()
    finally:
        runtime.close()


@pytest.mark.parametrize("tools", [["shell"], ["exec_command"]])
def test_research_shell_alias_inherits_read_tools_without_shell_execution(tmp_path, tools):
    svc = service(tmp_path, "chatgpt")
    runtime = worker(svc, tmp_path, tools=tools)
    try:
        assert {
            "read_file",
            "glob",
            "grep",
            "list_dir",
            "git_status",
            "git_diff",
        } <= runtime.core.helper_allowed_tools
        assert "bash" not in runtime.core.helper_allowed_tools
    finally:
        runtime.close()
    empty = worker(svc, tmp_path, tools=[])
    try:
        assert empty.core.helper_allowed_tools == set()
    finally:
        empty.close()


def test_root_close_cancels_only_helper_permission_and_waits_for_completion(tmp_path, monkeypatch):
    svc = service(tmp_path)
    svc._pending_permissions_guard = threading.RLock()
    parent_permission = Future()
    svc.pending_permissions = {"parent-permission": parent_permission}

    def answer(request_id, value):
        with svc._pending_permissions_guard:
            future = svc.pending_permissions.get(request_id)
            if future is not None and not future.done():
                future.set_result(value)
                return True
        return False

    svc.answer_permission = answer

    def response(_):
        return ChatResponse(
            content_parts=[],
            tool_calls=[ToolCall("web_fetch", {"url": "https://example.invalid"})],
            done=True,
        )

    monkeypatch.setattr("ollama_code.collaboration_bridge._HelperCore._stream_response", response)
    bridge = CollaborationBridge(svc, "permission-run")
    try:
        identifier = json.loads(bridge.call("spawn_agent", {"task": "Inspect a page"}))["id"]
        deadline = time.monotonic() + 3
        while len(svc.pending_permissions) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert len(svc.pending_permissions) == 2
        bridge.close()
        assert bridge.manager.read(identifier)["agent"]["state"] == "interrupted"
        assert all(f.done() for f in bridge.manager._futures.values())
        assert not parent_permission.done()
        assert list(svc.pending_permissions) == ["parent-permission"]
    finally:
        bridge.close()


def test_stopping_helper_waiting_for_provider_lease_does_not_call_provider(tmp_path):
    svc = service(tmp_path)
    svc.collaboration_scheduler = ModelCallScheduler(limit=1)
    runtime = worker(svc, tmp_path)
    results = []

    def waiting():
        try:
            with runtime._model_slot():
                results.append("unexpected model call")
        except InterruptedError:
            results.append("interrupted")

    try:
        with svc.collaboration_scheduler.lease("existing-task"):
            thread = threading.Thread(target=waiting)
            thread.start()
            deadline = time.monotonic() + 2
            while not svc.collaboration_scheduler._waiting and time.monotonic() < deadline:
                time.sleep(0.01)
            assert svc.collaboration_scheduler._waiting
            runtime.interrupt()
            thread.join(2)
            assert not thread.is_alive()
            assert results == ["interrupted"]
        assert svc.collaboration_scheduler.active_count == 0
    finally:
        runtime.close()


def test_helper_reports_progress_to_root_before_completing(tmp_path, monkeypatch):
    svc = service(tmp_path)
    continuing, release = threading.Event(), threading.Event()
    calls = []

    def response(_):
        calls.append(True)
        if len(calls) == 1:
            return ChatResponse(
                content_parts=[],
                tool_calls=[
                    ToolCall(
                        "send_parent_message",
                        {
                            "text": "Found the parser. Confirm whether empty input should be accepted; I am checking tests."
                        },
                    )
                ],
                done=True,
            )
        continuing.set()
        assert release.wait(3), "the root did not receive progress before completion"
        return ChatResponse(content_parts=["Finished checking tests"], tool_calls=[], done=True)

    monkeypatch.setattr("ollama_code.collaboration_bridge._HelperCore._stream_response", response)
    bridge = CollaborationBridge(svc, "progress-run")
    try:
        assert "send_parent_message" not in {
            s["function"]["name"] for s in svc.core.tool_registry.schemas()
        }
        identifier = json.loads(
            bridge.call("spawn_agent", {"task": "Inspect the parser", "tools": []})
        )["id"]
        assert continuing.wait(3)
        messages = bridge.deliveries()
        assert len(messages) == 1 and "Confirm whether empty input" in messages[0]["text"]
        assert bridge.manager.read(identifier)["agent"]["state"] == "running"
        assert (
            "send_parent_message" in bridge.manager._runtimes[identifier].core.helper_allowed_tools
        )
        assert not any(e.get("type") == "permission_request" for e in svc.events)
        bridge.applied(messages[0]["delivery_id"])
        release.set()
        bridge.before_finalize()
        assert bridge.manager.read(identifier)["agent"]["state"] == "idle"
    finally:
        release.set()
        bridge.close()


def test_parent_message_cannot_select_another_target_or_run_on_root(tmp_path):
    assert execute_tool("send_parent_message", {"text": "hello"}, ToolContext()).startswith(
        "Error:"
    )
    received = []
    runtime = AgentWorkerRuntime(
        service(tmp_path),
        WorkerSpec("helper", "session", "run", str(tmp_path), "research", {}, {}, "Helper", []),
        threading.RLock(),
        send_parent_message=lambda value: received.append(value) or {"ok": True},
    )
    try:
        core = runtime.core
        assert core.helper_allowed_tools == {"send_parent_message"}
        assert core.tool_registry.is_read_only_tool("send_parent_message")
        assert core.tool_registry.is_parallel_safe_tool("send_parent_message")
        assert execute_tool(
            "send_parent_message", {"text": "hello", "agent_id": "sibling"}, core.tool_ctx
        ).startswith("Error:")
        assert execute_tool("send_parent_message", {"text": "x" * 12001}, core.tool_ctx).startswith(
            "Error:"
        )
        assert not received
        result = core._run_tool_call(
            ToolCall("send_parent_message", {"text": "Need clarification"}),
            lambda *_: pytest.fail("parent messaging requested permission"),
        )
        assert json.loads(result)["ok"]
        assert received == ["Need clarification"]
        assert "spawn_agent" not in core.helper_allowed_tools
    finally:
        runtime.close()


@pytest.mark.parametrize(
    "family,tool",
    [
        ("computer", "computer_get_state"),
        ("browser", "browser_get_state"),
        ("simulator", "simulator_get_state"),
    ],
)
def test_native_interrupt_cancels_only_owned_futures(tmp_path, family, tool):
    svc = service(tmp_path)
    setattr(svc.core.tool_registry, f"{family}_enabled", True)
    parent_future = Future()
    requests = {"parent": parent_future}
    setattr(svc, f"pending_{family}_actions", requests)
    setattr(
        svc.core,
        f"{family}_executor",
        getattr(ChatService, f"execute_{family}").__get__(svc, type(svc)),
    )
    first, second = worker(svc, tmp_path), worker(svc, tmp_path)
    outputs = {}

    def invoke(runtime, name):
        outputs[name] = getattr(runtime.core, f"{family}_executor")(tool, {}, name)

    a = threading.Thread(target=invoke, args=(first, "first"))
    b = threading.Thread(target=invoke, args=(second, "second"))
    try:
        a.start()
        b.start()
        deadline = time.monotonic() + 3
        while (
            "first" not in first._native_actions or "second" not in second._native_actions
        ) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert "first" in first._native_actions and "second" in second._native_actions
        first.interrupt()
        a.join(2)
        assert not a.is_alive() and b.is_alive()
        assert "may have executed" in outputs["first"]
        assert not parent_future.done() and not requests["second"].done()
        assert first.snapshot()["native_actions"]["first"]["state"] == "interrupted_unknown"
        requests["second"].set_result({"text": "completed"})
        b.join(2)
        assert outputs["second"] == "completed"
    finally:
        first.interrupt()
        second.interrupt()
        a.join(2)
        b.join(2)
        first.close()
        second.close()


def test_interrupt_before_native_dispatch_releases_new_future_without_sending(tmp_path):
    svc = service(tmp_path)
    svc.core.tool_registry.computer_enabled = True
    svc.pending_computer_actions = {}
    svc.core.computer_executor = ChatService.execute_computer.__get__(svc, type(svc))
    runtime = worker(svc, tmp_path)
    created, release = threading.Event(), threading.Event()
    original = runtime._native_action_requested

    def pause_before_dispatch(event):
        created.set()
        assert release.wait(3)
        return original(event)

    runtime._native_action_requested = pause_before_dispatch
    results = []
    thread = threading.Thread(
        target=lambda: results.append(
            runtime.core.computer_executor("computer_get_state", {}, "not-sent")
        )
    )
    try:
        thread.start()
        assert created.wait(2)
        runtime.interrupt()
        release.set()
        thread.join(2)
        assert not thread.is_alive()
        assert "not sent" in results[0]
        assert not any(event.get("type") == "computer_action_request" for event in svc.events)
        assert runtime.snapshot()["native_actions"]["not-sent"]["state"] == "not_sent"
    finally:
        release.set()
        runtime.interrupt()
        thread.join(2)
        runtime.close()
