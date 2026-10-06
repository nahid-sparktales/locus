# Memory and RAG roadmap for Locus

Research date: October 6, 2026. Code baseline: `f2dda0a0` on
`codex/automatic-shared-memory`. This is an implementation proposal; the features
below had not been added or benchmarked in that research pass.

Implementation update: items **1, 2 and 3**, resumable embeddings and the frozen
relevance benchmark are now implemented. See [workspace retrieval](WorkspaceKnowledgeRetrieval.md)
and [Adaptive RAG](AdaptiveRAG.md) for behavior, measurements and limits. Items 4–6 remain proposals.

Locus already has retrieval-augmented generation: it finds relevant external
evidence and supplies it to a model. Durable memory decides which preferences,
facts and lessons should survive between tasks. Improving both requires better
selection, grounding and evaluation alongside storage.

The recommended first increment is **better workspace ranking and contextual
chunks**, supported by complete indexing and a frozen evaluation corpus. Keep
the existing local stores and shared-host architecture.

## What already exists

| Component | Existing implementation | Main opportunity |
| --- | --- | --- |
| Workspace knowledge | `KnowledgeStore.search` in `agent/ollama_code/knowledge.py`: SQLite FTS5/BM25, optional local Ollama vectors, exact cosine search, source locations | Lexical rank and cosine scores are added directly; no learned reranker |
| Document ingestion | `DocumentStore` in `agent/ollama_code/document_library.py`: persistent jobs, hashes, extraction caching, cancellation/recovery; `document_extract.py`: PDF/OCR, DOCX, spreadsheet locators | Preserve more structure through chunking and finish vector indexing after asynchronous extraction |
| Memory retrieval | `locus_memory/retrieval/ranking.py` and `service.py` already provide reciprocal rank fusion, diversity selection, deduplication and validity filtering | Extend these capabilities to workspace retrieval; evaluate optional learned reranking |
| Context assembly | `MemoryAdapter._packet` and the package compiler provide scoped, token-budgeted memory with final revalidation | Coordinate evidence from files, documents and optional saved chats under one bounded retrieval plan |
| Learning | `memory_learning.py` and `api/memory_learning.py`: task evidence, episodes, procedure nomination, evaluation and review | Propose reusable lessons from verified episodes instead of relying on manual nomination |
| Inspection/evaluation | Memory submission receipts, deterministic graders, isolated paired campaigns | Add retrieval relevance, source grounding and actual task-use measurements |

The new Markdown storage, conservative duplicate consolidation, source staleness,
and shared-host access are already in the baseline commit. They are not proposed
again here. The standalone memory package is a separate dependency: changes to
its public retrieval or learning interfaces should be released and pinned, rather
than patched inside `.agent-runtime/site-packages`.

## 1. Better hybrid RAG and optional local reranking

**User benefit:** find the right code or document when the question uses different
wording, while retaining exact matches for symbols, error codes and configuration.

Change `KnowledgeStore.search` to fuse ranked lexical and vector candidate lists
using reciprocal rank fusion. Reuse the package's existing pure `rrf_fuse` helper
through a supported interface; adapt diversity selection for document chunks
without inventing MemoryRecord objects. Collapse overlapping evidence, preserve
source IDs and record each rank component in diagnostics.

Add a separate optional reranker adapter after candidate retrieval. A starting
experiment is 30 candidates reduced to eight results, with a strict deadline and
the fused ordering as fallback. These are proposed tuning values. Filter scopes,
excluded paths and stale evidence before sending candidates to any model.
`/api/embed` is not a reranking API; implement the query/document-pair inference
contract explicitly and benchmark cold starts, resident RAM and latency on Macs.

Qwen's open text embedding/reranking models are candidates to evaluate. Its own
table shows the 0.6B reranker improving general retrieval while slightly reducing
the code score relative to its dense baseline; larger rerankers perform
differently. Model choice must follow Locus's coding and document evaluations.
[Qwen primary report](https://qwenlm.github.io/blog/qwen3-embedding/)

Initial fusion/diversity work needs no new service. The optional model runtime is
a separate, medium-complexity integration.

## 2. Contextual chunks and bounded parent expansion

**User benefit:** understand an isolated paragraph, code function or spreadsheet
row in its surrounding project/document context.

Replace character-only splitting in `_chunks` and `index_extracted_document`
incrementally. Begin with Markdown headings, Python AST function boundaries and
the document locators already emitted by `document_extract.py`. Add chunk fields
for parent identity, structural location and retrieval-only context. For example,
index a billing paragraph with its document title, heading and version, while
keeping the original paragraph unchanged for citations.

Retrieve small passages, then expand the relevant parent or adjacent passages
within a token allowance. Start with deterministic context. Evaluate generated
context only for ambiguous fragments, cache it by source hash and model/version,
and never present generated text as a source quotation.

Anthropic's contextual retrieval study combines chunk-specific context with
lexical/semantic retrieval and reranking. Its reported gains come from its own
corpora and model configurations; they motivate this experiment rather than
establish Locus's expected improvement.
[Contextual Retrieval](https://www.anthropic.com/engineering/contextual-retrieval)

## 3. Bounded adaptive retrieval across sources

Implemented: approved canonical memory, workspace code/text, and opted-in imported
documents share automatic turn preparation. The current chat model can request
one focused follow-up through `search_context`, explaining the missing evidence.
The host shares a two-round allowance across retries and delegated calls, a
five-second deadline per round, and a 24,000-byte evidence allowance. No separate
judge model, automatic model download, or new storage service is required.

Memory remains one exact, revalidated receipt-bound packet. Files from both rounds
are merged, deduplicated, versioned and rechecked at delivery. Keyword results
remain available when configured retrieval models time out. The collapsed
inspector records delivery phases, selected citations, exclusions, timing and
fallbacks without retaining source bodies. Adaptive retrieval defaults on and can
be disabled independently of memory saving. Previous conversations and web search
are outside this increment.

The frozen 22-question benchmark stays unchanged. A separately versioned mixed
corpus compares single-pass retrieval with scripted follow-ups; an opt-in local
model evaluation measures authored claim and citation checks separately. See
[implementation and benchmark limitations](AdaptiveRAG.md). Neither a ranking
score nor a successful retrieval is proof that an answer is supported.

Research motivation: [Adaptive-RAG](https://arxiv.org/abs/2403.14403) and
[Sufficient Context](https://research.google/blog/deeper-insights-into-retrieval-augmented-generation-the-role-of-sufficient-context/).

## 4. Temporal facts and relationship memory

**User benefit:** distinguish “What is true now?” from “What was true when we made
that decision?”, and connect services, people, decisions and dependencies.

Extend the canonical package's existing validity and supersession model with a
rebuildable entity/relationship projection: entity aliases, relation, source
record ID/revision, effective interval and observation time. Start with explicit
project decisions and source-backed relationships. Query SQLite edges under the
same scope and deletion rules as their source records; deletion must also
invalidate derived relationships. Preserve contradictory evidence for review.

Graphiti demonstrates temporal entity/relationship retrieval, including separate
event and ingestion timelines. Borrow that pattern before adopting an additional
graph runtime. Full GraphRAG community summaries belong in a later experiment for
broad questions across many documents, where their indexing cost can be measured.
[Graphiti](https://github.com/getzep/graphiti) ·
[Microsoft DRIFT](https://www.microsoft.com/en-us/research/blog/introducing-drift-search-combining-global-and-local-search-methods-to-improve-quality-and-efficiency/)

## 5. Background consolidation and verified task playbooks

**User benefit:** retain what resolved a recurring failure, including the conditions
under which the solution worked.

Use existing verified episodes and task evidence to propose a structured lesson:
problem, attempted fix, outcome, applicable repository/source versions and receipt
IDs. Schedule bounded work after a session or while idle. Use incremental lesson
updates with retained source history; avoid repeatedly rewriting every memory into
one increasingly compressed summary. An assistant suggestion must remain distinct
from a user preference or a verified outcome.

Reuse the existing procedure nomination, test-suite evaluation and review paths
before a proposed lesson becomes executable guidance. Repeated successes and
failures should influence applicability; self-reported success is insufficient.
Letta's background memory consolidation and ACE's incremental context playbooks
are useful patterns. This would extend Locus's existing learning pipeline.
[Letta memory](https://docs.letta.com/configuration/memory) ·
[ACE, ICLR 2026](https://arxiv.org/abs/2510.04618)

For deeper questions, Hindsight's separation of fast recall from explicit
reflection is another useful pattern. An optional future `reflect_memory` tool
could synthesize several evidence records and return their IDs, without making
every ordinary recall invoke another model.
[Hindsight best practices](https://hindsight.vectorize.io/best-practices)

## 6. Multimodal RAG for diagrams, screenshots and scanned PDFs

**User benefit:** find an architectural diagram or visually structured page that
text extraction does not represent well.

Build on the current PDF/OCR and citation pipeline. Retain an opt-in page-image
representation keyed by document hash/page, create a separate visual index, and
return the original page as evidence. Fuse visual and text candidates while
preserving exact page citations and the existing document exclusions. Do not
route every text document through a vision model.

Qwen3-VL-Embedding/Reranker provides an open 2026 reference for multimodal retrieval
with text, images and video. Treat its 2B model as a prototype candidate, not an
assumption of acceptable Apple Silicon performance. Verify the inference backend,
RAM, indexing time and layout-sensitive accuracy before integrating it. This is
the largest optional extension in this roadmap.
[Qwen3-VL-Embedding](https://github.com/QwenLM/Qwen3-VL-Embedding)

## Foundations to ship with the first increment

The code review found practical gaps to address before comparing new techniques:

- `_embed_missing` handles only 2,000 pending chunks per reindex. Add resumable
  backlog processing and publication checks bound to model generation and content
  hash. `DocumentStore._execute` should enqueue embeddings when asynchronous
  extraction publishes new chunks.
- Validate selected source hashes before returning evidence. The existing file
  watcher helps keep indexes current, but search should handle a missed event.
  Reuse `/api/knowledge/changes` for known changed paths and retain full-rescan
  fallback for dropped events.
- Expose embedding coverage, queue progress and semantic fallback reasons.
  Workspace vector-search errors currently fall back silently.
- Profile current exact vector scanning at realistic corpus sizes. Choose a vector
  index only if measured latency/RAM demands it; the first ranking improvements
  can use SQLite and existing local infrastructure.

## Implementation sequence and acceptance

| Increment | Deliverable | Evidence required before enabling by default |
| --- | --- | --- |
| A | Frozen corpus, retrieval diagnostics, resumable indexing, workspace rank fusion | Complete indexing after restart/model changes; source and scope correctness; lexical fallback; relevance baseline |
| B | Contextual chunks and parent expansion; optional local reranker | Better supported-answer/task results against A, with acceptable measured latency/RAM on target Macs |
| C | Bounded multi-source retrieval and evidence-sufficiency handling | Cross-source tasks improve; unanswerable questions do not gain unsupported answers; hard budgets hold |
| D | Temporal projection and episode-to-playbook proposals | Temporal/update questions and repeated tasks improve with retained provenance and verified outcomes |
| E | Optional visual document retrieval | Diagram/layout tasks improve over existing OCR/text extraction enough to justify runtime cost |

Use held-out Locus code/document tasks with exact identifiers, paraphrases,
competing versions, multi-document evidence, missing answers and poisoned source
instructions. Measure recall@k, ranking quality, citation/source correctness,
abstention, actual artifact/test success, ingestion/maintenance cost, prompt
tokens, p50/p95 latency and peak RAM. Scope and forgotten-record leaks must remain
zero. Compare changes independently with the same models and context allowances.

LongMemEval helps isolate retrieval, temporal updates and abstention; its oracle
evidence condition distinguishes retrieval failure from answer-generation failure.
Mem2ActBench (2026) evaluates whether remembered information is actually used in
tool selection and parameters. Both inform test design; neither substitutes for
Locus's own coding tasks. The existing small live campaign reported 2/6 successes
in both memory-on and memory-off arms, so functional test success should not be
presented as proven task-quality improvement.
[LongMemEval](https://github.com/xiaowu0162/LongMemEval) ·
[Mem2ActBench](https://arxiv.org/abs/2601.19935)

Run ingestion, retrieval and consolidation on the selected shared host. Both
devices should receive the same versioned evidence from that authority; no new
client-side replicas, graph server, cloud vector database or model downloads are
required for increment A. This research pass ran no new live-model benchmark.
