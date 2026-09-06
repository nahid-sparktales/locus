from __future__ import annotations

import pytest
from fastapi import HTTPException

from ollama_code.api.event_triggers import trigger_target_create, trigger_task_create
from ollama_code.api.schedules import (
    _ensure_schedule_session,
    schedule_create,
    schedule_task_create,
)
from ollama_code.api.sessions import _agent_owning_chat
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.sessions import SessionMeta, SessionStore


def _schedule(tmp_path):
    return {
        "id": "shared-agent", "name": "Scheduled review", "prompt": "Review changes.",
        "workspace_root": str(tmp_path), "mode": "work", "execution_environment": "local",
        "runner": "solo", "provider": "ollama", "model": "test-model", "timezone": "UTC",
        "rule": {"kind": "daily", "hour": 9, "minute": 30},
    }


def _event(service, target_id):
    service.run_store.create_connector_connection({"id": "source", "kind": "gmail", "display_name": "Mail"})
    return service.run_store.create_event_trigger({
        "id": "shared-agent", "name": "Mail review", "connection_id": "source",
        "target_session_id": target_id, "instruction": "Summarize the event.", "mode": "work", "filters": {},
    })


@pytest.mark.parametrize("event_first", [False, True])
def test_same_id_agents_keep_separate_primary_and_side_chats(tmp_path, event_first):
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    template = SessionStore(str(tmp_path), "test-model")
    request = {"trigger_id": "shared-agent", "template_session_id": template.session_id, "name": "Mail review"}
    if not event_first:
        schedule = schedule_create(service, _schedule(tmp_path))
    event_chat = trigger_target_create(service, request)["session"]
    _event(service, event_chat["id"])
    if event_first:
        schedule = schedule_create(service, _schedule(tmp_path))
    schedule_chat_id, _ = _ensure_schedule_session(schedule)
    assert schedule_chat_id != event_chat["id"]
    assert event_chat["agent_kind"] == "event"
    assert SessionMeta.get(schedule_chat_id)["agent_kind"] == "schedule"
    assert trigger_target_create(service, request)["session"]["id"] == event_chat["id"]
    event_side = trigger_task_create("shared-agent", service, {})["session"]
    schedule_side = schedule_task_create("shared-agent", service, {})["session"]
    assert event_side["agent_kind"] == "event"
    assert schedule_side["agent_kind"] == "schedule"
    assert not event_side["agent_primary"] and not schedule_side["agent_primary"]
    assert _agent_owning_chat(service, event_chat["id"]) == "Mail review"
    assert _agent_owning_chat(service, schedule_chat_id) == "Scheduled review"
    service.run_store.delete_event_trigger("shared-agent")
    assert _agent_owning_chat(service, event_chat["id"]) is None
    assert _agent_owning_chat(service, schedule_chat_id) == "Scheduled review"


def test_ambiguous_untyped_primary_is_not_adopted_by_either_kind(tmp_path):
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    legacy = SessionStore(str(tmp_path), "test-model")
    SessionMeta.update(legacy.session_id, agent_trigger_id="shared-agent", agent_primary=True)
    schedule = service.run_store.create_schedule(_schedule(tmp_path))
    _event(service, "some-other-target")
    schedule_chat, _ = _ensure_schedule_session(schedule)
    event_chat = trigger_target_create(service, {
        "trigger_id": "shared-agent", "template_session_id": legacy.session_id, "name": "Mail review",
    })["session"]
    assert legacy.session_id not in {schedule_chat, event_chat["id"]}
    assert schedule_chat != event_chat["id"]
    assert SessionMeta.get(legacy.session_id).get("agent_kind") is None
    assert _agent_owning_chat(service, legacy.session_id) == "an agent"


def test_legacy_schedule_provenance_projects_kind_and_preserves_primary(tmp_path):
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    schedule = service.run_store.create_schedule(_schedule(tmp_path))
    legacy = SessionStore(str(tmp_path), "test-model")
    SessionMeta.update(legacy.session_id, agent_trigger_id="shared-agent", schedule_id="shared-agent", agent_primary=True)
    _event(service, "some-other-target")
    summary = next(row for row in SessionStore.summaries(limit=500) if row["id"] == legacy.session_id)
    assert summary["agent_kind"] == "schedule"
    recovered, metadata = _ensure_schedule_session(schedule)
    assert recovered == legacy.session_id
    assert metadata["agent_kind"] == "schedule"


def test_event_side_chat_cannot_borrow_a_schedule_target(tmp_path):
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    schedule = schedule_create(service, _schedule(tmp_path))
    primary, _ = _ensure_schedule_session(schedule)
    _event(service, primary)
    with pytest.raises(HTTPException) as refused:
        trigger_task_create("shared-agent", service, {})
    assert refused.value.status_code == 409
    assert SessionMeta.get(primary)["agent_kind"] == "schedule"
