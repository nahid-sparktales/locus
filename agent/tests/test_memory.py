from __future__ import annotations

import sqlite3
import stat
import time

import pytest

from ollama_code.memory import MemoryError, MemoryVault


def vault(tmp_path, name="memory.sqlite3", key=b"k" * 32) -> MemoryVault:
    return MemoryVault(tmp_path / name, key=key)


def test_memory_content_is_authenticated_ciphertext_at_rest(tmp_path) -> None:
    store = vault(tmp_path)
    store.save(
        {
            "title": "Private preference",
            "content": "Never put the secret launch phrase in logs",
            "scope": "personal",
        }
    )

    for database_file in tmp_path.glob("memory.sqlite3*"):
        assert b"secret launch phrase" not in database_file.read_bytes()
    assert store.search("launch phrase", scopes=["personal"])[0]["scope"] == "personal"

    wrong_key = vault(tmp_path, key=b"x" * 32)
    with pytest.raises(MemoryError, match="could not be decrypted"):
        wrong_key.list(scopes=["personal"])


def test_memory_uses_a_user_only_local_key_without_keychain(tmp_path) -> None:
    key_path = tmp_path / "memory" / "master.key"
    database = tmp_path / "memory" / "memory.sqlite3"
    store = MemoryVault(database, fallback_key_path=key_path)
    saved = store.save({"content": "Persist across launches", "scope": "personal"})

    assert len(key_path.read_bytes()) == 32
    assert stat.S_IMODE(key_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(key_path.parent.stat().st_mode) == 0o700
    assert store.status()["approved_count"] == 1

    reopened = MemoryVault(database, fallback_key_path=key_path)
    assert reopened.list(scopes=["personal"])[0]["id"] == saved["id"]


def test_memory_scope_boundaries_and_just_chat_scope_selection(tmp_path) -> None:
    store = vault(tmp_path)
    one = tmp_path / "one"
    two = tmp_path / "two"
    one.mkdir()
    two.mkdir()
    store.save({"content": "personal marker", "scope": "personal"})
    store.save({"content": "workspace one marker", "scope": "workspace"}, workspace=str(one))
    store.save(
        {"content": "agent alpha marker", "scope": "agent"}, agent_id="alpha"
    )

    visible = store.list(workspace=str(one), agent_id="alpha")
    assert {item["scope"] for item in visible} == {"personal", "workspace", "agent"}
    assert store.search("workspace one", workspace=str(two), agent_id="alpha") == []
    chat_visible = store.list(
        workspace=str(one), agent_id="alpha", scopes=["personal", "agent"]
    )
    assert {item["scope"] for item in chat_visible} == {"personal", "agent"}


def test_candidates_require_approval_and_expire(tmp_path) -> None:
    store = vault(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    candidate = store.save(
        {
            "title": "Convention",
            "content": "Use tabs",
            "scope": "workspace",
            "status": "candidate",
            "reason": "The user stated it explicitly",
        },
        workspace=str(workspace),
        default_status="candidate",
    )
    assert store.search("Use tabs", workspace=str(workspace)) == []
    approved = store.approve(candidate["id"], workspace=str(workspace))
    assert approved["status"] == "approved"
    assert store.search("Use tabs", workspace=str(workspace))[0]["id"] == candidate["id"]

    expiring = store.save(
        {"content": "temporary", "scope": "workspace", "status": "candidate"},
        workspace=str(workspace),
        default_status="candidate",
    )
    with sqlite3.connect(store.path) as connection:
        connection.execute(
            "UPDATE memories SET expires_at=? WHERE id=?", (time.time() - 1, expiring["id"])
        )
    assert store.expire_candidates() == 1


def test_memory_export_import_round_trip(tmp_path) -> None:
    source = vault(tmp_path, "source.sqlite3")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    source.save({"title": "Decision", "content": "Ship on Friday", "scope": "personal"})
    document = source.export(workspace=str(workspace), agent_id="primary")

    destination = vault(tmp_path, "destination.sqlite3")
    assert destination.import_values(
        document, workspace=str(workspace), agent_id="primary"
    ) == 1
    assert destination.search("Friday", scopes=["personal"])[0]["title"] == "Decision"


def test_memory_v2_detects_and_resolves_conflicting_decisions(tmp_path) -> None:
    store = vault(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    older = store.save({
        "title": "Deployment region",
        "content": "Deploy production in Toronto.",
        "scope": "workspace",
        "kind": "decision",
        "confidence": 0.9,
    }, workspace=str(workspace))
    candidate = store.save({
        "title": "Deployment region",
        "content": "Deploy production in Montreal.",
        "scope": "workspace",
        "status": "candidate",
        "kind": "decision",
        "confidence": 1,
    }, workspace=str(workspace), default_status="candidate")

    inbox = store.list(
        workspace=str(workspace), status="candidate", scopes=["workspace"]
    )
    assert inbox[0]["conflicts"][0]["id"] == older["id"]
    approved = store.approve(
        candidate["id"], workspace=str(workspace), resolution="replace"
    )
    assert approved["kind"] == "decision" and approved["conflicts"] == []
    previous = next(item for item in store.list(
        workspace=str(workspace), status="approved", scopes=["workspace"]
    ) if item["id"] == older["id"])
    assert previous["stale"] is True
    assert previous["superseded_by"] == candidate["id"]


def test_memory_v2_hybrid_recall_keeps_vectors_encrypted(tmp_path, monkeypatch) -> None:
    store = vault(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store.save({
        "title": "Release procedure",
        "content": "Promote the canary after the grading suite passes.",
        "scope": "workspace",
        "kind": "procedure",
    }, workspace=str(workspace))

    def fake_embeddings(_model, _host, inputs):
        return [[1.0, 0.0] for _ in inputs]

    monkeypatch.setattr("ollama_code.knowledge.embed_texts", fake_embeddings)
    results = store.search(
        "shipping workflow", workspace=str(workspace),
        embedding_model="local-embed", ollama_host="http://127.0.0.1:11434",
    )
    assert results[0]["kind"] == "procedure"
    assert "semantic similarity" in results[0]["retrieval_reason"]
    assert results[0]["use_count"] == 0  # response is the pre-increment snapshot
    assert store.list(workspace=str(workspace))[0]["use_count"] == 1
    for database_file in tmp_path.glob("memory.sqlite3*"):
        assert b"local-embed" not in database_file.read_bytes()
