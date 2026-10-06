# Workspace retrieval fixture, version 1

This is an authored, fictional Harbor application repository. It contains no
production code, user files, credentials, or downloaded evaluation data. The
questions and relevance judgments were written before running the benchmark.
Do not silently change judgments or documents to improve an observed score:
create a new fixture version and retain the old report when changing the task.

Run from the repository root:

```sh
PYTHONPATH=agent python -m ollama_code.knowledge_evaluation --output /tmp/knowledge-report.json
```

The runner copies only the manifest's files into a temporary workspace and uses
an explicit temporary SQLite database. It does not use the current workspace,
user memory, Ollama, a network connection, or any downloaded model. `--corpus`
accepts the directory containing this manifest, and `--repeats` controls warm
query timing samples. The initial search is timed separately from repeat
searches; indexing is reported separately. Files are indexed in manifest order.

The reference arm freezes the pre-improvement behavior: 6,000-character line
chunks with eight overlapping lines, content-only FTS5 BM25 retrieval, quoted OR
query terms, reciprocal lexical position scores. It does not call production
chunking or ranking helpers. The production arm uses `KnowledgeStore.search`
with embeddings and reranking disabled. These are lexical retrieval results,
not measurements of semantic embeddings, a reranking model, answer generation,
or real user task success.

Every positive judgment names a file and an inclusive line span that contains
the answer evidence. A result must cover that entire span to count. Recall@8
counts unique judged evidence spans. MRR@8 scores the first relevant result.
nDCG@8 uses graded gains (2^grade - 1), crediting each judged span at most once,
so overlapping chunks cannot inflate it. Citation locator accuracy checks that
the path, inclusive line range, locator, and returned snippet agree with the
fixture source; a well-formed citation can still be irrelevant. Unanswerable
abstention means the retrieval API returned no results, not that an answering
model correctly refused to answer. Category scores and all result ranks are
included so regressions and lexical limitations stay visible.

The corpus includes exact identifiers, paraphrases, heading-dependent fragments,
competing versions, multiple evidence sources, chunks with overlapping content,
and unanswerable questions with and without shared vocabulary. It is a small
regression fixture, not a representative benchmark of arbitrary repositories.
Timing is diagnostic and depends on machine load and SQLite/Python versions.
The ranking reference keeps its FTS table in memory; production opens its
temporary persisted store and performs normal freshness and policy checks. Their
latencies are reported separately and are not an apples-to-apples speedup claim.
