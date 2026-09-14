import asyncio
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from ollama_code.api.runs import run_queue
from ollama_code.runstore import RunStore
from ollama_code.runtime import RuntimeSupervisor
from ollama_code.runtime_automation import RuntimeAutomation
from ollama_code.sessions import SessionMeta


@pytest.fixture
def chat_runtime(tmp_path, monkeypatch):
    service = SimpleNamespace(run_store=RunStore(tmp_path / "runs.sqlite3"))
    app = SimpleNamespace(state=SimpleNamespace(service=service))
    runtime = RuntimeSupervisor(app, tmp_path / "private", port=1)
    runtime.store.save_worker("chat", str(tmp_path), keep_running=True)
    profile = {"id": str(uuid.uuid4()), "name": "Researcher", "model": "default-model",
               "role": "generalist", "instructions": "Read the project", "access_ceiling": "read_only"}
    runtime.private.set("agent-profiles", {profile["id"]: {
        "profile": profile, "provider": {"provider": "ollama"},
    }})
    metadata = {"agent_profile_id": profile["id"], "agent_world_profile_id": profile["id"]}
    monkeypatch.setattr(SessionMeta, "get", lambda _: metadata)
    return runtime, profile, metadata


def queue_selected(runtime, profile, *, provider="ollama", account_id=None, **fields):
    route = {"profile_id": profile["id"], "provider": provider, "model": "selected-model"}
    if account_id is not None:
        route["provider_account_id"] = account_id
    return run_queue(runtime.service, {"session_id": "chat", "run_id": uuid.uuid4().hex,
        "request": "Help with this question", "workspace_root": "/tmp", "mode": "ask",
        "agent_chat_route": route, **fields})


def queued_command(runtime, run):
    runtime.ensure_worker = AsyncMock()
    commands = []
    runtime.enqueue = lambda session_id, command: commands.append(command)
    asyncio.run(RuntimeAutomation(runtime).queue_run(run))
    return commands


@pytest.mark.parametrize("provider", ["ollama", "chatgpt"])
@pytest.mark.parametrize("default_unavailable", [False, True])
def test_saved_chat_route_survives_runtime_restart(chat_runtime, provider, default_unavailable):
    runtime, profile, _ = chat_runtime
    if default_unavailable:
        runtime.private.set("agent-profiles", {profile["id"]: {"profile": profile, "unavailable": "Default account removed"}})
    account_id = str(uuid.uuid4()).upper() if provider != "ollama" else None
    if account_id:
        runtime.private.set(f"account:{account_id}", {"provider": provider, "account_id": account_id,
                                                   "model": "account-default", "api_key": "private-credential"})
    run = queue_selected(runtime, profile, provider=provider, account_id=account_id)
    assert set(run["manifest"]["agent_chat_route"]) <= {"profile_id", "provider", "provider_account_id", "model"}
    assert "private-credential" not in str(run)
    # Read both the queued snapshot and credentials from disk in a new runtime.
    restarted = RuntimeSupervisor(runtime.app, runtime.root, port=1)
    restored = restarted.service.run_store.run(run["id"])
    commands = queued_command(restarted, restored)
    assert len(commands) == 1
    command = commands[0]
    assert command["mode"] == "ask"
    assert command["agent_profile"] == {**profile, "model": "selected-model"}
    route = command["runtime_configuration"]["/api/provider"]
    assert route["provider"] == provider
    assert route["model"] == "selected-model"
    assert command["runtime_configuration"]["/api/config"] == {"model": "selected-model"}
    assert restarted.private.read()["agent-profiles"][profile["id"]]["profile"]["model"] == "default-model"


@pytest.mark.parametrize("available_provider", [None, "remote"])
def test_runtime_never_falls_back_from_selected_account(chat_runtime, available_provider):
    runtime, profile, _ = chat_runtime
    account_id = str(uuid.uuid4())
    if available_provider:
        runtime.private.set(f"account:{account_id}", {"provider": available_provider, "model": "other-model"})
    run = queue_selected(runtime, profile, provider="chatgpt", account_id=account_id)
    assert queued_command(runtime, run) == []
    assert runtime.store.worker("chat")["state"] == "waiting_for_account"


def test_saved_agent_goal_uses_its_original_execution_route(chat_runtime):
    runtime, profile, _ = chat_runtime
    account_id = str(uuid.uuid4())
    runtime.private.set(f"account:{account_id}", {"provider": "chatgpt", "model": "account-default"})
    run = {"id": "goal-run", "session_id": "chat", "workspace_root": "/tmp", "request": "Continue",
           "manifest": {"goal_id": "goal", "conversation_profile_id": profile["id"],
                        "provider": "chatgpt", "provider_account_id": account_id, "model": "goal-model"}}
    command = queued_command(runtime, run)[0]
    assert command["agent_profile"]["model"] == "goal-model"
    assert command["runtime_configuration"]["/api/provider"]["provider"] == "chatgpt"


def test_selected_local_model_preserves_its_provisioned_host_and_context(chat_runtime):
    runtime, profile, _ = chat_runtime
    runtime.private.set("account:local", {"provider": "ollama", "host": "http://192.168.1.50:11434",
                                        "context_window": 32768, "model": "previous-local-model"})
    run = queue_selected(runtime, profile)
    command = queued_command(runtime, run)[0]
    assert command["runtime_configuration"]["/api/provider"] == {
        "provider": "ollama", "host": "http://192.168.1.50:11434",
        "context_window": 32768, "model": "selected-model",
    }


def test_selected_route_waits_if_saved_profile_was_removed(chat_runtime):
    runtime, profile, _ = chat_runtime
    run = queue_selected(runtime, profile)
    runtime.private.set("agent-profiles", {})
    assert queued_command(runtime, run) == []
    assert runtime.store.worker("chat")["state"] == "waiting_for_locus"


@pytest.mark.parametrize("malformed", [None, {}, {"profile": None}, {"profile": []}, {"profile": {}}])
def test_selected_route_waits_if_saved_profile_is_malformed(chat_runtime, malformed):
    runtime, profile, _ = chat_runtime
    run = queue_selected(runtime, profile)
    runtime.private.set("agent-profiles", {profile["id"]: malformed})
    assert queued_command(runtime, run) == []
    assert runtime.store.worker("chat")["state"] == "waiting_for_locus"


def test_automation_cannot_use_a_chat_override(chat_runtime):
    runtime, profile, metadata = chat_runtime
    metadata["agent_primary"] = True
    with pytest.raises(HTTPException) as error:
        queue_selected(runtime, profile)
    assert error.value.status_code == 422
    metadata["agent_primary"] = False
    run = queue_selected(runtime, profile)
    run["manifest"]["schedule_id"] = "scheduled-task"
    assert queued_command(runtime, run) == []
    assert runtime.store.worker("chat")["state"] == "waiting_for_locus"


@pytest.mark.parametrize("invalid", [
    {"profile_id": str(uuid.uuid4())}, {"provider": []}, {"model": ""},
    {"api_key": "must-not-persist"}, {"provider": "remote"},
])
def test_invalid_or_foreign_route_is_not_persisted(chat_runtime, invalid):
    runtime, profile, _ = chat_runtime
    route = {"profile_id": profile["id"], "provider": "ollama", "model": "chosen", **invalid}
    with pytest.raises(HTTPException) as error:
        queue_selected(runtime, profile, agent_chat_route=route)
    assert error.value.status_code == 422
    assert runtime.service.run_store.list_runs() == []
