from __future__ import annotations

import copy
import hashlib
import json
import os

import pytest

from ollama_code import knowledge
from ollama_code import knowledge_retrieval as retrieval
from ollama_code.knowledge import KnowledgeStore


def candidate(identifier, *, score=.02, snippet="evidence", path=None, **extra):
    return {"id": identifier, "score": score, "snippet": snippet,
            "path": path or f"{identifier}.txt", "source": "text", **extra}


def mock_reranker(monkeypatch, *, scores=None, response=None, on_chat=None,
                  installed=True):
    calls = []

    class Transport:
        def __init__(self, host):
            assert host == "http://localhost:11434"

        def _json(self, path, payload, end):
            calls.append((path, payload, end))
            if path == "/api/tags":
                return {"models": [{"name": "ranker:latest"}]} if installed else {"models": []}
            assert path == "/api/chat"
            if on_chat:
                on_chat(payload)
            if response is not None:
                return response
            documents = json.loads(payload["messages"][-1]["content"])["documents"]
            values = scores if scores is not None else [
                {"id": item["id"], "score": 1 / (item["id"] + 1)} for item in documents
            ]
            return {"done": True, "message": {"content": json.dumps({"scores": values})}}

    monkeypatch.setattr(retrieval, "_LocalTransport", Transport)
    return calls


def rerank(items):
    return retrieval.rerank_candidates("question", items, model="ranker", host="http://localhost:11434")


def test_query_terms_dedupe_stopwords_and_bound_terms():
    assert retrieval.query_terms("Please find the auth_token and AUTH_TOKEN in src/main.py") == [
        "auth_token", "src", "main", "py",
    ]
    assert len(retrieval.query_terms(" ".join(f"term{i}" for i in range(100)))) == 24


def test_single_digit_versions_are_lexical_terms_but_not_exact_identifiers():
    assert retrieval.query_terms("version 3 and version 2") == ["version", "3", "2"]
    result = retrieval.fuse_candidates([
        candidate("guide", snippet="version 3 default timeout seconds"),
        candidate("code", snippet="return 3"),
    ], [], "version 3 default timeout seconds")
    assert result[0]["id"] == "guide"
    assert all("identifier" not in item["rank_components"] for item in result)


def test_sentence_punctuation_does_not_turn_plain_words_into_identifiers():
    result = retrieval.fuse_candidates([candidate("a", snippet="timeout")], [], "timeout.")
    assert "identifier" not in result[0]["rank_components"]


def test_named_version_identifier_can_match_inherited_heading_context():
    result = retrieval.fuse_candidates([
        candidate("old", context="guide.md | heading: Release v2", snippet="default duration"),
        candidate("new", context="guide.md | heading: Release v3", snippet="default duration"),
    ], [], "v3 default duration")
    assert result[0]["id"] == "new"
    assert result[0]["rank_components"]["identifier"] == 1
    assert "identifier" not in result[1]["rank_components"]


def test_lexical_coverage_combines_heading_and_raw_answer_without_extra_ranker():
    result = retrieval.fuse_candidates([
        candidate("heading", snippet="# Queue retries", score=1_000),
        candidate("answer", context="queue.md | heading: Queue retries",
                  snippet="The default delay is 40 seconds.", score=.001),
    ], [], "Queue retries default delay seconds")
    assert result[0]["id"] == "answer"
    assert result[0]["rank_components"] == {"lexical": 1}
    assert result[0]["score"] == pytest.approx(1 / 61)


def test_coverage_counts_distinct_terms_and_preserves_bm25_order_for_ties():
    result = retrieval.fuse_candidates([
        candidate("repeated", path="widget.py", context="widget " * 50, snippet="widget"),
        candidate("first", snippet="widget lock"),
        candidate("second", snippet="lock widget"),
    ], [], "widget lock")
    assert [item["id"] for item in result] == ["first", "second", "repeated"]


def test_natural_language_terms_match_underscore_identifier_components():
    result = retrieval.fuse_candidates([
        candidate("general", snippet="Check whether a path is available."),
        candidate("code", snippet="return is_file(path)"),
    ], [], "file path")
    assert result[0]["id"] == "code"


def test_fusion_uses_rank_not_incomparable_lexical_and_vector_score_scales():
    lexical = [candidate("a", score=-200), candidate("b", score=-.01)]
    semantic = [candidate("b", score=.95), candidate("c", score=.80)]
    original = copy.deepcopy((lexical, semantic))
    result = retrieval.fuse_candidates(lexical, semantic, "natural language")
    rescaled = retrieval.fuse_candidates(
        [{**item, "score": item["score"] * 10_000} for item in lexical],
        [{**item, "score": item["score"] / 100_000} for item in semantic], "natural language",
    )
    assert [(r["id"], r["score"]) for r in result] == [(r["id"], r["score"]) for r in rescaled]
    assert result[0]["id"] == "b"
    assert result[0]["source"] == "hybrid"
    assert result[0]["rank_components"] == {"lexical": 2, "semantic": 1}
    assert result[0]["score"] == pytest.approx(1 / 62 + 1 / 61)
    assert (lexical, semantic) == original


def test_exact_identifier_ranker_requires_token_boundary_and_keeps_original_ids():
    lexical = [candidate("file:123", snippet="auth_token_backup"),
               candidate("file:987", snippet="def auth_token(): pass")]
    result = retrieval.fuse_candidates(lexical, [], "auth_token")
    assert result[0]["id"] == "file:987"
    assert result[0]["rank_components"]["identifier"] == 1
    assert "identifier" not in result[1]["rank_components"]
    assert {r["id"] for r in result} == {"file:123", "file:987"}


def test_diversity_keeps_distinct_parent_children_and_distinct_source_citations():
    items = [candidate("a", score=1, snippet="authentication cookies", path="auth.py", parent_key="p", content_hash="h"),
             candidate("b", score=.99, snippet="refresh rotation", path="auth.py", parent_key="p", content_hash="h"),
             candidate("c", score=.98, snippet="authentication cookies", path="copy.py"),
             candidate("d", score=.95, snippet="database migration rollback")]
    result = retrieval.select_diverse(items, 4)
    assert [r["id"] for r in result] == ["a", "d", "b", "c"]
    assert retrieval.select_diverse(items, 0) == []


def test_diversity_only_hard_dedupes_evidence_already_present_in_same_source():
    items = [candidate("a", snippet="same source evidence", path="a", content_hash="h"),
             candidate("b", snippet="source evidence", path="a", content_hash="h"),
             candidate("c", snippet="source evidence", path="b", content_hash="h")]
    assert [item["id"] for item in retrieval.select_diverse(items, 3)] == ["a", "c"]


def test_longer_matching_passage_is_not_lost_when_a_shorter_one_was_selected():
    items = [candidate("short", score=1, snippet="shared", path="a", content_hash="h"),
             candidate("long", score=.9, snippet="shared with extra evidence", path="a", content_hash="h")]
    assert [item["id"] for item in retrieval.select_diverse(items, 2)] == ["short", "long"]


def test_pack_parent_expansion_keeps_raw_text_and_correct_line_citation():
    item = candidate("file:9", snippet="middle\n", context="guide.md | heading: Guide",
                     format="text", line_start=2, line_end=2,
                     locator={"kind": "line", "line_start": 2, "line_end": 2},
                     parent_content="# Guide\nmiddle\nend\n", parent_line_start=1, parent_line_end=3)
    original = copy.deepcopy(item)
    result = retrieval.pack_evidence([item])[0]
    assert result["snippet"] == original["parent_content"]
    assert "guide.md |" not in result["snippet"]
    assert result["expanded_parent"] is True
    assert (result["line_start"], result["line_end"]) == (1, 3)
    assert result["locator"] == {"kind": "line", "line_start": 1, "line_end": 3}
    assert "parent_content" not in result
    assert item == original


def test_pack_budget_reserves_other_children_before_expanding_and_counts_utf8():
    items = [candidate("a", snippet="😀", context="ctx", parent_content="😀" * 500),
             candidate("b", snippet="é", context="ctx", parent_content="é" * 500)]
    reserve = sum(len(i["snippet"].encode()) + len(i["context"].encode()) + 256 for i in items)
    result = retrieval.pack_evidence(items, byte_budget=reserve + 500)
    assert [r["snippet"] for r in result] == ["😀", "é"]
    assert not any(r.get("expanded_parent") for r in result)
    assert retrieval.pack_evidence(items, byte_budget=1) == []


def test_pack_document_parent_preserves_supplied_locator_without_fake_lines():
    locator = {"kind": "sheet", "sheet": "Cost", "cell_range": "A2:D2"}
    item = candidate("doc:1", snippet="A2: 10", context="report.xlsx | sheet: Cost",
                     format="xlsx", line_start=0, line_end=0, locator=locator,
                     parent_locator=locator, parent_content="A2: 10 | B2: tax | C2: 2 | D2: 12")
    result = retrieval.pack_evidence([item])[0]
    assert result["locator"] == locator
    assert result["line_start"] == result["line_end"] == 0
    assert result["snippet"] == item["parent_content"]


@pytest.mark.parametrize("metadata", [
    {"path": "p" * retrieval.CONTEXT_BYTES},
    {"title": "t" * retrieval.CONTEXT_BYTES},
    {"locator": {"kind": "paragraph", "heading": "h" * retrieval.CONTEXT_BYTES}},
    {"locator": {"kind": "paragraph", "heading": "界" * 2_400}},
])
def test_pack_budget_bounds_large_citation_metadata_and_encoded_links(metadata):
    huge = candidate("huge", snippet="short", **metadata)
    small = candidate("small", snippet="useful")
    result = retrieval.pack_evidence([huge, small])
    assert [item["id"] for item in result] == ["small"]


def test_parent_expansion_rechecks_larger_citation_metadata_against_budget():
    locator = {"kind": "paragraph", "paragraph_start": 1, "paragraph_end": 1}
    item = candidate("doc", snippet="child", format="docx", locator=locator,
                     parent_content="parent contains child",
                     parent_locator={**locator, "heading": "x" * retrieval.CONTEXT_BYTES})
    result = retrieval.pack_evidence([item])[0]
    assert result["snippet"] == "child"
    assert result["locator"] == locator
    assert not result.get("expanded_parent")


def test_distinct_children_survive_when_unicode_parent_exceeds_byte_budget():
    parent = "😀" * 2_000 + "🐈" * 2_000 + "🚀" * 2_000
    items = [candidate("a", snippet="😀" * 1_600, path="same.md", content_hash="h",
                       parent_key="p", parent_content=parent),
             candidate("b", snippet="🐈" * 1_600, path="same.md", content_hash="h",
                       parent_key="p", parent_content=parent)]
    result = retrieval.pack_evidence(retrieval.select_diverse(items, 2))
    assert [item["snippet"] for item in result] == [item["snippet"] for item in items]
    assert not any(item.get("expanded_parent") for item in result)


def test_parent_expansion_can_reuse_all_selected_child_reservations():
    parent = "a" * 2_500 + "b" * 2_500
    items = [candidate("a", snippet="a" * 2_200, path="same.md", content_hash="h",
                       parent_key="p", parent_content=parent),
             candidate("b", snippet="b" * 2_200, path="same.md", content_hash="h",
                       parent_key="p", parent_content=parent)]
    result = retrieval.pack_evidence(retrieval.select_diverse(items, 2), byte_budget=6_000)
    assert len(result) == 1
    assert result[0]["snippet"] == parent and result[0]["expanded_parent"]


def test_parent_group_cannot_collapse_children_from_distinct_sources():
    parent = "parent evidence"
    items = [candidate("a", snippet="evidence", path="a.md", content_hash="h",
                       parent_key="p", parent_content=parent),
             candidate("b", snippet="evidence", path="b.md", content_hash="h",
                       parent_key="p", parent_content=parent)]
    result = retrieval.pack_evidence(items)
    assert [item["path"] for item in result] == ["a.md", "b.md"]
    assert all(item["snippet"] == parent for item in result)


def test_reranker_uses_bounded_pairs_and_maps_only_original_candidate_ids(monkeypatch):
    calls = mock_reranker(monkeypatch, scores=[{"id": 1, "score": .9}, {"id": 0, "score": .1}])
    items = [candidate("file:111", snippet="x" * 8_000, context="c" * 1_000),
             candidate("file:999", snippet="original evidence")]
    original = copy.deepcopy(items)
    result = rerank(items)
    assert [r["id"] for r in result] == ["file:999", "file:111"]
    assert result[0]["snippet"] == "original evidence"
    assert items == original
    assert [call[0] for call in calls] == ["/api/tags", "/api/chat"]
    payload = calls[1][1]
    documents = json.loads(payload["messages"][-1]["content"])["documents"]
    assert [d["id"] for d in documents] == [0, 1]
    assert len(documents[0]["text"]) == 1_200
    assert len(documents[0]["context"]) == 512
    assert payload["stream"] is False and payload["options"]["temperature"] == 0
    assert calls[0][2] == calls[1][2]


@pytest.mark.parametrize("scores", [
    [{"id": 0, "score": .8}],
    [{"id": 0, "score": .8}, {"id": 0, "score": .6}],
    [{"id": 0, "score": .8}, {"id": 99, "score": .6}],
    [{"id": False, "score": .8}, {"id": 1, "score": .6}],
    [{"id": "0", "score": .8}, {"id": 1, "score": .6}],
    [{"id": 0, "score": float("nan")}, {"id": 1, "score": .6}],
    [{"id": 0, "score": float("inf")}, {"id": 1, "score": .6}],
    [{"id": 0, "score": -1}, {"id": 1, "score": .6}],
    [{"id": 0, "score": 1.1}, {"id": 1, "score": .6}],
    [{"id": 0, "score": True}, {"id": 1, "score": .6}],
    [{"id": 0, "score": "0.8"}, {"id": 1, "score": .6}],
    ["not a pair", {"id": 1, "score": .6}],
])
def test_reranker_rejects_invalid_scores_and_identities(monkeypatch, scores):
    mock_reranker(monkeypatch, scores=scores)
    with pytest.raises(ValueError):
        rerank([candidate("a"), candidate("b")])


@pytest.mark.parametrize("response", [
    {"done": False, "message": {"content": '{"scores":[]}' }},
    {"done": True, "message": {"content": "[]"}},
    {"done": True, "message": {"content": "null"}},
    {"done": True, "message": None},
    {"done": True, "message": {"content": "not json"}},
    {"done": True, "message": {"content": " " * 16_001}},
])
def test_reranker_rejects_malformed_or_incomplete_responses(monkeypatch, response):
    mock_reranker(monkeypatch, response=response)
    with pytest.raises(ValueError):
        rerank([candidate("a")])


def test_missing_reranker_model_does_not_download_or_call_chat(monkeypatch):
    calls = mock_reranker(monkeypatch, installed=False)
    with pytest.raises(ValueError, match="not installed"):
        rerank([candidate("a")])
    assert [call[0] for call in calls] == ["/api/tags"]


@pytest.fixture
def store(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "alpha.py").write_text("def exact_symbol():\n    return 'retrievalmarker'\n", encoding="utf-8")
    result = KnowledgeStore(str(workspace), tmp_path / "knowledge.sqlite3")
    result.reindex()
    return result


def test_search_diagnostics_returns_only_raw_source_and_compatible_search(store):
    report = store.search_with_diagnostics("exact_symbol", limit=8)
    assert isinstance(report["diagnostics"], dict)
    assert report["results"]
    assert report["diagnostics"]["returned"] == len(report["results"])
    assert report["diagnostics"]["lexical_candidates"] > 0
    assert report["diagnostics"]["reranked"] is False
    assert report["diagnostics"]["fallbacks"] == []
    item = report["results"][0]
    assert item["path"] == "alpha.py"
    assert item["snippet"] in (store.root / "alpha.py").read_text()
    assert item["locator"] == {"kind": "line", "line_start": item["line_start"], "line_end": item["line_end"]}
    assert item["id"] == store.search("exact_symbol")[0]["id"]


def test_unindexed_file_change_is_filtered_even_with_same_size_and_mtime(store):
    path = store.root / "alpha.py"
    original = path.stat()
    path.write_text(path.read_text().replace("retrievalmarker", "modified_marker"))
    os.utime(path, ns=(original.st_atime_ns, original.st_mtime_ns))
    assert path.stat().st_size == original.st_size
    report = store.search_with_diagnostics("retrievalmarker")
    assert report["results"] == []
    assert report["diagnostics"]["rejected_sources"] > 0


@pytest.mark.parametrize("mutation", ["delete", "exclude", "symlink"])
def test_missing_excluded_and_symlinked_sources_cannot_return_old_evidence(store, tmp_path, mutation):
    path = store.root / "alpha.py"
    if mutation == "delete":
        path.unlink()
    elif mutation == "exclude":
        store.configure(exclusions=["alpha.py"])
    else:
        outside = tmp_path / "outside.py"
        outside.write_text(path.read_text())
        path.unlink()
        path.symlink_to(outside)
    assert store.search_with_diagnostics("retrievalmarker")["results"] == []


def test_symlinked_source_ancestor_is_filtered(store, tmp_path):
    folder = store.root / "data"
    folder.mkdir()
    (folder / "guide.md").write_text("ancestor_marker")
    store.reindex()
    outside = tmp_path / "outside"
    folder.rename(outside)
    folder.symlink_to(outside, target_is_directory=True)
    assert store.search_with_diagnostics("ancestor_marker")["results"] == []


def test_malformed_reranker_falls_back_to_retrieval_with_diagnostics(store, monkeypatch):
    store.configure(rerank_model="ranker")
    mock_reranker(monkeypatch, response={"done": True, "message": {"content": "not json"}})
    report = store.search_with_diagnostics("retrievalmarker")
    assert report["results"][0]["path"] == "alpha.py"
    assert not any("rerank_score" in item for item in report["results"])
    assert report["diagnostics"]["reranked"] is False
    assert report["diagnostics"]["fallbacks"] == ["reranker_unavailable:JSONDecodeError"]


def test_successful_reranker_is_reported_without_changing_source_evidence(store, monkeypatch):
    store.configure(rerank_model="ranker")
    mock_reranker(monkeypatch)
    report = store.search_with_diagnostics("retrievalmarker")
    assert report["diagnostics"]["reranked"] is True
    assert report["diagnostics"]["fallbacks"] == []
    assert report["results"][0]["rerank_score"] == 1
    assert report["results"][0]["snippet"] == (store.root / "alpha.py").read_text()


def test_semantic_failure_keeps_lexical_results_and_reports_fallback(store, monkeypatch):
    store.configure(embedding_model="embed")

    def unavailable(*_args, **_kwargs):
        raise TimeoutError("local embedding deadline")

    monkeypatch.setattr(knowledge, "embed_texts", unavailable)
    report = store.search_with_diagnostics("retrievalmarker")
    assert report["results"][0]["path"] == "alpha.py"
    assert report["diagnostics"]["fallbacks"] == ["semantic_unavailable:TimeoutError"]


def test_stale_evidence_is_filtered_before_reranker_sees_it(store, monkeypatch):
    store.configure(rerank_model="ranker")
    (store.root / "alpha.py").write_text("replacement content")
    calls = mock_reranker(monkeypatch)
    assert store.search_with_diagnostics("retrievalmarker")["results"] == []
    assert calls == []


@pytest.mark.parametrize("mutation", ["disable", "exclude", "change"])
def test_source_or_policy_change_during_reranker_call_is_revalidated(store, monkeypatch, mutation):
    store.configure(rerank_model="ranker")

    def change(_):
        if mutation == "disable":
            store.configure(enabled=False)
        elif mutation == "exclude":
            store.configure(exclusions=["alpha.py"])
        else:
            path = store.root / "alpha.py"
            path.write_text(path.read_text().replace("retrievalmarker", "modified_marker"))

    calls = mock_reranker(monkeypatch, on_chat=change)
    assert store.search_with_diagnostics("retrievalmarker")["results"] == []
    assert any(call[0] == "/api/chat" for call in calls)


def test_disabling_during_query_embedding_returns_no_lexical_or_vector_results(store, monkeypatch):
    store.configure(embedding_model="embed")

    def embed(*_args, **_kwargs):
        store.configure(enabled=False)
        return [[1.0, 0.0]]

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    assert store.search_with_diagnostics("retrievalmarker")["results"] == []


def test_document_search_expansion_preserves_original_page_locator(store):
    store.configure(documents_enabled=True)
    path = store.root / "manual.pdf"
    raw = b"opaque document fixture"
    path.write_bytes(raw)
    locator = {"kind": "pdf", "page": 7, "page_index": 6}
    text = "lookupneedle " + "source passage " * 300
    store.index_extracted_document("manual.pdf", hashlib.sha256(raw).hexdigest(),
                                  [{"text": text, "locator": locator, "method": "embedded"}], "pdf")
    report = store.search_with_diagnostics("lookupneedle")
    item = report["results"][0]
    assert item["path"] == "manual.pdf" and item["locator"] == locator
    assert item["snippet"] == text
    assert item["line_start"] == item["line_end"] == 0
    assert item["expanded_parent"] is True
