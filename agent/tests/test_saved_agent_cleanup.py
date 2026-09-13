from __future__ import annotations

import shutil
import uuid
from concurrent.futures import Future
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import APIRouter, FastAPI, HTTPException
from fastapi.testclient import TestClient

from ollama_code.api.sessions import register_routes, saved_agent_sessions_cleanup, sessions_restore
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.sessions import ChatOrganizationStore, SessionMeta, SessionStore
from ollama_code.worktrees import TaskCheckoutStore, WorktreeError


def _service(tmp_path) -> ChatService:
    return ChatService(AgentCore(cwd=str(tmp_path), config={"model": "fixture"}))


def _chat(tmp_path, profile_id, **metadata) -> SessionStore:
    chat = SessionStore(str(tmp_path), "fixture")
    chat.append({"type": "message", "message": {"role": "user", "content": "Keep this history"}})
    SessionMeta.update(chat.session_id, agent_profile_id=str(profile_id), **metadata)
    return chat


def test_cleanup_routes_complete_profile_to_one_recoverable_batch(tmp_path):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    chat = _chat(tmp_path, str(profile).upper(), title="Hidden by search", pinned=True)
    archived = _chat(tmp_path, profile, archived=True)
    other = _chat(tmp_path, uuid.uuid4(), title="Keep this other agent")
    folder = ChatOrganizationStore.create_folder(str(tmp_path), "Saved")
    ChatOrganizationStore.move_session(chat.session_id, folder["id"])
    original = SessionMeta.all()
    app = FastAPI()
    app.state.service = service
    router = APIRouter()
    register_routes(router)
    app.include_router(router)

    with TestClient(app) as client:
        response = client.post(
            f"/api/sessions/agent-profile/{str(profile).upper()}/cleanup", json={"action": "delete"}
        )
    assert response.status_code == 200
    result = response.json()
    assert result["ok"] and result["count"] == 2
    assert set(result["session_ids"]) == {chat.session_id, archived.session_id}
    assert not result["deleted_active"]
    assert not chat.path.exists() and not archived.path.exists()
    assert other.path.exists()
    assert SessionMeta.get(other.session_id) == original[other.session_id]

    restored = sessions_restore(service, {"batch": result["trash_batch"]})
    assert set(restored["session_ids"]) == {chat.session_id, archived.session_id}
    assert SessionMeta.all() == original
    assert ChatOrganizationStore.placement(chat.session_id)["folder_id"] == folder["id"]


@pytest.mark.parametrize("action", ["archive", "delete"])
def test_cleanup_replaces_idle_active_chat_once_and_keeps_other_profiles(tmp_path, action):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    active = service.core.session
    SessionMeta.update(active.session_id, agent_profile_id=str(profile), agent_world_profile_id=str(profile))
    other = _chat(tmp_path, uuid.uuid4())
    events = []
    service.core.on_event(events.append)

    result = saved_agent_sessions_cleanup(str(profile), service, {"action": action})

    assert result["deleted_active"]
    assert result["session_ids"] == [active.session_id]
    assert result["replacement_session_info"]["session_id"] == service.core.session.session_id
    assert service.core.session.session_id != active.session_id
    assert len([event for event in events if event["type"] == "session_started"]) == 1
    assert other.path.exists() and not SessionMeta.get(other.session_id).get("archived")
    if action == "archive":
        assert active.path.exists()
        assert SessionMeta.get(active.session_id)["archived"]
        assert SessionMeta.get(active.session_id)["agent_profile_id"] == str(profile)
        assert not result["trash_batch"]
    else:
        assert not active.path.exists()
        assert result["trash_batch"]


def test_cleanup_includes_all_empty_archived_and_legacy_chats_beyond_catalog_limit(tmp_path):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    unrelated = uuid.uuid4()
    owned_ids = []
    metadata = {}
    for index in range(503):
        chat = SessionStore(str(tmp_path), "fixture")
        owned_ids.append(chat.session_id)
        metadata[chat.session_id] = {
            "agent_profile_id": str(profile).upper() if index % 2 else str(profile),
            "archived": index % 3 == 0,
            "title": f"Chat {index}",
        }
    legacy = SessionStore(str(tmp_path), "fixture")
    metadata[legacy.session_id] = {"agent_world_profile_id": str(profile).upper()}
    owned_ids.append(legacy.session_id)
    # A current owner must not be overwritten by a different old world binding.
    other = SessionStore(str(tmp_path), "fixture")
    metadata[other.session_id] = {
        "agent_profile_id": str(unrelated), "agent_world_profile_id": str(profile),
    }
    SessionMeta._write(metadata)
    assert len(SessionStore.summaries(limit=500, include_archived=True)) == 500

    result = saved_agent_sessions_cleanup(str(profile), service, {"action": "delete"})

    assert result["count"] == 504
    assert set(result["session_ids"]) == set(owned_ids)
    assert other.path.exists()
    assert SessionMeta.get(other.session_id) == metadata[other.session_id]
    restored = sessions_restore(service, {"batch": result["trash_batch"]})
    assert set(restored["session_ids"]) == set(owned_ids)
    assert SessionMeta.all() == metadata


@pytest.mark.parametrize("action", ["archive", "delete"])
@pytest.mark.parametrize("state", ["running", "queued", "waiting_dispatch_approval"])
def test_busy_chat_blocks_entire_batch_before_any_state_changes(tmp_path, action, state):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    first = _chat(tmp_path, profile)
    busy = _chat(tmp_path, profile, archived=True)
    SessionMeta.update(service.core.session.session_id, agent_profile_id=str(profile))
    active_id = service.core.session.session_id
    before = SessionMeta.all()
    service.run_store.start_run("live", session_id=busy.session_id, state=state)
    # An older active run must not vanish behind a recent-run result cap.
    for index in range(21):
        service.run_store.start_run(f"completed-{index}", session_id=busy.session_id, state="completed")

    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": action})

    assert refused.value.status_code == 409
    assert "stop" in refused.value.detail
    assert SessionMeta.all() == before
    assert first.path.exists() and busy.path.exists()
    assert service.core.session.session_id == active_id


@pytest.mark.parametrize("action", ["archive", "delete"])
def test_live_automation_owner_blocks_cleanup_even_without_primary_metadata(tmp_path, action):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    first = _chat(tmp_path, profile)
    destination = _chat(tmp_path, profile, archived=True)
    service.run_store.create_connector_connection({"id": "source", "kind": "gmail", "display_name": "Mail"})
    service.run_store.create_event_trigger({
        "id": "watch", "name": "Inbox watcher", "connection_id": "source",
        "target_session_id": destination.session_id, "instruction": "Read new mail", "mode": "work",
        "filters": {},
    })
    original = SessionMeta.all()

    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": action})

    assert refused.value.status_code == 409
    assert "Inbox watcher" in refused.value.detail
    assert SessionMeta.all() == original
    assert first.path.exists() and destination.path.exists()


def test_removed_event_and_live_schedule_with_same_id_keep_separate_ownership(tmp_path):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    other_profile = uuid.uuid4()
    removed_event = _chat(tmp_path, profile, agent_trigger_id="same-id", agent_kind="event", agent_primary=True)
    schedule_chat = _chat(tmp_path, other_profile, agent_trigger_id="same-id", agent_kind="schedule", agent_primary=True)
    service.run_store.create_schedule({
        "id": "same-id", "name": "Morning review", "prompt": "Review changes",
        "workspace_root": str(tmp_path), "mode": "work", "execution_environment": "local",
        "runner": "solo", "provider": "ollama", "model": "fixture", "timezone": "UTC",
        "rule": {"kind": "daily", "hour": 9, "minute": 30},
    })

    result = saved_agent_sessions_cleanup(str(profile), service, {"action": "delete"})
    assert result["session_ids"] == [removed_event.session_id]
    assert schedule_chat.path.exists()
    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(other_profile), service, {"action": "delete"})
    assert refused.value.status_code == 409
    assert "Morning review" in refused.value.detail


def test_archive_keeps_titles_and_ownership_and_verifies_persisted_flags(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    chats = [_chat(tmp_path, profile, title="Work to keep"), _chat(tmp_path, profile, archived=True)]
    before = SessionMeta.all()
    result = saved_agent_sessions_cleanup(str(profile), service, {"action": "archive"})
    assert set(result["session_ids"]) == {chat.session_id for chat in chats}
    for chat in chats:
        assert chat.path.exists()
        assert SessionMeta.get(chat.session_id) == {**before[chat.session_id], "archived": True}

    unwritable = _chat(tmp_path, profile)
    monkeypatch.setattr(SessionMeta, "_write", lambda _: None)
    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": "archive"})
    assert refused.value.status_code == 500
    assert unwritable.path.exists() and not SessionMeta.get(unwritable.session_id).get("archived")


@pytest.mark.parametrize("fails", [False, True])
def test_archiving_active_worktree_returns_replacement_to_source_workspace(tmp_path, monkeypatch, fails):
    monkeypatch.chdir(tmp_path)
    service = _service(tmp_path)
    profile = uuid.uuid4()
    active_id = service.core.session.session_id
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    task = SimpleNamespace(id="test-task", workspace_root=str(tmp_path), execution_path=str(checkout))
    service.current_task = task
    service.core.enter_task_checkout(str(checkout), str(tmp_path), {"id": task.id})
    SessionMeta.update(active_id, agent_profile_id=str(profile), task={"id": task.id})
    monkeypatch.setattr(TaskCheckoutStore, "load", lambda task_id: task)

    def snapshot_and_remove(task_id):
        assert service.core.execution_path == str(tmp_path.resolve())
        assert service.current_task is None
        if fails:
            raise WorktreeError("The worktree could not be saved.")
        checkout.rmdir()
        return {"task": {"id": task_id, "state": "snapshotted"}}

    monkeypatch.setattr(TaskCheckoutStore, "snapshot_and_remove", snapshot_and_remove)
    result = saved_agent_sessions_cleanup(str(profile), service, {"action": "archive"})
    assert result["ok"] is not fails
    if fails:
        assert result["error"] == "The worktree could not be saved."
    assert result["deleted_active"]
    assert result["replacement_session_info"]["execution_path"] == str(tmp_path.resolve())
    assert service.core.session.session_id != active_id
    assert SessionMeta.get(active_id)["archived"]


@pytest.mark.parametrize("action", ["archive", "delete"])
def test_busy_foreground_blocks_cleanup_without_mutation(tmp_path, action):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    chat = _chat(tmp_path, profile)
    before = SessionMeta.all()
    service.turn_future = Future()
    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": action})
    assert refused.value.status_code == 409
    assert chat.path.exists() and SessionMeta.all() == before


@pytest.mark.parametrize("profile,body", [("bad", {"action": "delete"}), (str(uuid.uuid4()), {}),
    (str(uuid.uuid4()), {"action": "detach"}), (str(uuid.uuid4()), {"action": {}})])
def test_invalid_cleanup_requests_are_rejected(tmp_path, profile, body):
    service = _service(tmp_path)
    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(profile, service, body)
    assert refused.value.status_code == 422


def test_unknown_profile_is_an_idempotent_no_op(tmp_path):
    service = _service(tmp_path)
    current = service.core.session.session_id
    result = saved_agent_sessions_cleanup(str(uuid.uuid4()), service, {"action": "delete"})
    assert result["ok"] and result["session_ids"] == [] and result["count"] == 0
    assert result["trash_batch"] is None
    assert service.core.session.session_id == current


def test_partial_recovery_move_is_restored_and_reported_as_failure(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    chats = [_chat(tmp_path, profile), _chat(tmp_path, profile)]
    before = SessionMeta.all()
    original_move = SessionStore.move_to_trash
    monkeypatch.setattr(SessionStore, "move_to_trash", lambda ids, **kwargs: original_move(ids[:1], **kwargs))

    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": "delete"})

    assert refused.value.status_code == 500
    assert all(chat.path.exists() for chat in chats)
    assert SessionMeta.all() == before


@pytest.mark.parametrize("action", ["archive", "delete"])
def test_post_replacement_failure_returns_new_foreground_without_reporting_cleanup_success(tmp_path, monkeypatch, action):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    active_id = service.core.session.session_id
    SessionMeta.update(active_id, agent_profile_id=str(profile))
    other = _chat(tmp_path, profile)
    before = SessionMeta.all()
    if action == "archive":
        monkeypatch.setattr(SessionMeta, "_write", lambda _: None)
    else:
        original_move = SessionStore.move_to_trash
        monkeypatch.setattr(SessionStore, "move_to_trash", lambda ids, **kwargs: original_move(ids[:1], **kwargs))

    result = saved_agent_sessions_cleanup(str(profile), service, {"action": action})

    assert not result["ok"] and result["error"]
    assert result["session_ids"] == [] and result["count"] == 0
    assert result["deleted_active"]
    assert result["replacement_session_info"]["session_id"] == service.core.session.session_id
    assert result["replacement_session_info"]["session_id"] != active_id
    assert SessionStore.path_for(active_id).exists() and other.path.exists()
    assert SessionMeta.all() == before


def test_recovery_manifest_failure_never_moves_chats_or_forgets_their_ownership(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    chat = _chat(tmp_path, profile, archived=True)
    before = SessionMeta.all()
    write_text = Path.write_text

    def fail_manifest(path, *args, **kwargs):
        if path.name == "manifest.json":
            raise OSError("Recovery storage unavailable")
        return write_text(path, *args, **kwargs)

    monkeypatch.setattr(Path, "write_text", fail_manifest)
    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": "delete"})
    assert refused.value.status_code == 500
    assert chat.path.exists() and SessionMeta.all() == before


def test_filesystem_move_failure_rolls_back_batch_before_metadata_cleanup(tmp_path, monkeypatch):
    service = _service(tmp_path)
    profile = uuid.uuid4()
    chats = [_chat(tmp_path, profile), _chat(tmp_path, profile, archived=True)]
    before = SessionMeta.all()
    original_move = shutil.move
    moves = 0

    def fail_second_move(source, destination, *args, **kwargs):
        nonlocal moves
        if Path(source).parent.name == "sessions":
            moves += 1
            if moves == 2:
                raise OSError("The second chat could not be moved")
        return original_move(source, destination, *args, **kwargs)

    monkeypatch.setattr(shutil, "move", fail_second_move)
    with pytest.raises(HTTPException) as refused:
        saved_agent_sessions_cleanup(str(profile), service, {"action": "delete"})
    assert refused.value.status_code == 500
    assert all(chat.path.exists() for chat in chats)
    assert SessionMeta.all() == before
