from __future__ import annotations

import json
import math

import pytest
import requests

from ollama_code import paths
from ollama_code.knowledge_evaluation import (
    DEFAULT_CORPUS,
    LegacyLexicalIndex,
    citation_is_valid,
    legacy_chunks,
    load_corpus,
    main,
    run_benchmark,
    score_results,
)


def _result(path, start, end, text):
    return {
        "id": f"{path}:{start}", "path": path, "line_start": start, "line_end": end,
        "locator": {"kind": "line", "line_start": start, "line_end": end},
        "snippet": text, "score": 1.0,
    }


def test_frozen_fixture_has_valid_judgments_and_representative_categories():
    manifest, files, fingerprint = load_corpus(DEFAULT_CORPUS)

    assert manifest["version"] == 1
    assert len(files) == 15
    assert len(manifest["queries"]) == 22
    assert fingerprint == "14ab83d9e4cb5745d6f91825775fc4185bc15410c6613e1550eb8bd4f8dd526a"
    assert {query["category"] for query in manifest["queries"]} == {
        "exact_identifier", "paraphrase", "ambiguous_heading", "competing_versions",
        "multiple_sources", "overlapping_chunks", "unanswerable",
    }
    # Competing versions really disagree; the current question judges only v3.
    assert "90 seconds" in files["docs/api/v3/leases.md"]
    assert "30 seconds" in files["docs/api/v2/leases.md"]
    current = next(query for query in manifest["queries"] if query["id"] == "current_lease_default")
    assert [target["path"] for target in current["relevance"]] == ["docs/api/v3/leases.md"]
    assert len(legacy_chunks(files["docs/operations.md"])) > 1


def test_legacy_chunks_freeze_line_boundary_overshoot_and_eight_line_overlap():
    content = "\n".join(f"{number:02d}" + "x" * 598 for number in range(25))
    chunks = legacy_chunks(content)

    assert chunks[0][:2] == (1, 10)
    assert chunks[1][:2] == (3, 12)
    assert chunks[0][2].splitlines()[2:] == chunks[1][2].splitlines()[:8]
    assert chunks[-1][1] == 25
    assert legacy_chunks("\n\n") == []


def test_baseline_uses_content_bm25_not_paths_or_production_helpers(monkeypatch):
    from ollama_code import knowledge

    def forbidden(*args, **kwargs):
        raise AssertionError("Baseline must not call production retrieval helpers")

    monkeypatch.setattr(knowledge, "text_chunks", forbidden)
    monkeypatch.setattr(knowledge.KnowledgeStore, "search", forbidden)
    baseline = LegacyLexicalIndex({
        "path_only_needle.py": "ordinary unrelated content",
        "implementation.py": "def exact_identifier():\n    return 42",
    })
    try:
        assert baseline.search("path_only_needle") == []
        result = baseline.search("exact_identifier")
        assert result[0]["path"] == "implementation.py"
        assert result[0]["score"] == 1.0
        assert result[0]["line_start"] == 1
        assert result[0]["line_end"] == 2
    finally:
        baseline.close()


def test_ranking_metrics_credit_unique_evidence_not_duplicate_overlap():
    files = {"a.md": "setup\nfirst evidence\nend", "b.md": "second evidence"}
    query = {"relevance": [
        {"path": "a.md", "line_start": 2, "line_end": 2, "grade": 3},
        {"path": "b.md", "line_start": 1, "line_end": 1, "grade": 2},
    ]}
    results = [
        _result("a.md", 1, 1, "setup"),
        _result("a.md", 1, 3, files["a.md"]),
        _result("a.md", 2, 3, "first evidence\nend"),
        _result("b.md", 1, 1, files["b.md"]),
    ]
    metrics = score_results(results, query, files)

    assert metrics["recall_at_8"] == 1.0
    assert metrics["mrr_at_8"] == 0.5
    expected = (7 / math.log2(3) + 3 / math.log2(5)) / (7 + 3 / math.log2(3))
    assert metrics["ndcg_at_8"] == pytest.approx(expected)
    assert [rank["credited_grade"] for rank in metrics["ranks"]] == [0, 3, 0, 2]
    assert metrics["citation_locator_accuracy"] == 1.0


def test_relevance_requires_complete_evidence_in_returned_snippet():
    files = {"source.md": "intro\nanswer begins\nanswer ends"}
    query = {"relevance": [
        {"path": "source.md", "line_start": 2, "line_end": 3, "grade": 3},
    ]}
    truncated = _result("source.md", 1, 3, "intro\nanswer begins")
    partial = _result("source.md", 1, 2, "intro\nanswer begins")
    fabricated = _result("source.md", 1, 3, "generated heading\n" + files["source.md"])

    assert citation_is_valid(truncated, files)
    assert not citation_is_valid(fabricated, files)
    for result in (truncated, partial, fabricated):
        assert score_results([result], query, files)["recall_at_8"] == 0.0


@pytest.mark.parametrize("change", [
    {"path": "missing.md"}, {"line_start": 0}, {"line_end": 20},
    {"locator": {"kind": "page", "page": 1}}, {"snippet": "invented evidence"},
])
def test_invalid_citation_is_not_relevance(change):
    files = {"source.md": "actual evidence"}
    query = {"relevance": [
        {"path": "source.md", "line_start": 1, "line_end": 1, "grade": 3},
    ]}
    result = {**_result("source.md", 1, 1, files["source.md"]), **change}
    metrics = score_results([result], query, files)

    assert metrics["recall_at_8"] == 0
    assert metrics["citation_locator_accuracy"] == 0


def test_unanswerable_and_no_result_cases_do_not_inflate_recall():
    unanswerable = score_results([], {"relevance": []}, {})
    answerable = score_results([], {"relevance": [
        {"path": "file.md", "line_start": 1, "line_end": 1, "grade": 3},
    ]}, {"file.md": "fact"})

    assert unanswerable["abstained"] is True
    assert unanswerable["recall_at_8"] is None
    assert unanswerable["ndcg_at_8"] is None
    assert answerable["recall_at_8"] == 0
    assert answerable["mrr_at_8"] == 0
    assert answerable["ndcg_at_8"] == 0
    assert answerable["citation_locator_accuracy"] is None


def test_benchmark_uses_only_fixture_and_disposable_index_without_network(monkeypatch):
    def no_network(*args, **kwargs):
        raise AssertionError("Offline fixture benchmark attempted network access")

    monkeypatch.setattr(requests.sessions.Session, "request", no_network)
    paths.APP_DIR.mkdir(parents=True)
    sentinel = paths.APP_DIR / "private-user-file.txt"
    sentinel.write_text("never index me", encoding="utf-8")
    before = sentinel.stat().st_mtime_ns
    fingerprint_before = load_corpus(DEFAULT_CORPUS)[2]

    report = run_benchmark(repeats=1)

    assert report["corpus"]["sha256"] == fingerprint_before == load_corpus(DEFAULT_CORPUS)[2]
    assert sentinel.read_text(encoding="utf-8") == "never index me"
    assert sentinel.stat().st_mtime_ns == before
    assert list(paths.APP_DIR.iterdir()) == [sentinel]
    assert report["models"] == {"embedding": None, "reranker": None}
    assert set(report["arms"]) == {"legacy_lexical", "production_lexical"}
    for arm in report["arms"].values():
        summary = arm["summary"]
        assert summary["answerable_count"] == 18
        assert summary["unanswerable_count"] == 4
        assert 0 <= summary["recall_at_8"] <= 1
        assert 0 <= summary["ndcg_at_8"] <= 1
        assert summary["repeat_query_latency"]["samples"] == 22
        assert summary["citation_locator_accuracy"] == 1
        assert all(query["stable_repeat_results"] for query in arm["queries"])
        exact = next(query for query in arm["queries"] if query["id"] == "claim_identifier")
        assert exact["ranks"][0]["path"] == "src/leases.py"
        assert exact["recall_at_8"] == 1
        missing = next(query for query in arm["queries"] if query["id"] == "missing_identifier")
        assert missing["abstained"] is True
        assert "private-user-file.txt" not in json.dumps(arm)


def test_cli_writes_reviewable_json_report(tmp_path, capsys):
    output = tmp_path / "report.json"

    assert main(["--output", str(output), "--repeats", "0"]) == 0
    report = json.loads(output.read_text(encoding="utf-8"))

    assert report["benchmark_version"] == 1
    assert report["limit"] == 8
    assert report["repeat_samples_per_query"] == 0
    assert report["arms"]["production_lexical"]["queries"][0]["judgments"]
    assert capsys.readouterr().out == ""


def test_fixture_paths_cannot_escape_into_user_files(tmp_path):
    (tmp_path / "corpus").mkdir()
    (tmp_path / "outside.md").write_text("not fixture evidence", encoding="utf-8")
    (tmp_path / "manifest.json").write_text(json.dumps({
        "files": ["../outside.md"], "queries": [],
    }), encoding="utf-8")

    with pytest.raises(ValueError, match="relative and contained"):
        load_corpus(tmp_path)
