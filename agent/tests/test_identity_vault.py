from __future__ import annotations

import asyncio
import copy
import json
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import pytest

from ollama_code import server
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.identity import context_sources, source_references
from ollama_code.ollama import OllamaClient, OllamaError, ToolCall
from ollama_code.remote import RemoteClient


@pytest.fixture
def core(tmp_path, monkeypatch):
    value = AgentCore(cwd=str(tmp_path), config={"model": "test-model", "auto_compact": False})
    value.messages = [value.system_message()]
    value.tool_registry.identity_enabled = True
    monkeypatch.setattr(value, "refresh_context_limit", lambda: None)
    monkeypatch.setattr(value, "check_context_spill", lambda: False)
    yield value
    value.close()


def test_identity_schema_is_native_gated_and_private_surface_is_exact(core):
    schema = next(item for item in core.tool_registry.schemas() if item["function"]["name"] == "identity_vault")
    assert schema["function"]["parameters"]["properties"]["action"]["enum"] == ["select"]
    core.enable_identity_mode()
    assert [item["function"]["name"] for item in core.tool_registry.schemas()] == ["identity_vault"]
    assert [item["function"]["name"] for item in core.tool_registry.parity_schemas()] == ["identity_vault"]
    assert [item["name"] for item in core.tool_registry.metadata()] == ["identity_vault"]
    assert core.solo_worker_tool_schemas() == []
    assert core.solo_worker_virtual_tools() == set()
    core.tool_registry.identity_enabled = False
    assert core.tool_registry.schemas() == []


@pytest.mark.parametrize("name", ["bash", "read_file", "browser_javascript", "browser_read_page",
                                 "browser_autofill", "computer_input", "delegate_read_only",
                                 "search_extension_tools", "search_workspace_knowledge", "background_service"])
def test_identity_dispatch_denies_guessed_tools_even_bypass(core, name):
    core.enable_identity_mode()
    core.perms.mode = "bypass"
    events = []
    core.on_event(events.append)
    assert "only the native Identity Vault" in core._run_tool_call(ToolCall(name, {"secret": "never log"}), None)
    assert events == []


def test_ordinary_task_cannot_materialize_identity_sources(core):
    called = []
    core.identity_executor = lambda *args: called.append(args) or "Selected"
    assert core._run_tool_call(ToolCall("identity_vault", {"action": "request_context"}), None).startswith("Error:")
    assert not called
    assert core._run_tool_call(ToolCall("identity_vault", {"action": "select"}), None) == "Selected"


def test_identity_activation_needs_empty_task_and_cannot_be_undone_by_argument(core):
    core._add_message({"role": "user", "content": "ordinary history"})
    with pytest.raises(ValueError, match="dedicated"):
        core.enable_identity_mode()


def test_native_task_creation_persists_private_mode_before_the_first_message(core):
    from ollama_code.api.sessions import session_new
    from ollama_code.sessions import SessionMeta

    result = session_new(ChatService(core), {"identity_mode": True, "environment": "local"})
    assert result["session_info"]["identity_mode"] is True
    assert core.identity_mode
    assert SessionMeta.get(core.session.session_id)["identity_mode"] is True
    assert core.messages == [core.system_message()]


def test_sources_exist_only_in_ephemeral_request_copy_and_renew_each_request(core):
    core.enable_identity_mode()
    core.identity_source_refs = ["source-1"]
    core._add_message({"role": "user", "content": "Draft a resume"})
    original = copy.deepcopy(core.messages)
    calls = []
    def resolve(refs):
        calls.append(refs)
        return [{"reference": "source-1", "text": "PRIVATE_SOURCE_MARKER"}]
    core.identity_context_executor = resolve
    for _ in range(2):
        request = core._request_messages()
        assert "PRIVATE_SOURCE_MARKER" in json.dumps(request)
        assert all("identity_mode" not in item for item in request)
    assert calls == [["source-1"], ["source-1"]]
    assert core.messages == original
    assert "PRIVATE_SOURCE_MARKER" not in core.session.path.read_text()


def test_context_requires_native_broker_even_with_zero_sources(core):
    core.enable_identity_mode()
    with pytest.raises(OllamaError, match="approval broker"):
        core._request_messages()
    calls = []
    core.identity_context_executor = lambda refs: calls.append(refs) or []
    core._request_messages()
    assert calls == [[]]


def test_restore_retains_only_opaque_refs_and_renews_native_epoch(core):
    core.enable_identity_mode()
    core.identity_source_refs = ["ref-safe-1"]
    core._add_message({"role": "user", "content": "Create the draft"})
    session_id = core.session.session_id
    epoch = core.identity_context_epoch
    core.resume_session(session_id)
    assert core.identity_mode is True
    assert core.identity_source_refs == ["ref-safe-1"]
    assert core.identity_context_epoch != epoch
    assert core.session_info()["identity_mode"] is True
    core.start_new_session()
    assert core.identity_mode is False
    assert core.identity_source_refs == []


def test_native_tool_args_are_omitted_from_plaintext_transcript_and_events(core):
    core.enable_identity_mode()
    events = []
    core.on_event(events.append)
    core.identity_executor = lambda *args: "Draft saved."
    args = {"action": "save_draft", "sections": [{"heading": "Experience", "text": "SOURCE_FRAGMENT"}]}
    core._add_message({"role": "assistant", "content": "Preparing your draft.", "tool_calls": [{
        "id": "call", "type": "function", "function": {"name": "identity_vault", "arguments": args},
    }]})
    assert core._run_tool_call(ToolCall("identity_vault", args), None) == "Draft saved."
    assert "SOURCE_FRAGMENT" not in core.session.path.read_text()
    assert "SOURCE_FRAGMENT" not in json.dumps(events)
    assert "Preparing your draft." in core.session.path.read_text()


def test_bridge_uses_actual_route_and_never_emits_context_results(core, monkeypatch):
    core.enable_identity_mode()
    service = ChatService(core)
    events = []
    def emit(event):
        events.append(event)
        if event["type"] == "identity_action_request":
            service.answer_identity(event["request_id"], {"text": "Selected source.", "source_refs": ["ref-1"]})
        elif event["type"] == "identity_context_request":
            service.answer_identity(event["request_id"], {"sources": [{"reference": "ref-1", "text": "EPHEMERAL_SECRET"}]}, context=True)
    monkeypatch.setattr(service, "emit", emit)
    assert service.execute_identity("identity_vault", {"action": "request_context", "provider": "forged"}, "action") == "Selected source."
    assert core.identity_source_refs == ["ref-1"]
    assert service.resolve_identity_context(["ref-1"])[0]["text"] == "EPHEMERAL_SECRET"
    assert all(item["provider"] == "ollama" for item in events)
    assert all(item["session_id"] == core.session.session_id for item in events)
    assert all(item["endpoint"] == core.host for item in events)
    assert "EPHEMERAL_SECRET" not in json.dumps(events)
    assert service.pending_identity_context == {}
    assert service.answer_identity("missing", {"sources": []}, context=True) is False
    service.close_codex()


def test_pending_review_is_cancelled_explicitly_and_late_reply_ignored(core, monkeypatch):
    core.enable_identity_mode()
    service = ChatService(core)
    waiting = Event()
    monkeypatch.setattr(service, "emit", lambda event: waiting.set())
    with ThreadPoolExecutor(max_workers=1) as pool:
        result = pool.submit(service.execute_identity, "identity_vault", {"action": "select"}, "waiting")
        assert waiting.wait(2)
        assert not result.done()
        service.cancel_all_identity()
        assert result.result(timeout=2).startswith("Error:")
    assert service.answer_identity("waiting", {"text": "late"}) is False
    service.close_codex()


def test_source_validation_rejects_missing_duplicate_or_unapproved_refs():
    assert source_references(["one", "one"]) == ["one"]
    with pytest.raises(ValueError):
        source_references(["not an opaque reference"])
    for result in ({"sources": []}, {"sources": [{"reference": "other", "text": "private"}]},
                   {"error": "private details"},
                   {"sources": [{"reference": "one", "text": "a"}, {"reference": "one", "text": "b"}]}):
        with pytest.raises(ValueError) as failure:
            context_sources(result, ["one"])
        assert "private details" not in str(failure.value)


def test_managed_provider_fails_before_retaining_or_sending_private_source(core):
    core.enable_identity_mode()
    core.provider = "chatgpt"
    events = []
    core.on_event(events.append)
    core.run_turn("Draft a resume")
    assert any(item.get("reason") == "error" for item in events)
    assert core.messages == [core.system_message()]


@pytest.mark.parametrize("kind", ["ollama", "remote"])
def test_private_provider_client_does_not_automatically_retry(kind, monkeypatch):
    client = OllamaClient() if kind == "ollama" else RemoteClient("https://example.invalid/v1", api_key="test")
    client.identity_private_request = True
    calls = []
    def fail(*args):
        calls.append(args)
        raise OllamaError("think tool function unsupported")
    monkeypatch.setattr(client, "_stream", fail)
    with pytest.raises(OllamaError):
        client.chat_stream("test", [{"role": "user", "content": "source"}], tools=[{"type": "function", "function": {"name": "identity_vault"}}])
    assert len(calls) == 1


def test_server_sets_private_mode_before_ambient_recall_or_delegation(core, monkeypatch):
    core.enable_identity_mode()
    service = ChatService(core)
    monkeypatch.setattr(server, "_automatic_memory_context", lambda *args, **kwargs: pytest.fail("memory recall"))
    monkeypatch.setattr(server, "_automatic_continuity_context", lambda *args, **kwargs: pytest.fail("continuity recall"))
    monkeypatch.setattr(server, "_capture_continuity_snapshot", lambda *args, **kwargs: pytest.fail("private snapshot"))
    monkeypatch.setattr(server, "SoloSwarmExecutor", lambda *args, **kwargs: pytest.fail("private delegation"))
    monkeypatch.setattr(core, "run_turn", lambda *args, **kwargs: None)
    server._run_user_turn(service, "Draft resume", False)
    service.close_codex()


def test_native_context_reply_is_not_queued_as_an_event(core, monkeypatch):
    service = ChatService(core)
    seen = []
    monkeypatch.setattr(service, "queue_event", lambda event: pytest.fail("raw context emitted"))
    monkeypatch.setattr(service, "answer_identity", lambda request_id, result, context=False: seen.append((request_id, result, context)))
    asyncio.run(server._handle_client_message(service, {"type": "identity_context_result", "request_id": "native", "result": {"sources": [{"reference": "one", "text": "PRIVATE"}]}}))
    assert seen == [("native", {"sources": [{"reference": "one", "text": "PRIVATE"}]}, True)]
    service.close_codex()
