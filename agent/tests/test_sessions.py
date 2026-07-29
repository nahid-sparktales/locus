"""Session lifecycle, branching and metadata tests."""
from __future__ import annotations

import tempfile
from concurrent.futures import Future
from pathlib import Path

import ollama_code.sessions as sessions_module
from fastapi import HTTPException
from ollama_code.core import AgentCore
from ollama_code import server
from ollama_code.sessions import (
    SessionStore,
    clear_saved_sessions,
    session_metadata,
    update_session_metadata,
)


def _isolated_sessions(directory: str) -> None:
    sessions_module.SESSIONS_DIR = Path(directory) / ".ollama-code" / "sessions"


def test_new_session_resets_transient_state() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
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


def test_new_session_endpoint_returns_explicit_acknowledgement() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
        core = AgentCore(cwd=directory, config={})
        old_id = core.session.path.stem
        server.app.state.service = server.ChatService(core)

        result = server.session_new({"reason": "clear_chat"})

        assert result["ok"] is True
        assert result["reason"] == "clear_chat"
        assert result["session_info"]["session_id"] != old_id
        assert result["session_info"]["session_id"] == core.session.path.stem


def test_clear_saved_sessions_preserves_active_run_and_is_recoverable() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
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


def test_clear_sessions_endpoint_does_not_interrupt_busy_service() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
        previous = SessionStore(directory)
        core = AgentCore(cwd=directory, config={})
        service = server.ChatService(core)
        service.turn_future = Future()
        server.app.state.service = service

        result = server.sessions_clear()

        assert result["ok"] is True
        assert result["count"] == 1
        assert result["job_active"] is True
        assert result["preserved_session_id"] == core.session.path.stem
        assert core.session.path.exists()
        assert not previous.path.exists()
        assert service.busy is True


def test_retry_branches_without_modifying_original() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
        core = AgentCore(cwd=directory, config={})
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
        core._run_response_loop = lambda decider=None: None  # type: ignore[method-assign]

        core.retry_last_response()

        assert core.session.path != original_path
        assert SessionStore.load(original_path) == history
        assert SessionStore.load(core.session.path) == history[:3]
        assert core.messages[1:] == history[:3]
        started = next(event for event in events if event["type"] == "session_started")
        assert started["reason"] == "retry"


def test_metadata_sort_search_and_archive() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
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


def test_session_detail_includes_export_provenance() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
        core = AgentCore(cwd=directory, model="qwen:test", config={})
        core._add_message({"role": "user", "content": "document this"})
        core.session.append({"type": "model", "model": "qwen:updated"})
        server.app.state.service = server.ChatService(core)

        detail = server.session_detail(core.session.path.stem)

        assert detail["cwd"] == directory
        assert detail["model"] == "qwen:updated"
        assert detail["started"]
        assert detail["messages"] == [{"role": "user", "content": "document this"}]


def test_metadata_endpoint_validates_and_updates_fields() -> None:
    with tempfile.TemporaryDirectory() as directory:
        _isolated_sessions(directory)
        core = AgentCore(cwd=directory, config={})
        server.app.state.service = server.ChatService(core)
        session_id = core.session.path.stem

        result = server.session_metadata_update(
            session_id,
            {"title": " Release notes ", "pinned": True},
        )

        assert result["title"] == "Release notes"
        assert result["pinned"] is True
        try:
            server.session_metadata_update(session_id, {"archived": "yes"})
        except HTTPException as invalid:
            assert invalid.status_code == 422
        else:
            raise AssertionError("invalid archived value was accepted")
        try:
            server.session_metadata_update(session_id, {"archived": True})
        except HTTPException as active:
            assert active.status_code == 409
        else:
            raise AssertionError("active session was archived")


if __name__ == "__main__":
    tests = [value for key, value in sorted(globals().items()) if key.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)} tests passed")
