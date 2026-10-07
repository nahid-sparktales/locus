"""Reproducible, model-free workspace retrieval evaluation.

Run ``python -m ollama_code.knowledge_evaluation --output report.json`` from a
source checkout. The frozen fixture is under tests/fixtures/knowledge_relevance;
installed packages can supply the same directory with ``--corpus``. This small
authored corpus measures lexical retrieval, not generated answers or live model
quality. Both indexes are disposable and never open the user's knowledge DB.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import re
import sqlite3
import statistics
import tempfile
import time
from collections.abc import Callable
from pathlib import Path, PurePosixPath
from typing import Any

DEFAULT_CORPUS = Path(__file__).resolve().parent.parent / "tests/fixtures/knowledge_relevance"
BENCHMARK_VERSION = 1
LIMIT = 8


def load_corpus(directory: Path) -> tuple[dict[str, Any], dict[str, str], str]:
    """Read explicitly listed fixture files and validate every relevance span."""
    manifest_raw = (directory / "manifest.json").read_bytes()
    manifest = json.loads(manifest_raw)
    files: dict[str, str] = {}
    digest = hashlib.sha256(manifest_raw)
    root = (directory / "corpus").resolve()
    for name in manifest["files"]:
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or "\\" in name:
            raise ValueError(f"Fixture path must be relative and contained: {name}")
        source = root.joinpath(*relative.parts)
        if source.resolve() != source or not source.is_file() or name in files:
            raise ValueError(f"Fixture file must be unique, regular, and not a symlink: {name}")
        raw = source.read_bytes()
        files[name] = raw.decode("utf-8")
        digest.update(name.encode("utf-8") + b"\0" + raw + b"\0")
    if not files or not manifest["queries"]:
        raise ValueError("Fixture needs files and judged queries")
    ids: set[str] = set()
    for query in manifest["queries"]:
        if query["id"] in ids or not query["query"].strip() or not query["category"]:
            raise ValueError("Each fixture query needs a unique ID, text, and category")
        ids.add(query["id"])
        seen_spans: set[tuple[str, int, int]] = set()
        for target in query["relevance"]:
            path, start, end = target["path"], target["line_start"], target["line_end"]
            if path not in files or not 1 <= start <= end <= len(files[path].splitlines()):
                raise ValueError(f"Invalid evidence span for {query['id']}: {target}")
            if target["grade"] not in (1, 2, 3) or (path, start, end) in seen_spans:
                raise ValueError(f"Invalid or duplicate relevance judgment: {target}")
            seen_spans.add((path, start, end))
    return manifest, files, digest.hexdigest()


def legacy_chunks(content: str) -> list[tuple[int, int, str]]:
    """Frozen pre-improvement chunking, independent of production helpers."""
    lines = content.splitlines()
    output = []
    start = 0
    while start < len(lines):
        end, size = start, 0
        while end < len(lines) and (size < 6_000 or end == start):
            size += len(lines[end]) + 1
            end += 1
        text = "\n".join(lines[start:end]).strip()
        if text:
            output.append((start + 1, end, text))
        if end >= len(lines):
            break
        start = max(start + 1, end - 8)
    return output


class LegacyLexicalIndex:
    """Content-only FTS5/BM25 arm; no calls to production rank or chunk code."""

    def __init__(self, files: dict[str, str]) -> None:
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute(
            "CREATE VIRTUAL TABLE chunks_fts USING fts5("
            "content, path UNINDEXED, chunk_id UNINDEXED, tokenize='unicode61')"
        )
        self.chunks: dict[int, tuple[int, int]] = {}
        for path, content in files.items():
            for start, end, chunk in legacy_chunks(content):
                chunk_id = len(self.chunks) + 1
                self.chunks[chunk_id] = (start, end)
                self.connection.execute(
                    "INSERT INTO chunks_fts(content,path,chunk_id) VALUES(?,?,?)",
                    (chunk, path, chunk_id),
                )

    def search(self, query: str, limit: int = LIMIT) -> list[dict[str, Any]]:
        query = query.strip()[:2_000]
        if not query:
            raise ValueError("Search requires a query")
        limit = min(max(int(limit), 1), 20)
        terms = [term for term in re.findall(r"[\w.-]+", query) if len(term) > 1]
        fts_query = " OR ".join(f'"{term.replace(chr(34), chr(34) * 2)}"' for term in terms[:16])
        if not fts_query:
            return []
        rows = self.connection.execute(
            "SELECT chunk_id,path,content,bm25(chunks_fts) AS rank "
            "FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?",
            (fts_query, limit * 4),
        ).fetchall()
        results = []
        for position, row in enumerate(rows):
            start, end = self.chunks[int(row["chunk_id"])]
            results.append({
                "id": f"file:{row['chunk_id']}", "path": row["path"],
                "line_start": start, "line_end": end, "snippet": str(row["content"])[:6_000],
                "locator": {"kind": "line", "line_start": start, "line_end": end},
                "score": 1.0 / (position + 1),
            })
        return sorted(results, key=lambda item: (-item["score"], item["id"]))[:limit]

    def close(self) -> None:
        self.connection.close()


def citation_is_valid(result: dict[str, Any], files: dict[str, str]) -> bool:
    """A locator must resolve to the exact source text, not indexed context."""
    path = result.get("path")
    start, end = result.get("line_start"), result.get("line_end")
    if path not in files or type(start) is not int or type(end) is not int:
        return False
    lines = files[path].splitlines()
    if not 1 <= start <= end <= len(lines):
        return False
    locator = result.get("locator") or {}
    if (locator.get("kind"), locator.get("line_start"), locator.get("line_end")) != (
        "line", start, end,
    ):
        return False
    snippet = result.get("snippet")
    return bool(isinstance(snippet, str) and snippet.strip()
                and "\n".join(lines[start - 1:end]).strip().startswith(snippet.strip()))


def score_results(
    results: list[dict[str, Any]], query: dict[str, Any], files: dict[str, str],
    limit: int = LIMIT,
) -> dict[str, Any]:
    """Score unique evidence units; repeated overlapping chunks get no extra gain."""
    targets = query["relevance"]
    covered: set[int] = set()
    dcg_credited: set[int] = set()
    ranks = []
    first_relevant = None
    dcg = 0.0
    for rank, result in enumerate(results[:limit], 1):
        valid = citation_is_valid(result, files)
        matched = [index for index, target in enumerate(targets) if valid
                   and result["path"] == target["path"]
                   and result["line_start"] <= target["line_start"]
                   and result["line_end"] >= target["line_end"]
                   and "\n".join(files[target["path"]].splitlines()[
                       target["line_start"] - 1:target["line_end"]
                   ]).strip() in result["snippet"]]
        covered.update(matched)
        if matched and first_relevant is None:
            first_relevant = rank
        uncredited = [index for index in matched if index not in dcg_credited]
        grade = 0
        if uncredited:
            best = max(uncredited, key=lambda index: targets[index]["grade"])
            grade = targets[best]["grade"]
            dcg_credited.update(matched)
            dcg += (2 ** grade - 1) / math.log2(rank + 1)
        ranks.append({
            "rank": rank, "id": result.get("id"), "path": result.get("path"),
            "line_start": result.get("line_start"), "line_end": result.get("line_end"),
            "locator": result.get("locator"), "score": result.get("score"),
            "snippet": result.get("snippet"), "citation_valid": valid,
            "matched_judgments": matched, "credited_grade": grade,
        })
    ideal = sum((2 ** grade - 1) / math.log2(rank + 1) for rank, grade in enumerate(
        sorted((target["grade"] for target in targets), reverse=True)[:limit], 1,
    ))
    return {
        "answerable": bool(targets), "returned": len(ranks),
        "recall_at_8": len(covered) / len(targets) if targets else None,
        "mrr_at_8": (1 / first_relevant if first_relevant else 0.0) if targets else None,
        "ndcg_at_8": dcg / ideal if ideal else None,
        "abstained": not ranks,
        "citation_locator_accuracy": sum(rank["citation_valid"] for rank in ranks) / len(ranks)
        if ranks else None,
        "ranks": ranks,
    }


def _mean(values: list[float]) -> float | None:
    return statistics.mean(values) if values else None


def _latencies(values: list[float]) -> dict[str, float | int | None]:
    ordered = sorted(values)
    return {
        "samples": len(values), "median_ms": statistics.median(values) if values else None,
        "p95_ms": ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)] if ordered else None,
    }


def _aggregate(queries: list[dict[str, Any]]) -> dict[str, Any]:
    answerable = [query for query in queries if query["answerable"]]
    unknown = [query for query in queries if not query["answerable"]]
    ranks = [rank for query in queries for rank in query["ranks"]]
    return {
        "query_count": len(queries), "answerable_count": len(answerable),
        "unanswerable_count": len(unknown),
        **{metric: _mean([query[metric] for query in answerable])
           for metric in ("recall_at_8", "mrr_at_8", "ndcg_at_8")},
        "unanswerable_abstention_rate": _mean([float(query["abstained"]) for query in unknown]),
        "answerable_no_evidence_rate": _mean([float(query["recall_at_8"] == 0) for query in answerable]),
        "citation_locator_accuracy": _mean([float(rank["citation_valid"]) for rank in ranks]),
        "initial_query_latency": _latencies([query["initial_latency_ms"] for query in queries]),
        "repeat_query_latency": _latencies([sample for query in queries
                                            for sample in query["repeat_latency_ms"]]),
    }


def _evaluate(
    search: Callable[..., list[dict[str, Any]]], manifest: dict[str, Any],
    files: dict[str, str], repeats: int,
) -> dict[str, Any]:
    scored = []
    for query in manifest["queries"]:
        started = time.perf_counter()
        results = search(query["query"], limit=LIMIT)
        initial_ms = (time.perf_counter() - started) * 1_000
        samples = []
        stable = True
        for _ in range(repeats):
            started = time.perf_counter()
            repeated = search(query["query"], limit=LIMIT)
            samples.append((time.perf_counter() - started) * 1_000)
            stable = stable and repeated == results
        scored.append({
            "id": query["id"], "category": query["category"], "query": query["query"],
            "judgments": query["relevance"], **score_results(results, query, files),
            "initial_latency_ms": initial_ms, "repeat_latency_ms": samples,
            "stable_repeat_results": stable,
        })
    return {
        "summary": _aggregate(scored),
        "categories": {category: _aggregate([query for query in scored if query["category"] == category])
                       for category in sorted({query["category"] for query in scored})},
        "queries": scored,
    }


def run_benchmark(corpus: Path = DEFAULT_CORPUS, *, repeats: int = 3) -> dict[str, Any]:
    """Evaluate copied fixtures in a temporary workspace with an explicit DB."""
    if not 0 <= repeats <= 100:
        raise ValueError("repeats must be between 0 and 100")
    manifest, files, fingerprint = load_corpus(corpus)
    # Importing the store does not open a profile; passing path avoids all user
    # knowledge locations. Explicit changed_paths also avoids git discovery.
    from .knowledge import KnowledgeStore

    with tempfile.TemporaryDirectory(prefix="locus-knowledge-evaluation-") as temporary:
        workspace = Path(temporary) / "workspace"
        workspace.mkdir()
        for path, content in files.items():
            target = workspace / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        started = time.perf_counter()
        baseline = LegacyLexicalIndex(files)
        baseline_index_ms = (time.perf_counter() - started) * 1_000
        try:
            store = KnowledgeStore(str(workspace), Path(temporary) / "profile/knowledge.sqlite3")
            configuration = store.settings()
            if configuration.get("embedding_model") or configuration.get("rerank_model"):
                raise RuntimeError("The offline benchmark requires empty model settings")
            started = time.perf_counter()
            indexed = store.reindex(changed_paths=list(files))
            production_index_ms = (time.perf_counter() - started) * 1_000
            arms = {
                "legacy_lexical": {
                    "description": "Frozen 6000-character chunks, overlap 8, raw content BM25 ranking",
                    "storage": "In-memory ranking reference; omits production persistence and policy overhead",
                    "index_ms": baseline_index_ms, "chunk_count": len(baseline.chunks),
                    **_evaluate(baseline.search, manifest, files, repeats),
                },
                "production_lexical": {
                    "description": "Production KnowledgeStore.search; no embeddings or model reranker",
                    "storage": "Temporary persisted SQLite store; normal production freshness and policy checks",
                    "index_ms": production_index_ms, "chunk_count": indexed["chunk_count"],
                    **_evaluate(store.search, manifest, files, repeats),
                },
            }
        finally:
            baseline.close()
    return {
        "benchmark_version": BENCHMARK_VERSION,
        "corpus": {"name": manifest["name"], "version": manifest["version"],
                   "sha256": fingerprint, "file_count": len(files),
                   "query_count": len(manifest["queries"])},
        "environment": {"python": platform.python_version(), "sqlite": sqlite3.sqlite_version},
        "limit": LIMIT, "repeat_samples_per_query": repeats,
        "models": {"embedding": None, "reranker": None},
        "scope": "Authored fixture lexical retrieval only; no generated-answer or live-model quality claim.",
        "metric_notes": {
            "recall_at_8": "Mean fraction of unique relevant evidence spans fully covered, answerable queries only.",
            "mrr_at_8": "Mean reciprocal rank of first valid relevant citation, answerable queries only.",
            "ndcg_at_8": "Graded gain 2^grade-1; repeated evidence receives no additional gain.",
            "citation_locator_accuracy": "Path, line bounds, locator, and snippet resolve to fixture source; not relevance.",
            "unanswerable_abstention_rate": "No retrieval results on a question with no judged evidence; not answer-model abstention.",
            "latency": "Indexing separate; in-memory reference and persisted production timings are diagnostic, not a speedup comparison, cold process timing, or SLA.",
        },
        "arms": arms,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--output", type=Path, help="JSON output path; default is stdout")
    parser.add_argument("--repeats", type=int, default=3, help="Warm timing samples per query (0-100)")
    args = parser.parse_args(argv)
    try:
        report = run_benchmark(args.corpus, repeats=args.repeats)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    encoded = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
