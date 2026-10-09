"""Turn preflight must not transfer or reconstruct the ongoing transcript."""
from __future__ import annotations

import json

import pytest
from fastapi import APIRouter, FastAPI, HTTPException
from fastapi.testclient import TestClient

from ollama_code.api.sessions import register_routes, session_execution_context
from ollama_code.sessions import SessionMeta, SessionStore


def test_execution_context_retains_checkout_and_fresh_ownership(tmp_path):
    chat = SessionStore(str(tmp_path), "fixture:model")
    task = {"id": "checkout", "session_id": chat.session_id}
    metadata = {
        "agent_profile_id": "saved-profile",
        "workspace_root": str(tmp_path),
        "execution_path": str(tmp_path / "checkout"),
        "environment": {"type": "worktree", "isolation": "managed_worktree"},
        "task": task,
    }
    SessionMeta.update(chat.session_id, **metadata)

    context = session_execution_context(chat.session_id)
    assert context == {"id": chat.session_id, "cwd": str(tmp_path), "archived": False, **metadata}

    SessionMeta.update(chat.session_id, agent_profile_id="replacement", archived=True)
    updated = session_execution_context(chat.session_id)
    assert updated["agent_profile_id"] == "replacement"
    assert updated["archived"] is True


def test_execution_context_does_not_read_history_or_export_content(tmp_path, monkeypatch):
    chat = SessionStore(str(tmp_path), "fixture:model")
    chat.append({"type": "message", "message": {"role": "user", "content": "private transcript text"}})
    chat.append({"type": "model", "model": "other:model"})
    SessionMeta.update(chat.session_id, title="private title")

    def unexpected(*args, **kwargs):
        pytest.fail("Turn preflight reconstructed transcript content")

    for name in ("load", "provenance", "preview", "agent_activity"):
        monkeypatch.setattr(SessionStore, name, unexpected)

    context = session_execution_context(chat.session_id)
    assert context["cwd"] == str(tmp_path)
    assert context["workspace_root"] is None
    assert context["agent_profile_id"] is None
    assert context["task"] is None
    assert not {"messages", "preview", "title", "model", "agent_activities"} & context.keys()
    assert "private transcript text" not in json.dumps(context)
    assert "private title" not in json.dumps(context)


@pytest.mark.parametrize("session_id", ["missing", "../outside", "sub/chat", ".hidden", "other\\chat"])
def test_execution_context_rejects_unknown_and_escaping_sessions(session_id):
    with pytest.raises(HTTPException) as error:
        session_execution_context(session_id)
    assert error.value.status_code == 404


def test_execution_context_rejects_symlink_outside_session_directory(tmp_path):
    chat = SessionStore(str(tmp_path))
    external = tmp_path / "outside.jsonl"
    external.write_text('{"type":"meta","cwd":"outside"}\n')
    chat.path.unlink()
    chat.path.symlink_to(external)
    with pytest.raises(HTTPException) as error:
        session_execution_context(chat.session_id)
    assert error.value.status_code == 404


def test_execution_context_http_route(tmp_path):
    chat = SessionStore(str(tmp_path))
    app = FastAPI()
    router = APIRouter()
    register_routes(router)
    app.include_router(router)
    with TestClient(app) as client:
        response = client.get(f"/api/sessions/{chat.session_id}/execution-context")
        assert response.status_code == 200
        assert response.json()["id"] == chat.session_id
        assert response.json()["cwd"] == str(tmp_path)
        assert client.get("/api/sessions/missing/execution-context").status_code == 404
