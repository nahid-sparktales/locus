from types import SimpleNamespace

import pytest

from ollama_code.runtime_connectors import ConnectorHTTPError, RuntimeConnectors


def connector_with_responses(responses):
    client = RuntimeConnectors(SimpleNamespace(service=SimpleNamespace(run_store=None)))
    calls = []

    def gmail(key, path, **kwargs):
        calls.append((path, kwargs.get("params", {})))
        value = responses[path]
        if isinstance(value, Exception):
            raise value
        if callable(value):
            return value(kwargs.get("params", {}))
        return value

    client.gmail = gmail
    return client, calls


def test_gmail_deleted_message_does_not_poison_history():
    client, calls = connector_with_responses({
        "history": {"historyId": "200", "history": [{"messagesAdded": [
            {"message": {"id": key}} for key in ["deleted", "live", "live", "seen"]]}]},
        "messages/deleted": ConnectorHTTPError(404),
        "messages/live": {"id": "live", "snippet": "hello"},
    })
    events, cursor = client._poll({"id": "gmail", "kind": "gmail", "cursor": {
        "history_id": "100", "recent_message_ids": ["seen"]}})
    assert [event["source_event_id"] for event in events] == ["live"]
    assert cursor["history_id"] == "200"
    assert "deleted" in cursor["recent_message_ids"]
    assert "messages/seen" not in [path for path, _ in calls]


def test_gmail_expired_history_captures_baseline_before_paginated_scan():
    client, calls = connector_with_responses({
        "history": ConnectorHTTPError(404),
        "profile": {"historyId": "300"},
        "messages": lambda params: ({"messages": [{"id": "live"}, {"id": "seen"}]}
                                    if params.get("pageToken") else
                                    {"messages": [{"id": "deleted"}], "nextPageToken": "next"}),
        "messages/deleted": ConnectorHTTPError(404),
        "messages/live": {"id": "live"},
    })
    events, cursor = client._poll({"id": "gmail", "kind": "gmail", "cursor": {
        "history_id": "100", "last_successful_at": 1000, "recent_message_ids": ["seen"]}})
    assert [event["source_event_id"] for event in events] == ["live"]
    assert cursor["history_id"] == "300"
    assert [path for path, _ in calls[:3]] == ["history", "profile", "messages"]
    assert calls[2][1]["q"] == "after:940"


@pytest.mark.parametrize("status", [401, 403, 429, 500, 503])
def test_gmail_does_not_swallow_other_failures(status):
    client, _ = connector_with_responses({
        "history": {"historyId": "200", "history": [{"messagesAdded": [{"message": {"id": "live"}}]}]},
        "messages/live": ConnectorHTTPError(status),
    })
    with pytest.raises(ConnectorHTTPError) as error:
        client._poll({"id": "gmail", "kind": "gmail", "cursor": {"history_id": "100"}})
    assert error.value.status == status
