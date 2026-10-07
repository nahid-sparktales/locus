"""Bounded retrieval for automatic context keeps current, scoped file evidence."""
from __future__ import annotations

import array
import hashlib
import sqlite3
import time
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from ollama_code import (
    knowledge,
    knowledge_embeddings,
    knowledge_retrieval,
    memory_embeddings,
    server,
)
from ollama_code.knowledge import KnowledgeStore
from ollama_code.knowledge_retrieval import RetrievalStopped


@pytest.fixture
def store(tmp_path, monkeypatch):
    monkeypatch.setattr(knowledge_embeddings, "schedule_embeddings", lambda _store: None)
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "guide.md").write_text("# Release\ncanary release uses signed packages\n")
    store = KnowledgeStore(str(root))
    store.reindex()
    return store


def add_document(store, *, text="canary procedure", name="manual.pdf"):
    store.configure(documents_enabled=True)
    raw = ("opaque document " + name).encode()
    (store.root / name).write_bytes(raw)
    store.index_extracted_document(name, hashlib.sha256(raw).hexdigest(),
        [{"text": text, "locator": {"kind": "pdf", "page": 1, "page_index": 0}, "method": "embedded"}], "pdf")


def test_adaptive_setting_defaults_true_survives_omission_and_preserves_false(store):
    assert store.settings()["adaptive_rag_enabled"] is True
    assert store.configure(adaptive_rag_enabled=False)["adaptive_rag_enabled"] is False
    assert store.configure(rerank_model="local")["adaptive_rag_enabled"] is False
    assert KnowledgeStore(str(store.root)).settings()["adaptive_rag_enabled"] is False
    assert store.configure(adaptive_rag_enabled=True)["adaptive_rag_enabled"] is True


def test_old_settings_schema_migrates_adaptive_default_true(tmp_path, monkeypatch):
    monkeypatch.setattr(knowledge_embeddings, "schedule_embeddings", lambda _store: None)
    root = tmp_path / "root"
    root.mkdir()
    path = tmp_path / "legacy.sqlite3"
    with sqlite3.connect(path) as connection:
        connection.executescript("""
            CREATE TABLE settings(singleton INTEGER PRIMARY KEY, workspace TEXT NOT NULL,
                enabled INTEGER DEFAULT 1, embedding_model TEXT DEFAULT '',
                ollama_host TEXT DEFAULT 'http://localhost:11434',
                vector_generation INTEGER DEFAULT 0, last_indexed REAL, last_error TEXT);
            INSERT INTO settings(singleton,workspace) VALUES(1,'');
        """)
    assert KnowledgeStore(str(root), path=path).settings()["adaptive_rag_enabled"] is True


def test_adaptive_api_updates_keep_explicit_false_and_omitted_value(store):
    service = SimpleNamespace(core=SimpleNamespace(workspace_root=str(store.root), cwd=str(store.root)))
    client = TestClient(server.create_app(chat_service=service, auth_token="local-token"))
    try:
        headers = {"x-locus-token": "local-token"}
        response = client.post("/api/knowledge/settings", headers=headers, json={"adaptive_rag_enabled": False})
        assert response.status_code == 200
        assert response.json()["adaptive_rag_enabled"] is False
        response = client.post("/api/knowledge/settings", headers=headers, json={"exclusions": []})
        assert response.json()["adaptive_rag_enabled"] is False
    finally:
        client.close()


@pytest.mark.parametrize("cold", [True, False])
def test_automatic_search_never_reindexes_cold_or_old_index(store, monkeypatch, cold):
    with store._connect() as connection:
        connection.execute("UPDATE settings SET last_indexed=?,index_version=?", (None if cold else time.time(), "old"))
    monkeypatch.setattr(store, "reindex", lambda: pytest.fail("Automatic search must not reindex"))
    result = store.search_with_diagnostics("canary", allow_reindex=False)
    assert result["results"] == []
    assert result["diagnostics"]["partial"] is True
    assert result["diagnostics"]["partial_reasons"] == ["index_not_ready"]


def test_files_only_excludes_legacy_memories_before_ranking(store):
    with store._connect() as connection:
        connection.executemany("INSERT INTO memories(id,title,content,created_at,updated_at) VALUES(?,?,?,?,?)",
            [(f"old-{i}", "canary", "canary", i, i) for i in range(30)])
    ordinary = store.search_with_diagnostics("canary", pack=False)
    assert any(item["kind"] == "memory" for item in ordinary["results"])
    result = store.search_with_diagnostics("canary", files_only=True, pack=False)
    assert result["results"] and all(item["kind"] == "file" for item in result["results"])
    assert result["diagnostics"]["lexical_candidates"] == len(result["results"])


def test_source_filter_precedes_lexical_limit(store):
    for i in range(30):
        (store.root / f"noise{i:02d}.txt").write_text("canary")
    store.reindex()
    add_document(store, text="canary " + "other " * 200)
    result = store.search_with_diagnostics("canary", sources=("documents",), files_only=True, pack=False)
    assert [item["path"] for item in result["results"]] == ["manual.pdf"]
    assert result["diagnostics"]["lexical_candidates"] == 1
    workspace = store.search_with_diagnostics("canary", sources=("workspace",), pack=False)
    assert workspace["results"] and all(item["format"] == "text" for item in workspace["results"])
    assert len(workspace["results"]) <= 24
    assert store.search_with_diagnostics("canary", sources=())["results"] == []


def test_source_filter_precedes_vector_scan_bound(store, monkeypatch):
    add_document(store)
    store.configure(embedding_model="embed")
    with store._connect() as connection:
        connection.execute("UPDATE chunks SET embedding=?,vector_generation=?", (
            array.array("f", [1, 0]).tobytes(), store.settings()["vector_generation"]))
    monkeypatch.setattr(knowledge, "MAX_CHUNKS", 1)
    monkeypatch.setattr(knowledge, "embed_texts", lambda *_: [[1, 0]])
    result = store.search_with_diagnostics("unmatched", sources=("documents",), pack=False)
    assert [item["path"] for item in result["results"]] == ["manual.pdf"]
    assert result["diagnostics"]["semantic_candidates"] == 1


@pytest.mark.parametrize("reason", ["cancelled", "deadline_exceeded"])
def test_stopped_request_does_no_settings_io_or_indexing(store, monkeypatch, reason):
    monkeypatch.setattr(store, "settings", lambda: pytest.fail("Stopped request should do no work"))
    controls = {"should_stop": lambda: True} if reason == "cancelled" else {"deadline": time.monotonic() - 1}
    result = store.search_with_diagnostics("canary", **controls)
    assert result["results"] == []
    assert result["diagnostics"]["partial_reasons"] == [reason]
    assert result["diagnostics"][reason] is True


@pytest.mark.parametrize("reason", ["cancelled", "deadline_exceeded"])
def test_interrupted_embedding_preserves_validated_lexical_fallback(store, monkeypatch, reason):
    store.configure(embedding_model="embed", rerank_model="ranker")
    clock = [100.0]
    cancelled = [False]
    monkeypatch.setattr(knowledge.time, "monotonic", lambda: clock[0])

    def embed(*_, **controls):
        assert controls["deadline"] == 105
        assert controls["should_stop"]() is False
        if reason == "cancelled":
            cancelled[0] = True
        else:
            clock[0] = 106
        return [[1, 0]]

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    monkeypatch.setattr(knowledge_retrieval, "rerank_candidates", lambda *_a, **_k: pytest.fail("Do not rerank after stop"))
    result = store.search_with_diagnostics("canary", deadline=105, should_stop=lambda: cancelled[0], pack=False)
    assert [item["path"] for item in result["results"]] == ["guide.md"]
    assert result["diagnostics"]["partial_reasons"] == [reason]
    assert result["diagnostics"][reason] is True
    assert result["diagnostics"]["reranked"] is False


def test_deadline_fallback_drops_source_changed_during_embedding(store, monkeypatch):
    store.configure(embedding_model="embed")
    cancelled = [False]

    def embed(*_, **_controls):
        (store.root / "guide.md").write_text("replacement text")
        cancelled[0] = True
        return [[1, 0]]

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    result = store.search_with_diagnostics("canary", should_stop=lambda: cancelled[0])
    assert result["results"] == []
    assert result["diagnostics"]["cancelled"] is True


@pytest.mark.parametrize("mutation", ["exclude", "delete", "disable", "source", "old_version"])
def test_public_revalidation_applies_current_policy_and_index(store, mutation):
    results = store.search_with_diagnostics("canary", files_only=True, pack=False)["results"]
    assert results and "parent_content" in results[0]
    if mutation == "exclude":
        store.configure(exclusions=["guide.md"])
    elif mutation == "delete":
        store.delete_all()
    elif mutation == "disable":
        store.configure(enabled=False)
    elif mutation == "source":
        (store.root / "guide.md").write_text("replacement")
    else:
        with store._connect() as connection:
            connection.execute("UPDATE settings SET index_version='old'")
    assert store.revalidate_results(results) == []


def test_raw_candidates_keep_parent_metadata_until_explicit_packing(store):
    (store.root / "guide.md").write_text("# Release\n" + "canary release signed packages.\n" * 120)
    store.reindex()
    raw = store.search_with_diagnostics("canary", pack=False)["results"]
    assert len(raw) >= 2
    assert all("parent_content" in item and "source_stat" in item for item in raw)
    assert all(not item.get("expanded_parent") for item in raw)
    packed = store.pack_results(store.revalidate_results(raw), limit=2, byte_budget=24_000)
    assert packed and packed[0]["expanded_parent"] is True
    assert all("source_stat" not in item and "parent_content" not in item for item in packed)
    assert all("parent_content" in item for item in raw)
    assert store.pack_results(raw, byte_budget=0) == []


def test_embed_transport_uses_caller_deadline_and_checks_cancellation(monkeypatch):
    calls, cancelled = [], [False]
    monkeypatch.setattr(knowledge.time, "monotonic", lambda: 100)

    class Transport:
        def __init__(self, _host):
            pass

        def _json(self, path, payload, end):
            calls.append((path, end))
            cancelled[0] = True
            return {"embeddings": [[1, 0]]}

    monkeypatch.setattr(memory_embeddings, "_LocalTransport", Transport)
    with pytest.raises(RetrievalStopped, match="cancelled"):
        knowledge.embed_texts("embed", "http://localhost:11434", ["canary"],
                             deadline=102, should_stop=lambda: cancelled[0])
    assert calls == [("/api/embed", 102)]


def test_rerank_stops_between_inventory_and_chat_and_keeps_caller_deadline(monkeypatch):
    calls, cancelled = [], [False]
    monkeypatch.setattr(knowledge_retrieval.time, "monotonic", lambda: 100)

    class Transport:
        def __init__(self, _host):
            pass

        def _json(self, path, payload, end):
            calls.append((path, end))
            cancelled[0] = True
            return {"models": [{"name": "ranker"}]}

    monkeypatch.setattr(knowledge_retrieval, "_LocalTransport", Transport)
    with pytest.raises(RetrievalStopped, match="cancelled"):
        knowledge_retrieval.rerank_candidates("canary", [{"id": "file:1", "snippet": "evidence"}],
            model="ranker", host="http://localhost:11434", deadline=102, should_stop=lambda: cancelled[0])
    assert calls == [("/api/tags", 102)]


def test_lexical_callback_precedes_models_and_preserves_ranked_scoped_snapshot(store, monkeypatch):
    store.configure(embedding_model="embed")
    add_document(store)
    captured = []

    def lexical(rows):
        assert rows and all(item["format"] == "text" and item["score"] > 0 for item in rows)
        captured.extend(rows)
        # The callback owns its copy and cannot replace normal search evidence.
        rows[0]["snippet"] = "callback mutation"

    def embed(*_, **_controls):
        assert captured
        raise RuntimeError("local model unavailable")

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    response = store.search_with_diagnostics("canary", sources=("workspace",), files_only=True,
                                            on_lexical=lexical, pack=False)
    assert len(captured) == 1
    assert "callback mutation" not in response["results"][0]["snippet"]
    assert response["diagnostics"]["fallbacks"] == ["semantic_unavailable:RuntimeError"]


@pytest.mark.parametrize("reason", ["deadline", "cancelled"])
def test_final_revalidation_keeps_unchanged_stat_but_never_hashes_changed_file_after_stop(store, monkeypatch, reason):
    from pathlib import Path

    unchanged = store.root / "unchanged.md"
    unchanged.write_text("canary reference stays current")
    store.reindex()
    rows = store.search_with_diagnostics("canary", files_only=True, pack=False)["results"]
    assert {row["path"] for row in rows} == {"guide.md", "unchanged.md"}
    changed = store.root / "guide.md"
    changed.write_text("canary replacement " * 10_000)
    original_open = Path.open

    def no_rehash(path, *args, **kwargs):
        if path == changed:
            pytest.fail("Expired revalidation must not read/hash the changed source")
        return original_open(path, *args, **kwargs)

    monkeypatch.setattr(Path, "open", no_rehash)
    controls = {"deadline": time.monotonic() - 1} if reason == "deadline" else {"should_stop": lambda: True}
    valid = store.revalidate_results(rows, **controls)
    assert [row["path"] for row in valid] == ["unchanged.md"]
