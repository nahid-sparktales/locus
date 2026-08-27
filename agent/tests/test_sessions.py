"""Session lifecycle, branching and metadata tests.

Every agent data path is redirected into a per-test temp directory by
``conftest.py``. This module used to point ``sessions.SESSIONS_DIR`` at a temp
directory itself, with a raw global assignment made inside each test body — so a
test that forgot the call, or that built a store before making it, swept the
developer's real transcripts into the trash.
"""
from __future__ import annotations

import json
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi import HTTPException

import ollama_code.sessions as sessions_module
from ollama_code import server
from ollama_code.core import AgentCore
from ollama_code.sessions import (
    ChatOrganizationStore,
    SessionStore,
    SessionTooLargeError,
    clear_saved_sessions,
    session_metadata,
    update_session_metadata,
)


def _chat(workspace: str, text: str) -> SessionStore:
    store = SessionStore(workspace)
    store.append({"type": "message", "message": {"role": "user", "content": text}})
    return store


def test_new_session_resets_transient_state(tmp_path) -> None:
    directory = str(tmp_path)
    core = AgentCore(cwd=directory, config={})
    events: list[dict] = []
    core.on_event(events.append)
    core._add_message({"role": "user", "content": "old request"})
    core.tool_ctx.todos = [{"content": "old task", "status": "pending"}]
    core.perms.allow_tool("bash")
    core.total_prompt_tokens = 120
    core.total_completion_tokens = 40
    old_path = core.session.path

    info = core.start_new_session(reason="clear_chat")

    assert core.session.path != old_path
    assert old_path.exists()
    assert info["session_id"] == core.session.path.stem
    assert len(core.messages) == 1 and core.messages[0]["role"] == "system"
    assert core.tool_ctx.todos == []
    assert core.perms.allowed == set()
    assert core.total_prompt_tokens == 0
    assert core.total_completion_tokens == 0
    started = next(event for event in events if event["type"] == "session_started")
    assert started["reason"] == "clear_chat"


def test_nested_chat_folders_validate_workspace_names_and_cycles(tmp_path) -> None:
    first = str(tmp_path / "one")
    second = str(tmp_path / "two")
    root = ChatOrganizationStore.create_folder(first, "Research")
    child = ChatOrganizationStore.create_folder(first, "Sources", root["id"])

    with pytest.raises(ValueError, match="already exists"):
        ChatOrganizationStore.create_folder(first, "research")
    with pytest.raises(ValueError, match="inside itself"):
        ChatOrganizationStore.update_folder(root["id"], parent_id=child["id"])
    with pytest.raises(ValueError, match="workspace"):
        ChatOrganizationStore.create_folder(second, "Wrong parent", root["id"])

    snapshot = ChatOrganizationStore.snapshot(first)
    assert [folder["name"] for folder in snapshot["folders"]] == ["Research", "Sources"]


def test_corrupt_organization_rehomes_invalid_placements_to_workspace_root(tmp_path) -> None:
    workspace = str(tmp_path)
    chat = _chat(workspace, "still visible")
    path = sessions_module._organization_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "version": 1,
        "folders": [
            {"id": "a", "workspace": workspace, "parent_id": "b", "name": "A", "order": 0},
            {"id": "b", "workspace": workspace, "parent_id": "a", "name": "B", "order": 0},
            {"id": 17, "workspace": workspace, "name": "bad"},
        ],
        "placements": {
            chat.session_id: {
                "session_id": chat.session_id,
                "workspace": workspace,
                "folder_id": "missing",
                "order": -9,
            },
        },
    }), encoding="utf-8")

    snapshot = ChatOrganizationStore.snapshot(workspace)
    assert len(snapshot["folders"]) == 2
    assert any(folder["parent_id"] is None for folder in snapshot["folders"])
    assert snapshot["placements"][chat.session_id]["folder_id"] is None
    summary = next(item for item in SessionStore.summaries() if item["id"] == chat.session_id)
    assert summary["folder_id"] is None


def test_chat_folder_writes_are_serialized_across_concurrent_callers(tmp_path) -> None:
    workspace = str(tmp_path)
    with ThreadPoolExecutor(max_workers=8) as pool:
        folders = list(pool.map(
            lambda index: ChatOrganizationStore.create_folder(workspace, f"Folder {index}"),
            range(40),
        ))

    snapshot = ChatOrganizationStore.snapshot(workspace)
    assert len(folders) == len(snapshot["folders"]) == 40
    assert len({folder["id"] for folder in snapshot["folders"]}) == 40
    assert sorted(folder["order"] for folder in snapshot["folders"]) == list(range(40))


def test_folder_and_chat_reordering_use_true_insertion_order(tmp_path) -> None:
    workspace = str(tmp_path)
    folders = [
        ChatOrganizationStore.create_folder(workspace, name)
        for name in ("First", "Second", "Third")
    ]
    ChatOrganizationStore.update_folder(folders[2]["id"], parent_id=None, index=0)
    ordered_folders = sorted(
        ChatOrganizationStore.snapshot(workspace)["folders"], key=lambda item: item["order"]
    )
    assert [folder["name"] for folder in ordered_folders] == ["Third", "First", "Second"]

    chats = [_chat(workspace, f"chat {index}") for index in range(3)]
    for chat in chats:
        ChatOrganizationStore.move_session(chat.session_id, None)
    ChatOrganizationStore.move_session(chats[2].session_id, None, 0)
    placements = ChatOrganizationStore.snapshot(workspace)["placements"]
    ordered_chats = sorted(placements.values(), key=lambda item: item["order"])
    assert [placement["session_id"] for placement in ordered_chats] == [
        chats[2].session_id, chats[0].session_id, chats[1].session_id,
    ]


def test_session_organization_listing_handles_five_hundred_chats(tmp_path) -> None:
    workspace = str(tmp_path)
    for index in range(500):
        _chat(workspace, f"chat {index}")

    summaries = SessionStore.summaries(limit=500)
    assert len(summaries) == 500
    assert all("folder_id" in summary and "sort_order" in summary for summary in summaries)


def test_folder_delete_promotes_children_and_chats_without_deleting_them(tmp_path) -> None:
    workspace = str(tmp_path)
    parent = ChatOrganizationStore.create_folder(workspace, "Parent")
    child = ChatOrganizationStore.create_folder(workspace, "Child", parent["id"])
    chat = _chat(workspace, "keep this")
    ChatOrganizationStore.move_session(chat.session_id, parent["id"])

    ChatOrganizationStore.delete_folder(parent["id"])

    snapshot = ChatOrganizationStore.snapshot(workspace)
    promoted = next(folder for folder in snapshot["folders"] if folder["id"] == child["id"])
    assert promoted["parent_id"] is None
    assert snapshot["placements"][chat.session_id]["folder_id"] is None
    assert SessionStore.path_for(chat.session_id) is not None


def test_trash_restore_preserves_folder_placement(tmp_path) -> None:
    workspace = str(tmp_path)
    folder = ChatOrganizationStore.create_folder(workspace, "Saved")
    chat = _chat(workspace, "recover me")
    ChatOrganizationStore.move_session(chat.session_id, folder["id"])

    count, trash = SessionStore.move_to_trash([chat.session_id])
    assert count == 1
    assert ChatOrganizationStore.placement(chat.session_id) is None

    restored = SessionStore.restore_from_trash_details(Path(trash).name)
    assert restored == [chat.session_id]
    assert ChatOrganizationStore.placement(chat.session_id)["folder_id"] == folder["id"]


def test_duplicate_keeps_messages_and_attachments_but_drops_live_run_records(tmp_path) -> None:
    source = SessionStore(str(tmp_path), model="test:model")
    source.append({
        "type": "message",
        "message": {
            "role": "user",
            "content": "hello",
            "run_id": "live-run",
            "attachments": [{"name": "pixel.png", "mime_type": "image/png", "data": "cG5n"}],
        },
    })
    source.append({"type": "agent_activity", "event": {"run_id": "live-run"}})
    clone = SessionStore.duplicate(source.path)

    messages = SessionStore.load(clone.path)
    assert messages[0]["content"] == "hello"
    assert messages[0]["attachments"][0]["name"] == "pixel.png"
    assert "run_id" not in messages[0]
    assert "live-run" not in clone.path.read_text(encoding="utf-8")
    assert SessionStore.header(clone.path)["duplicated_from"] == source.session_id


def test_export_messages_are_full_length_and_privacy_filtered(tmp_path) -> None:
    chat = SessionStore(str(tmp_path))
    chat.append({"type": "message", "message": {"role": "system", "content": "secret"}})
    chat.append({
        "type": "message",
        "message": {"role": "assistant", "content": "x" * 8_000, "_display_reasoning": "why"},
    })
    chat.append({"type": "message", "message": {"role": "tool", "name": "bash", "content": "details"}})

    visible = SessionStore.export_messages(chat.path)
    technical = SessionStore.export_messages(
        chat.path, include_reasoning=True, include_tool_details=True,
    )

    assert len(visible[0]["content"]) == 8_000
    assert "reasoning" not in visible[0]
    assert visible[1] == {"role": "tool", "name": "bash", "content": ""}
    assert technical[0]["reasoning"] == "why"
    assert technical[1]["content"] == "details"
    assert all(message["role"] != "system" for message in technical)


def test_new_session_endpoint_returns_explicit_acknowledgement(tmp_path) -> None:
    core = AgentCore(cwd=str(tmp_path), config={})
    old_id = core.session.path.stem
    server.app.state.service = server.ChatService(core)

    result = server.session_new({"reason": "clear_chat"})

    assert result["ok"] is True
    assert result["reason"] == "clear_chat"
    assert result["session_info"]["session_id"] != old_id
    assert result["session_info"]["session_id"] == core.session.path.stem


def test_team_activity_restores_separately_without_credentials(tmp_path) -> None:
    store = SessionStore(str(tmp_path))
    store.append({
        "type": "agent_activity",
        "event": {
            "type": "orchestration_started",
            "run_id": "run-1",
            "worker_id": "worker-1",
            "state": "dispatching",
        },
    })
    store.append({
        "type": "agent_activity",
        "event": {
            "type": "agent_job_started",
            "run_id": "run-1",
            "worker_id": "worker-1",
            "job_id": "research",
            "agent_name": "Researcher",
            "role": "researcher",
            "provider": "Hosted",
            "model": "exact-model",
            "goal": "Inspect evidence",
        },
    })
    store.append({
        "type": "agent_activity",
        "event": {
            "type": "agent_job_completed",
            "run_id": "run-1",
            "worker_id": "worker-1",
            "state": "completed",
            "result": {
                "job_id": "research",
                "agent_name": "Researcher",
                "role": "researcher",
                "output": "Finding",
                "reasoning_text": "Provider-supplied thought",
                "evidence": ["Sources.swift:12"],
                "prompt_tokens": 20,
                "completion_tokens": 5,
                "elapsed_ms": 42,
            },
        },
    })
    store.append({
        "type": "agent_activity",
        "event": {
            "type": "orchestration_completed",
            "run_id": "run-1",
            "worker_id": "worker-1",
            "state": "completed",
        },
    })

    restored = SessionStore.agent_activity(store.path)

    assert restored["orchestration_state"] == "completed"
    assert restored["worker_id"] == "worker-1"
    assert restored["activities"][0]["reasoning_text"] == "Provider-supplied thought"
    assert "api_key" not in str(restored)


def test_clear_saved_sessions_preserves_active_run_and_is_recoverable(
    tmp_path, clearable_sessions
) -> None:
    directory = str(tmp_path)
    previous = SessionStore(directory)
    previous.append({"type": "message", "message": {"role": "user", "content": "keep me"}})
    archived = SessionStore(directory)
    update_session_metadata(previous.path.stem, title="Previous work", pinned=True)
    update_session_metadata(archived.path.stem, archived=True)
    active = SessionStore(directory)

    result = clear_saved_sessions(active.path.stem)

    assert result["count"] == 2
    assert active.path.exists()
    assert SessionStore.find(active.path.stem) == active.path
    assert SessionStore.find(previous.path.stem) is None
    recovery = Path(result["recovery_path"])
    assert (recovery / previous.path.name).exists()
    assert (recovery / archived.path.name).exists()
    assert (recovery / "manifest.json").exists()
    assert session_metadata(previous.path.stem)["title"] == ""


def test_clear_sessions_endpoint_refuses_busy_service(
    tmp_path, clearable_sessions
) -> None:
    directory = str(tmp_path)
    previous = SessionStore(directory)
    core = AgentCore(cwd=directory, config={})
    service = server.ChatService(core)
    service.turn_future = Future()
    server.app.state.service = service

    try:
        server.sessions_clear()
    except HTTPException as error:
        assert error.status_code == 409
    else:
        raise AssertionError("busy session clear should be rejected")

    assert core.session.path.exists()
    assert previous.path.exists()
    assert service.busy is True


def test_session_loading_has_file_and_record_limits(tmp_path, monkeypatch) -> None:
    path = sessions_module.SESSIONS_DIR / "oversized.jsonl"
    path.parent.mkdir(parents=True)
    path.write_text('{"type":"message","message":{"role":"user","content":"long"}}\n')

    monkeypatch.setattr(sessions_module, "MAX_SESSION_BYTES", 16)
    with pytest.raises(SessionTooLargeError):
        SessionStore.load(path)

    monkeypatch.setattr(sessions_module, "MAX_SESSION_BYTES", 1_000)
    monkeypatch.setattr(sessions_module, "MAX_SESSION_LINE_BYTES", 16)
    with pytest.raises(SessionTooLargeError):
        SessionStore.load(path)


def test_restore_refuses_a_traversal_batch(tmp_path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "stolen.jsonl").write_text("{}\n")

    assert SessionStore.restore_from_trash("../outside") == 0
    assert (outside / "stolen.jsonl").exists()


def test_session_listing_ignores_symlinks_outside_the_store(tmp_path) -> None:
    outside = tmp_path / "outside.jsonl"
    outside.write_text(
        '{"type":"message","message":{"role":"user","content":"private"}}\n'
    )
    sessions_module.SESSIONS_DIR.mkdir(parents=True)
    (sessions_module.SESSIONS_DIR / "linked.jsonl").symlink_to(outside)

    assert SessionStore.list_sessions() == []
    assert SessionStore.path_for("linked") is None


def test_retry_branches_without_modifying_original(tmp_path) -> None:
    core = AgentCore(cwd=str(tmp_path), config={})
    core.messages = [core.system_message()]
    history = [
        {"role": "user", "content": "first"},
        {"role": "assistant", "content": "one"},
        {"role": "user", "content": "second"},
        {"role": "assistant", "content": "two"},
    ]
    for message in history:
        core._add_message(message)
    original_path = core.session.path
    events: list[dict] = []
    core.on_event(events.append)
    core._run_response_loop = lambda decider=None, **kwargs: None  # type: ignore[method-assign]

    core.retry_last_response()

    assert core.session.path != original_path
    assert SessionStore.load(original_path) == history
    assert SessionStore.load(core.session.path) == history[:3]
    assert core.messages[1:] == history[:3]
    started = next(event for event in events if event["type"] == "session_started")
    assert started["reason"] == "retry"


def test_metadata_sort_search_and_archive(tmp_path) -> None:
    directory = str(tmp_path)
    first = SessionStore(directory)
    first.append({"type": "message", "message": {"role": "user", "content": "alpha"}})
    second = SessionStore(directory)
    second.append({"type": "message", "message": {"role": "user", "content": "beta"}})

    update_session_metadata(first.path.stem, title="Pinned work", pinned=True)
    update_session_metadata(second.path.stem, archived=True)

    visible = AgentCore.list_session_summaries()
    assert [item["id"] for item in visible] == [first.path.stem]
    assert visible[0]["title"] == "Pinned work"
    assert visible[0]["pinned"] is True
    assert AgentCore.list_session_summaries(query="pinned")[0]["id"] == first.path.stem

    all_sessions = AgentCore.list_session_summaries(include_archived=True)
    assert {item["id"] for item in all_sessions} == {first.path.stem, second.path.stem}
    assert session_metadata(second.path.stem)["archived"] is True
    assert (sessions_module.SESSIONS_DIR.parent / "session-metadata.json").exists()


def test_session_detail_includes_export_provenance(tmp_path) -> None:
    directory = str(tmp_path)
    core = AgentCore(cwd=directory, model="qwen:test", config={})
    core._add_message({"role": "user", "content": "document this"})
    core.session.append({"type": "model", "model": "qwen:updated"})
    server.app.state.service = server.ChatService(core)

    detail = server.session_detail(core.session.path.stem)

    assert detail["cwd"] == directory
    assert detail["model"] == "qwen:updated"
    assert detail["started"]
    assert detail["messages"] == [{"role": "user", "content": "document this"}]


def test_metadata_endpoint_validates_and_updates_fields(tmp_path) -> None:
    core = AgentCore(cwd=str(tmp_path), config={})
    server.app.state.service = server.ChatService(core)
    session_id = core.session.path.stem

    result = server.session_metadata_update(
        session_id,
        {"title": " Release notes ", "pinned": True},
    )

    assert result["title"] == "Release notes"
    assert result["pinned"] is True
    trimmed = server.session_metadata_update(
        session_id,
        {"title": "  " + "x " * 100},
    )
    assert len(trimmed["title"]) == 120
    assert "  " not in trimmed["title"]
    try:
        server.session_metadata_update(session_id, {"archived": "yes"})
    except HTTPException as invalid:
        assert invalid.status_code == 422
    else:
        raise AssertionError("invalid archived value was accepted")
    with pytest.raises(HTTPException) as unknown:
        server.session_metadata_update(session_id, {"colour": "blue"})
    assert unknown.value.status_code == 422
    try:
        server.session_metadata_update(session_id, {"archived": True})
    except HTTPException as active:
        assert active.status_code == 409
    else:
        raise AssertionError("active session was archived")
