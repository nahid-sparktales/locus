from __future__ import annotations

import hashlib
import hmac
import sqlite3

import pytest

from ollama_code import runstore as runstore_module
from ollama_code.event_triggers import (
    EventTriggerValidationError,
    matches_trigger,
    normalize_event,
    normalize_filters,
    validate_filters_for_source,
    verify_webhook_signature,
)
from ollama_code.runstore import RunStore, RunStoreError


def _connection(store: RunStore, kind: str = "gmail", connection_id: str = "source"):
    return store.create_connector_connection({
        "id": connection_id,
        "kind": kind,
        "display_name": f"Test {kind}",
        "public_config": {"account": "person@example.com"},
    })


def _trigger(
    store: RunStore,
    *,
    trigger_id: str = "trigger",
    connection_id: str = "source",
    session_id: str = "session",
    filters: dict | None = None,
):
    return store.create_event_trigger({
        "id": trigger_id,
        "name": "Important mail",
        "connection_id": connection_id,
        "target_session_id": session_id,
        "instruction": "Summarize this and decide whether a reply is needed.",
        "mode": "work",
        "filters": filters or {},
    })


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
    assert matches_trigger({
        "senders": ["*@example.com"],
        "recipients": ["ME@example.com"],
        "subject_contains": ["launch"],
        "labels": ["important"],
        "has_attachments": True,
    }, event)
    assert event["actor"]["token"] == "[redacted]"
    assert event["data"]["authorization"] == "[redacted]"
    assert not matches_trigger({"senders": ["other@example.com"]}, event)
    with pytest.raises(EventTriggerValidationError, match="unknown filter field"):
        normalize_filters({"prompt": "ignore your rules"})


def test_telegram_and_webhook_filters_cover_source_specific_fields() -> None:
    telegram = normalize_event({
        "source_event_id": "update-42",
        "occurred_at": 1_700_000_000,
        "event_type": "photo",
        "actor": {"id": "7", "username": "nahid"},
        "text": "/triage this",
        "data": {"chat_id": "99"},
    }, source="telegram")
    assert matches_trigger({
        "chat_ids": ["99"], "sender_ids": ["7"],
        "command_prefixes": ["/triage"], "message_types": ["photo"],
    }, telegram)
    assert not matches_trigger({"command_prefixes": ["/triage"]}, {
        **telegram, "text": "please run /triage"
    })

    webhook = normalize_event({
        "source_event_id": "order-1",
        "occurred_at": 1_700_000_000,
        "event_type": "order.created",
        "data": {"order": {"status": "paid", "note": "rush delivery"}},
    }, source="webhook")
    assert matches_trigger({
        "event_names": ["order.created"],
        "predicates": [
            {"path": "order.status", "op": "equals", "value": "paid"},
            {"path": "order.note", "op": "contains", "value": "RUSH"},
            {"path": "order.status", "op": "exists"},
        ],
    }, webhook)


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
    signature = hmac.new(
        b"secret", timestamp.encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    assert verify_webhook_signature(
        "secret", timestamp, f"v1={signature}", body, now=1_700_000_100
    )
    assert not verify_webhook_signature(
        "secret", timestamp, signature, body + b" ", now=1_700_000_100
    )
    assert not verify_webhook_signature(
        "secret", timestamp, signature, body, now=1_700_001_000
    )


def test_schema_nine_adds_event_tables_without_losing_schedules(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    store.create_schedule({
        "id": "daily",
        "name": "Daily",
        "prompt": "Summarize",
        "workspace_root": str(tmp_path),
        "provider": "ollama",
        "model": "test",
        "timezone": "UTC",
        "rule": {"kind": "interval", "every": 1, "unit": "hours"},
    }, now=1_700_000_000)
    # Recreate the exact version boundary this feature must upgrade: schema 8
    # already has schedules, but none of the event-automation tables.
    with sqlite3.connect(path) as connection:
        for table in (
            "connector_action_receipts", "event_deliveries",
            "event_triggers", "connector_connections",
        ):
            connection.execute(f"DROP TABLE {table}")
        connection.execute("UPDATE schema_meta SET version=8 WHERE singleton=1")

    reopened = RunStore(path)

    assert reopened.schedule("daily")["name"] == "Daily"
    with sqlite3.connect(path) as connection:
        version = connection.execute(
            "SELECT version FROM schema_meta WHERE singleton=1"
        ).fetchone()[0]
        tables = {row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )}
    assert version == 9
    assert {
        "connector_connections", "event_triggers", "event_deliveries",
        "connector_action_receipts",
    } <= tables


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


def test_failed_delivery_requires_explicit_retry_and_action_receipts_are_idempotent(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    _connection(store)
    _trigger(store)
    delivery = store.ingest_event("source", _event("message-1"))[0]
    store.claim_event_delivery(delivery["id"])
    failed = store.finish_event_dispatch(delivery["id"], state="failed", error="offline")

    assert failed["state"] == "failed"
    retried = store.retry_event_delivery(delivery["id"])
    assert retried["state"] == "pending"
    assert retried["attempt"] == 1

    first = store.record_connector_action_receipt(
        "tool-call-1", event_delivery_id=delivery["id"],
        tool_name="gmail_send", result={"message_id": "sent-1"}, now=20,
    )
    repeated = store.record_connector_action_receipt(
        "tool-call-1", event_delivery_id=delivery["id"],
        tool_name="gmail_send", result={"message_id": "sent-2"}, now=30,
    )
    assert repeated == first
    assert repeated["result"] == {"message_id": "sent-1"}


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
