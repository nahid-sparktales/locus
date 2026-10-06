"""Actual coordinator benchmarks are disposable; live endpoints are explicit fakes."""
from __future__ import annotations

import ast
import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from ollama_code.adaptive_retrieval_evaluation import (
    DEFAULT_CORPUS,
    _LiveModel,
    load_corpus,
    run_benchmark,
    score_answer,
    score_snapshot,
)


@pytest.fixture(scope="module")
def report():
    return run_benchmark()


def test_mixed_fixture_is_versioned_separately_from_frozen_lexical_corpus():
    manifest, files, fingerprint = load_corpus(DEFAULT_CORPUS)
    assert manifest["version"] == 1 and len(files) == 6 and len(manifest["queries"]) == 8
    assert fingerprint == "5a2f464d0e4b2655034c6a98666386862b403d4adcbf865c49c5feb5e08752a5"
    code = ast.parse(files["src/flux_runtime.py"])
    assert any(isinstance(node, ast.FunctionDef) and node.name == "retry_policy" for node in ast.walk(code))
    assert any("src/flux_runtime.py" in memory["content"] for memory in manifest["memories"])
    assert {query["category"] for query in manifest["queries"]} == {
        "memory_to_workspace", "memory_to_document", "contradiction", "direct_memory", "irrelevant", "stale", "unanswerable",
    }


def test_actual_coordinator_follow_up_recovers_file_and_document_from_memory_pointer(report):
    baseline = report["arms"]["single_pass"]
    adaptive = report["arms"]["scripted_follow_up"]
    assert baseline["summary"]["evidence_recall"] == .75
    assert adaptive["summary"]["evidence_recall"] == 1
    assert baseline["summary"]["source_recall"] == {"memory": 1, "workspace": .5, "documents": 0}
    assert adaptive["summary"]["source_recall"] == {"memory": 1, "workspace": 1, "documents": 1}
    assert baseline["summary"]["source_mrr"] == {"memory": 1, "workspace": .5, "documents": 0}
    assert adaptive["summary"]["source_mrr"] == {"memory": 1, "workspace": 1, "documents": 1}
    assert baseline["summary"]["mrr"] == adaptive["summary"]["mrr"] == 1
    assert baseline["summary"]["follow_up_rate"] == 0
    assert adaptive["summary"]["follow_up_rate"] == .75
    for arm in (baseline, adaptive):
        assert arm["summary"]["citation_validity"] == 1
        assert arm["summary"]["maximum_packed_bytes"] <= 24_000
        assert all(1 <= row["rounds"] <= 2 and row["latency_ms"] >= 0 for row in arm["queries"])
        assert all("answer" not in row and "error" not in row for row in arm["queries"])
    assert "not model decision or answer quality" in report["scope"]


def test_stale_sources_and_expired_memory_stay_absent_and_irrelevance_is_not_abstention(report):
    for arm in report["arms"].values():
        rows = {row["id"]: row for row in arm["queries"]}
        assert rows["stale_workspace"]["retrieval_abstained"] is True
        assert rows["expired_memory"]["selected_memory_ids"] == []
        assert rows["unanswerable"]["retrieval_abstained"] is True
        assert rows["irrelevant_sources"]["answerable"] is False
        assert rows["irrelevant_sources"]["retrieval_abstained"] is False
        assert rows["irrelevant_sources"]["citation_validity"] == 1
        assert all("expired-credential" not in row["selected_memory_ids"] for row in arm["queries"])
    assert report["isolation"]["learning_enabled"] is False
    assert report["isolation"]["canonical_records_unchanged"] is True
    assert report["isolation"]["real_adapter_and_coordinator"] is True
    assert report["models"]["live_answer_and_decision"] is None


def test_citation_validity_cannot_be_awarded_for_wrong_memory_revision_or_document_locator():
    query = {"relevance": [{"kind": "memory", "id": "m"}]}
    snapshot = {"results": [{"format": "csv", "id": "file:1", "path": "test.csv", "snippet": "known source", "locator": {"kind": "sheet", "cell_range": "Z999"}}],
                "memory": {"items": [{"id": "m", "revision": 99}]}}
    memories = {"m": {"revision": 1}}
    documents = {"test.csv": {"segments": [{"text": "known source", "locator": {"kind": "sheet", "cell_range": "A1"}}]}}
    assert score_snapshot(snapshot, query, {}, documents, memories)["citation_validity"] == 0


def test_mrr_follows_delivered_memory_then_packed_file_order():
    files = {"noise.py": "ordinary unrelated source", "useful.py": "needed evidence"}
    results = [{"id": name, "format": "text", "path": name, "snippet": content,
        "content_hash": hashlib.sha256(content.encode()).hexdigest(), "line_start": 1, "line_end": 1,
        "locator": {"kind": "line", "line_start": 1, "line_end": 1}} for name, content in files.items()]
    snapshot = {"results": results, "memory": {"items": [{"id": "irrelevant-memory", "revision": 1}]}}
    query = {"relevance": [{"kind": "workspace", "path": "useful.py", "line_start": 1, "line_end": 1}]}
    scores = score_snapshot(snapshot, query, files, {}, {"irrelevant-memory": {"revision": 1}})
    assert scores["first_relevant_rank"] == 3
    assert scores["mrr"] == pytest.approx(1 / 3)
    assert scores["source_mrr"] == {"memory": None, "workspace": .5, "documents": None}


def test_live_grounding_uses_actual_identity_and_exact_quotes():
    query = {"answers": ["90 seconds"], "forbidden_answers": ["30 seconds"]}
    evidence = [{"id": "current", "text": "The timeout is 90 seconds."}]
    supported = {"abstain": False, "claims": [{"text": "The timeout is 90 seconds.",
        "citations": [{"id": "current", "quote": "The timeout is 90 seconds."}]}]}
    assert score_answer(supported, query, evidence)["answer_phrase_recall"] == 1
    unsupported = {"abstain": False, "claims": [{"text": "The timeout is 90 seconds.",
        "citations": [{"id": "invented", "quote": "The timeout is 90 seconds."}]}]}
    assert score_answer(unsupported, query, evidence)["grounded_authored_claim_rate"] == 0
    unsupported["claims"][0]["citations"] = [{"id": "current", "quote": "The timeout is 30 seconds."}]
    assert score_answer(unsupported, query, evidence)["answer_phrase_recall"] == 0
    abstention = {"abstain": True, "claims": []}
    assert score_answer(abstention, {"answers": []}, evidence)["correct_abstention"] is True


def test_opt_in_live_arms_use_bounded_installed_model_requests_and_no_learning():
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, value):
            raw = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            requests.append((self.path, None))
            self.respond({"models": [{"name": "fixture-model:latest"}]})

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append((self.path, payload))
            data = json.loads(payload["messages"][-1]["content"])
            query = data["question"]
            if "search" in payload["format"]["properties"]:
                if "Orchid" in query:
                    answer = {"search": True, "query": "Flux retry backoff attempts", "missing_information": "Need recovery settings", "sources": ["workspace"]}
                elif "Harbor" in query:
                    answer = {"search": True, "query": "Pilot boarding wind limit", "missing_information": "Need the threshold", "sources": ["documents"]}
                else:
                    answer = {"search": False, "query": "", "missing_information": "", "sources": []}
            else:
                phrases = ("40 seconds", "four attempts") if "Orchid" in query else (
                    ("17 metres per second",) if "Harbor" in query else (
                        ("90 seconds",) if "Beacon" in query else (
                            ("concise bullet points", "source citations") if "reporting" in query else ())))
                claims = [{"text": phrase, "citations": [{"id": item["id"], "quote": item["text"]}]}
                    for phrase in phrases for item in data["evidence"] if phrase in item["text"]]
                answer = {"abstain": not bool(claims), "claims": claims}
            self.respond({"done": True, "message": {"content": json.dumps(answer)}})

    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    try:
        report = run_benchmark(live_model="fixture-model", live_host=f"http://127.0.0.1:{http.server_port}")
    finally:
        http.shutdown()
        http.server_close()
        thread.join(timeout=2)
    assert {path for path, _ in requests} == {"/api/tags", "/api/chat"}
    assert sum(path == "/api/tags" for path, _ in requests) == 1
    assert sum(path == "/api/chat" for path, _ in requests) == 24  # 8 single + 8 decisions + 8 final answers.
    assert all(payload is None or payload["model"] == "fixture-model" for _, payload in requests)
    adaptive = report["arms"]["live_follow_up"]
    assert adaptive["summary"]["follow_up_rate"] == .25
    for row in adaptive["queries"]:
        assert "error" not in row
        if row["answerable"]:
            assert row["answer"]["answer_phrase_recall"] == 1
            assert row["answer"]["grounded_authored_claim_rate"] == 1
        else:
            assert row["answer"]["correct_abstention"] is True
    assert report["isolation"]["canonical_records_unchanged"] is True


def test_live_endpoint_rejects_nonlocal_transport_before_network():
    from locus_memory.errors import ProviderError

    with pytest.raises(ProviderError):
        _LiveModel("explicit-model", "https://example.invalid")


def test_missing_live_model_does_not_download(monkeypatch):
    from ollama_code import memory_embeddings

    calls = []
    class Transport:
        def __init__(self, _host):
            pass
        def _json(self, path, payload, end):
            calls.append(path)
            return {"models": []}
    monkeypatch.setattr(memory_embeddings, "_LocalTransport", Transport)
    with pytest.raises(ValueError, match="no download"):
        _LiveModel("missing", "http://localhost:11434")
    assert calls == ["/api/tags"]
