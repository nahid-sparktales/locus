from __future__ import annotations

import sqlite3
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from ollama_code.api import event_triggers as event_api
from ollama_code.api import schedules as schedule_api
from ollama_code.runstore import RunStore, RunStoreError


def seeded_store(tmp_path):
    store = RunStore(tmp_path / "runs.sqlite3")
    store.create_connector_connection({"id": "source", "kind": "gmail", "display_name": "Mail"})
    for agent in ["quiet", "busy"]:
        store.create_event_trigger({
            "id": agent, "name": agent, "connection_id": "source",
            "target_session_id": "chat-" + agent, "instruction": "Summarize", "mode": "work",
            "filters": {"subject_contains": [agent]},
        })
    return store


def ingest(store, number, agent="quiet"):
    return store.ingest_event("source", {
        "source_event_id": f"{agent}-{number}", "event_type": "message",
        "subject": agent, "text": "A message", "occurred_at": 1_800_000_000,
    })[0]


def test_agent_history_is_scoped_before_pagination_with_stable_ties(tmp_path):
    store = seeded_store(tmp_path)
    quiet = [ingest(store, n) for n in range(5)]
    # A busy peer must not push the quiet agent's history out of the window.
    for n in range(210):
        delivery = ingest(store, n, "busy")
        store.finish_event_dispatch(delivery["id"], state="completed")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE event_deliveries SET received_at=10, created_at=10 WHERE trigger_id='quiet'")
    seen, cursor = [], ""
    while True:
        page = store.agent_history_page("event", "quiet", cursor=cursor, limit=2)
        assert page["total"] == 5
        assert page["counts"] == {"pending": 5}
        seen.extend(item["id"] for item in page["deliveries"])
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert len(seen) == len(set(seen)) == 5
    assert set(seen) == {item["id"] for item in quiet}
    assert store.agent_history_page("event", "empty")["total"] == 0


def test_history_cursor_cannot_be_reused_for_another_agent(tmp_path):
    store = seeded_store(tmp_path)
    ingest(store, 1)
    ingest(store, 2)
    cursor = store.agent_history_page("event", "quiet", limit=1)["next_cursor"]
    with pytest.raises(ValueError, match="cursor"):
        store.agent_history_page("event", "busy", cursor=cursor)
    with pytest.raises(ValueError, match="cursor"):
        store.agent_history_page("event", "quiet", cursor="not-a-cursor")


def test_history_counts_running_completed_cancelled_and_waiting_separately(tmp_path):
    store = seeded_store(tmp_path)
    for number, state in enumerate(["running", "completed", "cancelled", "waiting_permission"]):
        item = ingest(store, number)
        run_id = f"run-{number}"
        store.queue_run(run_id, session_id="chat-quiet")
        store.set_state(run_id, state)
        store.finish_event_dispatch(item["id"], state="queued", run_id=run_id)
    page = store.agent_history_page("event", "quiet")
    assert page["total"] == 4
    assert page["counts"] == {"running": 1, "completed": 1, "cancelled": 1, "waiting_permission": 1}
    assert {item["state"] for item in page["deliveries"]} == set(page["counts"])


def test_retry_links_survive_pointer_reset_relaunch_and_generic_retry(tmp_path):
    store = seeded_store(tmp_path)
    item = ingest(store, 1)
    _, _, first = store.claim_event_delivery(item["id"])
    store.queue_run(first, session_id="chat-quiet")
    store.set_state(first, "failed")
    store.finish_event_dispatch(item["id"], state="failed", run_id=first)
    store.retry_event_delivery(item["id"])
    assert store.event_delivery(item["id"])["run_id"] is None
    assert [link["run_id"] for link in store.inspector_execution_links("event", item["id"])] == [first]
    _, _, second = store.claim_event_delivery(item["id"])
    store.queue_run(second, session_id="chat-quiet")
    store.finish_event_dispatch(item["id"], state="queued", run_id=second)
    store.set_state(second, "failed")
    store.queue_run("third", session_id="chat-quiet", retry_parent_id=second)
    store = RunStore(store.path)
    links = store.inspector_execution_links("event", item["id"])
    assert [link["run_id"] for link in links] == [first, second, "third"]
    assert [link["attempt"] for link in links] == [0, 1, 2]


def test_get_by_id_is_not_limited_to_the_first_history_page(tmp_path, monkeypatch):
    store = seeded_store(tmp_path)
    item = ingest(store, "old")
    monkeypatch.setattr(event_api, "_require_capability", lambda: None)
    monkeypatch.setattr(schedule_api, "_require_capability", lambda _: None)
    detail = event_api.delivery_detail(item["id"], SimpleNamespace(run_store=store))
    assert detail["delivery"]["id"] == item["id"]
    assert detail["executions"] == []
    with pytest.raises(HTTPException) as missing:
        event_api.delivery_detail("missing", SimpleNamespace(run_store=store))
    assert missing.value.status_code == 404
    with pytest.raises(HTTPException) as missing:
        schedule_api.occurrence_detail("missing", SimpleNamespace(run_store=store))
    assert missing.value.status_code == 404


def test_schema_upgrade_backfills_current_and_historical_provenance(tmp_path):
    store = seeded_store(tmp_path)
    item = ingest(store, 1)
    store.queue_run("prior", session_id="chat-quiet", manifest={"event_delivery_id": item["id"]})
    store.set_state("prior", "failed")
    store.queue_run("current", session_id="chat-quiet")
    store.finish_event_dispatch(item["id"], state="queued", run_id="current")
    with sqlite3.connect(store.path) as connection:
        connection.execute("DROP TABLE agent_execution_links")
        connection.execute("UPDATE schema_meta SET version=11")
    upgraded = RunStore(store.path)
    assert {link["run_id"] for link in upgraded.inspector_execution_links("event", item["id"])} == {"prior", "current"}


def test_resume_retry_and_warning_acknowledgement_are_independent(tmp_path):
    store = seeded_store(tmp_path)
    held = ingest(store, "held")
    requested = ingest(store, "retry")
    store.finish_event_dispatch(requested["id"], state="failed", error="offline")
    store.pause_event_trigger("quiet", "offline")
    store.retry_event_delivery(requested["id"])
    assert store.event_trigger("quiet")["enabled"] is False
    assert store.event_trigger("quiet")["last_error"] == "offline"
    assert [item["id"] for item in store.pending_event_deliveries()] == [requested["id"]]
    with pytest.raises(RunStoreError, match="paused"):
        store.claim_event_delivery(held["id"])
    # One explicit retry may run while ordinary arrivals stay paused.
    _, delivery, _ = store.claim_event_delivery(requested["id"])
    assert delivery["state"] == "claiming"
    assert store.event_trigger("quiet")["enabled"] is False
    resumed = store.update_event_trigger("quiet", {"enabled": True})
    assert resumed["enabled"] is True
    assert resumed["last_error"] == "offline"
    cleared = store.clear_event_trigger_warning("quiet")
    assert cleared["enabled"] is True
    assert cleared["last_error"] is None


def test_schedule_history_is_scoped_paginated_and_separates_handoff_from_work(tmp_path, monkeypatch):
    store = seeded_store(tmp_path)
    schedule = store.create_schedule({
        "name": "Morning review", "prompt": "Summarize", "workspace_root": str(tmp_path),
        "mode": "work", "execution_environment": "local", "runner": "solo",
        "provider": "ollama", "model": "test", "timezone": "UTC",
        "rule": {"kind": "daily", "hour": 9, "minute": 0},
    }, now=1000)
    ids = []
    for n in range(4):
        _, occurrence, _ = store.claim_schedule_occurrence(
            schedule["id"], trigger="manual", request_id=str(n), now=2000 + n,
        )
        ids.append(occurrence["id"])
        store.finish_schedule_occurrence(occurrence["id"], state="skipped")
    store.queue_run("scheduled", session_id="chat", schedule_id=schedule["id"], occurrence_id=ids[0])
    store.set_state("scheduled", "waiting_permission")
    store.finish_schedule_occurrence(ids[0], state="queued", run_id="scheduled", session_id="chat")
    first = store.agent_history_page("schedule", schedule["id"], limit=2)
    second = store.agent_history_page("schedule", schedule["id"], limit=2, cursor=first["next_cursor"])
    assert first["total"] == 4
    assert first["counts"] == {"skipped": 3, "waiting_permission": 1}
    assert {item["id"] for item in first["occurrences"] + second["occurrences"]} == set(ids)
    monkeypatch.setattr(schedule_api, "_require_capability", lambda _: None)
    detail = schedule_api.occurrence_detail(ids[0], SimpleNamespace(run_store=store))
    assert detail["occurrence"]["id"] == ids[0]
    assert detail["delivery_state"] == "queued"
    assert detail["execution_state"] == "waiting_permission"
    assert detail["executions"][0]["run_id"] == "scheduled"


def test_workflow_approval_is_not_reported_as_completed_and_links_its_step(tmp_path, monkeypatch):
    store = seeded_store(tmp_path)
    item = ingest(store, "workflow")
    workflow = {
        "version": 1, "entry_step_id": "work", "steps": [
            {"id": "work", "type": "agent", "title": "Read", "instruction_template": "Read",
             "mode": "work", "outputs": [], "next_step_id": "approve"},
            {"id": "approve", "type": "approval", "title": "Review", "explanation_template": "Review result",
             "approve_step_id": "respond"},
            {"id": "respond", "type": "agent", "title": "Finish", "instruction_template": "Finish",
             "mode": "work", "outputs": [], "next_step_id": None},
        ],
    }
    execution, _ = store.create_automation_execution(
        automation_kind="event", automation_id="quiet", occurrence_id=item["id"],
        session_id="chat-quiet", workflow=workflow, trigger={}, settings={},
    )
    action = store.advance_automation_execution(execution["id"])
    store.queue_run("workflow-step", session_id="chat-quiet")
    store.bind_automation_step_run(execution["id"], action["step"]["id"], "workflow-step")
    store.set_state("workflow-step", "completed")
    store.finish_event_dispatch(item["id"], state="queued", run_id="workflow-step")
    store.complete_automation_step(execution["id"], run_id="workflow-step", result={})
    history = store.agent_history_page("event", "quiet")
    assert history["counts"] == {"waiting_approval": 1}
    assert history["workflow_execution_ids"] == {item["id"]: execution["id"]}
    monkeypatch.setattr(event_api, "_require_capability", lambda: None)
    detail = event_api.delivery_detail(item["id"], SimpleNamespace(run_store=store))
    assert detail["execution_state"] == "waiting_approval"
    assert detail["delivery_state"] == "queued"
    assert detail["workflow_execution_id"] == execution["id"]
    assert detail["executions"][0]["run_id"] == "workflow-step"
    focused = store.attention_items(workflow_execution_id=execution["id"])
    assert len(focused) == 1
    assert focused[0]["kind"] == "workflow_approval"
    assert store.attention_items(workflow_execution_id="unrelated") == []
    store.finish_event_dispatch(item["id"], state="failed", run_id="workflow-step", error="failed")
    with pytest.raises(RunStoreError, match="review the workflow"):
        store.retry_event_delivery(item["id"])


def test_attention_focus_is_applied_before_the_page_limit(tmp_path):
    store = seeded_store(tmp_path)
    for n in range(6):
        store.queue_run(f"run-{n}", session_id=f"chat-{n}")
        store.set_state(f"run-{n}", "waiting_permission")
    assert len(store.attention_items(limit=1)) == 1
    selected = store.attention_items(limit=1, run_id="run-5")
    assert len(selected) == 1
    assert selected[0]["run_id"] == "run-5"
