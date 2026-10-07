from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from ollama_code import document_library, knowledge_embeddings, server
from ollama_code.api import knowledge as api
from ollama_code.knowledge import KnowledgeStore


@pytest.fixture
def client(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    service = SimpleNamespace(core=SimpleNamespace(workspace_root=str(workspace), cwd=str(workspace)))
    client = TestClient(server.create_app(chat_service=service, auth_token="local-token"))
    yield client, workspace, {"x-locus-token": "local-token"}
    client.close()


def test_settings_expose_optional_reranker_and_reject_invalid_provider(client):
    http, workspace, headers = client
    assert http.post("/api/knowledge/settings", json={"rerank_model": "local-ranker"}).status_code == 401
    result = http.post("/api/knowledge/settings", headers=headers, json={"rerank_model": "local-ranker"})
    assert result.status_code == 200, result.text
    assert result.json()["rerank_model"] == "local-ranker"
    # Unrelated updates preserve the selected ranker; an explicit empty model disables it.
    result = http.post("/api/knowledge/settings", headers=headers, json={"exclusions": ["private/**"]})
    assert result.json()["rerank_model"] == "local-ranker"
    refused = http.post("/api/knowledge/settings", headers=headers,
                        json={"embedding_model": "local-embed", "ollama_host": "https://example.invalid"})
    assert refused.status_code == 422
    assert "only to local Ollama" in refused.json()["detail"]
    assert KnowledgeStore(str(workspace)).settings()["embedding_model"] == ""
    cleared = http.post("/api/knowledge/settings", headers=headers, json={"rerank_model": ""})
    assert cleared.json()["rerank_model"] == ""


def test_search_keeps_results_and_diagnostics_on_the_http_boundary(client, monkeypatch):
    http, workspace, headers = client
    diagnostics = {"fusion": "rrf", "semantic": "unavailable", "partial": True}
    calls = []

    class Store:
        def search_with_diagnostics(self, query, limit):
            calls.append((query, limit))
            return {"results": [{"id": "file:1", "path": "guide.md"}], "diagnostics": diagnostics}

    monkeypatch.setattr(api, "_knowledge_store", lambda *_: Store())
    response = http.get("/api/knowledge/search", headers=headers,
                        params={"query": "release steps", "workspace": str(workspace), "limit": 5})
    assert response.status_code == 200, response.text
    assert response.json()["diagnostics"] == diagnostics
    assert response.json()["results"][0]["path"] == "guide.md"
    assert calls == [("release steps", 5)]


@pytest.mark.parametrize("host", ["https://127.0.0.1:11434", "http://127.0.0.1:11434/ollama"])
def test_settings_reject_local_urls_the_transport_cannot_use(client, host):
    http, workspace, headers = client
    response = http.post("/api/knowledge/settings", headers=headers,
                         json={"embedding_model": "local-embed", "ollama_host": host})
    assert response.status_code == 422
    assert KnowledgeStore(str(workspace)).settings()["embedding_model"] == ""


@pytest.mark.parametrize("primary", [True, False])
def test_backend_lifecycle_resumes_only_primary_but_always_stops_embeddings(monkeypatch, primary):
    events = []
    monkeypatch.setenv("LOCUS_DOCUMENT_COORDINATOR", "1" if primary else "0")
    monkeypatch.setenv("LOCUS_PARENT_PID", "0")
    monkeypatch.setattr(document_library, "restore_document_jobs", lambda: events.append("restore_documents"))
    monkeypatch.setattr(knowledge_embeddings, "restore_embedding_jobs", lambda: events.append("restore_embeddings"))
    monkeypatch.setattr(document_library, "stop_document_jobs", lambda: events.append("stop_documents"))
    monkeypatch.setattr(knowledge_embeddings, "stop_embedding_jobs", lambda: events.append("stop_embeddings"))

    async def run():
        async with server.lifespan(FastAPI()):
            events.append("serving")

    asyncio.run(run())
    expected = ["restore_documents", "restore_embeddings"] if primary else []
    assert events == expected + ["serving", "stop_documents", "stop_embeddings"]
