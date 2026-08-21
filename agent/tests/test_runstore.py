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


def test_solo_swarm_identity_survives_queue_execution_completion_and_restore(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    queued = store.queue_run(
        "solo-swarm-no-workers",
        session_id="session",
        request="Inspect the project",
        run_kind="solo",
        manifest={"solo_swarm": True},
    )
    assert queued["manifest"] == {"solo_swarm": True}
    assert queued["attempts"] == []

    store.admit("solo-swarm-no-workers")
    assert store.run("solo-swarm-no-workers")["manifest"]["solo_swarm"] is True
    store.set_state("solo-swarm-no-workers", "running")
    assert store.run("solo-swarm-no-workers")["manifest"]["solo_swarm"] is True
    store.set_state("solo-swarm-no-workers", "completed")

    restored = RunStore(path).run("solo-swarm-no-workers")
    assert restored["state"] == "completed"
    assert restored["manifest"] == {"solo_swarm": True}
    assert restored["attempts"] == []


def test_run_store_persists_agent_tree_metadata_without_rewriting_job_ids(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-tree", state="running")
    store.append_event("run-tree", {
        "type": "agent_job_started", "job_id": "plan.1", "node_id": "plan.1",
        "parent_node_id": "plan", "depth": 1,
        "execution_engine": "openai_responses", "agent_id": "reviewer",
        "agent_name": "Reviewer", "role": "reviewer", "goal": "Inspect tests",
    })
    store.append_event("run-tree", {
        "type": "agent_job_completed", "state": "completed",
        "result": {
            "job_id": "plan.1", "node_id": "plan.1", "parent_node_id": "plan",
            "depth": 1, "execution_engine": "locus_managed", "output": "done",
        },
    })

    attempt = store.run("run-tree")["attempts"][0]
    assert attempt["job_id"] == "plan.1"
    assert attempt["node_id"] == "plan.1"
    assert attempt["parent_node_id"] == "plan"
    assert attempt["depth"] == 1
    assert attempt["execution_engine"] == "locus_managed"


def test_branch_retry_creates_a_new_attempt_under_the_same_node(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-retry", state="running")
    for state in ("stopped", "completed"):
        store.append_event("run-retry", {
            "type": "agent_job_started", "job_id": "plan.1", "node_id": "plan.1",
            "parent_node_id": "plan", "depth": 1, "agent_id": "researcher",
            "agent_name": "Researcher", "role": "researcher", "goal": "Inspect auth",
        })
        store.append_event("run-retry", {
            "type": "agent_job_completed", "state": state,
            "result": {"job_id": "plan.1", "node_id": "plan.1", "output": state},
        })

    attempts = store.run("run-retry")["attempts"]
    assert [attempt["attempt"] for attempt in attempts] == [1, 2]
    assert [attempt["node_id"] for attempt in attempts] == ["plan.1", "plan.1"]
    assert attempts[0]["attempt_id"] != attempts[1]["attempt_id"]


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


def test_queued_runs_keep_fifo_order_across_abandonment_and_reordering(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    first = store.queue_run("first", session_id="chat-a", message_id="message-a")
    second = store.queue_run("second", session_id="chat-b", message_id="message-b")
    third = store.queue_run("third", session_id="chat-c", message_id="message-c")
    fourth = store.queue_run("fourth", session_id="chat-c", message_id="message-d")

    assert [
        first["queue_position"], second["queue_position"],
        third["queue_position"], fourth["queue_position"],
    ] == [1, 2, 3, 4]
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE runs SET owner_pid=?", (999_999_999,))
    assert store.mark_abandoned() == []
    assert store.run("first")["state"] == "queued"

    store.reorder_queue("fourth", "move_top")
    queued = sorted(
        store.list_runs(states=["queued"]), key=lambda item: item["queue_position"]
    )
    assert [item["id"] for item in queued] == ["first", "second", "third", "fourth"]

    store.reorder_queue("third", "move_top")
    queued = sorted(
        store.list_runs(states=["queued"]), key=lambda item: item["queue_position"]
    )
    assert [item["id"] for item in queued] == ["third", "first", "second", "fourth"]
    store.reorder_queue("first", "cancel")
    assert store.run("first")["state"] == "cancelled"
    assert store.run("second")["queue_position"] == 2


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
        ).fetchone()[0] == 8


def test_schema_v4_migrates_a_v3_store_and_records_turn_usage(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    first = RunStore(path)
    first.start_run("existing-run")
    with sqlite3.connect(path) as connection:
        connection.execute("DROP TABLE turn_usage")
        connection.execute("UPDATE schema_meta SET version=3 WHERE singleton=1")
        connection.commit()

    migrated = RunStore(path)

    assert migrated.read_only is False
    migrated.record_turn_usage(
        session_id="session-1", workspace_root="/tmp/ws",
        provider="ollama", model="test-model",
        prompt_tokens=120, completion_tokens=45,
    )
    summary = migrated.usage_summary()
    assert summary["solo"]["turns"] == 1
    assert summary["solo"]["prompt_tokens"] == 120
    assert summary["solo"]["completion_tokens"] == 45
    assert summary["solo"]["recorded_since"] is not None
    assert migrated.run("existing-run") is not None


def test_usage_summary_survives_a_store_stuck_below_schema_v4(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    store.start_run("old-run", state="completed")
    with sqlite3.connect(path) as connection:
        connection.execute("DROP TABLE turn_usage")
        connection.execute("UPDATE schema_meta SET version=3 WHERE singleton=1")
        connection.commit()
    # Simulate the read-only fallback of a store whose migration cannot run:
    # the table stays missing, and the summary must degrade, not raise.
    store.read_only = True

    summary = store.usage_summary()

    assert summary["orchestration"]["runs"] == 1
    assert summary["solo"] == {
        "turns": 0, "prompt_tokens": 0, "completion_tokens": 0,
        "recorded_since": None,
    }


def test_turn_usage_recording_is_skipped_on_a_read_only_store(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    RunStore(path)  # create a healthy store first

    store = RunStore(path)
    store.read_only = True
    store.record_turn_usage(session_id="session-1", prompt_tokens=10)

    assert store.usage_summary()["solo"]["turns"] == 0


def test_usage_summary_rolls_up_runs_and_respects_since(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-a", workspace_root="/tmp/ws", team_name="Team A")
    store.append_event("run-a", {
        "type": "orchestration_completed",
        "state": "completed",
        "usage": {"model_calls": 6, "metered_tokens": 4_000, "estimated_cost": 1.25},
    })
    store.record_turn_usage(session_id="s1", prompt_tokens=100, completion_tokens=50)

    summary = store.usage_summary()
    assert summary["orchestration"]["runs"] == 1
    assert summary["orchestration"]["estimated_cost"] == pytest.approx(1.25)
    assert summary["by_workspace"][0]["workspace_root"] == "/tmp/ws"
    assert summary["expensive_runs"][0]["id"] == "run-a"
    assert summary["expensive_runs"][0]["estimated_cost"] == pytest.approx(1.25)
    assert summary["solo"]["turns"] == 1

    future = store.usage_summary(since=time.time() + 3_600)
    assert future["orchestration"]["runs"] == 0
    assert future["solo"]["turns"] == 0


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
