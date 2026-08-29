from __future__ import annotations

import json
import threading
import time

import pytest

from ollama_code.openai_responses_multi_agent import (
    BETA_HEADER,
    SAFE_TOOL_NAMES,
    OpenAIResponsesLimitBreach,
    OpenAIResponsesMultiAgentClient,
    OpenAIResponsesMultiAgentError,
    safe_tool_schemas,
)


class _Response:
    def __init__(self, events):
        self.lines = []
        for event in events:
            self.lines.extend([
                b"data: " + json.dumps(event).encode() + b"\n",
                b"\n",
            ])
        self.lines.extend([b"data: [DONE]\n", b"\n"])

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def __iter__(self):
        return iter(self.lines)


def _events(root_text: str, child: str = "/root/researcher"):
    return [
        {
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "message", "agent": {"agent_name": child}},
        },
        {"type": "response.output_text.delta", "output_index": 0, "delta": "evidence"},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message", "agent": {"agent_name": child},
                "phase": "final_answer",
                "content": [{"type": "output_text", "text": "child evidence"}],
            },
        },
        {
            "type": "response.output_item.added", "output_index": 1,
            "item": {"type": "message", "agent": {"agent_name": "/root"}},
        },
        {"type": "response.output_text.delta", "output_index": 1, "delta": root_text},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message", "agent": {"agent_name": "/root"},
                "phase": "final_answer",
                "content": [{"type": "output_text", "text": root_text}],
            },
        },
        {
            "type": "response.completed",
            "response": {"usage": {"input_tokens": 12, "output_tokens": 8}},
        },
    ]


def test_adapter_streams_with_beta_header_normalizes_tree_and_never_emits_key(tmp_path):
    captured = {}
    emitted = []

    def opener(request, **_kwargs):
        captured["headers"] = dict(request.header_items())
        captured["body"] = json.loads(request.data)
        return _Response(_events('{"evidence_records": []}'))

    client = OpenAIResponsesMultiAgentClient(
        api_key="secret-never-emit", model="gpt-5.6-sol", workspace=str(tmp_path),
        max_concurrent_subagents=3, max_total_agents=8, max_depth=2,
        emit=emitted.append, opener=opener,
    )
    result = client.run("inspect", multi_agent=True)

    assert captured["headers"]["Openai-beta"] == BETA_HEADER
    assert captured["body"]["multi_agent"] == {
        "enabled": True, "max_concurrent_subagents": 3,
    }
    assert captured["body"]["max_output_tokens"] == 64_000
    assert result.agent_count == 2
    assert result.tree_depth == 1
    assert result.usage == {"prompt_tokens": 12, "completion_tokens": 8}
    assert any(event["type"] == "agent_spawned" for event in emitted)
    assert "secret-never-emit" not in json.dumps(emitted)


def test_safe_tool_allowlist_has_no_mutation_or_external_tools():
    names = {tool["name"] for tool in safe_tool_schemas(knowledge_enabled=True)}
    assert names == SAFE_TOOL_NAMES
    assert names.isdisjoint({
        "write_file", "edit_file", "shell", "bash", "mcp", "browser",
        "computer", "credentials",
    })


def test_flat_responses_evidence_can_use_read_only_tools_without_subagents(tmp_path):
    captured = {}
    root_text = '{"evidence_records": []}'
    events = [
        {
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "message", "agent": {"agent_name": "/root"}},
        },
        {"type": "response.output_text.delta", "output_index": 0, "delta": root_text},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message", "agent": {"agent_name": "/root"},
                "content": [{"type": "output_text", "text": root_text}],
            },
        },
        {"type": "response.completed", "response": {"usage": {}}},
    ]

    def opener(request, **_kwargs):
        captured["body"] = json.loads(request.data)
        return _Response(events)

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
    )
    client.run("inspect", multi_agent=False, allow_tools=True)

    assert captured["body"]["multi_agent"]["enabled"] is False
    assert {tool["name"] for tool in captured["body"]["tools"]} == SAFE_TOOL_NAMES - {
        "workspace_knowledge_search"
    }


def test_hosted_tree_limit_breach_stops_immediately(tmp_path):
    def opener(_request, **_kwargs):
        return _Response(_events("{}", child="/root/researcher/tester"))

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path),
        max_total_agents=2, max_depth=1, opener=opener,
    )
    with pytest.raises(OpenAIResponsesLimitBreach):
        client.run("inspect")


def test_hosted_agent_paths_are_strictly_normalized(tmp_path):
    def opener(_request, **_kwargs):
        return _Response(_events("{}", child="/root/../escape"))

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
    )
    with pytest.raises(OpenAIResponsesMultiAgentError, match="invalid agent path"):
        client.run("inspect")


def test_safe_tool_call_continues_the_same_response_history(tmp_path):
    (tmp_path / "note.txt").write_text("bounded evidence\n")
    captured = []
    first = [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call", "name": "read_file",
                "arguments": '{"path":"note.txt"}', "call_id": "call-1",
                "agent": {"agent_name": "/root"},
            },
        },
        {"type": "response.completed", "response": {"usage": {}}},
    ]
    root_text = '{"evidence_records": []}'
    second = [
        {
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "message", "agent": {"agent_name": "/root"}},
        },
        {"type": "response.output_text.delta", "output_index": 0, "delta": root_text},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message", "agent": {"agent_name": "/root"},
                "content": [{"type": "output_text", "text": root_text}],
            },
        },
        {"type": "response.completed", "response": {"usage": {}}},
    ]

    def opener(request, **_kwargs):
        captured.append(json.loads(request.data))
        return _Response(first if len(captured) == 1 else second)

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
    )
    client.run("inspect")

    outputs = [
        item for item in captured[1]["input"]
        if item.get("type") == "function_call_output"
    ]
    assert outputs == [{
        "type": "function_call_output", "call_id": "call-1",
        "output": "bounded evidence",
    }]


def test_injected_tool_surface_uses_root_owned_executor_and_agent_identity(tmp_path):
    requests = []
    calls = []
    first = [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call", "name": "web_fetch",
                "arguments": '{"url":"https://example.com/weather"}',
                "call_id": "call-weather",
                "agent": {"agent_name": "/root/weather"},
            },
        },
        {"type": "response.completed", "response": {"usage": {}}},
    ]
    root_text = '{"results":[]}'
    second = [
        {
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "message", "agent": {"agent_name": "/root"}},
        },
        {"type": "response.output_text.delta", "output_index": 0, "delta": root_text},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message", "agent": {"agent_name": "/root"},
                "content": [{"type": "output_text", "text": root_text}],
            },
        },
        {"type": "response.completed", "response": {"usage": {}}},
    ]

    def opener(request, **_kwargs):
        requests.append(json.loads(request.data))
        return _Response(first if len(requests) == 1 else second)

    def execute(name, arguments, call_id, agent):
        calls.append((name, json.loads(arguments), call_id, agent))
        return "Toronto: 26 C"

    tools = [{
        "type": "function", "name": "web_fetch", "description": "Fetch a URL.",
        "parameters": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
        },
    }]
    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
        tools=tools, tool_executor=execute,
        developer_instructions="Use the inherited root permission boundary.",
    )

    client.run("weather", multi_agent=True)

    assert requests[0]["tools"] == tools
    assert calls == [(
        "web_fetch", {"url": "https://example.com/weather"},
        "call-weather", "/root/weather",
    )]
    output = next(
        item for item in requests[1]["input"]
        if item.get("type") == "function_call_output"
    )
    assert output["output"] == "Toronto: 26 C"


def test_injected_hosted_tool_calls_can_run_concurrently(tmp_path):
    requests = []
    first = [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call", "name": "web_fetch", "arguments": "{}",
                "call_id": f"call-{index}",
                "agent": {"agent_name": f"/root/worker-{index}"},
            },
        }
        for index in range(2)
    ] + [{"type": "response.completed", "response": {"usage": {}}}]
    root_text = '{"results":[]}'
    second = [
        {
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "message", "agent": {"agent_name": "/root"}},
        },
        {"type": "response.output_text.delta", "output_index": 0, "delta": root_text},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message", "agent": {"agent_name": "/root"},
                "content": [{"type": "output_text", "text": root_text}],
            },
        },
        {"type": "response.completed", "response": {"usage": {}}},
    ]

    def opener(request, **_kwargs):
        requests.append(json.loads(request.data))
        return _Response(first if len(requests) == 1 else second)

    active = 0
    peak = 0
    guard = threading.Lock()

    def execute(_name, _arguments, _call_id, _agent):
        nonlocal active, peak
        with guard:
            active += 1
            peak = max(peak, active)
        time.sleep(0.04)
        with guard:
            active -= 1
        return "ok"

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
        tools=[], tool_executor=execute,
    )

    client.run("parallel reads", multi_agent=True)

    assert peak == 2


def test_hosted_continuations_observe_calls_and_aggregate_usage(tmp_path):
    (tmp_path / "note.txt").write_text("bounded evidence\n")
    requests = []
    observed_usage = []
    first = [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call", "name": "read_file",
                "arguments": '{"path":"note.txt"}', "call_id": "call-1",
                "agent": {"agent_name": "/root"},
            },
        },
        {
            "type": "response.completed",
            "response": {"usage": {"input_tokens": 12, "output_tokens": 3}},
        },
    ]
    second = _events('{"evidence_records": []}', child="/root/researcher")

    def opener(_request, **_kwargs):
        requests.append(True)
        return _Response(first if len(requests) == 1 else second)

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
        before_request=lambda: None,
        usage_observer=lambda prompt, completion: observed_usage.append((prompt, completion)),
    )
    result = client.run("inspect")

    assert len(requests) == 2
    assert observed_usage == [(12, 3), (12, 8)]
    assert result.usage == {"prompt_tokens": 24, "completion_tokens": 11}


def test_malformed_hosted_root_schema_is_a_safe_adapter_error(tmp_path):
    def opener(_request, **_kwargs):
        return _Response(_events("not-json", child="/root/researcher"))

    client = OpenAIResponsesMultiAgentClient(
        api_key="test", model="gpt-5.6", workspace=str(tmp_path), opener=opener,
    )
    with pytest.raises(OpenAIResponsesMultiAgentError, match="malformed structured output"):
        client.run("inspect")
