from __future__ import annotations

import pytest

from ollama_code.codex_app_server import (
    CodexAppServerError,
    CodexAppServerManager,
    CodexProtocolMismatch,
    dynamic_tools,
)
from ollama_code.core import AgentCore


def schema(name: str) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": f"Run {name}",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
                "additionalProperties": False,
            },
        },
    }


def test_dynamic_tools_preserve_only_the_locus_inventory():
    translated = dynamic_tools([schema("read_file"), schema("browser_read_page")])
    assert [item["name"] for item in translated] == ["read_file", "browser_read_page"]
    assert all(item["type"] == "function" for item in translated)
    assert all("command_execution" not in item["name"] for item in translated)
    assert translated[0]["inputSchema"]["required"] == ["path"]


def test_dynamic_tools_reject_duplicates_and_invalid_names():
    with pytest.raises(CodexProtocolMismatch, match="duplicate"):
        dynamic_tools([schema("read_file"), schema("read_file")])
    with pytest.raises(CodexProtocolMismatch, match="not App Server compatible"):
        dynamic_tools([schema("bad tool name")])


def test_bundled_codex_command_uses_supported_app_server_flags():
    manager = CodexAppServerManager(helper_path="/fake/codex")
    assert manager._command() == ["/fake/codex", "app-server", "--listen", "stdio://"]


def test_thread_contract_disables_native_environment_and_tools(monkeypatch):
    manager = CodexAppServerManager(helper_path="/fake/codex")
    captured = {}

    def request(method, params=None, **_kwargs):
        captured["method"] = method
        captured["params"] = params
        return {"thread": {"id": "thread-1"}}

    monkeypatch.setattr(manager, "request", request)
    assert manager.start_thread(
        model="gpt-test",
        cwd="/workspace",
        base_instructions="Locus system prompt",
        tools=[schema("read_file")],
    ) == "thread-1"

    assert captured["method"] == "thread/start"
    params = captured["params"]
    assert params["environments"] == []
    assert params["approvalPolicy"] == "never"
    assert params["sandbox"] == "read-only"
    assert params["baseInstructions"] == "Locus system prompt"
    assert [item["name"] for item in params["dynamicTools"]] == ["read_file"]
    assert params["config"]["web_search"] == "disabled"
    assert params["config"]["model_reasoning_summary"] == "auto"
    assert params["config"]["agents"]["enabled"] is False
    assert all(value is False for value in params["config"]["features"].values())


def test_chatgpt_route_contains_no_secret_fields():
    from ollama_code.orchestration import AgentProfile

    base = {
        "id": "writer",
        "name": "Writer",
        "model": "gpt-test",
        "role": "implementer",
        "instructions": "Write carefully",
        "capabilities": [],
        "access_ceiling": "workspace_write",
        "timeout_seconds": 60,
        "token_limit": 8_000,
        "metering": "self_hosted",
        "route": {
            "provider": "chatgpt",
            "account_id": "managed-account",
            "account_label": "ChatGPT plan",
        },
    }
    assert AgentProfile.parse(base).route["provider"] == "chatgpt"
    base["route"]["api_key"] = "must-not-pass"
    with pytest.raises(ValueError, match="contains credentials"):
        AgentProfile.parse(base)


class FakeManagedRuntime:
    runtime_version = "0.147.0"

    def __init__(self, *, reject_resume: bool = False):
        self.reject_resume = reject_resume
        self.started: list[str] = []
        self.resumed: list[str] = []
        self.turn_texts: list[str] = []

    def account(self, *, refresh=False):
        del refresh
        return {"account": {"type": "chatgpt", "email": "person@example.com"}}

    def models(self):
        return [{"model": "gpt-test"}]

    def start_thread(self, **_kwargs):
        thread_id = f"thread-{len(self.started) + 1}"
        self.started.append(thread_id)
        return thread_id

    def resume_thread(self, thread_id, **_kwargs):
        self.resumed.append(thread_id)
        if self.reject_resume:
            raise CodexAppServerError("history unavailable")
        return thread_id

    def run_turn(self, *, text, event_handler, **_kwargs):
        self.turn_texts.append(text)
        event_handler({
            "method": "item/reasoning/summaryTextDelta",
            "params": {"delta": "Checked the workspace."},
        })
        event_handler({
            "method": "item/reasoning/textDelta",
            "params": {"delta": "private chain of thought"},
        })
        event_handler({
            "method": "item/agentMessage/delta",
            "params": {"delta": "managed answer"},
        })
        event_handler({
            "method": "thread/tokenUsage/updated",
            "params": {
                "tokenUsage": {"last": {"inputTokens": 4, "outputTokens": 2}},
            },
        })
        return {"status": "completed"}


def _managed_core(tmp_path, runtime):
    core = AgentCore(cwd=str(tmp_path), config={})
    core.use_chatgpt(
        account_id="managed-account",
        model="gpt-test",
        account_label="ChatGPT plan",
        manager=runtime,
    )
    return core


def test_managed_thread_resumes_from_secret_free_session_marker(tmp_path):
    runtime = FakeManagedRuntime()
    core = _managed_core(tmp_path, runtime)
    core.run_turn("first request", allow_tools=False)
    session_id = core.session.session_id

    core.start_new_session()
    core.resume_session(session_id)
    core.run_turn("second request", allow_tools=False)

    assert runtime.started == ["thread-1"]
    assert runtime.resumed == ["thread-1"]
    marker = core.session.chatgpt_thread_state(core.session.path)
    assert marker is not None
    assert marker["thread_id"] == "thread-1"
    assert "token" not in marker and "api_key" not in marker


def test_managed_reasoning_streams_only_provider_summary(tmp_path):
    runtime = FakeManagedRuntime()
    core = _managed_core(tmp_path, runtime)
    events = []
    core.on_event(events.append)

    core.run_turn("inspect", allow_tools=False)

    thinking = "".join(event.get("text", "") for event in events if event["type"] == "thinking")
    assert thinking == "Checked the workspace."
    assert "private chain of thought" not in thinking
    assistant = next(message for message in reversed(core.messages) if message["role"] == "assistant")
    assert assistant["_display_reasoning"] == "Checked the workspace."


def test_missing_managed_history_rebuilds_from_canonical_transcript(tmp_path):
    runtime = FakeManagedRuntime(reject_resume=True)
    core = _managed_core(tmp_path, runtime)
    core.run_turn("first request", allow_tools=False)
    session_id = core.session.session_id

    core.start_new_session()
    core.resume_session(session_id)
    core.run_turn("second request", allow_tools=False)

    assert runtime.resumed == ["thread-1"]
    assert runtime.started == ["thread-1", "thread-2"]
    assert "Canonical Locus transcript" in runtime.turn_texts[-1]
    assert "first request" in runtime.turn_texts[-1]
