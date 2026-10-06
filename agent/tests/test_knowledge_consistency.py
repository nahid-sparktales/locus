"""Exclusions and removals must revoke in-flight document search candidates."""
from __future__ import annotations

import pytest

from ollama_code import document_library, knowledge, knowledge_embeddings, knowledge_retrieval
from ollama_code.knowledge import KnowledgeStore


@pytest.fixture
def document(tmp_path, monkeypatch):
    class ManualCoordinator:
        def register(self, _store):
            pass

    monkeypatch.setattr(document_library, "_coordinator", lambda: ManualCoordinator())
    monkeypatch.setattr(knowledge_embeddings, "schedule_embeddings", lambda _store: None)
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "release.csv").write_text("release,method\ncanary,signed deployment packages\n")
    store = KnowledgeStore(str(root))
    store.configure(documents_enabled=True)
    library = document_library.DocumentStore(str(root), start_worker=False)
    job = library.submit("release.csv")
    library._execute(job["id"])
    assert library.job(job["id"])["state"] == "ready"
    store.reindex()
    assert store.search("canary")
    return store, library, job["document_id"]


@pytest.mark.parametrize("stage", ["query_embedding", "reranking"])
@pytest.mark.parametrize("mutation", ["remove_document", "clear_index", "exclude_document"])
def test_document_removal_during_retrieval_cannot_return_or_forward_old_candidates(document, monkeypatch, stage, mutation):
    store, library, identifier = document
    store.configure(embedding_model="local-embed", rerank_model="local-ranker")
    reranked, mutations = [], []

    def revoke():
        mutations.append(mutation)
        if mutation == "remove_document":
            store.remove_document_chunks("release.csv")
        elif mutation == "clear_index":
            store.delete_all()
        else:
            library.exclude(identifier, True)

    def embed(*_):
        if stage == "query_embedding":
            revoke()
        return [[1.0, .5]]

    def rerank(query, candidates, **_):
        reranked.extend(item["path"] for item in candidates)
        if stage == "reranking":
            revoke()
        return candidates

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    monkeypatch.setattr(knowledge_retrieval, "rerank_candidates", rerank)
    response = store.search_with_diagnostics("canary")
    assert mutations == [mutation]
    assert response["results"] == []
    assert store.settings()["chunk_count"] == 0
    if stage == "query_embedding":
        assert reranked == []
    else:
        assert reranked and set(reranked) == {"release.csv"}


@pytest.mark.parametrize("model", ["", "replacement-ranker"])
def test_reranker_dispatch_uses_settings_changed_during_query_embedding(document, monkeypatch, model):
    store, _, _ = document
    store.configure(embedding_model="local-embed", rerank_model="previous-ranker")
    calls = []

    def embed(*_):
        store.configure(rerank_model=model, ollama_host="http://127.0.0.1:11435")
        return [[1.0, .5]]

    def rerank(query, candidates, **settings):
        calls.append(settings)
        return candidates

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    monkeypatch.setattr(knowledge_retrieval, "rerank_candidates", rerank)
    assert store.search_with_diagnostics("canary")["results"]
    assert calls == ([{"model": model, "host": "http://127.0.0.1:11435"}] if model else [])
