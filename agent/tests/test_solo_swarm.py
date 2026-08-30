from __future__ import annotations

import json
import threading
import time
from types import SimpleNamespace

import pytest

import ollama_code.openai_responses_multi_agent as responses_multi_agent
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse, ToolCall
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
    assert {tool["name"] for tool in captured["tools"]} == {
        "read_file", "glob", "grep", "list_dir", "git_status", "git_diff",
    }
    assert callable(captured["tool_executor"])


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
    assert "This is Plan mode: never mutate files or external state." in instructions
    assert instructions.index("Plan mode") < instructions.index("Custom instructions")

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


def test_chatgpt_workers_inherit_scoped_tools_and_native_web_search(tmp_path):
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
                    "findings": "live result", "evidence": [], "uncertainties": [],
                })},
            })

    def schema(name):
        return {
            "type": "function",
            "function": {
                "name": name, "description": name,
                "parameters": {"type": "object", "properties": {}},
            },
        }

    manager = _ChatGPTManager()
    route = _route(tmp_path, manager, provider="chatgpt")
    route = SoloSwarmRoute(**{**route.__dict__, "native_web_search": True})
    output = json.loads(SoloSwarmExecutor(
        route, emit=lambda _event: None, should_stop=lambda: False,
        tool_schemas=lambda: [schema("web_fetch"), schema("write_file")],
        tool_execute=lambda *_args: "ok",
        tool_is_read_only=lambda name: name == "web_fetch",
        tool_is_parallel_safe=lambda name: name == "web_fetch",
        virtual_tools=lambda: {"web_search"},
    ).execute({"tasks": [
        {**task, "tools": ["web_fetch", "web_search"]} for task in _tasks(2)
    ]}))

    assert {item["status"] for item in output["results"]} == {"completed"}
    assert all(
        {tool["function"]["name"] for tool in start["tools"]} == {"web_fetch"}
        for start in manager.starts
    )
    assert all(start["options"].web_search is True for start in manager.starts)
    assert all(start["options"].sandbox == "workspace-write" for start in manager.starts)


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


def test_inherited_explicit_and_model_only_task_tool_scopes(tmp_path):
    def schema(name):
        return {
            "type": "function",
            "function": {
                "name": name,
                "description": name,
                "parameters": {"type": "object", "properties": {}},
            },
        }

    executor = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
        tool_schemas=lambda: [
            schema("read_file"), schema("web_fetch"), schema("write_file"),
            schema("delegate_read_only"), schema("todo_write"),
        ],
        tool_execute=lambda *_args: "ok",
        tool_is_read_only=lambda name: name != "write_file",
        tool_is_parallel_safe=lambda name: name != "write_file",
    )

    inherited, explicit, model_only = executor._resolve_task_tools([
        {"id": "all", "label": "All", "goal": "Use inherited tools"},
        {
            "id": "web", "label": "Web", "goal": "Use web only",
            "tools": ["web_fetch"],
        },
        {"id": "none", "label": "None", "goal": "Reason only", "tools": []},
    ])

    assert inherited["_allowed_tools"] == {"read_file", "web_fetch", "write_file"}
    assert inherited["read_only"] is False
    assert explicit["_allowed_tools"] == {"web_fetch"}
    assert explicit["read_only"] is True
    assert model_only["_allowed_tools"] == set()
    assert model_only["_schemas"] == []

    with pytest.raises(SoloSwarmError, match="unavailable tools: browser_navigate"):
        executor.execute({"tasks": [
            {**_tasks(2)[0], "tools": ["browser_navigate"]},
            {**_tasks(2)[1], "tools": ["web_fetch"]},
        ]})
    with pytest.raises(SoloSwarmError, match="root-only tools: delegate_read_only"):
        executor.execute({"tasks": [
            {**_tasks(2)[0], "tools": ["delegate_read_only"]},
            {**_tasks(2)[1], "tools": ["web_fetch"]},
        ]})


def test_multi_city_workers_use_inherited_live_web_tool(tmp_path):
    class _WeatherClient:
        def __init__(self):
            self.calls = {}

        def chat_stream(self, _model, messages, **_kwargs):
            prompt = str(messages[1]["content"])
            identifier = prompt.split("Task ID: ", 1)[1].splitlines()[0]
            label = prompt.split("Label: ", 1)[1].splitlines()[0]
            count = self.calls.get(identifier, 0)
            self.calls[identifier] = count + 1
            if count == 0:
                return ChatResponse(
                    content_parts=[], done=True, done_reason="tool_calls",
                    tool_calls=[ToolCall(
                        name="web_fetch",
                        arguments={"url": f"https://weather.example/{identifier}"},
                        call_id=f"fetch-{identifier}",
                    )],
                )
            return ChatResponse(
                content_parts=[json.dumps({
                    "id": identifier, "label": label, "status": "completed",
                    "findings": f"Current weather for {label}: 26 C",
                    "evidence": [f"https://weather.example/{identifier}"],
                    "uncertainties": [],
                })],
                done=True,
                done_reason="stop",
            )

    def schema(name):
        return {
            "type": "function",
            "function": {
                "name": name, "description": "Fetch current external data.",
                "parameters": {
                    "type": "object",
                    "properties": {"url": {"type": "string"}},
                    "required": ["url"],
                },
            },
        }

    tool_calls = []

    def execute(name, arguments, call_id, context, lock):
        tool_calls.append((name, arguments, call_id, context["agent_id"], lock))
        return "26 C and partly cloudy"

    client = _WeatherClient()
    executor = SoloSwarmExecutor(
        _route(tmp_path, client), emit=lambda _event: None, should_stop=lambda: False,
        tool_schemas=lambda: [schema("web_fetch")],
        tool_execute=execute,
        tool_is_read_only=lambda _name: True,
        tool_is_parallel_safe=lambda _name: True,
    )
    tasks = [
        {
            "id": city.lower().replace(" ", "-"),
            "label": city,
            "goal": f"Get the current weather in {city}",
            "tools": ["web_fetch"],
        }
        for city in ("Toronto", "Dubai", "Austin", "Mexico City")
    ]

    output = json.loads(executor.execute({"tasks": tasks}))

    assert {result["status"] for result in output["results"]} == {"completed"}
    assert len(tool_calls) == 4
    assert all(call[0] == "web_fetch" and call[4] is None for call in tool_calls)

    unavailable = SoloSwarmExecutor(
        _route(tmp_path), emit=lambda _event: None, should_stop=lambda: False,
        tool_schemas=lambda: [], tool_execute=execute,
    )
    with pytest.raises(SoloSwarmError, match="unavailable tools: web_fetch"):
        unavailable.execute({"tasks": tasks[:2]})


def test_effectful_worker_calls_serialize_while_read_only_calls_remain_parallel(tmp_path):
    class _OneToolClient:
        def __init__(self, tool):
            self.tool = tool
            self.calls = {}
            self.guard = threading.Lock()

        def chat_stream(self, _model, messages, **_kwargs):
            prompt = str(messages[1]["content"])
            identifier = prompt.split("Task ID: ", 1)[1].splitlines()[0]
            label = prompt.split("Label: ", 1)[1].splitlines()[0]
            with self.guard:
                count = self.calls.get(identifier, 0)
                self.calls[identifier] = count + 1
            if count == 0:
                return ChatResponse(
                    content_parts=[], done=True, done_reason="tool_calls",
                    tool_calls=[ToolCall(name=self.tool, arguments={}, call_id=identifier)],
                )
            return ChatResponse(
                content_parts=[json.dumps({
                    "id": identifier, "label": label, "status": "completed",
                    "findings": "done", "evidence": [], "uncertainties": [],
                })],
                done=True,
                done_reason="stop",
            )

    def schema(name):
        return {
            "type": "function",
            "function": {
                "name": name, "description": name,
                "parameters": {"type": "object", "properties": {}},
            },
        }

    tasks = [
        {**task, "tools": ["probe"]} for task in _tasks(3)
    ]

    def run(parallel_safe):
        active = 0
        peak = 0
        guard = threading.Lock()

        def execute(_name, _arguments, _call_id, _context, execution_lock):
            nonlocal active, peak
            if execution_lock is not None:
                execution_lock.acquire()
            try:
                with guard:
                    active += 1
                    peak = max(peak, active)
                time.sleep(0.04)
                return "ok"
            finally:
                with guard:
                    active -= 1
                if execution_lock is not None:
                    execution_lock.release()

        executor = SoloSwarmExecutor(
            _route(tmp_path, _OneToolClient("probe")),
            emit=lambda _event: None,
            should_stop=lambda: False,
            tool_schemas=lambda: [schema("probe")],
            tool_execute=execute,
            tool_is_read_only=lambda _name: parallel_safe,
            tool_is_parallel_safe=lambda _name: parallel_safe,
        )
        output = json.loads(executor.execute({"tasks": tasks}))
        assert {result["status"] for result in output["results"]} == {"completed"}
        return peak

    assert run(False) == 1
    assert run(True) >= 2


def test_plan_mode_rejects_mutating_worker_tools(tmp_path):
    def schema(name):
        return {
            "type": "function",
            "function": {
                "name": name, "description": name,
                "parameters": {"type": "object", "properties": {}},
            },
        }

    route = _route(tmp_path)
    route = SoloSwarmRoute(**{**route.__dict__, "mode": "plan"})
    executor = SoloSwarmExecutor(
        route, emit=lambda _event: None, should_stop=lambda: False,
        tool_schemas=lambda: [schema("read_file"), schema("write_file")],
        tool_execute=lambda *_args: "ok",
        tool_is_read_only=lambda name: name == "read_file",
    )

    inherited = executor._resolve_task_tools([
        {"id": "read", "label": "Read", "goal": "Inspect"},
    ])[0]
    assert inherited["_allowed_tools"] == {"read_file"}
    with pytest.raises(SoloSwarmError, match="unavailable tools: write_file"):
        executor.execute({"tasks": [
            {**_tasks(2)[0], "tools": ["write_file"]},
            {**_tasks(2)[1], "tools": ["read_file"]},
        ]})


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


def test_root_delegation_tool_is_ephemeral_and_independent_of_workspace_read(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={"model": "same-model"})

    def names():
        return {item["function"]["name"] for item in core.tool_registry.schemas()}

    assert "delegate_read_only" not in names()
    core.tool_ctx.delegate_read_only = lambda _arguments: '{"results":[]}'
    core.tool_registry.set_solo_swarm_enabled(True)
    assert "delegate_read_only" in names()
    assert core.tool_registry.is_safe("delegate_read_only")
    contract = core.system_message()["content"]
    assert "Locked adaptive Solo delegation contract" in contract
    assert "If tools is omitted" in contract
    assert "inherits every delegable tool and the current permission mode" in contract
    assert "workspace, shell, web, MCP, browser, computer" in contract
    assert "Plan-mode workers remain non-mutating" in contract

    delegate_schema = next(
        item for item in core.tool_registry.schemas()
        if item["function"]["name"] == "delegate_read_only"
    )
    description = delegate_schema["function"]["description"]
    assert "inherit every currently delegable root tool" in description
    assert "normal permission prompts and safety checks" in description
    task_properties = delegate_schema["function"]["parameters"]["properties"]["tasks"][
        "items"
    ]["properties"]
    assert task_properties["tools"]["type"] == "array"
    assert task_properties["tools"]["uniqueItems"] is True

    parity_contract = core._parity_developer_instructions()
    assert "inherits every delegable tool and the current permission mode" in parity_contract
    assert "normal permission prompt" in parity_contract

    core.tool_registry.set_user_capability_policy({"workspace_read": False})
    assert "delegate_read_only" in names()
    assert core.tool_registry.is_safe("delegate_read_only")
    inherited = {
        item["function"]["name"] for item in core.solo_worker_tool_schemas()
    }
    assert "read_file" not in inherited
    assert "web_fetch" in inherited

    core.tool_registry.set_solo_swarm_enabled(False)
    core.tool_ctx.delegate_read_only = None
    assert "delegate_read_only" not in names()
    assert "Locked adaptive Solo delegation contract" not in core.system_message()["content"]


def test_worker_calls_use_root_permissions_hard_blocks_and_attribution(tmp_path):
    core = AgentCore(
        cwd=str(tmp_path),
        config={"model": "same-model", "permission_mode": "ask"},
    )
    events = []
    core.on_event(events.append)
    context = {
        "node_id": "/root/writer",
        "agent_id": "writer",
        "agent_name": "Writer worker",
        "job_id": "writer",
        "label": "Writer worker",
    }
    decisions = []

    def allow_always(tool, summary, detail, request_id):
        decisions.append((tool, summary, detail, request_id))
        return "always"

    result = core.run_solo_worker_tool(
        "write_file",
        {"path": "worker.txt", "content": "inherited authority\n"},
        "provider-call-1",
        allow_always,
        event_context=context,
        execution_lock=threading.Lock(),
    )

    assert not result.startswith("Error")
    assert (tmp_path / "worker.txt").read_text() == "inherited authority\n"
    assert len(decisions) == 1
    permission = next(event for event in events if event["type"] == "permission_request")
    assert permission["node_id"] == "/root/writer"
    assert permission["agent_name"] == "Writer worker"
    assert permission["summary"].startswith("Writer worker:")

    core.run_solo_worker_tool(
        "write_file",
        {"path": "worker-two.txt", "content": "already allowed\n"},
        "provider-call-2",
        lambda *_args: pytest.fail("always-allowed worker call prompted again"),
        event_context=context,
        execution_lock=threading.Lock(),
    )
    assert (tmp_path / "worker-two.txt").exists()

    blocked = core.run_solo_worker_tool(
        "bash",
        {"command": "rm -rf /"},
        "provider-call-3",
        lambda *_args: pytest.fail("hard-blocked call requested permission"),
        event_context=context,
        execution_lock=threading.Lock(),
    )
    assert blocked.startswith("Error: blocked by the deny list")


def test_root_plan_surface_is_read_only_and_keeps_external_research(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={"model": "same-model"})
    core.configure_agent(None, mode="plan")
    core.tool_ctx.delegate_read_only = lambda _arguments: '{"results":[]}'
    core.tool_registry.set_solo_swarm_enabled(True)

    names = {item["function"]["name"] for item in core.solo_worker_tool_schemas()}

    assert "read_file" in names
    assert "web_fetch" in names
    assert names.isdisjoint({
        "write_file", "edit_file", "multi_edit", "bash", "background_service",
        "delegate_read_only", "todo_write", "submit_plan", "propose_memory",
        # Only the visible root may address the user.
        "ask_user_question",
    })
