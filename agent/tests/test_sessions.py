"""Session lifecycle, branching and metadata tests.

Every agent data path is redirected into a per-test temp directory by
``conftest.py``. This module used to point ``sessions.SESSIONS_DIR`` at a temp
directory itself, with a raw global assignment made inside each test body — so a
test that forgot the call, or that built a store before making it, swept the
developer's real transcripts into the trash.
"""
from __future__ import annotations

from concurrent.futures import Future
from pathlib import Path

import pytest
from fastapi import HTTPException

import ollama_code.sessions as sessions_module
from ollama_code import server
from ollama_code.core import AgentCore
from ollama_code.sessions import (
    SessionStore,
    SessionTooLargeError,
    clear_saved_sessions,
    session_metadata,
    update_session_metadata,
)


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
