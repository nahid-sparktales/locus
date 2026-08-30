from __future__ import annotations

import pytest

from ollama_code.codex_app_server import (
    CodexAppServerError,
    CodexAppServerManager,
    CodexManagerRegistry,
    CodexProtocolMismatch,
    codex_home_for_account,
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


class StructuredManagedRuntime(FakeManagedRuntime):
    def run_turn(self, *, text, event_handler, **_kwargs):
        self.turn_texts.append(text)
        for event in [
            {
                "method": "item/started",
                "params": {"item": {"id": "reason-1", "type": "reasoning"}},
            },
            {
                "method": "item/reasoning/summaryPartAdded",
                "params": {"itemId": "reason-1", "summaryIndex": 0},
            },
            {
                "method": "item/reasoning/summaryTextDelta",
                "params": {
                    "itemId": "reason-1", "summaryIndex": 0,
                    "delta": "draft summary",
                },
            },
            {
                "method": "item/reasoning/textDelta",
                "params": {"itemId": "reason-1", "delta": "private chain of thought"},
            },
            {
                "method": "item/completed",
                "params": {"item": {
                    "id": "reason-1", "type": "reasoning",
                    "summary": [
                        {"type": "summary_text", "text": "**Loading skill**"},
                        {"type": "summary_text", "text": "**Fetching data**"},
                    ],
                }},
            },
            {
                "method": "item/started",
                "params": {"item": {
                    "id": "commentary-1", "type": "agentMessage",
                    "phase": "commentary",
                }},
            },
            {
                "method": "item/agentMessage/delta",
                "params": {"itemId": "commentary-1", "delta": "Using **weather**."},
            },
            {
                "method": "item/completed",
                "params": {"item": {
                    "id": "commentary-1", "type": "agentMessage",
                    "phase": "commentary", "text": "Using **weather** to check.",
                }},
            },
            # Duplicate completion must not create a duplicate transcript row.
            {
                "method": "item/completed",
                "params": {"item": {
                    "id": "commentary-1", "type": "agentMessage",
                    "phase": "commentary", "text": "Using **weather** to check.",
                }},
            },
            {
                "method": "item/agentMessage/delta",
                "params": {"itemId": "final-1", "delta": "joined draft"},
            },
            {
                "method": "item/completed",
                "params": {"item": {
                    "id": "final-1", "type": "agentMessage",
                    "phase": "final_answer",
                    "content": [{
                        "type": "output_text",
                        "text": "- **Seoul:** 25°C\n- **Dubai:** 33°C",
                    }],
                }},
            },
            {
                "method": "thread/tokenUsage/updated",
                "params": {"tokenUsage": {"last": {"inputTokens": 6, "outputTokens": 4}}},
            },
        ]:
            event_handler(event)
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

    deltas = [event for event in events if event["type"] == "assistant_item_delta"]
    assert "".join(event.get("text", "") for event in deltas) == (
        "Checked the workspace.managed answer"
    )
    assert "private chain of thought" not in str(events)
    stored = core.session.load(core.session.path)
    reasoning = next(message for message in stored if message.get("_display_only"))
    assert reasoning["_display_reasoning_sections"] == ["Checked the workspace."]
    assert reasoning["_display_reasoning"] == "Checked the workspace."


def test_managed_items_preserve_phases_sections_and_authoritative_completion(tmp_path):
    runtime = StructuredManagedRuntime()
    core = _managed_core(tmp_path, runtime)
    events = []
    core.on_event(events.append)

    core.run_turn("inspect", allow_tools=False)

    starts = [event for event in events if event["type"] == "assistant_item_start"]
    assert [(event["item_id"], event["kind"], event.get("phase")) for event in starts] == [
        ("reason-1", "reasoning", None),
        ("commentary-1", "message", "commentary"),
        ("final-1", "message", "final_answer"),
    ]
    ends = [event for event in events if event["type"] == "assistant_item_end"]
    assert ends[0]["sections"] == ["**Loading skill**", "**Fetching data**"]
    assert ends[1]["phase"] == "commentary"
    assert ends[1]["text"] == "Using **weather** to check."
    assert ends[2]["phase"] == "final_answer"
    assert ends[2]["text"].startswith("- **Seoul:**")
    assert "joined draft" not in ends[2]["text"]
    assert "private chain of thought" not in str(events)

    stored = core.session.load(core.session.path)
    assistant = [message for message in stored if message.get("role") == "assistant"]
    assert len(assistant) == 3
    assert assistant[0]["_display_reasoning_sections"] == [
        "**Loading skill**", "**Fetching data**",
    ]
    assert assistant[1]["_phase"] == "commentary"
    assert assistant[2]["_phase"] == "final_answer"
    assert assistant[2]["content"].startswith("- **Seoul:**")
    assert all(not message.get("_display_only") for message in core.messages)


def test_managed_structured_history_survives_resume_without_reasoning_in_context(tmp_path):
    runtime = StructuredManagedRuntime()
    core = _managed_core(tmp_path, runtime)
    core.run_turn("inspect", allow_tools=False)
    session_id = core.session.session_id

    core.start_new_session()
    result = core.resume_session(session_id)

    restored = result["data"]["messages"]
    reasoning = next(message for message in restored if message.get("reasoning_sections"))
    assert reasoning["reasoning_sections"] == ["**Loading skill**", "**Fetching data**"]
    assert next(message for message in restored if message.get("phase") == "commentary")[
        "item_id"
    ] == "commentary-1"
    assert next(message for message in restored if message.get("phase") == "final_answer")[
        "content"
    ].startswith("- **Seoul:**")
    assert all(not message.get("_display_only") for message in core.messages)


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


def test_account_homes_are_separate_directories(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCUS_CODEX_HOME", str(tmp_path / "codex"))
    legacy = codex_home_for_account("")
    first = codex_home_for_account("11111111-2222-3333-4444-555555555555")
    second = codex_home_for_account("66666666-7777-8888-9999-000000000000")

    # The empty id keeps the pre-multi-account home, so upgrading does not sign
    # the existing user out.
    assert legacy == tmp_path / "codex"
    assert first != second
    assert first != legacy and second != legacy
    # Per-account homes live beside the legacy one, never inside it: nesting
    # would make one account's credentials part of another's home.
    assert legacy not in first.parents


def test_account_home_ids_that_could_escape_are_refused(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCUS_CODEX_HOME", str(tmp_path / "codex"))
    for hostile in ("../escape", "a/b", ".hidden", "with space", "x" * 65, "/abs"):
        with pytest.raises(ValueError, match="invalid ChatGPT account home id"):
            codex_home_for_account(hostile)


def test_registry_keeps_one_helper_per_account(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCUS_CODEX_HOME", str(tmp_path / "codex"))
    registry = CodexManagerRegistry(client_version="1")

    first = registry.manager("aaaa1111")
    second = registry.manager("bbbb2222")

    assert first is registry.manager("aaaa1111")
    assert first is not second
    assert first.codex_home != second.codex_home
    # Listing an account must not be what launches its helper.
    assert registry.existing("cccc3333") is None
    assert not first.is_running and not second.is_running


def test_registry_listeners_reach_accounts_added_later(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCUS_CODEX_HOME", str(tmp_path / "codex"))
    registry = CodexManagerRegistry()
    seen: list[dict] = []
    early = registry.manager("aaaa1111")
    registry.add_listener(seen.append)
    late = registry.manager("bbbb2222")

    for manager in (early, late):
        for listener in manager._global_listeners:
            listener({"method": "account/updated"})

    assert len(seen) == 2


def test_registry_close_forgets_the_helper_it_closed(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCUS_CODEX_HOME", str(tmp_path / "codex"))
    registry = CodexManagerRegistry()
    first = registry.manager("aaaa1111")
    registry.close("aaaa1111")
    assert registry.existing("aaaa1111") is None
    assert registry.manager("aaaa1111") is not first

    registry.manager("bbbb2222")
    registry.close_all()
    assert registry.existing("aaaa1111") is None
    assert registry.existing("bbbb2222") is None


# --- Codex-native parity mode -----------------------------------------------


from ollama_code.codex_app_server import CodexThreadOptions  # noqa: E402
from ollama_code.sessions import split_parity_prompt  # noqa: E402

PARITY_OPTIONS = CodexThreadOptions(
    native_prompt=True,
    developer_instructions="workspace notes",
    sandbox="workspace-write",
    approval_policy="on-request",
)


def test_parity_thread_contract_omits_base_instructions_and_personality(monkeypatch):
    manager = CodexAppServerManager(helper_path="/fake/codex")
    captured = {}

    def request(method, params=None, **_kwargs):
        captured["method"] = method
        captured["params"] = params
        return {"thread": {"id": "thread-1"}}

    monkeypatch.setattr(manager, "request", request)
    manager.start_thread(
        model="gpt-test",
        cwd="/workspace",
        tools=[schema("shell")],
        options=PARITY_OPTIONS,
    )
    params = captured["params"]
    # Omission — not an empty string — is what selects the native prompt.
    assert "baseInstructions" not in params
    assert "personality" not in params
    assert params["developerInstructions"] == "workspace notes"
    assert params["sandbox"] == "workspace-write"
    assert params["approvalPolicy"] == "on-request"
    assert params["environments"] == []
    assert params["config"]["web_search"] == "disabled"


def test_parity_web_search_toggle_flips_config(monkeypatch):
    manager = CodexAppServerManager(helper_path="/fake/codex")
    captured = {}

    def request(method, params=None, **_kwargs):
        captured["params"] = params
        return {"thread": {"id": "thread-1"}}

    monkeypatch.setattr(manager, "request", request)
    search_on = CodexThreadOptions(native_prompt=True, web_search=True)
    manager.start_thread(model="gpt-test", cwd="/w", tools=[], options=search_on)
    config = captured["params"]["config"]
    assert config["web_search"] == "cached"
    assert config["features"]["standalone_web_search"] is True
    assert config["features"]["web_search_request"] is True
    assert config["features"]["web_search_cached"] is True
    assert config["features"]["shell_tool"] is False


def test_legacy_thread_contract_is_unchanged_without_options(monkeypatch):
    manager = CodexAppServerManager(helper_path="/fake/codex")
    captured = {}

    def request(method, params=None, **_kwargs):
        captured["params"] = params
        return {"thread": {"id": "thread-1"}}

    monkeypatch.setattr(manager, "request", request)
    manager.start_thread(
        model="gpt-test", cwd="/w", base_instructions="Locus prompt", tools=[],
    )
    params = captured["params"]
    assert params["baseInstructions"] == "Locus prompt"
    assert params["personality"] == "none"
    assert params["developerInstructions"] == ""
    assert params["sandbox"] == "read-only"
    assert params["approvalPolicy"] == "never"
    assert all(value is False for value in params["config"]["features"].values())


def test_config_toml_follows_thread_defaults(tmp_path):
    manager = CodexAppServerManager(helper_path="/fake/codex", codex_home=tmp_path / "home")
    manager._prepare_home()
    baseline = (tmp_path / "home" / "config.toml").read_text()
    assert 'web_search = "disabled"' in baseline
    assert "standalone_web_search = false" in baseline

    manager.set_thread_defaults(CodexThreadOptions(web_search=True))
    manager._prepare_home()
    enabled = (tmp_path / "home" / "config.toml").read_text()
    assert 'web_search = "cached"' in enabled
    assert "standalone_web_search = true" in enabled
    assert "web_search_cached = true" in enabled


def test_effort_rides_turn_start_only_when_set(monkeypatch):
    manager = CodexAppServerManager(helper_path="/fake/codex")
    captured = []

    def request(method, params=None, **_kwargs):
        captured.append((method, params))
        if method == "turn/start":
            for target in manager._thread_queues.get(params["threadId"], []):
                target.put({"method": "turn/completed", "params": {
                    "threadId": params["threadId"], "turn": {"status": "completed"},
                }})
        return {"turn": {"id": "turn-1"}}

    monkeypatch.setattr(manager, "request", request)
    manager.run_turn(thread_id="t1", text="hello", effort="high")
    manager.run_turn(thread_id="t1", text="hello")
    with_effort, without_effort = captured[0][1], captured[1][1]
    assert with_effort["effort"] == "high"
    assert "effort" not in without_effort


def test_structured_tool_results_pass_through(monkeypatch):
    manager = CodexAppServerManager(helper_path="/fake/codex")
    responses = []

    def request(method, params=None, **_kwargs):
        if method == "turn/start":
            targets = manager._thread_queues.get(params["threadId"], [])
            for target in targets:
                target.put({
                    "id": 7, "method": "item/tool/call",
                    "params": {"threadId": params["threadId"], "tool": "view_image",
                               "arguments": {}, "callId": "c1"},
                })
                target.put({"method": "turn/completed", "params": {
                    "threadId": params["threadId"], "turn": {}}})
        return {"turn": {"id": "turn-1"}}

    monkeypatch.setattr(manager, "request", request)
    monkeypatch.setattr(manager, "respond", lambda ident, body: responses.append(body))
    structured = {
        "content_items": [{"type": "inputImage", "imageUrl": "data:image/png;base64,AAA"}],
        "success": True,
    }
    manager.run_turn(
        thread_id="t1", text="x", tool_handler=lambda *a: structured,
    )
    assert responses == [{
        "contentItems": [{"type": "inputImage", "imageUrl": "data:image/png;base64,AAA"}],
        "success": True,
    }]


def test_split_parity_prompt_modes():
    decorated = (
        "[Locus mode: Work]\n\n"
        "Solve the request using the workspace and tools when useful.\n\n"
        "Use this explicitly selected context:\n--- /x.txt ---\ncontents\n\n"
        "User request:\nfix the bug"
    )
    context, raw = split_parity_prompt(decorated, "work")
    assert raw == "fix the bug"
    assert "[Locus mode:" not in context
    assert "Solve the request" not in context
    assert "--- /x.txt ---" in context

    context, raw = split_parity_prompt(decorated.replace("Work", "Plan"), "plan")
    assert raw == "fix the bug"
    assert "Solve the request" in context

    context, raw = split_parity_prompt("plain CLI text", "work")
    assert (context, raw) == ("", "plain CLI text")


class ParityFakeRuntime(FakeManagedRuntime):
    supports_parity = True

    def __init__(self, tool_calls: list[tuple[str, dict]] | None = None):
        super().__init__()
        self.tool_calls = tool_calls or []
        self.start_kwargs: list[dict] = []
        self.turn_kwargs: list[dict] = []
        self.thread_defaults = CodexThreadOptions()

    def set_thread_defaults(self, options):
        self.thread_defaults = options

    def start_thread(self, **kwargs):
        self.start_kwargs.append(kwargs)
        return super().start_thread()

    def run_turn(self, *, text, event_handler, tool_handler=None, **kwargs):
        self.turn_kwargs.append({"text": text, **kwargs})
        for name, arguments in self.tool_calls:
            assert tool_handler is not None
            tool_handler(name, arguments, f"call-{name}")
        return super().run_turn(text=text, event_handler=event_handler)


DECORATED = (
    "[Locus mode: Work]\n\n"
    "Solve the request using the workspace and tools when useful.\n\n"
    "User request:\nwhat changed?"
)


def test_parity_turn_uses_native_contract_and_raw_input(tmp_path):
    (tmp_path / "AGENTS.md").write_text("Always answer in haiku.\n")
    runtime = ParityFakeRuntime()
    core = _managed_core(tmp_path, runtime)

    core.run_turn(DECORATED)

    start = runtime.start_kwargs[-1]
    options = start["options"]
    assert options.native_prompt is True
    assert "Always answer in haiku." in options.developer_instructions
    assert start["base_instructions"] == ""
    tool_names = [item["function"]["name"] for item in start["tools"]]
    assert tool_names == ["shell", "apply_patch", "update_plan", "ask_user_question"]

    items = runtime.turn_kwargs[-1]["input_items"]
    texts = [item["text"] for item in items if item["type"] == "text"]
    assert texts[-1] == "what changed?"
    assert all("[Locus mode:" not in text for text in texts)


def test_parity_thread_survives_identical_turns_and_effort_changes(tmp_path):
    runtime = ParityFakeRuntime()
    core = _managed_core(tmp_path, runtime)

    core.run_turn(DECORATED)
    core.run_turn(DECORATED)
    assert runtime.started == ["thread-1"]

    # Effort is applied per turn: changing it must not restart the thread.
    core.use_chatgpt(
        account_id="managed-account", model="gpt-test",
        account_label="ChatGPT plan", manager=runtime, reasoning_effort="high",
    )
    core.run_turn(DECORATED)
    assert runtime.started == ["thread-1"]
    assert runtime.turn_kwargs[-1]["effort"] == "high"
    assert runtime.turn_kwargs[0]["effort"] == ""

    # Flipping web search changes the thread contract and must restart it.
    core.use_chatgpt(
        account_id="managed-account", model="gpt-test",
        account_label="ChatGPT plan", manager=runtime, web_search=True,
    )
    core.run_turn(DECORATED)
    assert runtime.started == ["thread-1", "thread-2"]
    assert runtime.start_kwargs[-1]["options"].web_search is True


def test_parity_gate_falls_back_to_legacy_contract(tmp_path):
    runtime = ParityFakeRuntime()
    core = _managed_core(tmp_path, runtime)
    assert core.chatgpt_parity_active() is True

    core.config["chatgpt_native_mode"] = False
    assert core.chatgpt_parity_active() is False
    core.config["chatgpt_native_mode"] = True

    core.agent_mode = "ask"
    assert core.chatgpt_parity_active() is False
    core.agent_mode = "work"

    core.tool_ctx.delegate_read_only = lambda args: ""
    assert core.chatgpt_parity_active() is True
    core.tool_ctx.delegate_read_only = None

    core.agent_role_contract = "read-only reviewer"
    assert core.chatgpt_parity_active() is False
    core.agent_role_contract = ""

    # The broker proxy never runs parity threads.
    runtime_no_parity = FakeManagedRuntime()
    core.codex_manager = runtime_no_parity
    assert core.chatgpt_parity_active() is False


def test_parity_disabled_keeps_locus_instructions(tmp_path):
    runtime = ParityFakeRuntime()
    core = _managed_core(tmp_path, runtime)
    core.config["chatgpt_native_mode"] = False

    core.run_turn(DECORATED)

    start = runtime.start_kwargs[-1]
    assert start["options"] is None
    assert "Locked runtime rules" in start["base_instructions"]
    # Legacy behavior unchanged: a fresh thread's first turn carries the
    # canonical-transcript wrapper with the decorated text embedded.
    items = runtime.turn_kwargs[-1]["input_items"]
    assert "[Locus mode: Work]" in items[0]["text"]


def test_parity_shell_and_update_plan_execute_as_canonical_tools(tmp_path):
    runtime = ParityFakeRuntime(tool_calls=[
        ("shell", {"command": "echo parity", "workdir": str(tmp_path)}),
        ("update_plan", {"plan": [
            {"step": "look around", "status": "completed"},
            {"step": "fix it", "status": "in_progress"},
        ]}),
    ])
    core = _managed_core(tmp_path, runtime)
    events = []
    core.on_event(events.append)

    core.run_turn(DECORATED, lambda *a: "once")

    proposed = [event for event in events if event["type"] == "tool_call_proposed"]
    assert [event["tool"] for event in proposed] == ["bash", "todo_write"]
    assert f"cd {tmp_path} && echo parity" in proposed[0]["detail"]
    results = [event for event in events if event["type"] == "tool_result"]
    assert "parity" in results[0]["result"]
    todo_updates = [event for event in events if event["type"] == "todo_update"]
    assert todo_updates[-1]["todos"] == [
        {"content": "look around", "status": "completed"},
        {"content": "fix it", "status": "in_progress"},
    ]


def test_parity_schemas_add_submit_plan_only_in_plan_mode(tmp_path):
    runtime = ParityFakeRuntime()
    core = _managed_core(tmp_path, runtime)
    work = [item["function"]["name"] for item in core.tool_registry.parity_schemas()]
    plan = [
        item["function"]["name"]
        for item in core.tool_registry.parity_schemas(plan_mode=True)
    ]
    assert "submit_plan" not in work
    assert "submit_plan" in plan
    # The question tool rides every parity surface: Grill and Work turns need
    # the popup as much as Plan does.
    assert "ask_user_question" in plan
    assert set(work) == {"shell", "apply_patch", "update_plan", "ask_user_question"}

    core.tool_ctx.delegate_read_only = lambda _arguments: '{"results":[]}'
    core.tool_registry.set_solo_swarm_enabled(True)
    adaptive = [
        item["function"]["name"]
        for item in core.tool_registry.parity_schemas()
    ]
    assert set(adaptive) == {
        "shell", "apply_patch", "update_plan", "delegate_read_only",
        "ask_user_question",
    }
    core.run_turn(DECORATED)
    start = runtime.start_kwargs[-1]
    assert start["options"].native_prompt is True
    assert "adaptive Solo delegation" in start["options"].developer_instructions
    assert "delegate_read_only" in {
        item["function"]["name"] for item in start["tools"]
    }


class MeteredManagedRuntime(FakeManagedRuntime):
    """A helper that bills each model call separately, as the real one does."""

    def __init__(self, *, total=None, calls=2, tools=(), include_last=True):
        super().__init__()
        self.total = total
        self.calls = calls
        self.tools = list(tools)
        self.include_last = include_last

    def run_turn(self, *, text, event_handler, tool_handler=None, **_kwargs):
        self.turn_texts.append(text)
        if tool_handler is not None:
            for name, arguments in self.tools:
                tool_handler(name, arguments, f"call-{name}")
        for index in range(self.calls):
            usage = {}
            if self.include_last:
                usage["last"] = {"inputTokens": 100, "outputTokens": 10 + index}
            if self.total is not None:
                usage["total"] = self.total
            event_handler({
                "method": "thread/tokenUsage/updated",
                "params": {"tokenUsage": usage},
            })
        event_handler({
            "method": "item/agentMessage/delta",
            "params": {"delta": "done"},
        })
        return {"status": "completed"}


def _turn_done(core, runtime, text="do the work", **kwargs):
    events = []
    core.on_event(events.append)
    core.run_turn(text, **kwargs)
    return next(event for event in events if event["type"] == "turn_done")


def test_managed_turn_counts_every_model_call_and_tool_step(tmp_path):
    """A managed turn used to report one model call however much it did."""
    # Two tools keeps this under FINAL_ANSWER_TOOL_FLOOR, so the turn is
    # exactly one thread call's worth of work and the arithmetic stays legible.
    runtime = MeteredManagedRuntime(
        calls=3, tools=[("list_dir", {}), ("glob", {"pattern": "*"})]
    )
    core = _managed_core(tmp_path, runtime)

    terminal = _turn_done(core, runtime)

    assert terminal["model_calls"] == 3
    assert terminal["tool_steps"] == 2
    assert terminal["prompt_tokens"] == 300
    assert terminal["completion_tokens"] == 10 + 11 + 12


def test_managed_turn_reports_the_per_call_sum_even_when_a_total_is_present(tmp_path):
    """The thread ``total`` is cumulative; it must never displace the turn's own sum.

    An earlier build preferred the total wholesale, so every turn re-billed
    the whole thread and a trivial late turn read as tens of thousands of
    tokens in the Runs panel.
    """
    runtime = MeteredManagedRuntime(
        calls=2, total={"inputTokens": 900, "outputTokens": 90}
    )
    core = _managed_core(tmp_path, runtime)

    terminal = _turn_done(core, runtime, allow_tools=False)

    assert terminal["prompt_tokens"] == 200
    assert terminal["completion_tokens"] == 10 + 11
    assert terminal["model_calls"] == 2
    assert terminal["tool_steps"] == 0


def test_managed_turn_attributes_only_the_thread_total_delta(tmp_path):
    """Without per-call updates, a turn claims only its slice of the total."""
    runtime = MeteredManagedRuntime(
        calls=1, include_last=False,
        total={"inputTokens": 900, "outputTokens": 90},
    )
    core = _managed_core(tmp_path, runtime)

    first = _turn_done(core, runtime, allow_tools=False)
    assert first["prompt_tokens"] == 900
    assert first["completion_tokens"] == 90

    runtime.total = {"inputTokens": 950, "outputTokens": 100}
    second = _turn_done(core, runtime, allow_tools=False)
    assert second["prompt_tokens"] == 50
    assert second["completion_tokens"] == 10


def test_managed_turn_survives_a_shrinking_thread_total(tmp_path):
    """A restarted or compacted thread resets the baseline, never goes negative."""
    runtime = MeteredManagedRuntime(
        calls=1, include_last=False,
        total={"inputTokens": 900, "outputTokens": 90},
    )
    core = _managed_core(tmp_path, runtime)
    _turn_done(core, runtime, allow_tools=False)

    runtime.total = {"inputTokens": 100, "outputTokens": 10}
    terminal = _turn_done(core, runtime, allow_tools=False)
    assert terminal["prompt_tokens"] == 100
    assert terminal["completion_tokens"] == 10


def test_usage_less_turn_leaves_token_baselines_alone(tmp_path):
    """Zeros mean absence: a turn with no usage must not reset the baselines.

    An interrupted turn that never saw a tokenUsage update reports totals of
    0/0; treating that as a thread restart re-billed the whole thread to the
    next turn.
    """
    runtime = MeteredManagedRuntime(
        calls=1, include_last=False,
        total={"inputTokens": 900, "outputTokens": 90},
    )
    core = _managed_core(tmp_path, runtime)
    _turn_done(core, runtime, allow_tools=False)

    runtime.calls = 0
    quiet = _turn_done(core, runtime, allow_tools=False)
    assert quiet["prompt_tokens"] == 0
    assert quiet["completion_tokens"] == 0

    runtime.calls = 1
    runtime.total = {"inputTokens": 950, "outputTokens": 100}
    terminal = _turn_done(core, runtime, allow_tools=False)
    assert terminal["prompt_tokens"] == 50
    assert terminal["completion_tokens"] == 10


def test_baselines_stay_continuous_across_per_call_and_delta_paths(tmp_path):
    """A per-call-summed turn still advances the baseline the next turn needs."""
    runtime = MeteredManagedRuntime(
        calls=2, total={"inputTokens": 900, "outputTokens": 90}
    )
    core = _managed_core(tmp_path, runtime)
    first = _turn_done(core, runtime, allow_tools=False)
    assert first["prompt_tokens"] == 200

    runtime.calls = 1
    runtime.include_last = False
    runtime.total = {"inputTokens": 950, "outputTokens": 100}
    second = _turn_done(core, runtime, allow_tools=False)
    assert second["prompt_tokens"] == 50
    assert second["completion_tokens"] == 10


def test_replacement_thread_resets_token_baselines(tmp_path):
    """A fingerprint change starts a new thread whose totals restart at zero."""
    runtime = MeteredManagedRuntime(
        calls=1, include_last=False,
        total={"inputTokens": 100, "outputTokens": 10},
    )
    core = _managed_core(tmp_path, runtime)
    first = _turn_done(core, runtime, allow_tools=False)
    assert first["prompt_tokens"] == 100

    # Flipping web search changes the thread contract and forces a restart.
    core.use_chatgpt(
        account_id="managed-account", model="gpt-test",
        account_label="ChatGPT plan", manager=runtime, web_search=True,
    )
    runtime.total = {"inputTokens": 150, "outputTokens": 15}
    second = _turn_done(core, runtime, allow_tools=False)
    assert runtime.started == ["thread-1", "thread-2"]
    assert second["prompt_tokens"] == 150, "the new thread's total is all this turn's"
    assert second["completion_tokens"] == 15


def test_resumed_session_inherits_token_baselines(tmp_path):
    """The resume marker carries the baselines, so the first post-resume turn
    is billed as a delta rather than the thread's whole cumulative total."""
    runtime = MeteredManagedRuntime(
        calls=1, include_last=False,
        total={"inputTokens": 900, "outputTokens": 90},
    )
    core = _managed_core(tmp_path, runtime)
    _turn_done(core, runtime, allow_tools=False)
    session_id = core.session.session_id

    core.start_new_session()
    core.resume_session(session_id)
    runtime.total = {"inputTokens": 950, "outputTokens": 100}
    terminal = _turn_done(core, runtime, allow_tools=False)

    assert runtime.resumed == ["thread-1"]
    assert terminal["prompt_tokens"] == 50
    assert terminal["completion_tokens"] == 10


def test_ask_user_question_over_the_parity_route_emits_question_ready(tmp_path):
    runtime = MeteredManagedRuntime(
        calls=1,
        tools=[(
            "ask_user_question",
            {
                "title": "Feed scope",
                "question": "Which feed should the script read?",
                "options": ["Site-wide /new", {"label": "One subreddit"}],
                "recommended": "Site-wide /new",
            },
        )],
    )
    core = _managed_core(tmp_path, runtime)
    events = []
    core.on_event(events.append)

    core.run_turn(DECORATED)

    ready = next(event for event in events if event["type"] == "question_ready")
    assert ready["question"]["title"] == "Feed scope"
    assert [option["label"] for option in ready["question"]["options"]] == [
        "Site-wide /new", "One subreddit",
    ]
    result = next(
        event for event in events
        if event["type"] == "tool_result" and event["tool"] == "ask_user_question"
    )
    assert "End your turn" in result["result"]


def test_managed_turn_without_usage_updates_still_reports_one_call(tmp_path):
    runtime = MeteredManagedRuntime(calls=0)
    core = _managed_core(tmp_path, runtime)

    terminal = _turn_done(core, runtime, allow_tools=False)

    assert terminal["model_calls"] == 1
    assert terminal["tool_steps"] == 0
