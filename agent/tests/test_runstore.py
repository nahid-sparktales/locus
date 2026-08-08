from __future__ import annotations

import json
import os
import sqlite3
import time

import pytest

from ollama_code.runstore import RunStore, sanitize_event


def test_run_store_orders_events_and_rebuilds_attempts(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", session_id="session", team_id="team", request="work")
    started = store.append_event("run-1", {
        "type": "agent_job_started", "job_id": "research", "agent_id": "a",
        "agent_name": "Researcher", "role": "researcher", "goal": "inspect",
    })
    completed = store.append_event("run-1", {
        "type": "agent_job_completed", "state": "completed",
        "result": {"job_id": "research", "agent_id": "a", "agent_name": "Researcher",
                   "role": "researcher", "output": "done"},
    })
    assert started["seq"] == 1
    assert completed["seq"] == 2
    assert started["attempt_id"] == completed["attempt_id"]
    detail = store.run("run-1", include_events=True)
    assert detail is not None
    assert [event["seq"] for event in detail["events"]] == [1, 2]
    assert detail["attempts"][0]["result"]["output"] == "done"


def test_run_store_attempt_ids_are_scoped_to_each_run(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    attempt_ids = []

    for run_id in ("first-run", "second-run"):
        store.start_run(run_id, session_id="session", team_id="team", request="work")
        started = store.append_event(run_id, {
            "type": "agent_job_started", "job_id": "writer",
            "agent_id": "writer-agent", "agent_name": "Writer",
            "role": "implementer", "goal": "implement",
        })
        completed = store.append_event(run_id, {
            "type": "agent_job_completed", "state": "completed",
            "result": {"job_id": "writer", "output": "done"},
        })
        assert started["attempt_id"] == completed["attempt_id"]
        attempt_ids.append(started["attempt_id"])

    assert attempt_ids == ["first-run:writer:1", "second-run:writer:1"]


def test_incomplete_writer_attempt_is_paused_and_not_counted_as_completed(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run", state="running")
    store.append_event("run", {
        "type": "agent_job_started", "job_id": "writer",
        "agent_id": "writer-agent", "agent_name": "Writer",
        "role": "implementer", "goal": "implement",
    })
    store.append_event("run", {
        "type": "agent_job_incomplete", "job_id": "writer",
        "agent_id": "writer-agent", "state": "paused",
        "reason": "model_call_budget", "message": "Saved for resume",
    })

    detail = store.run("run", include_events=True)

    assert detail["attempts"][0]["state"] == "paused"
    assert detail["attempts"][0]["completed_at"] is None
    assert detail["job_count"] == 1
    assert detail["completed_job_count"] == 0
    summary = store.list_runs()[0]
    assert summary["job_count"] == 1
    assert summary["completed_job_count"] == 0


def test_run_store_checkpoint_and_redacted_export(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", request="secret request")
    store.append_event("run-1", {
        "type": "tool_result", "result": "visible result", "api_key": "never-store-me",
        "prompt_tokens": 12,
    })
    checkpoint = store.checkpoint("run-1", "writer_complete", {"state": "reviewing"})
    assert checkpoint["seq"] == 1
    exported = store.export("run-1")
    encoded = json.dumps(exported)
    assert "never-store-me" not in encoded
    assert "visible result" not in encoded
    assert "content omitted" in encoded
    assert store.latest_checkpoint("run-1")["kind"] == "writer_complete"


def test_abandoned_run_is_recoverable_but_never_started(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", state="running")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE runs SET owner_pid=? WHERE id='run-1'", (999_999_999,))
    changed = store.mark_abandoned()
    assert [run["id"] for run in changed] == ["run-1"]
    assert changed[0]["recoverable"] is True
    assert changed[0]["state"] == "interrupted"


def test_live_owner_is_not_marked_abandoned(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", state="running")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE runs SET owner_pid=? WHERE id='run-1'", (os.getpid(),))
    assert store.mark_abandoned() == []


def test_live_state_event_clears_stale_recovery_metadata(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", state="waiting_dispatch_approval")
    store.set_state(
        "run-1", "waiting_dispatch_approval", recoverable=True,
        reason="Waiting for plan approval.",
    )

    store.append_event("run-1", {
        "type": "orchestration_state", "state": "running",
    })

    run = store.run("run-1")
    assert run["state"] == "running"
    assert run["recoverable"] is False
    assert run["recovery_reason"] is None

    store.set_state(
        "run-1", "running", recoverable=True,
        reason="An older caller tried to restore stale recovery metadata.",
    )
    run = store.run("run-1")
    assert run["recoverable"] is False
    assert run["recovery_reason"] is None


def test_pause_and_resume_transition_recovery_metadata(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", state="running")
    store.set_state("run-1", "paused", recoverable=True, reason="Saved checkpoint.")
    assert store.run("run-1")["recoverable"] is True

    store.append_event("run-1", {
        "type": "orchestration_started", "state": "running", "resumed": True,
    })

    run = store.run("run-1")
    assert run["recoverable"] is False
    assert run["recovery_reason"] is None


@pytest.mark.parametrize("event_type", ["permission_request", "computer_action_request"])
def test_active_wait_clears_stale_recovery_metadata(tmp_path, event_type: str) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-1", state="waiting_dispatch_approval")
    store.set_state(
        "run-1", "waiting_dispatch_approval", recoverable=True,
        reason="Waiting for plan approval.",
    )

    store.append_event("run-1", {"type": event_type})

    run = store.run("run-1")
    assert run["recoverable"] is False
    assert run["recovery_reason"] is None


def test_active_scheduler_lease_prevents_abandoned_recovery(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("leased", state="running")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE runs SET owner_pid=? WHERE id='leased'", (999_999_999,))

    assert store.mark_abandoned(lambda run_id: run_id == "leased") == []
    assert store.run("leased")["state"] == "running"

    changed = store.mark_abandoned(lambda _run_id: False)
    assert [run["id"] for run in changed] == ["leased"]


def test_run_store_retention_preserves_pinned_runs(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    for run_id in ("old", "pinned"):
        store.start_run(run_id, state="completed")
        store.set_state(run_id, "completed")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE runs SET updated_at=?", (time.time() - 200 * 86_400,))
        connection.execute("UPDATE runs SET pinned=1 WHERE id='pinned'")
    assert store.prune(retention_days=90) == 1
    assert store.run("old") is None
    assert store.run("pinned") is not None


def test_size_retention_does_not_delete_pinned_runs(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("ordinary", state="completed")
    store.start_run("pinned", state="completed")
    store.set_pinned("pinned", True)

    assert store.prune(retention_days=365, max_bytes=1) == 1
    assert store.run("ordinary") is None
    assert store.run("pinned") is not None


def test_run_pinning_is_persisted(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run")
    assert store.set_pinned("run", True)["pinned"] is True
    assert store.run("run")["pinned"] is True


def test_current_schema_reopens_writable_without_reapplying_migrations(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    first = RunStore(path)
    first.start_run("before-reopen")

    reopened = RunStore(path)

    assert reopened.read_only is False
    reopened.start_run("after-reopen")
    assert reopened.run("after-reopen") is not None
    with sqlite3.connect(path) as connection:
        assert connection.execute(
            "SELECT version FROM schema_meta WHERE singleton=1"
        ).fetchone()[0] == 3


def test_sanitizer_preserves_usage_tokens_but_redacts_credentials() -> None:
    value = sanitize_event({
        "authorization": "Bearer secret", "completion_tokens": 9,
        "nested": {"password": "bad", "text": "okay"},
    })
    assert value["authorization"] == "[redacted]"
    assert value["completion_tokens"] == 9
    assert value["nested"]["password"] == "[redacted]"
    text = sanitize_event(
        "Authorization: Bearer abcdefghijklmnop\napi_key='top-secret-value'\nvisible"
    )
    assert "abcdefghijklmnop" not in text
    assert "top-secret-value" not in text
    assert "visible" in text


def test_legacy_snapshot_import_is_final_state_only_and_idempotent(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    snapshot = {
        "run_id": "old-run", "worker_id": "old-worker",
        "orchestration_state": "completed",
        "activities": [{
            "id": "review", "agent_name": "Reviewer", "role": "reviewer",
            "state": "completed", "goal": "Review", "output": "Approved",
        }],
    }
    imported = store.import_legacy_snapshot("session-old", snapshot, workspace_root="/tmp")
    again = store.import_legacy_snapshot("session-old", snapshot, workspace_root="/tmp")

    assert imported is not None and imported["legacy"] is True
    assert store.events("old-run") == []
    assert len(imported["attempts"]) == 1
    assert again["id"] == "old-run"


def test_mcp_tasks_are_persisted_with_origin_and_terminal_state(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run")
    store.upsert_mcp_task(
        "remote-task", server_id="server", tool_name="build_report",
        state="working", run_id="run", job_id="writer", tool_call_id="call-1",
    )
    assert store.mcp_tasks(run_id="run", nonterminal=True)[0]["state"] == "working"
    store.upsert_mcp_task(
        "remote-task", server_id="server", tool_name="build_report",
        state="completed", run_id="run", job_id="writer", tool_call_id="call-1",
        payload={"result": "done", "authorization": "secret"},
    )
    task = store.mcp_tasks(run_id="run")[0]
    assert task["state"] == "completed"
    assert task["completed_at"] is not None
    assert task["payload"]["authorization"] == "[redacted]"
