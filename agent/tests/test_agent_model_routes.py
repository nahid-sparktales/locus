"""Exercise account/model routing at durable admission and actual provider turns."""
import asyncio
import threading
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from test_chatgpt_app_server import FakeManagedRuntime, _managed_core

from ollama_code.agent_chat_routes import validate_chat_route
from ollama_code.agent_model_routes import (
    clean_task_choices,
    freeze_task_choices,
    normalize_runtime_choices,
    provider_route,
    run_with_model_fallback,
    trusted_task_choices,
)
from ollama_code.api.runs import run_queue
from ollama_code.api.runtime import agent_profiles_update
from ollama_code.codex_app_server import CodexAppServerError
from ollama_code.orchestration import AgentProfile, OrchestrationBudget, TeamOrchestrator
from ollama_code.runstore import RunStore
from ollama_code.runtime import RuntimeSupervisor
from ollama_code.runtime_automation import RuntimeAutomation
from ollama_code.sessions import SessionMeta, SessionStore


def provider(model, account=None, kind="chatgpt"):
    return {"provider": kind, "model": model, **({"account_id": account} if account else {})}


@pytest.fixture
def pool(tmp_path, monkeypatch):
    service = SimpleNamespace(run_store=RunStore(tmp_path / "runs.sqlite3"))
    app = SimpleNamespace(state=SimpleNamespace(service=service))
    runtime = RuntimeSupervisor(app, tmp_path / "private", port=1)
    app.state.runtime = runtime
    runtime.store.save_worker("chat", str(tmp_path), keep_running=True)
    primary = provider("first", str(uuid.uuid4()))
    extra = provider("second", str(uuid.uuid4()))
    profile = {"id": str(uuid.uuid4()), "name": "Writer", "model": "first", "role": "generalist",
               "access_ceiling": "read_only", "model_choices": [
                   {"route": {"kind": "account", "accountID": extra["account_id"]}, "model": "second"}]}
    envelope = {"profile": profile, "provider": primary, "model_choices": [
        {"model": item["model"], "provider": item} for item in [primary, extra]]}
    agent_profiles_update(SimpleNamespace(app=app), {"profiles": [envelope]})
    monkeypatch.setenv("LOCUS_RUNTIME_PROFILE_ROOT", str(runtime.root))
    monkeypatch.setattr(SessionMeta, "get", lambda _: {"agent_profile_id": profile["id"]})
    return runtime, profile, [primary, extra]


def test_queued_pool_is_frozen_without_secrets_and_revocation_removes_only_that_route(pool):
    runtime, profile, providers = pool
    snapshots = [provider_route(item) for item in providers]
    run = run_queue(runtime.service, {"session_id": "chat", "run_id": "frozen", "request": "write code",
        "workspace_root": "/tmp", "agent_chat_route": {"profile_id": profile["id"], **snapshots[0]},
        "agent_model_choices": snapshots})
    frozen = runtime.private.read()["agent-model-task:frozen"]
    assert set(frozen) == {"profile_id", "choices", "created_at"}
    assert "providers" not in frozen
    # A later profile edit cannot change the authorized task's models/order.
    runtime.private.set("agent-profiles", {profile["id"]: {
        "profile": {**profile, "model": "edited"}, "provider": provider("edited", kind="ollama")}})
    assert [item["model"] for item in trusted_task_choices(profile["id"], snapshots, run["id"])] == ["first", "second"]
    runtime.private.set("account:" + providers[0]["account_id"], None)
    runtime.ensure_worker = AsyncMock()
    commands = []
    runtime.enqueue = lambda _, command: commands.append(command)
    asyncio.run(RuntimeAutomation(runtime).queue_run(run))
    assert len(commands) == 1
    assert commands[0]["agent_model_choices"] == snapshots
    selected = commands[0]["runtime_configuration"]["/api/provider"]
    assert selected["account_id"] == providers[1]["account_id"]
    assert selected["model"] == "second"
    assert trusted_task_choices(profile["id"], commands[0]["agent_model_choices"], run["id"]) == [selected]
    runtime.private.set("account:" + providers[1]["account_id"], None)
    assert trusted_task_choices(profile["id"], snapshots, run["id"]) == []
    assert "agent_model_choices" in run["manifest"]


def test_snapshot_rejects_unassigned_route_and_changed_order(pool):
    _, profile, providers = pool
    snapshots = [provider_route(item) for item in providers]
    freeze_task_choices(profile["id"], snapshots, "frozen")
    with pytest.raises(ValueError, match="snapshot changed"):
        freeze_task_choices(profile["id"], snapshots[::-1], "frozen")
    with pytest.raises(ValueError, match="not assigned"):
        freeze_task_choices(profile["id"], [provider_route(provider("invented", kind="ollama"))], "new")


def test_frozen_references_are_cleaned_when_terminal_or_orphaned(pool):
    runtime, profile, providers = pool
    snapshot = [provider_route(providers[0])]
    freeze_task_choices(profile["id"], snapshot, "orphan")
    freeze_task_choices(profile["id"], snapshot, "done")
    runs = SimpleNamespace(run=lambda run_id: {"state": "completed"} if run_id == "done" else None)
    clean_task_choices(runtime.private, runs, now=0)
    assert "agent-model-task:done" not in runtime.private.read()
    assert "agent-model-task:orphan" in runtime.private.read()
    clean_task_choices(runtime.private, runs, now=10**12)
    assert "agent-model-task:orphan" not in runtime.private.read()


def test_unavailable_preferred_model_allows_assigned_extra(pool):
    runtime, profile, providers = pool
    entry = runtime.private.read()["agent-profiles"][profile["id"]]
    entry["unavailable"] = "Primary account removed"
    entry.pop("provider")
    entry["model_choices"][0] = {"model": "first", "unavailable": "Primary account removed"}
    normalized = normalize_runtime_choices(entry)
    agent_profiles_update(SimpleNamespace(app=runtime.app), {"profiles": [normalized]})
    assert trusted_task_choices(profile["id"], [provider_route(providers[1])]) == [providers[1]]


@pytest.mark.parametrize("bad", [[], {}, None, 42])
def test_malformed_route_provider_returns_validation_error(bad):
    with pytest.raises(ValueError):
        validate_chat_route({"provider": bad, "model": "model"})


class RejectedManagedRuntime(FakeManagedRuntime):
    def __init__(self, error="401 not authenticated", event=None):
        super().__init__()
        self.error, self.event = error, event

    def run_turn(self, *, text, event_handler, **kwargs):
        self.turn_texts.append(text)
        if self.event:
            event_handler(self.event)
        raise CodexAppServerError(self.error)


@pytest.mark.parametrize("error", ["401 not authenticated", "404 model not found", "429 usage limit exceeded"])
def test_real_managed_initial_failure_uses_next_model_once(tmp_path, error):
    first = RejectedManagedRuntime(error)
    second = FakeManagedRuntime(answer="Recovered answer")
    core = _managed_core(tmp_path, first)
    account = str(uuid.uuid4())
    core.use_chatgpt(account_label="Account", account_id=account, model="gpt-test", manager=first)
    choices = [provider("gpt-test", account), provider("alternate", account)]
    events, applied = [], []
    core.on_event(events.append)
    runs = RunStore(tmp_path / "outcomes.sqlite3")
    def apply(selected):
        applied.append(selected)
        core.use_chatgpt(account_label="Account", account_id=selected["account_id"], model=selected["model"], manager=second)
    service = SimpleNamespace(core=core, run_store=runs)
    run_with_model_fallback(service, choices, "write code", None, apply_route=apply, allow_tools=False)
    assert len(first.turn_texts) == len(second.turn_texts) == 1
    assert len(applied) == 1
    assert core.last_turn_result["reason"] == "complete"
    assert core.last_turn_result["model_calls"] == 2
    assert len([event for event in events if event["type"] == "turn_done"]) == 1
    assert not [event for event in events if event["type"] == "error"]
    assert len([m for m in core.messages if m.get("role") == "user"]) == 1
    transcript = SessionStore.load(core.session.path)
    assert len([m for m in transcript if m.get("role") == "user"]) == 1
    saved = SessionMeta.get(core.session.session_id)
    assert saved["model"] == "alternate" and saved["model_route_selection"] == "automatic"
    # Outcome identities match the native selector and remain model-specific.
    first_sample = runs.routing_samples("model-route:" + account + ":gpt-test", ["coding"])
    next_sample = runs.routing_samples("model-route:" + account + ":alternate", ["coding"])
    assert len(first_sample) == len(next_sample) == 1
    assert not first_sample[0]["reliable"] and next_sample[0]["reliable"]
    core.close()


@pytest.mark.parametrize("event", [
    {"method": "item/reasoning/summaryTextDelta", "params": {"delta": "Working"}},
    {"method": "item/agentMessage/delta", "params": {"delta": "Answer started"}},
    {"method": "item/started", "params": {"item": {"id": "hosted-action", "type": "webSearch"}}},
])
def test_real_managed_progress_prevents_fallback(tmp_path, event):
    runtime = RejectedManagedRuntime(event=event)
    core = _managed_core(tmp_path, runtime)
    account = str(uuid.uuid4())
    core.use_chatgpt(account_label="Account", account_id=account, model="gpt-test", manager=runtime)
    attempts = []
    run_with_model_fallback(SimpleNamespace(core=core),
        [provider("gpt-test", account), provider("other", account)], "inspect", None,
        apply_route=attempts.append, allow_tools=False)
    assert attempts == []
    assert core.last_turn_result["reason"] == "error"
    core.close()


def test_same_model_different_account_applies_selected_identity(tmp_path):
    core = _managed_core(tmp_path, FakeManagedRuntime())
    old, new = str(uuid.uuid4()), str(uuid.uuid4())
    core.use_chatgpt(account_label="Account", account_id=old, model="gpt-test", manager=FakeManagedRuntime())
    applied = []
    def apply(selected):
        applied.append(selected["account_id"])
        core.use_chatgpt(account_label="Account", account_id=selected["account_id"], model=selected["model"], manager=FakeManagedRuntime())
    run_with_model_fallback(SimpleNamespace(core=core), [provider("gpt-test", new)], "question", None,
                            apply_route=apply, allow_tools=False)
    assert applied == [new]
    assert SessionMeta.get(core.session.session_id)["provider_account_id"] == new
    core.close()


@pytest.mark.parametrize("suppressed", [False, True])
def test_all_configuration_failures_replace_previous_success(suppressed):
    events = []
    core = SimpleNamespace(provider="ollama", model="previous", account_id="", messages=[],
        _event_handler=events.append, _suppress_turn_done=suppressed, _interrupt=threading.Event(),
        last_turn_result={"type": "turn_done", "reason": "complete", "model_calls": 42})
    core.on_event = lambda handler: setattr(core, "_event_handler", handler)
    def fail(_):
        raise RuntimeError("provider unavailable")
    run_with_model_fallback(SimpleNamespace(core=core), [provider("a", kind="ollama"), provider("b", kind="ollama")],
                            "new task", None, apply_route=fail)
    assert core.last_turn_result["reason"] == "error"
    assert core.last_turn_result["model_calls"] == 0
    assert len([item for item in events if item["type"] == "turn_done"]) == (0 if suppressed else 1)


def test_team_unavailable_helper_can_fallback_but_budget_failure_cannot(pool, monkeypatch):
    runtime, profile, providers = pool
    import ollama_code.orchestration as orchestration
    from ollama_code.ollama import ChatResponse
    # The first client construction really fails, before a request exists.
    monkeypatch.setattr(orchestration, "_TEAM_CODEX_BROKER", None)
    local = provider("local", kind="ollama")
    snapshots = [provider_route(providers[0]), provider_route(local)]
    monkeypatch.setattr("ollama_code.agent_model_routes.trusted_task_choices", lambda *args: [providers[0], local])
    monkeypatch.setattr("ollama_code.agent_model_routes.rank_task_choices", lambda choices, *args: choices)
    monkeypatch.setattr("ollama_code.model_usage.tracked_chat", lambda *args, **kwargs: ChatResponse(content_parts=["answer"], done=True))
    selected = AgentProfile.parse({**profile, "route": providers[0], "agent_model_choices": snapshots})
    runner = TeamOrchestrator(lambda _: None, lambda: False)
    result = runner._raw_call("run", selected, [{"role": "user", "content": "write"}], OrchestrationBudget())
    assert result.content == "answer"
    assert runner._call_count == 2
    with pytest.raises(orchestration.OrchestrationError, match="budget exhausted"):
        runner._raw_call("run", selected, [], OrchestrationBudget(max_model_calls=2))
    assert runner._call_count == 2


def test_ordinary_session_info_and_clone_keep_saved_route(tmp_path):
    from ollama_code.agent_chat_routes import remember_chat_route
    from ollama_code.api.sessions import session_detail, session_duplicate
    core = _managed_core(tmp_path, FakeManagedRuntime())
    account = str(uuid.uuid4())
    core.use_chatgpt(account_label="Original", account_id=account, model="original", manager=FakeManagedRuntime())
    core._add_message({"role": "user", "content": "existing conversation"})
    remember_chat_route(core)
    core.use_chatgpt(account_label="Global", account_id=str(uuid.uuid4()), model="global", manager=FakeManagedRuntime())
    expected = {"model": "original", "provider": "chatgpt", "provider_account_id": account,
                "model_route_selection": "manual", "route_established": True}
    assert {key: core.session_info()[key] for key in expected} == expected
    service = SimpleNamespace(core=core, busy=False, run_store=RunStore(tmp_path / "runs.sqlite3"))
    detail = session_detail(core.session.session_id)
    assert {key: detail[key] for key in expected} == expected
    copied = session_duplicate(core.session.session_id, service, {"mode": "conversation"})["session"]
    assert {key: copied[key] for key in expected} == expected
    core.close()


@pytest.mark.parametrize("reasoning", [False, True])
def test_real_classic_connection_error_falls_back_only_before_output(tmp_path, monkeypatch, reasoning):
    from ollama_code.core import AgentCore
    from ollama_code.knowledge import KnowledgeStore
    from ollama_code.ollama import ChatResponse, OllamaError
    KnowledgeStore(str(tmp_path)).configure(adaptive_rag_enabled=False)
    core = AgentCore(cwd=str(tmp_path), config={"model": "first"})
    calls = []
    def chat_stream(*args, **kwargs):
        calls.append(kwargs["model"])
        if kwargs["model"] == "first":
            if reasoning:
                kwargs["on_thinking"]("Started reasoning")
            raise OllamaError("connection refused")
        kwargs["on_token"]("Recovered")
        return ChatResponse(content_parts=["Recovered"], done=True)
    monkeypatch.setattr(core.client, "chat_stream", chat_stream)
    monkeypatch.setattr(core, "refresh_context_limit", lambda: None)
    def apply(choice):
        core.set_model(choice["model"])
    run_with_model_fallback(SimpleNamespace(core=core), [provider("first", kind="ollama"), provider("second", kind="ollama")],
                            "question", None, apply_route=apply, allow_tools=False)
    assert calls == (["first"] if reasoning else ["first", "second"])
    assert core.last_turn_result["reason"] == ("error" if reasoning else "complete")
    assert len([m for m in SessionStore.load(core.session.path) if m.get("role") == "user"]) == 1
    core.close()


def test_failure_consuming_remaining_call_budget_cannot_fallback():
    events, calls = [], []
    core = SimpleNamespace(provider="ollama", model="first", account_id="", messages=[],
        _event_handler=events.append, _suppress_turn_done=False, _interrupt=threading.Event())
    core.on_event = lambda handler: setattr(core, "_event_handler", handler)
    def fail(*args, **kwargs):
        from ollama_code.ollama import OllamaError
        calls.append(kwargs["model_call_limit"])
        core._initial_provider_error = OllamaError("connection refused")
        core.last_turn_result = {"type": "turn_done", "reason": "error", "model_calls": 2}
        core._event_handler(core.last_turn_result)
    core.run_turn = fail
    run_with_model_fallback(SimpleNamespace(core=core),
        [provider("first", kind="ollama"), provider("second", kind="ollama")],
        "task", None, model_call_limit=2)
    assert calls == [2]
    assert core.last_turn_result["model_calls"] == 2


def test_writer_route_installation_can_recover_missing_primary_helper(tmp_path, monkeypatch):
    import ollama_code.orchestration as orchestration
    from ollama_code.server import _install_writer_route, _restore_writer_route
    core = _managed_core(tmp_path, FakeManagedRuntime())
    primary = provider("primary", str(uuid.uuid4()))
    local = provider("local", kind="ollama")
    choices = [provider_route(primary), provider_route(local)]
    profile = AgentProfile.parse({"id": str(uuid.uuid4()), "name": "Writer", "model": "primary",
        "role": "implementer", "access_ceiling": "workspace_write", "route": primary,
        "agent_model_choices": choices})
    monkeypatch.setattr(orchestration, "_TEAM_CODEX_BROKER", None)
    monkeypatch.setattr("ollama_code.agent_model_routes.trusted_task_choices", lambda *args: [primary, local])
    prior = (core.provider, core.model)
    snapshot = _install_writer_route(core, profile)
    assert (core.provider, core.model) == ("ollama", "local")
    _restore_writer_route(core, snapshot)
    assert (core.provider, core.model) == prior
    core.close()


def test_writer_cannot_use_stale_route_when_all_assigned_accounts_are_revoked(monkeypatch):
    from contextlib import nullcontext

    from ollama_code.orchestration import OrchestrationError
    from ollama_code.server import _run_team_writer
    calls = []
    core = SimpleNamespace(total_prompt_tokens=0, total_completion_tokens=0,
                           run_turn=lambda *args, **kwargs: calls.append(args))
    writer = SimpleNamespace(id=str(uuid.uuid4()), name="Writer", role="implementer", model="old",
        route=provider("old", str(uuid.uuid4())), task_model_choices=({"provider": "ollama", "model": "assigned"},))
    prepared = SimpleNamespace(run_id="run", team=SimpleNamespace(budget=None))
    orchestrator = SimpleNamespace(remaining_model_calls=lambda _: 5, writer_slot=lambda *args: nullcontext())
    monkeypatch.setattr("ollama_code.agent_model_routes.trusted_task_choices", lambda *args: [])
    service = SimpleNamespace(core=core, emit=lambda _: None)
    with pytest.raises(OrchestrationError, match="Reconnect"):
        _run_team_writer(service, orchestrator, prepared, writer, "task", persisted_user_text="task",
                         job_id="writer", goal="task", model_call_limit=3)
    assert calls == []


@pytest.mark.parametrize("progress", ["", "text", "reasoning"])
def test_team_managed_failure_falls_back_only_without_returned_progress(pool, monkeypatch, progress):
    import ollama_code.orchestration as orchestration
    from ollama_code.ollama import ChatResponse, OllamaClient
    _, profile, providers = pool
    local = provider("local", kind="ollama")
    responses = []
    def complete(**kwargs):
        responses.append(kwargs)
        return {"turn": {"status": "failed", "error": {"message": "429 usage limit exceeded"}},
                **({progress: "Already started"} if progress else {})}
    monkeypatch.setattr(orchestration, "_TEAM_CODEX_BROKER", SimpleNamespace(complete=complete))
    monkeypatch.setattr("ollama_code.agent_model_routes.trusted_task_choices", lambda *args: [providers[0], local])
    monkeypatch.setattr("ollama_code.agent_model_routes.rank_task_choices", lambda choices, *args: choices)
    monkeypatch.setattr(OllamaClient, "chat_stream", lambda *args, **kwargs: ChatResponse(content_parts=["Recovered"], done=True))
    selected = AgentProfile.parse({**profile, "route": providers[0], "agent_model_choices": [
        provider_route(providers[0]), provider_route(local)]})
    runner = TeamOrchestrator(lambda _: None, lambda: False)
    if progress:
        with pytest.raises(CodexAppServerError, match="429"):
            runner._raw_call("run", selected, [], OrchestrationBudget())
        assert runner._call_count == 1
    else:
        assert runner._raw_call("run", selected, [], OrchestrationBudget()).content == "Recovered"
        assert runner._call_count == 2
    assert len(responses) == 1


def test_ordinary_queued_chat_uses_its_exact_account_after_defaults_change(pool, monkeypatch):
    runtime, _, providers = pool
    monkeypatch.setattr(SessionMeta, "get", lambda _: {})
    selected = {**provider_route(providers[0]), "model": "chat-original"}
    run = run_queue(runtime.service, {"session_id": "chat", "run_id": "ordinary", "request": "next task",
        "workspace_root": "/tmp", "chat_route": selected, "mode": "ask"})
    runtime.private.set("worker:chat", {"/api/provider": providers[1]})
    runtime.ensure_worker = AsyncMock()
    commands = []
    runtime.enqueue = lambda _, command: commands.append(command)
    asyncio.run(RuntimeAutomation(runtime).queue_run(run))
    assert commands[0]["chat_route"] == selected
    assert commands[0]["runtime_configuration"]["/api/provider"]["account_id"] == providers[0]["account_id"]
    assert commands[0]["runtime_configuration"]["/api/config"]["model"] == "chat-original"
    assert commands[0]["mode"] == "ask"
    assert "agent_profile" not in commands[0]
