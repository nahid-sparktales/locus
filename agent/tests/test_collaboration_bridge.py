from __future__ import annotations

import json
import threading
from types import SimpleNamespace

from ollama_code.collaboration import WorkerSpec
from ollama_code.collaboration_bridge import AgentWorkerRuntime, CollaborationBridge
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.tools import execute_tool


def service(tmp_path, *, provider="ollama", mode="work"):
    root = AgentCore(
        cwd=str(tmp_path),
        config={
            "model": "fixture",
            "provider": provider,
            "chatgpt_model": "fixture",
            "chatgpt_native_mode": True,
        },
    )
    root.configure_agent(None, mode=mode)
    events = []
    return SimpleNamespace(
        core=root,
        codex=SimpleNamespace(supports_parity=True),
        run_store=None,
        emit=events.append,
        events=events,
        decide=lambda *_: "once",
        _execute_background_service=lambda _: "unused",
        pending_context_deliveries=lambda: [],
        mark_question_delivery_applied=lambda _: None,
        question_before_finalize=lambda: False,
    )


def worker(svc, path, mode="research", checkpoint=None, tools=None):
    return AgentWorkerRuntime(
        svc,
        WorkerSpec(
            "child", "parent", "run", str(path), mode, {}, checkpoint or {}, "Reader", tools
        ),
        threading.RLock(),
    )


def response(text="Done", calls=None):
    return ChatResponse(
        content_parts=[text], tool_calls=calls or [], done=True, prompt_eval_count=10, eval_count=5
    )


def test_native_resume_preserves_the_instruction_entered_in_helper_controls(tmp_path, monkeypatch):
    bridge = CollaborationBridge(service(tmp_path), "run")
    calls = []
    monkeypatch.setattr(bridge.manager, "resume", lambda identifier, prompt:
                        calls.append((identifier, prompt)) or {"ok": True})
    try:
        result = json.loads(bridge.call("resume_agent", {
            "agent_id": "saved-helper", "text": "Keep the existing API while fixing retries.",
        }))
        assert result["ok"]
        assert calls == [("saved-helper", "Keep the existing API while fixing retries.")]
    finally:
        bridge.close()


def test_native_plan_gets_canonical_read_tools_and_cannot_guess_mutations(tmp_path):
    svc = service(tmp_path, provider="chatgpt", mode="plan")
    runtime = worker(svc, tmp_path)
    try:
        names = {s["function"]["name"] for s in runtime.core.tool_registry.parity_schemas(True)}
        assert {"read_file", "grep", "glob", "list_dir"} <= names
        assert (
            not {"bash", "apply_patch", "write_file", "spawn_agent", "ask_question_async"} & names
        )
        result = runtime.core._run_tool_call(
            ToolCall("write_file", {"path": "bad", "content": "bad"}), svc.decide
        )
        assert result.startswith("Error:")
        assert not (tmp_path / "bad").exists()
    finally:
        runtime.close()


def test_worker_context_is_independent_and_resume_retains_messages(tmp_path):
    svc = service(tmp_path)
    svc.core.messages.append({"role": "user", "content": "root only"})
    runtime = worker(svc, tmp_path)
    runtime.core._stream_response = lambda: response("retained finding")
    usages = []
    result = runtime.run(
        "Read one file",
        max_calls=8,
        should_stop=lambda: False,
        drain_messages=lambda: [],
        on_usage=usages.append,
    )
    assert result["reason"] == "complete"
    assert usages[-1]["model_calls"] == 1
    assert usages[-1]["prompt_tokens"] == 10
    assert all(m.get("content") != "retained finding" for m in svc.core.messages)
    snapshot = runtime.snapshot()
    runtime.close()
    resumed = worker(svc, tmp_path, checkpoint=snapshot)
    try:
        assert any(m.get("content") == "retained finding" for m in resumed.core.messages)
        assert resumed.core.tool_ctx is not svc.core.tool_ctx
        assert resumed.core.perms is not svc.core.perms
        assert resumed.core.session.session_id == "child"
    finally:
        resumed.close()


def test_edit_helper_uses_active_execution_path_and_blocks_parent_writes(tmp_path):
    parent, child = tmp_path / "parent", tmp_path / "child"
    parent.mkdir()
    child.mkdir()
    svc = service(parent)
    runtime = worker(svc, child, mode="edit")
    try:
        assert runtime.core.cwd == str(child)
        assert runtime.core._run_tool_call(
            ToolCall("write_file", {"path": str(parent / "bad"), "content": "x"}), svc.decide
        ).startswith("Error:")
        assert (
            runtime.core._run_tool_call(
                ToolCall("write_file", {"path": "good", "content": "x"}), svc.decide
            )
            != "Error:"
        )
        assert (child / "good").read_text() == "x"
        assert not (parent / "bad").exists()
    finally:
        runtime.close()


def test_bridge_single_helper_nonblocking_then_collects_before_final(tmp_path, monkeypatch):
    svc = service(tmp_path)
    released, started = threading.Event(), threading.Event()

    def complete(_core):
        started.set()
        assert released.wait(3), "root did not continue while helper ran"
        return response("independent result")

    monkeypatch.setattr("ollama_code.collaboration_bridge._HelperCore._stream_response", complete)
    bridge = CollaborationBridge(svc, "one-helper-run")
    try:
        spawn = json.loads(
            bridge.call("spawn_agent", {"task": "Inspect the fixture", "mode": "research"})
        )
        assert spawn["ok"]
        assert started.wait(3)
        # Root can do useful work while the helper remains active.
        (tmp_path / "root-progress").write_text("continued")
        released.set()
        bridge.before_finalize()
        messages = bridge.deliveries()
        assert len(messages) == 1 and "independent result" in messages[0]["text"]
        bridge.applied(messages[0]["delivery_id"])
        assert bridge.deliveries() == []
        assert bridge.usage["model_calls"] == 1
    finally:
        released.set()
        bridge.close()


def test_tool_capability_negotiation_and_optional_question_dispatch(tmp_path):
    svc = service(tmp_path)
    registry = svc.core.tool_registry
    assert "spawn_agent" not in {s["function"]["name"] for s in registry.schemas()}
    registry.set_collaboration_enabled(True)
    registry.set_ask_question_enabled(True)
    registry.set_ask_question_async_enabled(True)
    for schemas in (registry.schemas(), registry.parity_schemas()):
        assert {"spawn_agent", "integrate_agent", "ask_question_async"} <= {
            s["function"]["name"] for s in schemas
        }
    svc.core.tool_ctx.ask_question_async = lambda value: json.dumps(
        {"status": "pending", "questions": value["questions"]}
    )
    assert (
        json.loads(execute_tool("ask_question_async", {"questions": []}, svc.core.tool_ctx))[
            "status"
        ]
        == "pending"
    )
