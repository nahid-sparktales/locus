# Workspace retrieval: first implementation

Implemented October 6, 2026, following items 1 and 2 of [the memory/RAG roadmap](MemoryRAGRoadmap.md). This uses the existing workspace SQLite index and shared Locus host. The canonical memory vault and cross-device connection model stay as before.

## Retrieval

`KnowledgeStore.search` gathers BM25 and optional local vector candidates. Lexical candidates prefer coverage of distinct query terms, with BM25 breaking ties. Reciprocal rank fusion combines candidate ranks, including a separate exact-identifier signal; raw cosine and lexical scores are not added. Single numbers remain searchable but do not receive identifier boosts.

A diversity pass removes overlapping passages from the same source. Identical text at different paths retains its separate citations. A maximum of 24 fused candidates supplies up to eight results by default (the API permits 1–20).

Optional **Reranking** is available under Settings → Memory → Workspace search index. Enter the name of an already installed local Ollama **generation model**, or leave it empty (the default). The model scores query/passage pairs using a constrained JSON response. It does not generate replacement evidence. This is not an implementation of a dedicated cross-encoder model's inference protocol.

The adapter checks the installed model inventory, sends at most 24 bounded passages, validates every returned candidate ID and finite score, and has a five-second total deadline. Missing models, malformed output and timeouts retain fused ranking. No model is downloaded. Embeddings and reranking use direct loopback HTTP with no environment proxies or redirects. Unsupported URL origins are rejected by settings.

`GET /api/knowledge/search` includes `diagnostics` alongside `results`: candidate counts, rejected sources, selected rank components on results, fallback reasons, elapsed time, and pending embeddings. The existing tool-facing search result list remains compatible.

Candidates are checked before reranking and again before returning: enabled settings, exclusions, indexed identity, source existence and source version. Removed documents and index resets revoke in-flight candidates. File identity, size, nanosecond modification/change times, and a hash when the recorded identity differs prevent stale citations. These checks are observations of local files, not a filesystem snapshot or a guarantee that a file cannot change after return.

## Context and citations

Markdown uses heading hierarchy; Python uses AST class/function boundaries, including decorators and nested functions. Other code/text uses bounded line/paragraph windows. PDF/OCR, DOCX and spreadsheet passages retain the extractor's original page, paragraph, sheet/cell and other locator metadata.

Children are at most 2,400 characters and parents at most 6,000. Source slices remain unchanged. Separate retrieval context contains the path and heading, symbol or document locator, capped at 512 characters. Context is included in lexical/embedding inputs but is labeled separately from quoted source evidence. Whitespace-only symbol gaps are not indexed.

Search expands a matching child to its bounded parent when the selected evidence fits a 24,000-byte UTF-8 allowance, including citation metadata. This is a byte budget, not a model-specific token estimate. Expanded passages use the parent's real source range. Stored chunker versions trigger rebuilding older text indexes on the next search or reindex; document extraction caches are re-published through the new chunker when needed.

## Complete, resumable embeddings

Unembedded or old-generation chunk rows are the durable queue. Reindexing schedules work and returns without waiting for model inference. Successful persistent asynchronous document publication schedules the same queue. Temporary extraction does not.

Workers process bounded batches until the queue is empty, without a 2,000-chunk ceiling. Each coordinator visit yields after four batches so large workspaces do not monopolize the process. File locks allow one worker per database and at most two across host processes. Primary backend startup resumes saved queues; shutdown prevents late vector publication. A failed call leaves work pending for retry.

Publication rechecks settings, model, host, generation, raw/contextual content and document hash inside a transaction. Switching the model or host invalidates old vectors. Keyword search remains available while vectors are pending or Ollama is unavailable. Settings displays completed/pending counts and the last embedding error, with a manual Refresh Status action.

## Relevance benchmark

The frozen corpus contains 15 fictional files and 22 authored questions: exact identifiers, paraphrases, inherited headings, competing versions, multiple sources, overlapping passages and four unanswerable questions. It is copied into a temporary workspace and never indexes the user's project or profile. It compares the original raw-content, 6,000-character/8-line-overlap lexical ranking with production search. Neither arm uses models or network access.

From the repository root, using the project's Python environment:

```sh
PYTHONPATH=agent python -m ollama_code.knowledge_evaluation --output /tmp/locus-relevance.json
python -m pytest agent/tests/test_knowledge_evaluation.py
```

The report contains per-query rankings, source/line validation, recall@8, MRR@8, nDCG@8, retrieval abstention and repeated query latency. [The checked-in summary](Benchmarks/workspace-retrieval-v1.json) preserves the corpus hash, results and per-query metrics without repeating source text.

This is a small regression fixture, not a held-out accuracy claim. It exposed blank passages and heading-only ranking errors during implementation; judgments were not changed. Full evidence recall and source-locator validity are 100% for both final arms. Aggregate ranking remains close to the original baseline, with small decreases documented in the summary. Only one of four unanswerable questions produces no retrieved results in either arm: retrieval still requires the answer model to assess whether evidence actually supports a claim.

No claim of semantic or reranking quality improvement is established by this offline run. Live-model relevance, cold-start latency, resident memory and answer sufficiency still require a separate measured evaluation before choosing a default reranker. Graph retrieval, adaptive multi-source routing and other heavier roadmap items are outside this implementation.
