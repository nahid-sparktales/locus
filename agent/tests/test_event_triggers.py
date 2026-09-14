from __future__ import annotations

import hashlib
import hmac
import sqlite3

import pytest
from fastapi import HTTPException

from ollama_code import runstore as runstore_module
from ollama_code.api.automation_workflows import execution_complete_step, execution_retry
from ollama_code.api.event_triggers import (
    delivery_dispatch,
    delivery_fail,
    delivery_retry,
    trigger_target_create,
    trigger_task_create,
)
from ollama_code.automation_workflows import implicit_workflow
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.event_triggers import (
    EventTriggerValidationError,
    matches_trigger,
    normalize_event,
    normalize_filters,
    validate_filters_for_source,
    verify_webhook_signature,
)
from ollama_code.runstore import RunStore, RunStoreError
from ollama_code.sessions import ChatOrganizationStore, SessionMeta, SessionStore


def _connection(store: RunStore, kind: str = "gmail", connection_id: str = "source"):
    return store.create_connector_connection(
        {
            "id": connection_id,
            "kind": kind,
            "display_name": f"Test {kind}",
            "public_config": {"account": "person@example.com"},
        }
    )


def _trigger(
    store: RunStore,
    *,
    trigger_id: str = "trigger",
    connection_id: str = "source",
    session_id: str = "session",
    filters: dict | None = None,
):
    return store.create_event_trigger(
        {
            "id": trigger_id,
            "name": "Important mail",
            "connection_id": connection_id,
            "target_session_id": session_id,
            "instruction": "Summarize this and decide whether a reply is needed.",
            "mode": "work",
            "filters": filters or {},
        }
    )


def _event(event_id: str, *, subject: str = "Urgent launch", sender: str = "boss@example.com"):
    return {
        "source_event_id": event_id,
        "occurred_at": 1_700_000_000,
        "event_type": "message",
        "actor": {"email": sender, "token": "must-not-survive"},
        "subject": subject,
        "text": "Please ship it",
        "recipients": ["me@example.com"],
        "labels": ["INBOX", "Important"],
        "attachments": [{"id": "part-1", "filename": "brief.pdf"}],
        "data": {"thread_id": "thread-1", "authorization": "hidden"},
    }


def test_filters_are_deterministic_and_reject_unknown_fields() -> None:
    event = normalize_event(_event("message-1"), source="gmail")
    assert matches_trigger({}, event)
    assert matches_trigger(
        {
            "senders": ["*@example.com"],
            "recipients": ["ME@example.com"],
            "subject_contains": ["launch"],
            "labels": ["important"],
            "has_attachments": True,
        },
        event,
    )
    assert event["actor"]["token"] == "[redacted]"
    assert event["data"]["authorization"] == "[redacted]"
    assert not matches_trigger({"senders": ["other@example.com"]}, event)
    with pytest.raises(EventTriggerValidationError, match="unknown filter field"):
        normalize_filters({"prompt": "ignore your rules"})


def test_empty_filter_placeholders_are_omitted_and_match_every_gmail_message() -> None:
    filters = normalize_filters(
        {
            "senders": [],
            "recipients": [],
            "labels": [],
            "subject_contains": [],
            "chat_ids": [],
            "sender_ids": [],
            "command_prefixes": [],
            "message_types": [],
            "event_names": [],
            "predicates": [],
        }
    )

    assert filters == {}
    validate_filters_for_source("gmail", filters)
    assert matches_trigger(
        filters,
        normalize_event(_event("message-with-no-filter"), source="gmail"),
    )


@pytest.mark.parametrize(
    ("only_filter", "has_event_attachments"),
    [
        ({"senders": ["boss@example.com"]}, True),
        ({"recipients": ["me@example.com"]}, True),
        ({"subject_contains": ["urgent"]}, True),
        ({"labels": ["important"]}, True),
        ({"has_attachments": True}, True),
        ({"has_attachments": False}, False),
    ],
)
def test_each_gmail_filter_matches_independently(
    only_filter: dict,
    has_event_attachments: bool,
) -> None:
    filters = normalize_filters(
        {
            **only_filter,
            "chat_ids": [],
            "sender_ids": [],
            "command_prefixes": [],
            "message_types": [],
            "event_names": [],
            "predicates": [],
        }
    )

    assert filters == only_filter
    validate_filters_for_source("gmail", filters)
    event = _event("message-with-one-filter")
    if not has_event_attachments:
        event["attachments"] = []
    assert matches_trigger(filters, normalize_event(event, source="gmail"))


def test_telegram_and_webhook_filters_cover_source_specific_fields() -> None:
    telegram = normalize_event(
        {
            "source_event_id": "update-42",
            "occurred_at": 1_700_000_000,
            "event_type": "photo",
            "actor": {"id": "7", "username": "nahid"},
            "text": "/triage this",
            "data": {"chat_id": "99"},
        },
        source="telegram",
    )
    assert matches_trigger(
        {
            "chat_ids": ["99"],
            "sender_ids": ["7"],
            "command_prefixes": ["/triage"],
            "message_types": ["photo"],
        },
        telegram,
    )
    assert not matches_trigger(
        {"command_prefixes": ["/triage"]}, {**telegram, "text": "please run /triage"}
    )

    webhook = normalize_event(
        {
            "source_event_id": "order-1",
            "occurred_at": 1_700_000_000,
            "event_type": "order.created",
            "data": {"order": {"status": "paid", "note": "rush delivery"}},
        },
        source="webhook",
    )
    assert matches_trigger(
        {
            "event_names": ["order.created"],
            "predicates": [
                {"path": "order.status", "op": "equals", "value": "paid"},
                {"path": "order.note", "op": "contains", "value": "RUSH"},
                {"path": "order.status", "op": "exists"},
            ],
        },
        webhook,
    )


def test_source_specific_filter_validation_requires_narrow_telegram_and_webhook_inputs() -> None:
    validate_filters_for_source("gmail", {"senders": ["*@example.com"]})
    validate_filters_for_source("telegram", {"chat_ids": ["99"]})
    validate_filters_for_source("webhook", {"event_names": ["order.created"]})
    with pytest.raises(EventTriggerValidationError, match="not valid for gmail"):
        validate_filters_for_source("gmail", {"chat_ids": ["99"]})
    with pytest.raises(EventTriggerValidationError, match="require an allowed"):
        validate_filters_for_source("telegram", {})
    with pytest.raises(EventTriggerValidationError, match="event name"):
        validate_filters_for_source("webhook", {"predicates": []})


def test_webhook_hmac_rejects_stale_and_modified_requests() -> None:
    body = b'{"event":"order.created"}'
    timestamp = "1700000000"
    signature = hmac.new(b"secret", timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    assert verify_webhook_signature("secret", timestamp, f"v1={signature}", body, now=1_700_000_100)
    assert not verify_webhook_signature(
        "secret", timestamp, signature, body + b" ", now=1_700_000_100
    )
    assert not verify_webhook_signature("secret", timestamp, signature, body, now=1_700_001_000)


def test_schema_upgrade_adds_price_state_without_losing_schedules(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    store.create_schedule(
        {
            "id": "daily",
            "name": "Daily",
            "prompt": "Summarize",
            "workspace_root": str(tmp_path),
            "provider": "ollama",
            "model": "test",
            "timezone": "UTC",
            "rule": {"kind": "interval", "every": 1, "unit": "hours"},
        },
        now=1_700_000_000,
    )
    # Recreate the exact version boundary this feature must upgrade: schema 8
    # already has schedules, but none of the event-automation tables.
    with sqlite3.connect(path) as connection:
        for table in (
            "connector_action_receipts",
            "event_deliveries",
            "event_triggers",
            "connector_connections",
        ):
            connection.execute(f"DROP TABLE {table}")
        connection.execute("UPDATE schema_meta SET version=8 WHERE singleton=1")

    reopened = RunStore(path)

    assert reopened.schedule("daily")["name"] == "Daily"
    with sqlite3.connect(path) as connection:
        version = connection.execute(
            "SELECT version FROM schema_meta WHERE singleton=1"
        ).fetchone()[0]
        tables = {
            row[0]
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
    assert version == runstore_module.SCHEMA_VERSION
    assert {
        "connector_connections",
        "event_triggers",
        "event_deliveries",
        "connector_action_receipts",
    } <= tables
    with sqlite3.connect(path) as connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(event_triggers)")}
    assert {
        "trigger_kind", "runtime_state_json", "workflow_json",
        "runner", "team_id", "team_name",
    } <= columns


def test_schema_nine_event_trigger_rows_migrate_in_place(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    _connection(store)
    _trigger(store)
    with sqlite3.connect(path) as connection:
        connection.execute("ALTER TABLE event_triggers DROP COLUMN trigger_kind")
        connection.execute("ALTER TABLE event_triggers DROP COLUMN runtime_state_json")
        connection.execute("UPDATE schema_meta SET version=9 WHERE singleton=1")

    reopened = RunStore(path)

    migrated = reopened.event_trigger("trigger")
    assert migrated is not None
    assert migrated["trigger_kind"] == "event"
    assert migrated["runtime_state"] == {}


def test_ingestion_deduplicates_and_dispatches_fifo_per_chat(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store, filters={"senders": ["boss@example.com"]})

    first = store.ingest_event("source", _event("message-1"), now=10)[0]
    duplicate = store.ingest_event("source", _event("message-1"), now=11)[0]
    second = store.ingest_event("source", _event("message-2"), now=12)[0]

    assert duplicate["id"] == first["id"]
    assert len(store.event_deliveries()) == 2
    with pytest.raises(RunStoreError, match="ahead"):
        store.claim_event_delivery(second["id"])

    trigger, claimed, run_id = store.claim_event_delivery(first["id"])
    assert trigger["target_session_id"] == "session"
    assert claimed["state"] == "claiming"
    assert len(run_id) == 32
    store.queue_run(run_id, session_id="session", request="event", run_kind="solo")
    store.finish_event_dispatch(first["id"], state="queued", run_id=run_id)
    with pytest.raises(RunStoreError, match="busy"):
        store.claim_event_delivery(second["id"])

    store.set_state(run_id, "completed")
    assert store.claim_event_delivery(second["id"])[1]["id"] == second["id"]


def test_overlapping_triggers_fan_out_and_separate_chats_claim_concurrently(
    tmp_path,
) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(
        store,
        trigger_id="broad",
        session_id="broad-chat",
        filters={"subject_contains": ["locus"]},
    )
    _trigger(
        store,
        trigger_id="specific",
        session_id="specific-chat",
        filters={"subject_contains": ["locus ab"]},
    )

    deliveries = store.ingest_event(
        "source", _event("overlap-1", subject="Locus ab status"), now=10
    )
    duplicate = store.ingest_event(
        "source", _event("overlap-1", subject="Locus ab status"), now=11
    )

    assert [item["trigger_id"] for item in deliveries] == ["broad", "specific"]
    assert {item["target_session_id"] for item in deliveries} == {
        "broad-chat",
        "specific-chat",
    }
    assert {item["matched_trigger_count"] for item in deliveries} == {2}
    assert [item["id"] for item in duplicate] == [item["id"] for item in deliveries]
    assert len(store.event_deliveries()) == 2

    broad = next(item for item in deliveries if item["trigger_id"] == "broad")
    specific = next(item for item in deliveries if item["trigger_id"] == "specific")
    assert store.claim_event_delivery(broad["id"])[1]["state"] == "claiming"
    assert store.claim_event_delivery(specific["id"])[1]["state"] == "claiming"


def test_trigger_creation_is_idempotent_for_client_generated_id(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)

    first = _trigger(store, trigger_id="stable-create-id")
    repeated = _trigger(store, trigger_id="stable-create-id")

    assert repeated == first
    assert [item["id"] for item in store.event_triggers()] == ["stable-create-id"]

    with pytest.raises(RunStoreError, match="already exists"):
        store.create_event_trigger(
            {
                "id": "stable-create-id",
                "name": "Different agent",
                "connection_id": "source",
                "target_session_id": "session",
                "instruction": "Do something else.",
                "mode": "work",
                "filters": {},
            }
        )


def test_dedicated_agent_target_is_stable_visible_and_file_backed(tmp_path) -> None:
    template = SessionStore(
        str(tmp_path),
        model="k3",
        provider="remote",
        account="Kimi Code — new kimi",
        account_id="account-123",
    )
    template.append(
        {
            "type": "message",
            "message": {"role": "user", "content": "Template chat"},
        }
    )
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    request = {
        "trigger_id": "weather-agent",
        "template_session_id": template.session_id,
        "name": "Toronto weather agent",
        "provider": "remote",
        "provider_account_id": "22222222-2222-2222-2222-222222222222",
        "account_label": "Kimi Code — testingnew",
        "model": "k3",
    }

    first = trigger_target_create(service, request)
    repeated = trigger_target_create(service, request)

    assert first["created"] is True
    assert repeated["created"] is False
    assert repeated["session"]["id"] == first["session"]["id"]
    summary = first["session"]
    assert summary["title"] == "Toronto weather agent"
    assert summary["agent_trigger_id"] == "weather-agent"
    assert summary["agent_name"] == "Toronto weather agent"
    metadata = SessionMeta.get(summary["id"])
    assert metadata["provider_account_id"] == "22222222-2222-2222-2222-222222222222"
    assert metadata["provider_account_label"] == "Kimi Code — testingnew"
    assert metadata["provider"] == "remote"
    assert metadata["model"] == "k3"
    header = SessionStore.header(SessionStore.path_for(summary["id"]))
    assert header["account_id"] == "22222222-2222-2222-2222-222222222222"
    snapshot = ChatOrganizationStore.snapshot(str(tmp_path))
    assert summary["id"] not in snapshot["placements"]
    assert all(item["name"] != "Agents" for item in snapshot["folders"])


def test_dedicated_agent_can_create_top_level_conversational_tasks(tmp_path) -> None:
    template = SessionStore(
        str(tmp_path),
        model="k3",
        provider="remote",
        account="Kimi Code — current",
        account_id="account-current",
    )
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    target = trigger_target_create(
        service,
        {
            "trigger_id": "weather-agent",
            "template_session_id": template.session_id,
            "name": "Weather agent",
        },
    )["session"]
    _connection(service.run_store)
    _trigger(
        service.run_store,
        trigger_id="weather-agent",
        session_id=target["id"],
    )

    task = trigger_task_create(
        "weather-agent",
        service,
        {
            "name": "Check Toronto",
            "provider": "remote",
            "provider_account_id": "account-current",
            "account_label": "Kimi Code — current",
            "model": "k3",
        },
    )["session"]

    assert task["id"] != target["id"]
    assert task["title"] == "Check Toronto"
    assert task["agent_trigger_id"] == "weather-agent"
    assert task["agent_name"] == "Weather agent"
    metadata = SessionMeta.get(task["id"])
    assert metadata["provider_account_id"] == "account-current"
    snapshot = ChatOrganizationStore.snapshot(str(tmp_path))
    assert task["id"] not in snapshot["placements"]


def test_the_event_chat_is_primary_and_survives_side_chats_and_deletion(tmp_path) -> None:
    from fastapi import HTTPException

    from ollama_code.api.sessions import _agent_owning_chat, session_delete

    template = SessionStore(
        str(tmp_path), model="k3", provider="remote", account="A", account_id="acct"
    )
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    request = {
        "trigger_id": "weather-agent",
        "template_session_id": template.session_id,
        "name": "Weather agent",
    }
    target = trigger_target_create(service, request)["session"]
    assert target["agent_primary"] is True
    _connection(service.run_store)
    _trigger(service.run_store, trigger_id="weather-agent", session_id=target["id"])

    # A side chat shares the identity but is not where events land.
    side = trigger_task_create("weather-agent", service, {})["session"]
    assert side["agent_primary"] is False
    assert _agent_owning_chat(service, side["id"]) is None

    # Editing the agent recovers the event chat, not the newer side chat.
    again = trigger_target_create(service, request)
    assert again["created"] is False
    assert again["session"]["id"] == target["id"]

    # The event chat cannot be pulled out from under a live agent.
    with pytest.raises(HTTPException) as refused:
        session_delete(target["id"], service)
    assert refused.value.status_code == 409
    # The guard names the trigger, whose stored name the helper sets.
    assert "Important mail" in refused.value.detail
    service.run_store.delete_event_trigger("weather-agent")
    assert _agent_owning_chat(service, target["id"]) is None


def test_editing_an_older_agent_keeps_its_own_event_chat(tmp_path) -> None:
    """An agent made before chats carried the flag must not move its events."""
    from ollama_code.sessions import SessionMeta

    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    target = SessionStore(str(tmp_path), model="k3", provider="ollama")
    SessionMeta.update(target.session_id, agent_trigger_id="weather-agent", title="Weather")
    side = SessionStore(str(tmp_path), model="k3", provider="ollama")
    SessionMeta.update(side.session_id, agent_trigger_id="weather-agent", title="Chat 2")
    _connection(service.run_store)
    _trigger(service.run_store, trigger_id="weather-agent", session_id=target.session_id)

    recovered = trigger_target_create(
        service,
        {
            "trigger_id": "weather-agent",
            "template_session_id": target.session_id,
            "name": "Weather agent",
        },
    )

    # The newer side chat is not promoted over the chat the trigger points at.
    assert recovered["created"] is False
    assert recovered["session"]["id"] == target.session_id
    assert SessionMeta.get(target.session_id)["agent_primary"] is True


def test_delivery_manifest_prefers_repaired_agent_route_metadata(tmp_path) -> None:
    target = SessionStore(
        str(tmp_path),
        model="old-model",
        provider="remote",
        account="Kimi Code — old",
        account_id="old-account",
    )
    SessionMeta.update(
        target.session_id,
        workspace_root=str(tmp_path),
        execution_path=str(tmp_path),
        environment={"type": "local", "isolation": "local"},
        provider="remote",
        model="k3",
        provider_account_id="33333333-3333-3333-3333-333333333333",
        provider_account_label="Kimi Code — current",
    )
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    _connection(service.run_store)
    _trigger(service.run_store, session_id=target.session_id)
    delivery = service.run_store.ingest_event("source", _event("repaired-route"))[0]

    result = delivery_dispatch(delivery["id"], service)

    assert result["run"]["manifest"]["provider"] == "remote"
    assert result["run"]["manifest"]["provider_account_id"] == (
        "33333333-3333-3333-3333-333333333333"
    )
    assert result["run"]["manifest"]["model"] == "k3"


def test_delivery_manifest_uses_stable_provider_account_id(tmp_path) -> None:
    target = SessionStore(
        str(tmp_path),
        model="k3",
        provider="remote",
        account="Kimi Code — new kimi",
        account_id="11111111-1111-1111-1111-111111111111",
    )
    target.append(
        {
            "type": "message",
            "message": {"role": "user", "content": "Persistent target"},
        }
    )
    SessionMeta.update(
        target.session_id,
        workspace_root=str(tmp_path),
        execution_path=str(tmp_path),
        environment={"type": "local", "isolation": "local"},
    )
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    _connection(service.run_store)
    _trigger(service.run_store, session_id=target.session_id)
    delivery = service.run_store.ingest_event("source", _event("stable-account"))[0]

    result = delivery_dispatch(delivery["id"], service)

    assert result["run"]["manifest"]["provider_account_id"] == (
        "11111111-1111-1111-1111-111111111111"
    )


def test_auth_handoff_failure_keeps_email_arrivals_and_recovers_after_login(tmp_path) -> None:
    target = SessionStore(
        str(tmp_path), model="claude-test", provider="claude_plan", account_id="claude-account"
    )
    SessionMeta.update(
        target.session_id, workspace_root=str(tmp_path), execution_path=str(tmp_path),
        environment={"type": "local", "isolation": "local"},
    )
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    store = service.run_store
    _connection(store)
    _trigger(store, session_id=target.session_id)
    original = store.ingest_event("source", _event("before-login"), now=10)[0]
    delayed = store.ingest_event("source", _event("waiting-for-login"), now=11)[0]
    first = delivery_dispatch(original["id"], service)

    # Native account preparation failed before the worker accepted any work.
    failed = delivery_fail(original["id"], service, {"error": "Claude needs sign-in."})

    assert failed["state"] == "failed"
    assert store.run(first["run"]["id"])["state"] == "interrupted"
    assert store.event_trigger("trigger")["enabled"] is True
    assert [d["id"] for d in store.pending_event_deliveries()] == [delayed["id"]]
    duplicate = store.ingest_event("source", _event("before-login"), now=12)[0]
    assert duplicate["id"] == original["id"]
    assert duplicate["state"] == "failed"
    assert duplicate["attempt"] == 0

    # Account recovery updates the saved route; dispatch uses that current
    # metadata and the failed handoff no longer holds the chat's FIFO queue.
    SessionMeta.update(
        target.session_id, provider="claude_plan", model="claude-ready",
        provider_account_id="claude-account",
    )
    recovered = delivery_dispatch(delayed["id"], service)
    assert recovered["run"]["manifest"]["model"] == "claude-ready"
    assert recovered["run"]["manifest"]["provider_account_id"] == "claude-account"
    assert recovered["delivery"]["state"] == "queued"
    store.set_state(recovered["run"]["id"], "completed")
    latest = store.ingest_event("source", _event("after-login"), now=13)[0]
    following = delivery_dispatch(latest["id"], service)
    assert following["delivery"]["state"] == "queued"
    store.set_state(following["run"]["id"], "completed")

    # Login alone does not replay the failed email. Its explicit Retry remains
    # a distinct attempt linked to the original interrupted run.
    retried = delivery_retry(original["id"], service)
    assert retried["delivery"]["attempt"] == 1
    with pytest.raises(HTTPException) as duplicate_retry:
        delivery_retry(original["id"], service)
    assert duplicate_retry.value.status_code == 409
    replay = delivery_dispatch(original["id"], service)
    assert replay["run"]["id"] != first["run"]["id"]
    assert replay["run"]["retry_parent_id"] == first["run"]["id"]


@pytest.mark.parametrize("pause_before_failure", [False, True])
def test_delivery_failure_preserves_explicit_pause(tmp_path, pause_before_failure) -> None:
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    store = service.run_store
    _connection(store)
    _trigger(store)
    original = store.ingest_event("source", _event("message-1"))[0]
    _, _, run_id = store.claim_event_delivery(original["id"])
    store.queue_run(run_id, session_id="session")
    store.finish_event_dispatch(original["id"], state="queued", run_id=run_id)
    if pause_before_failure:
        store.update_event_trigger("trigger", {"enabled": False})

    body = {"error": "Account unavailable."}
    if not pause_before_failure:
        body["pause_trigger"] = True
    delivery_fail(original["id"], service, body)

    assert store.event_trigger("trigger")["enabled"] is False
    assert store.ingest_event("source", _event("message-2")) == []
    assert delivery_retry(original["id"], service)["trigger"]["enabled"] is False


def test_workflow_auth_failure_releases_chat_and_retry_reacquires_it(tmp_path) -> None:
    target = SessionStore(str(tmp_path), model="claude-test", provider="claude_plan")
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    store = service.run_store
    _connection(store)
    _trigger(store, session_id=target.session_id)
    store.update_event_trigger("trigger", {"workflow": implicit_workflow("Summarize mail", "work")})
    original = store.ingest_event("source", _event("before-login"), now=10)[0]
    delayed = store.ingest_event("source", _event("waiting-for-login"), now=11)[0]
    first = delivery_dispatch(original["id"], service)
    first_run = first["run"]["id"]
    execution_id = first["workflow_execution"]["id"]
    # This is the native failure order observed in the saved database: cancel
    # the unaccepted queue item, then fail the corresponding delivery.
    store.reorder_queue(first_run, "cancel")
    delivery_fail(original["id"], service, {"run_id": first_run, "error": "Claude needs sign-in."})

    assert store.automation_execution(execution_id)["state"] == "failed"
    assert store.event_trigger("trigger")["enabled"] is True
    assert store.automation_execution(execution_id)["attempts"][0]["state"] == "failed"
    recovered = delivery_dispatch(delayed["id"], service)
    assert recovered["workflow_execution"]["state"] == "running"
    with pytest.raises(HTTPException) as busy:
        execution_retry(execution_id, service)
    assert busy.value.status_code == 409
    assert store.automation_execution(execution_id)["state"] == "failed"

    store.set_state(recovered["run"]["id"], "completed")
    execution_complete_step(recovered["workflow_execution"]["id"], service,
                            {"run_id": recovered["run"]["id"], "result": {}})
    retry = execution_retry(execution_id, service)
    assert retry["run"]["id"] != first_run
    assert retry["execution"]["state"] == "running"
    with pytest.raises(HTTPException) as stale:
        delivery_fail(original["id"], service,
                      {"run_id": first_run, "error": "Late failure from the old attempt."})
    assert stale.value.status_code == 409
    assert store.run(retry["run"]["id"])["state"] == "queued"
    assert store.automation_execution(execution_id)["current_run_id"] == retry["run"]["id"]
    with pytest.raises(RunStoreError, match="no longer running"):
        store.fail_automation_step(execution_id, "old failure", run_id=first_run)


def test_event_handoff_failure_cannot_interrupt_an_accepted_run(tmp_path) -> None:
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))
    store = service.run_store
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("accepted"))[0]
    _, _, run_id = store.claim_event_delivery(delivery["id"])
    store.queue_run(run_id, session_id="session")
    store.finish_event_dispatch(delivery["id"], state="queued", run_id=run_id)
    store.admit(run_id)
    store.append_event(run_id, {"type": "message_start"})

    with pytest.raises(HTTPException) as accepted:
        delivery_fail(delivery["id"], service, {"run_id": run_id, "error": "Late timeout."})

    assert accepted.value.status_code == 409
    assert store.run(run_id)["state"] == "dispatching"
    assert store.event_delivery(delivery["id"])["state"] == "queued"
    assert store.event_trigger("trigger")["enabled"] is True


def test_multiple_triggers_share_one_chat_fifo(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store, trigger_id="first")
    _trigger(store, trigger_id="second")

    deliveries = store.ingest_event("source", _event("message-1"), now=10)

    assert [item["trigger_id"] for item in deliveries] == ["first", "second"]
    store.claim_event_delivery(deliveries[0]["id"])
    with pytest.raises(RunStoreError, match="ahead|busy"):
        store.claim_event_delivery(deliveries[1]["id"])


def test_restart_recovers_claim_without_replaying_an_existing_run(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("message-1"))[0]

    store.claim_event_delivery(delivery["id"])
    recovered = RunStore(path)
    assert recovered.event_delivery(delivery["id"])["state"] == "pending"

    trigger, claimed, run_id = recovered.claim_event_delivery(delivery["id"])
    recovered.queue_run(
        run_id,
        session_id=trigger["target_session_id"],
        request="event",
        run_kind="solo",
        manifest={"event_triggered": True},
    )
    relinked = RunStore(path)
    value = relinked.event_delivery(claimed["id"])
    assert value["state"] == "queued"
    assert value["run_id"] == run_id


def test_failed_delivery_requires_explicit_retry_and_action_receipts_are_idempotent(
    tmp_path,
) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("message-1"))[0]
    _, _, run_id = store.claim_event_delivery(delivery["id"])
    store.queue_run(run_id, session_id="session")
    store.set_state(run_id, "failed")
    failed = store.finish_event_dispatch(
        delivery["id"], state="failed", run_id=run_id, error="offline"
    )
    stopped = store.pause_event_trigger("trigger", "offline")

    assert failed["state"] == "failed"
    assert stopped["enabled"] is False
    assert stopped["last_error"] == "offline"
    retried = store.retry_event_delivery(delivery["id"])
    assert retried["state"] == "pending"
    assert retried["attempt"] == 1
    reset_trigger = store.event_trigger("trigger")
    assert reset_trigger["enabled"] is False
    assert reset_trigger["last_error"] == "offline"
    with pytest.raises(RunStoreError, match="only stopped"):
        store.retry_event_delivery(delivery["id"])

    first = store.record_connector_action_receipt(
        "tool-call-1",
        event_delivery_id=delivery["id"],
        tool_name="gmail_send",
        result={"message_id": "sent-1"},
        now=20,
    )
    repeated = store.record_connector_action_receipt(
        "tool-call-1",
        event_delivery_id=delivery["id"],
        tool_name="gmail_send",
        result={"message_id": "sent-2"},
        now=30,
    )
    assert repeated == first
    assert repeated["result"] == {"message_id": "sent-1"}


def test_trigger_warning_can_be_cleared_without_resuming_the_agent(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store)
    paused = store.pause_event_trigger("trigger", "worker stopped")
    assert paused["enabled"] is False
    assert paused["last_error"] == "worker stopped"

    cleared = store.clear_event_trigger_warning("trigger")

    assert cleared["enabled"] is False
    assert cleared["last_error"] is None


def test_acknowledging_a_removed_event_clears_only_its_matching_warning(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("message-1"))[0]
    _, _, run_id = store.claim_event_delivery(delivery["id"])
    store.queue_run(run_id, session_id="session")
    store.set_state(run_id, "failed")
    failed = store.finish_event_dispatch(
        delivery["id"], state="failed", run_id=run_id, error="offline"
    )
    store.pause_event_trigger("trigger", "offline")

    acknowledged = store.acknowledge_event_delivery(delivery["id"])
    assert acknowledged["enabled"] is False
    assert acknowledged["last_error"] is None

    # If a newer failure owns the trigger warning, removing old history must
    # not erase the newer warning.
    store.update_event_trigger("trigger", {"enabled": True})
    newer = store.ingest_event("source", _event("message-2"))[0]
    _, _, newer_run_id = store.claim_event_delivery(newer["id"])
    store.queue_run(newer_run_id, session_id="session")
    store.set_state(newer_run_id, "failed")
    store.finish_event_dispatch(
        newer["id"], state="failed", run_id=newer_run_id, error="new failure"
    )
    store.pause_event_trigger("trigger", "new failure")
    unchanged = store.acknowledge_event_delivery(delivery["id"])
    assert unchanged["last_run_id"] != failed["run_id"]
    assert unchanged["last_error"] == "new failure"


def test_removing_an_old_retry_attempt_cannot_clear_the_new_attempt_warning(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("message-1"))[0]
    _, _, first_run_id = store.claim_event_delivery(delivery["id"])
    store.queue_run(first_run_id, session_id="session")
    store.set_state(first_run_id, "failed")
    store.finish_event_dispatch(
        delivery["id"], state="failed", run_id=first_run_id, error="first failure"
    )
    store.pause_event_trigger("trigger", "first failure")
    store.retry_event_delivery(delivery["id"])

    _, _, second_run_id = store.claim_event_delivery(delivery["id"])
    store.queue_run(second_run_id, session_id="session")
    store.set_state(second_run_id, "failed")
    store.finish_event_dispatch(
        delivery["id"], state="failed", run_id=second_run_id, error="new failure"
    )
    store.pause_event_trigger("trigger", "new failure")

    with pytest.raises(RunStoreError, match="newer run"):
        store.acknowledge_event_delivery(
            delivery["id"], expected_run_id=first_run_id
        )
    assert store.event_trigger("trigger")["last_error"] == "new failure"

    acknowledged = store.acknowledge_event_delivery(
        delivery["id"], expected_run_id=second_run_id
    )
    assert acknowledged["last_error"] is None


def test_queue_backpressure_is_per_trigger_and_history_survives_deletion(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(runstore_module, "MAX_PENDING_PER_TRIGGER", 1)
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("message-1"))[0]

    with pytest.raises(RunStoreError, match="queue is full"):
        store.ingest_event("source", _event("message-2"))

    store.delete_event_trigger("trigger")
    assert store.event_trigger("trigger") is None
    assert store.event_deliveries()[0]["id"] == delivery["id"]

    store.delete_connector_connection("source")
    assert store.connector_connection("source") is None
    assert store.event_deliveries()[0]["source_event_id"] == "message-1"


def _price_trigger(store: RunStore, *, lifecycle: str = "once", comparison: str = "crosses_above"):
    _connection(store, kind="price_feed", connection_id="prices")
    return store.create_event_trigger(
        {
            "id": "price-trigger",
            "trigger_kind": "price",
            "name": "Bitcoin threshold",
            "connection_id": "prices",
            "target_session_id": "session",
            "instruction": "Implement the configured response.",
            "mode": "work",
            "filters": {
                "price_condition": {
                    "provider_symbol": "BTCUSDT",
                    "display_symbol": "Bitcoin",
                    "asset_class": "crypto",
                    "quote_currency": "USD",
                    "comparison": comparison,
                    "threshold": "100000.00",
                    "lifecycle": lifecycle,
                    "repeat_interval_seconds": 900,
                }
            },
        }
    )


def _quote(identifier: str, price: str, occurred_at: float) -> dict:
    return {
        "source_event_id": identifier,
        "occurred_at": occurred_at,
        "event_type": "price.quote",
        "subject": "Bitcoin price quote",
        "data": {
            "provider_symbol": "BTCUSDT",
            "display_symbol": "Bitcoin",
            "asset_class": "crypto",
            "quote_currency": "USD",
            "price": price,
            "provider_timestamp": occurred_at,
            "venue": "Test Feed",
        },
    }


def test_price_once_baselines_crosses_and_requires_explicit_rearm(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    trigger = _price_trigger(store)
    assert trigger["action_connection_ids"] == []
    assert trigger["filters"]["price_condition"]["threshold"] == "100000"

    assert store.ingest_event("prices", _quote("q1", "99000", 100), now=100) == []
    fired = store.ingest_event("prices", _quote("q2", "100000", 101), now=101)
    assert len(fired) == 1
    assert store.event_trigger("price-trigger")["runtime_state"]["fired"] is True
    assert store.ingest_event("prices", _quote("q3", "99000", 102), now=102) == []
    assert store.ingest_event("prices", _quote("q4", "101000", 103), now=103) == []

    rearmed = store.rearm_price_trigger("price-trigger")
    assert rearmed["runtime_state"] == {}
    assert store.ingest_event("prices", _quote("q5", "101000", 104), now=104) == []
    assert store.ingest_event("prices", _quote("q6", "99000", 105), now=105) == []
    assert len(store.ingest_event("prices", _quote("q7", "100001", 106), now=106)) == 1


def test_price_rearm_fires_on_each_recross_and_ignores_stale_or_old_quotes(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _price_trigger(store, lifecycle="rearm", comparison="crosses_below")
    assert store.ingest_event("prices", _quote("q1", "101000", 1_000), now=1_000) == []
    assert len(store.ingest_event("prices", _quote("q2", "100000", 1_001), now=1_001)) == 1
    assert store.ingest_event("prices", _quote("old", "99000", 999), now=1_002) == []
    assert store.ingest_event("prices", _quote("stale", "110000", 1_003), now=2_000) == []
    assert store.ingest_event("prices", _quote("q3", "101000", 2_001), now=2_001) == []
    assert len(store.ingest_event("prices", _quote("q4", "99999", 2_002), now=2_002)) == 1


def test_price_repeat_respects_cooldown_and_outstanding_delivery(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _price_trigger(store, lifecycle="repeat")
    first = store.ingest_event("prices", _quote("q1", "101000", 10_000), now=10_000)
    assert len(first) == 1
    assert store.ingest_event("prices", _quote("q2", "102000", 10_899), now=10_899) == []
    assert store.ingest_event("prices", _quote("q3", "103000", 10_900), now=10_900) == []
    store.finish_event_dispatch(first[0]["id"], state="failed", error="test")
    assert len(store.ingest_event("prices", _quote("q4", "104000", 10_901), now=10_901)) == 1


def test_price_trigger_validation_and_webhook_contract(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store, kind="webhook", connection_id="relay")
    base = {
        "trigger_kind": "price",
        "name": "Relay price",
        "connection_id": "relay",
        "target_session_id": "session",
        "instruction": "Respond",
        "mode": "work",
        "filters": {
            "event_names": ["price.quote"],
            "price_condition": {
                "provider_symbol": "AAPL",
                "display_symbol": "Apple",
                "asset_class": "stock",
                "quote_currency": "USD",
                "comparison": "crosses_above",
                "threshold": "250",
                "lifecycle": "repeat",
                "repeat_interval_seconds": 899,
            },
        },
    }
    with pytest.raises(RunStoreError, match="at least 15 minutes"):
        store.create_event_trigger(base)
    base["filters"]["price_condition"]["repeat_interval_seconds"] = 900
    created = store.create_event_trigger(base)
    assert created["trigger_kind"] == "price"
    base["id"] = "huge-price"
    base["filters"]["price_condition"]["threshold"] = "1e1000000"
    with pytest.raises(RunStoreError, match="bounded positive decimal"):
        store.create_event_trigger(base)


def test_saved_profile_owns_event_destination_and_side_chats(tmp_path):
    import uuid

    template = SessionStore(str(tmp_path), model="fixture")
    profile_id = str(uuid.uuid4())
    SessionMeta.update(template.session_id, agent_profile_id=profile_id, agent_world_profile_id=profile_id)
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "fixture"}))
    _connection(service.run_store)
    for trigger_id in ("mail", "price"):
        target = trigger_target_create(service, {
            "trigger_id": trigger_id, "template_session_id": template.session_id, "name": trigger_id,
        })["session"]
        _trigger(service.run_store, trigger_id=trigger_id, session_id=target["id"])
        side = trigger_task_create(trigger_id, service, {"name": "Questions"})["session"]
        assert target["agent_profile_id"] == profile_id
        assert side["agent_profile_id"] == profile_id
        assert SessionMeta.get(side["id"])["agent_world_profile_id"] == profile_id
    assert SessionMeta.get(template.session_id).get("agent_trigger_id") is None


def test_owned_event_retarget_preserves_old_chat_and_uses_exact_new_task(tmp_path):
    import uuid

    from ollama_code.api.event_triggers import trigger_create, trigger_update
    from ollama_code.api.sessions import session_detached

    owner = str(uuid.uuid4())
    other_folder = tmp_path / "other-project"
    other_folder.mkdir()
    def chat(folder):
        return session_detached({"cwd": str(folder), "title": "Receiving chat",
            "agent_profile_id": owner, "execution_environment": "automatic"})
    first, second = chat(tmp_path), chat(other_folder)
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "fixture"}))
    _connection(service.run_store)
    route = {"provider": "ollama", "model": "captured-model"}
    trigger = trigger_create(service, {"id": "retarget", "name": "Inbox", "connection_id": "source",
        "target_session_id": first["session_id"], "agent_profile_id": owner, "profile_route": route,
        "instruction": "Summarize", "mode": "work", "filters": {}})
    old_metadata = SessionMeta.get(first["session_id"])
    old_transcript = SessionStore.path_for(first["session_id"]).read_bytes()
    old_delivery = service.run_store.ingest_event("source", _event("before-move"))[0]
    old_run = delivery_dispatch(old_delivery["id"], service)["run"]
    updated = trigger_update(trigger["id"], service, {"target_session_id": second["session_id"],
        "agent_profile_id": owner, "profile_route": route})
    assert updated["target_session_id"] == second["session_id"]
    assert SessionMeta.get(first["session_id"]) == old_metadata
    assert SessionStore.path_for(first["session_id"]).read_bytes() == old_transcript
    assert service.run_store.run(old_run["id"])["session_id"] == first["session_id"]
    bound = SessionMeta.get(second["session_id"])
    assert bound["execution_path"] == second["execution_path"]
    assert bound["output_directory"] == second["output_directory"]
    assert bound["agent_trigger_id"] == trigger["id"]
    assert bound["model"] == "captured-model"
    next_delivery = service.run_store.ingest_event("source", _event("after-move"))[0]
    next_run = delivery_dispatch(next_delivery["id"], service)["run"]
    assert next_run["session_id"] == second["session_id"]
    assert next_run["execution_path"] == second["execution_path"]


def test_owned_event_cannot_retarget_foreign_or_other_automation_chat(tmp_path):
    import uuid

    from ollama_code.api.event_triggers import trigger_create, trigger_update

    owner = str(uuid.uuid4())
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "fixture"}))
    _connection(service.run_store)
    first = SessionStore(str(tmp_path), model="fixture")
    SessionMeta.update(first.session_id, agent_profile_id=owner)
    trigger = trigger_create(service, {"id": "guarded", "name": "Inbox", "connection_id": "source",
        "target_session_id": first.session_id, "agent_profile_id": owner,
        "instruction": "Summarize", "mode": "work", "filters": {}})
    for foreign in (True, False):
        target = SessionStore(str(tmp_path), model="fixture")
        fields = {"agent_profile_id": str(uuid.uuid4()) if foreign else owner}
        if not foreign:
            fields.update(agent_trigger_id="other-rule", agent_kind="schedule")
        SessionMeta.update(target.session_id, **fields)
        before = SessionMeta.get(target.session_id)
        with pytest.raises(HTTPException) as refused:
            # Ownership also applies when an API caller omits the profile field.
            trigger_update(trigger["id"], service, {"target_session_id": target.session_id})
        assert refused.value.status_code == 409
        assert service.run_store.event_trigger(trigger["id"])["target_session_id"] == first.session_id
        assert SessionMeta.get(target.session_id) == before


def test_home_event_side_chat_gets_its_own_resumable_task_folder(tmp_path, monkeypatch):
    import uuid
    from pathlib import Path

    from ollama_code.agent_workspaces import home_session_workspace
    from ollama_code.api.event_triggers import trigger_create
    from ollama_code.api.sessions import session_detached

    owner = str(uuid.uuid4())
    homes = tmp_path / "AgentHomes"
    monkeypatch.setenv("LOCUS_AGENT_HOMES_ROOT", str(homes))
    home = homes / owner / "Workspace"
    home.mkdir(parents=True)
    target = session_detached({"cwd": str(home), "title": "Inbox", "agent_profile_id": owner,
        "execution_environment": "automatic", "agent_home": True})
    service = ChatService(AgentCore(cwd=str(tmp_path), config={"model": "fixture"}))
    _connection(service.run_store)
    trigger_create(service, {"id": "home-event", "name": "Inbox", "connection_id": "source",
        "target_session_id": target["session_id"], "agent_profile_id": owner,
        "profile_route": {"provider": "ollama", "model": "fixture"},
        "instruction": "Summarize", "mode": "work", "filters": {}})
    side = trigger_task_create("home-event", service, {})["session"]
    metadata = SessionMeta.get(side["id"])
    assert metadata["execution_path"] != target["execution_path"]
    assert metadata["output_directory"] != target["output_directory"]
    assert home_session_workspace(metadata, side["id"]) == (home, home / "Tasks" / side["id"])
    assert Path(metadata["output_directory"]).is_dir()
