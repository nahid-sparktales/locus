from __future__ import annotations

import sqlite3
from datetime import datetime

import pytest

from ollama_code.runstore import RunStore, RunStoreError
from ollama_code.schedules import (
    ScheduleValidationError,
    latest_due_occurrence,
    next_occurrence,
    normalize_rule,
    timezone,
)


def timestamp(value: str, zone: str = "UTC", *, fold: int = 0) -> float:
    return datetime.fromisoformat(value).replace(tzinfo=timezone(zone), fold=fold).timestamp()


def schedule_value(tmp_path, **updates):
    value = {
        "name": "Morning review",
        "prompt": "Review the workspace and summarize what changed.",
        "workspace_root": str(tmp_path),
        "mode": "work",
        "execution_environment": "local",
        "runner": "solo",
        "provider": "ollama",
        "model": "test-model",
        "timezone": "UTC",
        "rule": {"kind": "daily", "hour": 9, "minute": 30},
    }
    value.update(updates)
    return value


def test_custom_intervals_enforce_fifteen_minute_minimum() -> None:
    with pytest.raises(ScheduleValidationError, match="at least 15 minutes"):
        normalize_rule(
            {"kind": "interval", "every": 14, "unit": "minutes", "anchor": 1_000},
            now=900,
        )
    rule = normalize_rule(
        {"kind": "interval", "every": 15, "unit": "minutes", "anchor": 1_000},
        now=900,
    )
    assert next_occurrence(rule, timezone("UTC"), after=1_000) == 1_900


def test_calendar_recurrence_preserves_wall_time_across_dst() -> None:
    zone = timezone("America/Toronto")
    rule = {"kind": "daily", "hour": 9, "minute": 15}
    before = timestamp("2026-03-06T12:00:00", "America/Toronto")
    first = next_occurrence(rule, zone, after=before)
    second = next_occurrence(rule, zone, after=first)

    assert datetime.fromtimestamp(first, zone).strftime("%Y-%m-%d %H:%M") == "2026-03-07 09:15"
    assert datetime.fromtimestamp(second, zone).strftime("%Y-%m-%d %H:%M") == "2026-03-08 09:15"
    assert second - first == 23 * 60 * 60


def test_nonexistent_dst_time_moves_forward_and_ambiguous_time_runs_once() -> None:
    zone = timezone("America/Toronto")
    spring = next_occurrence(
        {"kind": "daily", "hour": 2, "minute": 30}, zone,
        after=timestamp("2026-03-07T23:00:00", "America/Toronto"),
    )
    assert datetime.fromtimestamp(spring, zone).strftime("%Y-%m-%d %H:%M") == "2026-03-08 03:00"

    fall = next_occurrence(
        {"kind": "daily", "hour": 1, "minute": 30}, zone,
        after=timestamp("2026-10-31T23:00:00", "America/Toronto"),
    )
    assert datetime.fromtimestamp(fall, zone).fold == 0
    following = next_occurrence(
        {"kind": "daily", "hour": 1, "minute": 30}, zone, after=fall,
    )
    assert datetime.fromtimestamp(following, zone).strftime("%Y-%m-%d") == "2026-11-02"


def test_latest_due_occurrence_collapses_missed_calendar_runs() -> None:
    rule = {"kind": "daily", "hour": 9, "minute": 0}
    due = latest_due_occurrence(
        rule, timezone("UTC"),
        earliest=timestamp("2026-08-17T09:00:00"),
        now=timestamp("2026-08-21T16:00:00"),
    )
    assert due == timestamp("2026-08-21T09:00:00")


def test_due_claim_catches_up_once_and_is_idempotent(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    created = store.create_schedule(
        schedule_value(tmp_path), now=timestamp("2026-08-17T08:00:00")
    )
    now = timestamp("2026-08-21T16:00:00")
    schedule, occurrence, claimed = store.claim_schedule_occurrence(
        created["id"], trigger="due", now=now,
    )

    assert claimed is True
    assert occurrence["scheduled_for"] == timestamp("2026-08-21T09:30:00")
    assert schedule["next_run_at"] == timestamp("2026-08-22T09:30:00")
    store.queue_run(
        occurrence["id"], session_id="scheduled-chat", request=created["prompt"],
        schedule_id=created["id"], occurrence_id=occurrence["id"],
        scheduled_for=occurrence["scheduled_for"],
    )
    store.finish_schedule_occurrence(
        occurrence["id"], state="queued", session_id="scheduled-chat",
        run_id=occurrence["id"],
    )

    _, duplicate, claimed_again = store.claim_schedule_occurrence(
        created["id"], trigger="due", now=now,
    )
    assert claimed_again is False
    assert duplicate["id"] == occurrence["id"]
    assert len(store.schedule_occurrences(created["id"])) == 1


def test_manual_runs_are_idempotent_and_do_not_advance_recurrence(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    created = store.create_schedule(schedule_value(tmp_path), now=1_000)
    initial_next = created["next_run_at"]
    _, first, claimed = store.claim_schedule_occurrence(
        created["id"], trigger="manual", request_id="button-click", now=2_000,
    )
    _, second, claimed_again = store.claim_schedule_occurrence(
        created["id"], trigger="manual", request_id="button-click", now=2_001,
    )
    assert claimed is True and claimed_again is False
    assert first["id"] == second["id"]
    assert store.schedule(created["id"])["next_run_at"] == initial_next


def test_pause_resume_and_persistence_across_restart(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    created = store.create_schedule(schedule_value(tmp_path), now=1_000)
    paused = store.pause_schedule(created["id"], "Model was removed")
    assert paused["enabled"] is False
    assert paused["last_error"] == "Model was removed"

    resumed = store.update_schedule(created["id"], {"enabled": True}, now=2_000)
    assert resumed["enabled"] is True
    assert resumed["last_error"] is None
    assert RunStore(path).schedule(created["id"])["name"] == "Morning review"


def test_schema_eight_migrates_schedule_tables_without_losing_runs(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    store.start_run("old-run")
    with sqlite3.connect(path) as connection:
        connection.execute("DROP TABLE schedule_occurrences")
        connection.execute("DROP TABLE schedules")
        connection.execute("UPDATE schema_meta SET version=7 WHERE singleton=1")
        connection.commit()

    migrated = RunStore(path)
    assert migrated.read_only is False
    assert migrated.run("old-run") is not None
    created = migrated.create_schedule(schedule_value(tmp_path), now=1_000)
    assert migrated.schedule(created["id"]) is not None


def test_crud_rejects_invalid_once_dates_and_unknown_fields(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    with pytest.raises(RunStoreError, match="future"):
        store.create_schedule(
            schedule_value(tmp_path, rule={"kind": "once", "at": 900}), now=1_000,
        )
    created = store.create_schedule(schedule_value(tmp_path), now=1_000)
    with pytest.raises(RunStoreError, match="unknown schedule field"):
        store.update_schedule(created["id"], {"attachments": []}, now=1_100)
    store.delete_schedule(created["id"])
    assert store.schedule(created["id"]) is None
