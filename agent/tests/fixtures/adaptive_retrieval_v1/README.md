# Adaptive retrieval fixture v1

This separately versioned, authored corpus exercises the production
`AdaptiveRetrieval` coordinator with a disposable canonical memory profile and
workspace knowledge index. It does not change the frozen lexical corpus in
`knowledge_relevance`.

Eight questions cover a memory pointer to a Python function, a memory pointer to
a CSV document, conflicting versioned facts, a direct personal preference,
irrelevant retrieved evidence, a changed source file, an expired memory, and a
question without evidence. CSV extraction segments and cell locators are explicit
fixture data: this benchmark evaluates retrieval and citations, not extraction.
The stale file is modified after indexing and is not reindexed automatically.

The default comparison is one retrieval pass versus one authored focused
follow-up. The latter is a deterministic coverage test, not an evaluation of a
model's decision to search or ability to answer. Evidence recall measures unique
judged source units. Reciprocal rank uses the actual delivery order: memory
packet items followed by packed workspace/document evidence. Per-source MRR
uses the same order restricted to that source type. Citation validity measures current hashes/revisions and
exact source text at its locator; a valid citation can still be irrelevant.

Run from `agent/`:

```sh
python -m ollama_code.adaptive_retrieval_evaluation --output report.json
```

An optional live comparison uses an explicitly named model already installed on
a loopback Ollama server. It adds model decisions and answers to the same fixture,
permits one follow-up, and makes no download requests:

```sh
python -m ollama_code.adaptive_retrieval_evaluation \
  --live-model YOUR_SELECTED_MODEL --live-host http://localhost:11434 \
  --output live-report.json
```

Live answer scores are transparent authored-phrase and exact supporting-quote
checks, not a semantic judge of arbitrary prose. Per-query answers, abstentions,
forbidden answer phrases, retrieval decisions, errors, and timings remain in the
report for inspection. A benchmark worker starts with a temporary app home and
empty host capabilities (no external memory providers or Keychain discovery).
It uses the real memory adapter/engine and confirms canonical records and
revisions stay unchanged. Generated answers never enter a learning pipeline.

The manifest and listed source bytes are fingerprinted. Changes to queries,
judgments, memories, extraction segments, or source files require a deliberate
fixture version/fingerprint update; do not tune the older lexical judgments.
