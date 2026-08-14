from __future__ import annotations

import json
import threading
import time
from types import SimpleNamespace

import pytest

import ollama_code.openai_responses_multi_agent as responses_multi_agent
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse
from ollama_code.openai_responses_multi_agent import (
    OpenAIResponsesMultiAgentError,
    OpenAIResponsesResult,
)
from ollama_code.solo_swarm import (
    MAX_CONCURRENT_WORKERS,
    MAX_DELEGATED_TOKENS,
    MAX_MODEL_CALLS,
    MAX_RESULT_CHARS,
    SoloSwarmError,
    SoloSwarmExecutor,
    SoloSwarmRoute,
    snapshot_route,
)


class _CompletionClient:
    def __init__(self, *, delay: float = 0) -> None:
        self.delay = delay
        self.active = 0
        self.peak = 0
        self.guard = threading.Lock()

    def chat_stream(self, _model, messages, tools=None, should_stop=None, **_kwargs):
        with self.guard:
            self.active += 1
            self.peak = max(self.peak, self.active)
        try:
            if self.delay:
                time.sleep(self.delay)
            if should_stop and should_stop():
                return ChatResponse(done=True, done_reason="interrupted")
            prompt = str(messages[-1]["content"])
            identifier = prompt.split("Task ID: ", 1)[1].splitlines()[0]
            label = prompt.split("Label: ", 1)[1].splitlines()[0]
            return ChatResponse(
                content_parts=[json.dumps({
                    "id": identifier,
                    "label": label,
                    "status": "completed",
                    "findings": f"finding for {identifier}",
                    "evidence": [f"src/{identifier}.py:1"],
                    "uncertainties": [],
                })],
                done=True,
                done_reason="stop",
                prompt_eval_count=10,
                eval_count=5,
            )
        finally:
            with self.guard:
                self.active -= 1


def _route(tmp_path, client=None, *, eligible=False, provider="ollama"):
    return SoloSwarmRoute(
        provider=provider,
        model="gpt-5.6" if eligible else "same-model",
        provider_label="Selected route",
        client=client or _CompletionClient(),
        behavior={"response_style": {"tone": "balanced", "verbosity": "concise"}},
        workspace=str(tmp_path),
        hosted_openai_eligible=eligible,
    )


def _tasks(count=2):
    return [
        {"id": f"task-{index}", "label": f"Task {index}", "goal": f"Inspect area {index}"}
        for index in range(count)
    ]


def test_managed_workers_run_concurrently_and_emit_durable_activity(tmp_path):
    client = _CompletionClient(delay=0.05)
    events = []
    executor = SoloSwarmExecutor(
        _route(tmp_path, client), emit=events.append, should_stop=lambda: False,
    )

    output = json.loads(executor.execute({"tasks": _tasks(4)}))

    assert [item["id"] for item in output["results"]] == [f"task-{i}" for i in range(4)]
    assert all(item["status"] == "completed" for item in output["results"])
    assert 2 <= client.peak <= MAX_CONCURRENT_WORKERS
    assert output["summary"]["execution_engine"] == "locus_managed"
    assert output["summary"]["usage"] == {
        "model_calls": 4,
        "prompt_tokens": 40,
        "completion_tokens": 20,
        "delegated_tokens": 60,
    }
    assert sum(event["type"] == "agent_job_started" for event in events) == 4
    completed = [event for event in events if event["type"] == "agent_job_completed"]
    assert len(completed) == 4
    assert completed[0]["result"]["node_id"].startswith("/root/task-")
    assert all(event.get("provider") == "Selected route" for event in completed)


def test_validation_and_turn_limits_preserve_completed_batches(tmp_path):
    executor = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
    )
    with pytest.raises(SoloSwarmError, match="unique"):
        executor.execute({"tasks": [_tasks()[0], _tasks()[0]]})
    with pytest.raises(SoloSwarmError, match="2 to 4"):
        executor.execute({"tasks": _tasks(1)})

    assert "results" in json.loads(executor.execute({"tasks": _tasks(4)}))
    with pytest.raises(SoloSwarmError, match="unique across"):
        executor.execute({"tasks": [
            _tasks(1)[0],
            {"id": "new-task", "label": "New", "goal": "Inspect new area"},
        ]})
    second = json.loads(executor.execute({"tasks": [
        {"id": "third-a", "label": "Third A", "goal": "Inspect A"},
        {"id": "third-b", "label": "Third B", "goal": "Inspect B"},
    ]}))
    assert second["summary"]["worker_count"] == 6
    assert second["summary"]["batch_worker_count"] == 2
    limited = json.loads(executor.execute({"tasks": [
        {"id": "extra-a", "label": "Extra A", "goal": "Inspect A"},
        {"id": "extra-b", "label": "Extra B", "goal": "Inspect B"},
    ]}))
    assert limited["results"] == []
    assert "two-batch" in limited["error"]


def test_model_call_and_token_budgets_stop_new_worker_calls(tmp_path):
    call_limited = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
    )
    call_limited._reserve_calls(MAX_MODEL_CALLS)
    call_output = json.loads(call_limited.execute({"tasks": _tasks(2)}))
    assert {item["status"] for item in call_output["results"]} == {"failed"}
    assert call_output["summary"]["usage"]["model_calls"] == MAX_MODEL_CALLS

    token_limited = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
    )
    token_limited._record_tokens(MAX_DELEGATED_TOKENS, 0)
    token_output = json.loads(token_limited.execute({"tasks": _tasks(2)}))
    assert {item["status"] for item in token_output["results"]} == {"failed"}
    assert token_output["summary"]["usage"]["delegated_tokens"] == MAX_DELEGATED_TOKENS


def test_malformed_worker_result_is_partial_and_does_not_discard_sibling(tmp_path):
    class _PartialClient(_CompletionClient):
        def chat_stream(self, model, messages, **kwargs):
            prompt = str(messages[-1]["content"])
            if "Task ID: task-0" in prompt:
                return ChatResponse(
                    content_parts=["not-json"], done=True, done_reason="stop",
                    prompt_eval_count=3, eval_count=2,
                )
            return super().chat_stream(model, messages, **kwargs)

    executor = SoloSwarmExecutor(
        _route(tmp_path, _PartialClient()), emit=lambda _event: None,
        should_stop=lambda: False,
    )
    output = json.loads(executor.execute({"tasks": _tasks(2)}))

    assert [item["status"] for item in output["results"]] == ["failed", "completed"]
    assert output["results"][0]["usage"] == {
        "model_calls": 1, "prompt_tokens": 3, "completion_tokens": 2,
    }


def test_bounded_tool_output_remains_valid_json(tmp_path):
    executor = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
    )
    results = [{
        "id": f"large-{index}",
        "label": f"Large {index}",
        "status": "completed",
        "findings": "x" * 80_000,
        "evidence": ["y" * 8_000] * 30,
        "uncertainties": [],
        "usage": {},
    } for index in range(4)]

    encoded = executor._encode_output(results, {"worker_count": 4})
    decoded = json.loads(encoded)

    assert len(encoded) <= MAX_RESULT_CHARS
    assert [item["id"] for item in decoded["results"]] == [f"large-{i}" for i in range(4)]


def test_stop_returns_structured_cancelled_siblings(tmp_path):
    executor = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: True,
    )
    output = json.loads(executor.execute({"tasks": _tasks(2)}))
    assert {item["status"] for item in output["results"]} == {"cancelled"}


def test_hosted_failure_falls_back_to_same_client_and_route(tmp_path, monkeypatch):
    client = _CompletionClient()
    client.api_key = "secret-never-emit"
    client.base_url = "https://api.openai.com/v1"
    events = []

    class _HostedFailure:
        def __init__(self, **_kwargs):
            pass

        def run(self, *_args, **_kwargs):
            raise OpenAIResponsesMultiAgentError("beta failed")

    monkeypatch.setattr(
        "ollama_code.solo_swarm.OpenAIResponsesMultiAgentClient", _HostedFailure,
    )
    executor = SoloSwarmExecutor(
        _route(tmp_path, client, eligible=True, provider="remote"),
        emit=events.append,
        should_stop=lambda: False,
    )

    output = json.loads(executor.execute({"tasks": _tasks(2)}))

    assert output["summary"]["execution_engine"] == "locus_managed"
    assert all(item["status"] == "completed" for item in output["results"])
    assert any(event.get("solo_swarm_fallback") for event in events)
    assert "secret-never-emit" not in json.dumps(events)


def test_hosted_success_uses_depth_one_beta_and_shared_budget(tmp_path, monkeypatch):
    client = _CompletionClient()
    client.api_key = "secret-never-emit"
    client.base_url = "https://api.openai.com/v1"
    captured = {}

    class _HostedSuccess:
        def __init__(self, **kwargs):
            captured.update(kwargs)

        def run(self, *_args, **_kwargs):
            captured["before_request"]()
            captured["usage_observer"](20, 10)
            return OpenAIResponsesResult(
                output={"results": [{
                    "id": task["id"], "label": task["label"], "status": "completed",
                    "findings": f"hosted {task['id']}", "evidence": [], "uncertainties": [],
                } for task in _tasks(2)]},
                usage={"prompt_tokens": 20, "completion_tokens": 10},
                agent_count=3,
            )

    monkeypatch.setattr(
        "ollama_code.solo_swarm.OpenAIResponsesMultiAgentClient", _HostedSuccess,
    )
    executor = SoloSwarmExecutor(
        _route(tmp_path, client, eligible=True, provider="remote"),
        emit=lambda _event: None,
        should_stop=lambda: False,
    )

    output = json.loads(executor.execute({"tasks": _tasks(2)}))

    assert output["summary"]["execution_engine"] == "openai_responses"
    assert output["summary"]["worker_count"] == 2
    assert output["summary"]["usage"]["model_calls"] == 3
    assert output["summary"]["usage"]["delegated_tokens"] == 30
    assert captured["max_depth"] == 1
    assert captured["max_concurrent_subagents"] == MAX_CONCURRENT_WORKERS


def test_route_snapshot_keeps_exact_provider_model_behavior_and_eligibility(tmp_path):
    behavior_value = {
        "display_name": "Scout",
        "response_style": {"tone": "direct"},
        "custom_instructions": "Prefer dependency evidence.",
        "mode_instructions": {"plan": "Compare alternatives."},
    }
    behavior = SimpleNamespace(structured=lambda: behavior_value)
    source = SimpleNamespace(
        base_url="https://api.openai.com/v1", api_key="secret", timeout=321,
        auth_style="bearer", lists_models=True,
    )
    core = SimpleNamespace(
        provider="remote", model="gpt-5.6", client=source, account_label="OpenAI",
        agent_configuration=behavior, agent_mode="plan",
        workspace_root=str(tmp_path), cwd=str(tmp_path),
    )

    route = snapshot_route(core, None)

    assert route.provider == "remote"
    assert route.model == "gpt-5.6"
    assert route.behavior == behavior_value
    assert route.mode == "plan"
    assert route.client is not source
    assert route.client.base_url == source.base_url
    assert route.client.api_key == "secret"
    assert route.hosted_openai_eligible
    instructions = SoloSwarmExecutor(
        route, emit=lambda _event: None, should_stop=lambda: False,
    )._worker_instructions()
    assert "Prefer dependency evidence." in instructions
    assert "Compare alternatives." in instructions
    assert instructions.index("strictly read-only") < instructions.index("Custom instructions")

    core.model = "claude-sonnet"
    core.client = SimpleNamespace(
        base_url="https://api.anthropic.com/v1", api_key="secret", timeout=321,
        auth_style="anthropic", lists_models=False,
    )
    assert not snapshot_route(core, None).hosted_openai_eligible


def test_chatgpt_managed_workers_use_ephemeral_read_only_threads(tmp_path):
    class _ChatGPTManager:
        def __init__(self):
            self.starts = []

        def start_thread(self, **kwargs):
            self.starts.append(kwargs)
            return f"thread-{len(self.starts)}"

        def run_turn(self, *, text, event_handler, **_kwargs):
            identifier = text.split("Task ID: ", 1)[1].splitlines()[0]
            label = text.split("Label: ", 1)[1].splitlines()[0]
            event_handler({
                "method": "item/agentMessage/delta",
                "params": {"delta": json.dumps({
                    "id": identifier, "label": label, "status": "completed",
                    "findings": "managed finding", "evidence": [], "uncertainties": [],
                })},
            })
            event_handler({
                "method": "thread/tokenUsage/updated",
                "params": {"tokenUsage": {"last": {"inputTokens": 9, "outputTokens": 4}}},
            })

    manager = _ChatGPTManager()
    output = json.loads(SoloSwarmExecutor(
        _route(tmp_path, manager, provider="chatgpt"),
        emit=lambda _event: None,
        should_stop=lambda: False,
    ).execute({"tasks": _tasks(2)}))

    assert {item["status"] for item in output["results"]} == {"completed"}
    assert output["summary"]["usage"]["model_calls"] == 2
    assert output["summary"]["usage"]["delegated_tokens"] == 26
    assert len(manager.starts) == 2
    assert all(start["ephemeral"] is True for start in manager.starts)
    assert all(
        {tool["function"]["name"] for tool in start["tools"]}.isdisjoint({
            "write_file", "bash", "delegate_read_only",
        })
        for start in manager.starts
    )


def test_worker_tool_inventory_is_read_only_and_executor_rejects_guessed_names(tmp_path):
    executor = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
    )
    names = {item["function"]["name"] for item in executor._chat_tool_schemas()}
    assert names == {"read_file", "glob", "grep", "list_dir", "git_status", "git_diff"}
    assert names.isdisjoint({
        "write_file", "edit_file", "bash", "shell", "browser", "mcp",
        "computer", "propose_memory", "delegate_read_only",
    })
    with pytest.raises(OpenAIResponsesMultiAgentError, match="disallowed"):
        executor.workspace_tools.execute("write_file", '{"path":"owned"}')


def test_worker_reads_cannot_escape_or_open_workspace_credentials(tmp_path, monkeypatch):
    outside = tmp_path.parent / f"{tmp_path.name}-outside-secret.txt"
    outside.write_text("outside-secret")
    (tmp_path / "escape.txt").symlink_to(outside)
    (tmp_path / ".env").write_text("TOKEN=workspace-secret\n")
    (tmp_path / "credentials.json").write_text('{"token":"workspace-secret"}\n')
    (tmp_path / "visible.txt").write_text("ordinary evidence\n")
    executor = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
    )

    def missing_ripgrep(*_args, **_kwargs):
        raise FileNotFoundError("rg")

    monkeypatch.setattr(
        responses_multi_agent.subprocess,
        "run",
        missing_ripgrep,
    )

    with pytest.raises(OpenAIResponsesMultiAgentError, match="escaped"):
        executor.workspace_tools.execute("read_file", '{"path":"escape.txt"}')
    with pytest.raises(OpenAIResponsesMultiAgentError, match="credential"):
        executor.workspace_tools.execute("read_file", '{"path":".env"}')
    assert "ordinary evidence" in executor.workspace_tools.execute(
        "read_file", '{"path":"visible.txt"}',
    )
    searched = executor.workspace_tools.execute(
        "grep", '{"path":".","query":"workspace-secret"}',
    )
    assert "workspace-secret" not in searched
    ordinary = executor.workspace_tools.execute(
        "grep", '{"path":".","query":"ordinary evidence"}',
    )
    assert "visible.txt:1:ordinary evidence" in ordinary


def test_root_delegation_tool_is_ephemeral_and_requires_workspace_read(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={"model": "same-model"})

    def names():
        return {item["function"]["name"] for item in core.tool_registry.schemas()}

    assert "delegate_read_only" not in names()
    core.tool_ctx.delegate_read_only = lambda _arguments: '{"results":[]}'
    core.tool_registry.set_solo_swarm_enabled(True)
    assert "delegate_read_only" in names()
    assert core.tool_registry.is_safe("delegate_read_only")
    assert "Locked Solo Swarm contract" in core.system_message()["content"]

    core.tool_registry.set_user_capability_policy({"workspace_read": False})
    assert "delegate_read_only" not in names()
    assert not core.tool_registry.is_safe("delegate_read_only")

    core.tool_registry.set_solo_swarm_enabled(False)
    core.tool_ctx.delegate_read_only = None
    assert "delegate_read_only" not in names()
    assert "Locked Solo Swarm contract" not in core.system_message()["content"]
