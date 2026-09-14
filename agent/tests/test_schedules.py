from __future__ import annotations

import os
import sqlite3
import time
from datetime import datetime
from pathlib import Path

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
    assert resumed["last_error"] == "Model was removed"
    assert RunStore(path).schedule(created["id"])["name"] == "Morning review"


def test_schedule_warning_can_be_cleared_without_resuming_the_agent(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    created = store.create_schedule(schedule_value(tmp_path), now=1_000)
    paused = store.pause_schedule(created["id"], "worker stopped")
    assert paused["enabled"] is False
    assert paused["last_error"] == "worker stopped"

    cleared = store.clear_schedule_warning(created["id"])

    assert cleared["enabled"] is False
    assert cleared["last_error"] is None


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


# --------------------------------------------------------------- dedicated chat


def _service(tmp_path):
    from ollama_code.chat_service import ChatService
    from ollama_code.core import AgentCore

    return ChatService(AgentCore(cwd=str(tmp_path), config={"model": "local"}))


def _primary_session(schedule_id: str) -> str | None:
    from ollama_code.sessions import SessionMeta

    return next(
        (
            session_id
            for session_id, entry in SessionMeta.all().items()
            if entry.get("agent_trigger_id") == schedule_id and entry.get("agent_primary")
        ),
        None,
    )


def test_a_schedule_owns_one_chat_that_every_run_continues(tmp_path) -> None:
    from fastapi import HTTPException

    from ollama_code.api.schedules import _dispatch_schedule, schedule_create
    from ollama_code.sessions import SessionMeta, SessionStore

    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))

    # The chat exists before the first run, so Agents mode can show the agent.
    primary = _primary_session(schedule["id"])
    assert primary is not None
    metadata = SessionMeta.get(primary)
    assert metadata["title"] == "Morning review"
    assert metadata["agent_name"] == "Morning review"
    assert metadata["model"] == "test-model"
    summary = next(
        item for item in SessionStore.summaries(limit=500, include_archived=True)
        if item["id"] == primary
    )
    assert summary["agent_primary"] is True
    assert summary["model"] == "test-model"
    assert summary["provider"] == "ollama"

    first = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")
    assert first["occurrence"]["session_id"] == primary

    # While that run is still open the next occurrence is skipped, not queued
    # behind it into the same worker, and the schedule stays enabled.
    with pytest.raises(HTTPException) as skipped:
        _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="two")
    assert skipped.value.status_code == 409
    assert "still in progress" in skipped.value.detail
    occurrences = service.run_store.schedule_occurrences(schedule["id"])
    assert any(
        item["state"] == "skipped" and "Skipped" in str(item["error"] or "")
        for item in occurrences
    )
    # An overlap is not a failure of the agent: the schedule keeps running and
    # its last run still points at the run that is actually in progress.
    after_skip = service.run_store.schedule(schedule["id"])
    assert after_skip["enabled"] is True
    assert after_skip["last_error"] is None
    assert after_skip["last_run_id"] == first["run"]["id"]

    # Once it finishes, the following occurrence continues the same chat.
    service.run_store.set_state(first["run"]["id"], "completed")
    third = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="three")
    assert third["occurrence"]["session_id"] == primary
    owned = [
        session_id
        for session_id, entry in SessionMeta.all().items()
        if entry.get("agent_trigger_id") == schedule["id"]
    ]
    assert owned == [primary]


def test_a_schedule_side_chat_shares_identity_but_never_receives_runs(tmp_path) -> None:
    from ollama_code.api.schedules import (
        _dispatch_schedule,
        schedule_create,
        schedule_task_create,
    )

    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))
    primary = _primary_session(schedule["id"])

    side = schedule_task_create(schedule["id"], service, {"name": "Ask about Monday"})["session"]
    assert side["id"] != primary
    assert side["title"] == "Ask about Monday"
    assert side["agent_trigger_id"] == schedule["id"]
    assert side["agent_name"] == "Morning review"
    assert side["agent_primary"] is False

    run = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="x")
    assert run["occurrence"]["session_id"] == primary


def test_renaming_a_schedule_renames_its_chat(tmp_path) -> None:
    from ollama_code.api.schedules import schedule_create, schedule_update
    from ollama_code.sessions import SessionMeta

    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))
    primary = _primary_session(schedule["id"])

    schedule_update(schedule["id"], service, {"name": "Evening review"})

    metadata = SessionMeta.get(primary)
    assert metadata["title"] == "Evening review"
    assert metadata["agent_name"] == "Evening review"


def test_an_agents_event_chat_cannot_be_deleted_while_the_agent_exists(tmp_path) -> None:
    from fastapi import HTTPException

    from ollama_code.api.schedules import schedule_create, schedule_task_create
    from ollama_code.api.sessions import _agent_owning_chat, session_delete

    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))
    primary = _primary_session(schedule["id"])

    with pytest.raises(HTTPException) as refused:
        session_delete(primary, service)
    assert refused.value.status_code == 409
    assert "Morning review" in refused.value.detail

    # A side chat is not the agent's event chat, so it may go.
    side = schedule_task_create(schedule["id"], service, {})["session"]
    assert _agent_owning_chat(service, side["id"]) is None

    # Once the agent itself is gone, so is the protection.
    service.run_store.delete_schedule(schedule["id"])
    assert _agent_owning_chat(service, primary) is None


def test_listing_gives_pre_existing_schedules_their_chat(tmp_path) -> None:
    from ollama_code.api.schedules import schedule_list

    service = _service(tmp_path)
    # Created straight in the store, the way schedules existed before they
    # were agents: no dedicated chat.
    created = service.run_store.create_schedule(schedule_value(tmp_path))
    assert _primary_session(created["id"]) is None

    listed = schedule_list(service)
    assert [item["id"] for item in listed["schedules"]] == [created["id"]]
    primary = _primary_session(created["id"])
    assert primary is not None

    # Listing again reuses it rather than making another.
    schedule_list(service)
    assert _primary_session(created["id"]) == primary


def _repo(tmp_path, monkeypatch, name="repo"):
    """A throwaway git workspace a scheduled agent can run a worktree in."""
    import shutil
    import subprocess

    if shutil.which("git") is None:
        pytest.skip("git is not installed")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    root = tmp_path / name
    root.mkdir()
    run = lambda *args: subprocess.run(  # noqa: E731
        ["git", *args], cwd=root, check=True, capture_output=True
    )
    run("init", "-q")
    run("symbolic-ref", "HEAD", "refs/heads/main")
    run("config", "user.email", "t@example.com")
    run("config", "user.name", "Test")
    run("config", "commit.gpgsign", "false")
    (root / "first.txt").write_text("one\n", encoding="utf-8")
    run("add", "-A")
    run("commit", "-q", "-m", "first")
    return root, run


def test_moving_a_schedule_moves_where_its_runs_execute(tmp_path) -> None:
    from ollama_code.api.schedules import _dispatch_schedule, schedule_create, schedule_update
    from ollama_code.sessions import SessionMeta

    service = _service(tmp_path)
    here = tmp_path / "here"
    there = tmp_path / "there"
    here.mkdir()
    there.mkdir()
    schedule = schedule_create(service, schedule_value(tmp_path, workspace_root=str(here)))
    first = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")
    assert first["run"]["execution_path"] == str(here)

    schedule_update(schedule["id"], service, {"workspace_root": str(there)})

    primary = _primary_session(schedule["id"])
    metadata = SessionMeta.get(primary)
    assert metadata["workspace_root"] == str(there)
    assert metadata["execution_path"] == str(there)

    service.run_store.set_state(first["run"]["id"], "completed")
    second = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="two")
    assert second["run"]["execution_path"] == str(there)
    assert second["occurrence"]["session_id"] == primary


def test_a_worktree_agent_keeps_one_checkout_that_follows_the_workspace(
    tmp_path, monkeypatch
) -> None:
    from ollama_code import worktrees
    from ollama_code.api.schedules import _dispatch_schedule, schedule_create
    from ollama_code.sessions import SessionMeta
    from ollama_code.worktrees import TaskCheckoutStore

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    root, run = _repo(tmp_path, monkeypatch)
    service = _service(tmp_path)
    schedule = schedule_create(
        service,
        schedule_value(tmp_path, workspace_root=str(root), execution_environment="worktree"),
    )
    primary = _primary_session(schedule["id"])
    task_id = str(SessionMeta.get(primary)["task"]["id"])

    # The checkout is the agent's home, so pruning idle worktrees must skip it.
    assert TaskCheckoutStore.load(task_id).permanent is True

    first = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")
    checkout = Path(first["run"]["execution_path"])
    assert checkout.is_dir()
    assert (checkout / "first.txt").exists()

    # Work landed in the workspace after the agent was made reaches its runs.
    (root / "second.txt").write_text("two\n", encoding="utf-8")
    run("add", "-A")
    run("commit", "-q", "-m", "second")
    service.run_store.set_state(first["run"]["id"], "completed")
    second = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="two")
    assert (Path(second["run"]["execution_path"]) / "second.txt").exists()

    # A checkout taken away by an archive or an older prune is restored rather
    # than pausing the agent for good.
    TaskCheckoutStore.snapshot_and_remove(task_id)
    service.run_store.set_state(second["run"]["id"], "completed")
    third = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="three")
    assert Path(third["run"]["execution_path"]).is_dir()
    assert service.run_store.schedule(schedule["id"])["enabled"] is True


def test_new_git_schedule_keeps_its_output_folder_and_ignored_deliverables(
    tmp_path, monkeypatch
) -> None:
    from ollama_code import worktrees
    from ollama_code.api.schedules import _dispatch_schedule, schedule_create, schedule_update
    from ollama_code.sessions import SessionMeta
    from ollama_code.worktrees import TaskCheckoutStore

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    root, run = _repo(tmp_path, monkeypatch)
    (root / ".gitignore").write_text("Outputs/\n", encoding="utf-8")
    run("add", ".gitignore")
    run("commit", "-q", "-m", "ignore generated outputs")
    service = _service(tmp_path)
    schedule = schedule_create(
        service,
        schedule_value(tmp_path, workspace_root=str(root), execution_environment="worktree"),
    )
    primary = _primary_session(schedule["id"])
    metadata = SessionMeta.get(primary)
    checkout = Path(metadata["execution_path"])
    output = checkout / "Outputs" / primary
    task_id = metadata["task"]["id"]
    assert metadata["output_directory"] == str(output)
    assert metadata["environment"]["output_directory"] == str(output)
    assert output.is_dir()

    schedule_update(schedule["id"], service, {"name": "Project reports"})
    assert SessionMeta.get(primary)["output_directory"] == str(output)

    # Empty output folders are not tracked by Git, so clean refresh and restore
    # must recreate the same recorded location for the next run.
    (root / "second.txt").write_text("two\n", encoding="utf-8")
    run("add", "second.txt")
    run("commit", "-q", "-m", "second")
    first = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")
    assert (checkout / "second.txt").is_file()
    assert output.is_dir()
    assert SessionMeta.get(primary)["environment"]["output_directory"] == str(output)

    TaskCheckoutStore.snapshot_and_remove(task_id)
    service.run_store.set_state(first["run"]["id"], "completed")
    second = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="two")
    assert output.is_dir()
    assert SessionMeta.get(primary)["output_directory"] == str(output)

    # A report ignored by Git is still saved work. An otherwise clean checkout
    # must not be rebuilt over it when the next scheduled run starts.
    report = output / "report.txt"
    report.write_text("Keep this report.\n", encoding="utf-8")
    patch, _ = TaskCheckoutStore.load(task_id).patch()
    assert not patch.strip()
    service.run_store.set_state(second["run"]["id"], "completed")
    third = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="three")
    assert third["run"]["execution_path"] == str(checkout)
    assert report.read_text(encoding="utf-8") == "Keep this report.\n"
    assert SessionMeta.get(primary)["environment"]["output_directory"] == str(output)


def test_existing_git_schedule_does_not_acquire_an_output_folder(
    tmp_path, monkeypatch
) -> None:
    from ollama_code import worktrees
    from ollama_code.api.schedules import _dispatch_schedule, schedule_list, schedule_update
    from ollama_code.sessions import SessionMeta

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    root, _ = _repo(tmp_path, monkeypatch)
    service = _service(tmp_path)
    schedule = service.run_store.create_schedule(
        schedule_value(tmp_path, workspace_root=str(root), execution_environment="worktree")
    )

    # Adoption, routine editing, and dispatch all keep the old layout.
    schedule_list(service)
    primary = _primary_session(schedule["id"])
    schedule_update(schedule["id"], service, {"name": "Existing project review"})
    _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")
    metadata = SessionMeta.get(primary)
    assert not metadata.get("schedule_outputs")
    assert not metadata.get("output_directory")
    assert "output_directory" not in metadata["environment"]
    assert not (Path(metadata["execution_path"]) / "Outputs").exists()


def test_git_schedule_does_not_follow_a_replaced_output_folder(
    tmp_path, monkeypatch
) -> None:
    from fastapi import HTTPException

    from ollama_code import worktrees
    from ollama_code.api.schedules import _dispatch_schedule, schedule_create
    from ollama_code.sessions import SessionMeta

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    root, _ = _repo(tmp_path, monkeypatch)
    service = _service(tmp_path)
    schedule = schedule_create(
        service,
        schedule_value(tmp_path, workspace_root=str(root), execution_environment="worktree"),
    )
    primary = _primary_session(schedule["id"])
    output = Path(SessionMeta.get(primary)["output_directory"])
    external = tmp_path / "other-agent-outputs"
    external.mkdir()
    output.rmdir()
    output.parent.rmdir()
    output.parent.symlink_to(external, target_is_directory=True)

    with pytest.raises(HTTPException) as refused:
        _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")
    assert refused.value.status_code == 409
    assert not (external / primary).exists()
    assert SessionMeta.get(primary)["output_directory"] == str(output)
    assert service.run_store.schedule(schedule["id"])["enabled"] is False


def test_archiving_the_chat_an_agent_runs_in_is_refused(tmp_path) -> None:
    from fastapi import HTTPException

    from ollama_code.api.schedules import schedule_create
    from ollama_code.api.sessions import session_metadata_update

    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))
    primary = _primary_session(schedule["id"])

    with pytest.raises(HTTPException) as refused:
        session_metadata_update(primary, service, {"archived": True})
    assert refused.value.status_code == 409
    assert "Morning review" in refused.value.detail


def test_listing_adopts_older_schedules_and_the_chats_their_runs_left(tmp_path) -> None:
    from ollama_code.api.schedules import schedule_list
    from ollama_code.sessions import SessionMeta, SessionStore

    service = _service(tmp_path)
    created = service.run_store.create_schedule(schedule_value(tmp_path))
    assert _primary_session(created["id"]) is None

    # A chat from the days when every run opened its own conversation.
    older = SessionStore(str(tmp_path), "test-model", "ollama").session_id
    SessionMeta.update(older, title="Morning review · Sep 1", schedule_id=created["id"])

    listed = schedule_list(service)
    assert [item["id"] for item in listed["schedules"]] == [created["id"]]
    primary = _primary_session(created["id"])
    assert primary is not None and primary != older

    # The older run's chat joins the agent as a side conversation.
    adopted = SessionMeta.get(older)
    assert adopted["agent_trigger_id"] == created["id"]
    assert adopted["agent_name"] == "Morning review"
    assert adopted.get("agent_primary") is None

    # Listing again reuses what is there rather than making a second chat.
    schedule_list(service)
    assert _primary_session(created["id"]) == primary


def test_a_second_dispatch_cannot_queue_into_a_chat_that_is_already_running(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.queue_run_if_idle("run-one", session_id="chat", request="first")

    with pytest.raises(RunStoreError, match="the chat is busy"):
        store.queue_run_if_idle("run-two", session_id="chat", request="second")

    store.set_state("run-one", "completed")
    assert store.queue_run_if_idle("run-two", session_id="chat", request="second")["id"] == "run-two"


def test_a_run_waiting_for_a_person_does_not_silence_the_agent(tmp_path) -> None:
    from ollama_code.api.schedules import _dispatch_schedule, schedule_create

    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))
    first = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="one")

    # A paused run is waiting for the person, not working. One unattended
    # pause must not stop every future run of the agent.
    service.run_store.set_state(first["run"]["id"], "paused", recoverable=True)

    second = _dispatch_schedule(service, schedule["id"], trigger="manual", request_id="two")
    assert second["occurrence"]["session_id"] == _primary_session(schedule["id"])
    assert second["run"]["id"] != first["run"]["id"]


def test_a_skipped_one_shot_keeps_the_run_it_never_had(tmp_path) -> None:
    from ollama_code.api.schedules import _record_skip, schedule_create

    service = _service(tmp_path)
    at = time.time() + 300
    schedule = schedule_create(
        service, schedule_value(tmp_path, rule={"kind": "once", "at": at})
    )
    # Claiming consumes the single slot and switches the schedule off before
    # the chat is known to be free.
    _, occurrence, claimed = service.run_store.claim_schedule_occurrence(
        schedule["id"], trigger="due", now=at + 1
    )
    assert claimed
    assert service.run_store.schedule(schedule["id"])["enabled"] is False

    _record_skip(service.run_store, occurrence, _primary_session(schedule["id"]))

    restored = service.run_store.schedule(schedule["id"])
    assert restored["enabled"] is True, "a skipped run is not a run that happened"
    assert restored["next_run_at"] == pytest.approx(at)
    assert restored["last_error"] is None


def test_a_move_that_cannot_be_made_leaves_the_schedule_where_it_was(
    tmp_path, monkeypatch
) -> None:
    import subprocess

    from fastapi import HTTPException

    from ollama_code import worktrees
    from ollama_code.api.schedules import schedule_create, schedule_update

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(tmp_path))
    # A repository with no commits: it passes validation, but no worktree can
    # be cut from it.
    unborn = tmp_path / "unborn"
    unborn.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=unborn, check=True, capture_output=True)

    with pytest.raises(HTTPException) as refused:
        schedule_update(
            schedule["id"],
            service,
            {"workspace_root": str(unborn), "execution_environment": "worktree"},
        )
    assert refused.value.status_code == 409

    # The edit was reported as failed, so it must not have happened.
    row = service.run_store.schedule(schedule["id"])
    assert row["workspace_root"] == str(tmp_path)
    assert row["execution_environment"] == "local"


def test_a_half_built_checkout_does_not_brick_a_worktree_agent(tmp_path, monkeypatch) -> None:
    from ollama_code import worktrees
    from ollama_code.api.schedules import _checkout_task_id, _ensure_schedule_session

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    root, _ = _repo(tmp_path, monkeypatch)
    service = _service(tmp_path)
    created = service.run_store.create_schedule(
        schedule_value(tmp_path, workspace_root=str(root), execution_environment="worktree")
    )
    # A creation that died before it wrote its metadata. The id is derived
    # from the schedule, so nothing else would ever get past it.
    (tmp_path / "tasks" / _checkout_task_id(created["id"], str(root))).mkdir(parents=True)

    session_id, metadata = _ensure_schedule_session(created)

    assert Path(metadata["execution_path"]).is_dir()
    assert _primary_session(created["id"]) == session_id


def test_deleting_a_worktree_agent_frees_its_checkout(tmp_path, monkeypatch) -> None:
    from ollama_code import worktrees
    from ollama_code.api.schedules import schedule_create, schedule_delete
    from ollama_code.sessions import SessionMeta
    from ollama_code.worktrees import TaskCheckoutStore

    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    root, _ = _repo(tmp_path, monkeypatch, name="delete-repo")
    service = _service(tmp_path)
    schedule = schedule_create(
        service,
        schedule_value(tmp_path, workspace_root=str(root), execution_environment="worktree"),
    )
    task_id = str(SessionMeta.get(_primary_session(schedule["id"]))["task"]["id"])
    assert TaskCheckoutStore.load(task_id).permanent is True

    schedule_delete(schedule["id"], service)

    # Kept out of pruning's reach while the agent existed; ordinary again now.
    assert TaskCheckoutStore.load(task_id).permanent is False


def test_saved_profile_owns_schedule_and_side_chats_after_update(tmp_path):
    import uuid

    from ollama_code.api.schedules import schedule_create, schedule_task_create, schedule_update
    from ollama_code.sessions import SessionMeta

    service = _service(tmp_path)
    profile_id = str(uuid.uuid4())
    schedule = schedule_create(service, schedule_value(tmp_path, agent_profile_id=profile_id))
    primary = _primary_session(schedule["id"])
    assert SessionMeta.get(primary)["agent_profile_id"] == profile_id
    schedule_update(schedule["id"], service, {"name": "Renamed schedule"})
    side = schedule_task_create(schedule["id"], service, {"name": "Questions"})["session"]
    assert side["agent_profile_id"] == profile_id
    assert SessionMeta.get(side["id"])["agent_world_profile_id"] == profile_id
    assert SessionMeta.get(primary)["agent_profile_id"] == profile_id


def test_schedule_rejects_invalid_profile_before_creating_anything(tmp_path):
    from fastapi import HTTPException

    from ollama_code.api.schedules import schedule_create

    service = _service(tmp_path)
    with pytest.raises(HTTPException) as error:
        schedule_create(service, schedule_value(tmp_path, agent_profile_id="not-a-profile"))
    assert error.value.status_code == 422
    assert service.run_store.schedules() == []


def test_home_schedules_and_side_chats_have_separate_persistent_task_folders(tmp_path, monkeypatch):
    import uuid
    from pathlib import Path

    from ollama_code.api.schedules import (
        _dispatch_schedule,
        schedule_create,
        schedule_task_create,
        schedule_update,
    )
    from ollama_code.sessions import SessionMeta

    owner = str(uuid.uuid4())
    homes = tmp_path / "AgentHomes"
    monkeypatch.setenv("LOCUS_AGENT_HOMES_ROOT", str(homes))
    home = homes / owner / "Workspace"
    home.mkdir(parents=True)
    service = _service(tmp_path)
    first = schedule_create(service, schedule_value(home, agent_profile_id=owner))
    second = schedule_create(service, schedule_value(home, agent_profile_id=owner))
    first_id, second_id = _primary_session(first["id"]), _primary_session(second["id"])
    before = SessionMeta.get(first_id)
    other = SessionMeta.get(second_id)
    assert before["execution_path"] != other["execution_path"]
    assert before["execution_path"] == str(home / "Tasks" / first_id)
    artifact = Path(before["output_directory"]) / "report.md"
    artifact.write_text("Keep this output")
    schedule_update(first["id"], service, {"name": "Renamed"})
    assert SessionMeta.get(first_id)["execution_path"] == before["execution_path"]
    assert SessionMeta.get(first_id)["output_directory"] == before["output_directory"]
    dispatched = _dispatch_schedule(service, first["id"], trigger="manual", request_id="home-run")
    assert dispatched["run"]["execution_path"] == before["execution_path"]
    side = schedule_task_create(first["id"], service, {})["session"]
    assert SessionMeta.get(side["id"])["execution_path"] not in {before["execution_path"], other["execution_path"], str(home)}
    assert artifact.read_text() == "Keep this output"


def test_explicit_home_project_home_schedule_change_reuses_only_its_recorded_task(tmp_path, monkeypatch):
    import uuid
    from pathlib import Path

    from ollama_code.api.schedules import schedule_create, schedule_update
    from ollama_code.sessions import SessionMeta

    owner = str(uuid.uuid4())
    homes = tmp_path / "AgentHomes"
    monkeypatch.setenv("LOCUS_AGENT_HOMES_ROOT", str(homes))
    home = homes / owner / "Workspace"
    home.mkdir(parents=True)
    project = tmp_path / "shared-project"
    project.mkdir()
    service = _service(tmp_path)
    schedule = schedule_create(service, schedule_value(home, agent_profile_id=owner))
    session_id = _primary_session(schedule["id"])
    before = SessionMeta.get(session_id)
    artifact = Path(before["output_directory"]) / "keep.txt"
    artifact.write_text("Original home output")
    schedule_update(schedule["id"], service, {"workspace_root": str(project)})
    assert SessionMeta.get(session_id)["execution_path"] == str(project)
    schedule_update(schedule["id"], service, {"workspace_root": str(home)})
    restored = SessionMeta.get(session_id)
    assert restored["execution_path"] == before["execution_path"]
    assert restored["output_directory"] == before["output_directory"]
    assert artifact.read_text() == "Original home output"


def test_existing_home_schedule_is_not_moved_by_routine_edit(tmp_path, monkeypatch):
    import uuid

    from ollama_code.api.schedules import schedule_create, schedule_update
    from ollama_code.sessions import SessionMeta

    owner = str(uuid.uuid4())
    homes = tmp_path / "AgentHomes"
    monkeypatch.setenv("LOCUS_AGENT_HOMES_ROOT", str(homes))
    home = homes / owner / "Workspace"
    home.mkdir(parents=True)
    service = _service(tmp_path)
    legacy = schedule_create(service, schedule_value(home))
    session_id = _primary_session(legacy["id"])
    SessionMeta.update(session_id, agent_profile_id=owner)
    schedule_update(legacy["id"], service, {"name": "Existing layout"})
    assert SessionMeta.get(session_id)["execution_path"] == str(home)
    assert not (home / "Tasks").exists()
