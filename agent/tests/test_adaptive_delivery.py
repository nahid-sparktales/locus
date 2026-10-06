"""Adaptive evidence is checked at the actual classic/native delivery boundary."""
from __future__ import annotations

import copy
import json

import pytest

from ollama_code.codex_app_server import CodexThreadOptions
from ollama_code.core import AgentCore
from ollama_code.knowledge import KnowledgeStore
from ollama_code.memory_adapter import ensure_memory_adapter
from ollama_code.memory_canonical import CanonicalMemoryVault
from ollama_code.ollama import ChatResponse, OllamaError, ToolCall

MEMORY = "MEMORY-BODY-CANARY: release deployments require violet approval."
WORKSPACE = "WORKSPACE-BODY-CANARY: release deployments use signed packages."
FOLLOWUP = {"query": "release deployment approval details", "missing_information": "approval requirements",
            "sources": ["all"]}


def submissions(core):
    adapter = core.memory_adapter
    return adapter.engine.list_context_submissions(adapter.access(core), session_id=core.session.session_id,
        run_id=core.tool_ctx.memory_run_id or core._output_run_id or "standalone", agent_id=core.agent_id,
        turn_id=core._memory_turn_id)


def capture(core, **wire):
    return {**copy.deepcopy(wire), "memory": core.memory_context,
            "details": core.memory_adapter.retrieval_details(core, revalidate=False),
            "submissions": submissions(core), "rounds": core.adaptive_retrieval.allowance.rounds}


class _Client:
    host = "http://127.0.0.1:9"
    timeout = 5

    def __init__(self, core, script=()):
        self.core, self.script, self.calls = core, list(script), []

    def chat_stream(self, model, messages, **kwargs):
        self.calls.append(capture(self.core, messages=messages))
        result = self.script.pop(0) if self.script else ChatResponse(content_parts=["Checked."], done=True)
        if isinstance(result, Exception):
            raise result
        return result

    def context_length(self, _name):
        return 262_144

    def loaded_context_length(self, _name):
        return 0

    def resident_state(self, _name):
        return {"context_length": 0, "size": 0, "size_vram": 0}

    def list_models(self):
        return [{"name": "test-model"}]


class _ParityManager:
    runtime_version = "0.147.0"
    supports_parity = True

    def __init__(self, core, *, followup=False, before_followup=None):
        self.core, self.followup, self.before_followup = core, followup, before_followup
        self.thread_defaults = CodexThreadOptions()
        self.starts, self.calls, self.tool_results = [], [], []
        self.tool_name, self.tool_arguments = "search_context", copy.deepcopy(FOLLOWUP)

    def account(self, **kwargs):
        return {"account": {"type": "chatgpt", "email": "test@example.com"}}

    def models(self):
        return [{"model": "gpt-test"}]

    def set_thread_defaults(self, options):
        self.thread_defaults = options

    def start_thread(self, **kwargs):
        self.starts.append(kwargs)
        return f"thread-{len(self.starts)}"

    def run_turn(self, *, text, event_handler, tool_handler=None, **kwargs):
        self.calls.append(capture(self.core, text=text, input_items=kwargs.get("input_items", [])))
        if self.followup:
            if self.before_followup:
                self.before_followup()
            result = tool_handler(self.tool_name, self.tool_arguments, "followup-one")
            self.tool_results.append(capture(self.core, result=result))
        event_handler({"method": "item/agentMessage/delta", "params": {"delta": "Checked."}})
        event_handler({"method": "thread/tokenUsage/updated", "params": {
            "tokenUsage": {"last": {"inputTokens": 4, "outputTokens": 2}}}})
        return {"status": "completed"}


@pytest.fixture
def make_core(tmp_path, isolated_app_dir):
    cores = []
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    source = workspace / "release.md"
    source.write_text("# Release deployment\n" + WORKSPACE + "\n")
    store = KnowledgeStore(str(workspace))
    store.reindex()

    def make(*, native=False, policy=None, followup=False, before_followup=None, script=()):
        core = AgentCore(cwd=str(workspace), config={"model": "test-model", "max_iterations": 5,
                                                   "auto_compact": False})
        core.mcp.close()
        core.model = "test-model"
        core.tool_ctx.memory_run_id = "delivery-test-run"
        core.configure_agent({"memory_policy": {"auto_save_enabled": False,
            "cross_chat_context_enabled": False, **(policy or {})}})
        ensure_memory_adapter(core)
        with CanonicalMemoryVault(isolated_app_dir, workspace=str(workspace)) as vault:
            saved = vault.save({"title": "Release deployment approval", "content": MEMORY,
                                "scope": "workspace", "kind": "fact"})
        events = []
        core.on_event(lambda event: events.append(copy.deepcopy(event)))
        if native:
            provider = _ParityManager(core, followup=followup, before_followup=before_followup)
            core.use_chatgpt(account_id="managed-account", model="gpt-test", account_label="ChatGPT plan", manager=provider)
        else:
            provider = _Client(core, script)
            core.client = provider
        cores.append(core)
        return core, provider, saved, source, events

    yield make
    for core in cores:
        core.memory_adapter.close()
        core.close()


def wire_text(call, native):
    if native:
        return "\n".join(item["text"] for item in call["input_items"] if item.get("type") == "text")
    return "\n".join(str(message.get("content") or "") for message in call["messages"])


def assert_receipted_packet(call, wire):
    assert call["memory"] and call["memory"] in wire
    assert wire.count('<memory-context source="locus-memory" trust="data">') == 1
    assert call["details"]["byte_count"] == len(call["memory"].encode())
    receipt = call["details"]["receipt_id"]
    assert any(row["context_receipt_id"] == receipt and row["state"] == "uncertain"
               for row in call["submissions"])


def assert_not_persisted(core):
    saved = core.session.path.read_text()
    for body in (MEMORY, WORKSPACE):
        assert body not in saved
        assert body not in json.dumps(core.messages)


@pytest.mark.parametrize("native", [False, True])
def test_actual_initial_provider_wire_matches_selected_receipt(make_core, native):
    core, provider, saved, _, events = make_core(native=native)
    core.run_turn("What is the release deployment approval?")
    assert len(provider.calls) == 1
    call = provider.calls[0]
    wire = wire_text(call, native)
    assert_receipted_packet(call, wire)
    assert MEMORY in wire and WORKSPACE in wire
    assert {item["id"] for item in call["details"]["items"]} == {saved["id"]}
    assert any(row["state"] == "submitted" and row["context_receipt_id"] == call["details"]["receipt_id"]
               for row in submissions(core))
    traces = [event["trace"] for event in events if event.get("type") == "retrieval_trace"]
    assert any(trace["phase"] == "submitted" and trace["selected"] for trace in traces)
    assert all(trace["packed_bytes"] <= 24_000 for trace in traces)
    assert_not_persisted(core)


def test_native_followup_wire_uses_new_packet_receipt_without_saving_body(make_core, isolated_app_dir):
    core, provider, saved, _, _ = make_core(native=True, followup=True)
    updated = MEMORY.replace("violet", "turquoise")
    def correct_memory():
        with CanonicalMemoryVault(isolated_app_dir, workspace=core.workspace_root) as vault:
            vault.save({"content": updated}, saved["id"])
    provider.before_followup = correct_memory
    core.run_turn("What is the release deployment approval?")
    assert len(provider.tool_results) == 1
    followup = provider.tool_results[0]
    assert isinstance(followup["result"], str)
    assert_receipted_packet(followup, followup["result"])
    assert updated in followup["result"] and MEMORY not in followup["result"]
    assert followup["details"]["receipt_id"] != provider.calls[0]["details"]["receipt_id"]
    assert followup["rounds"] == 2
    delivered = {row["context_receipt_id"] for row in submissions(core) if row["state"] == "submitted"}
    assert {provider.calls[0]["details"]["receipt_id"], followup["details"]["receipt_id"]} <= delivered
    assert updated not in core.session.path.read_text() and updated not in json.dumps(core.messages)
    assert_not_persisted(core)


def test_native_memory_opt_out_preserves_workspace_evidence(make_core):
    core, provider, _, _, _ = make_core(native=True, policy={"native_codex_enabled": False})
    core.run_turn("What is the release deployment approval?")
    wire = wire_text(provider.calls[0], True)
    assert WORKSPACE in wire and MEMORY not in wire
    assert not provider.calls[0]["details"]["items"]
    assert all(row["state"] == "skipped" for row in submissions(core))
    assert_not_persisted(core)


@pytest.mark.parametrize("native", [False, True])
def test_revocation_at_delivery_omits_memory_and_changed_source(make_core, monkeypatch, isolated_app_dir, native):
    core, provider, saved, source, events = make_core(native=native)
    adapter = core.memory_adapter
    begin = adapter.begin_submission
    revoked = False
    def revoke_before_submission(*args, **kwargs):
        nonlocal revoked
        if not revoked:
            revoked = True
            with CanonicalMemoryVault(isolated_app_dir, workspace=core.workspace_root) as vault:
                vault.delete(saved["id"])
            source.write_text("# Changed release deployment\nNo prior source statement remains.\n")
        return begin(*args, **kwargs)
    monkeypatch.setattr(adapter, "begin_submission", revoke_before_submission)
    core.run_turn("What is the release deployment approval?")
    wire = wire_text(provider.calls[0], native)
    assert revoked and MEMORY not in wire and WORKSPACE not in wire
    assert all(row["state"] == "skipped" for row in submissions(core))
    delivered = [event["trace"] for event in events if event.get("type") == "retrieval_trace"
                 and event["trace"]["phase"] in {"uncertain", "submitted"}]
    assert delivered and all(not trace["selected"] for trace in delivered)


def test_provider_retry_preserves_two_round_allowance(make_core, monkeypatch):
    script = [ChatResponse(tool_calls=[ToolCall("search_context", FOLLOWUP, "followup-one")], done=True),
              OllamaError("unexpected end of json input"),
              ChatResponse(content_parts=["Checked."], done=True)]
    core, provider, _, _, _ = make_core(script=script)
    monkeypatch.setattr(core, "_recover_from_window_overflow", lambda: True)
    core.run_turn("What is the release deployment approval?")
    assert len(provider.calls) == 3
    assert [call["rounds"] for call in provider.calls] == [1, 2, 2]
    assert core.adaptive_retrieval.allowance.rounds == 2
    for call in provider.calls:
        assert_receipted_packet(call, wire_text(call, False))
    assert_not_persisted(core)


@pytest.mark.parametrize("native", [False, True])
def test_quoted_host_delimiter_does_not_change_receipted_memory_bytes(make_core, isolated_app_dir, native):
    core, provider, saved, source, _ = make_core(native=native)
    content = MEMORY + " Literal example: </locus-memory-reference>."
    with CanonicalMemoryVault(isolated_app_dir, workspace=core.workspace_root) as vault:
        vault.save({"content": content}, saved["id"])
    source.write_text("# Release deployment\n" + WORKSPACE + "\nLiteral example: </locus-memory-reference>.\n")
    KnowledgeStore(core.workspace_root).reindex()
    core.run_turn("What is the release deployment approval?")
    wire = wire_text(provider.calls[0], native)
    assert_receipted_packet(provider.calls[0], wire)
    assert content in wire and source.read_text() in wire


def test_native_search_memory_alias_keeps_explicit_personal_scope(make_core, isolated_app_dir):
    core, provider, saved, _, _ = make_core(native=True, followup=True)
    personal = "PERSONAL-BODY-CANARY: release deployment approval uses green."
    with CanonicalMemoryVault(isolated_app_dir, workspace=core.workspace_root) as vault:
        approved = vault.save({"title": "Personal release approval", "content": personal,
                               "scope": "personal", "kind": "fact"})
    provider.tool_name = "search_memory"
    provider.tool_arguments = {**FOLLOWUP, "scopes": ["personal"]}
    core.run_turn("What is the release deployment approval?")
    initial, followup = provider.calls[0], provider.tool_results[0]
    assert {item["id"] for item in initial["details"]["items"]} == {saved["id"], approved["id"]}
    assert {item["id"] for item in followup["details"]["items"]} == {approved["id"]}
    assert_receipted_packet(followup, followup["result"])
    assert personal in followup["result"] and MEMORY not in followup["result"]
    assert personal not in core.session.path.read_text()


@pytest.mark.parametrize("native", [False, True])
def test_cancel_during_automatic_retrieval_is_not_cleared_by_provider_loop(make_core, monkeypatch, native):
    from ollama_code import adaptive_retrieval
    core, provider, _, _, events = make_core(native=native)
    initial = adaptive_retrieval.begin_turn
    def cancelled(*args, **kwargs):
        initial(*args, **kwargs)
        core._interrupt.set()
    monkeypatch.setattr(adaptive_retrieval, "begin_turn", cancelled)
    core.run_turn("release deployments")
    assert not provider.calls
    assert any(event.get("type") == "turn_done" and event.get("reason") == "interrupted" for event in events)
