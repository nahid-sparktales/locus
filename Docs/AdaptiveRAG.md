# Adaptive retrieval

Locus retrieves permitted memory, workspace code/text, and opted-in documents
before an eligible work turn. The answering model can request one focused
follow-up when it identifies missing information. The same coordinator governs
`search_context`, `search_memory`, and `search_workspace_knowledge`; changing the
tool name does not create another search allowance.

## Controls and flow

In **Settings → Memory → Workspace search index**, **Adaptive retrieval** is on
by default. Choose **Save Index Settings** after changing it. The workspace
setting is `adaptive_rag_enabled` in `POST /api/knowledge/settings`; omitted
updates preserve its value, including explicit `false`. Turning this off removes
the combined automatic retrieval flow while preserving the existing manual
search and memory settings.

Memory recall/search switches and allowed personal/workspace/agent scopes still
apply. Workspace evidence additionally requires workspace read permission,
enabled indexing, and the workspace-knowledge capability. Document evidence
requires the separate document-library opt-in. Ask mode, private identity mode,
disabled/shadow memory-engine rollout, and evaluation turns with memory disabled
do not start adaptive retrieval. Native Codex memory delivery respects its
existing native-memory policy switch.

1. The initial round searches allowed sources concurrently. Workspace retrieval
   combines keyword and optional local vector ranks, uses optional local
   reranking, and preserves original evidence and citations.
2. A follow-up requires a focused `query`, a concrete `missing_information`, and
   selected sources (`memory`, `workspace`, `documents`, or `all`). Repeating the
   same normalized query/source request reuses the current state. Helpers share
   their parent turn's two-round allowance and retrieve memory under their own
   permissions.
3. Before delivery, Locus rechecks permissions, indexed identities, source
   versions, and memory receipts. Model reference data carries memory IDs and
   revisions, or file IDs, SHA-256 hashes and original source locators. It is
   supplied as untrusted request-only evidence. A successful search or high rank
   does not establish that a source supports the answer.

With adaptive retrieval enabled, legacy Solo workers use the ordinary completion
route on the same selected provider and model instead of the hosted multi-agent
loop. This lets Locus inject freshly revalidated evidence on every request while
keeping worker tool history free of retrieved bodies. Native workers receive
fresh evidence at the tool-result boundary. Helpers use host-derived memory
identities and separate packets; successful requests confirm their delivery
receipts, while failed or unconfirmed requests remain uncertain. Turning adaptive
retrieval off preserves the existing hosted-route choice.

## Bounds and inspection

Each source-retrieval round gets a five-second deadline. A bounded worker pool
limits concurrent work. Local-model failure or timeout keeps freshly validated
keyword evidence when available. Cancellation and changes to the active turn,
session, run, workspace, agent, or policy prevent obsolete results from being
installed. Final source checks are additional local work; the deadline is not an
end-to-end response-time guarantee or an atomic filesystem snapshot.

There are at most two retrieval rounds per turn. Workspace search returns at
most 24 ranked candidates per round, retains at most 48 across rounds, and packs
up to eight file/document results. Memory selection is capped at 12,000 bytes
inside a shared 24,000-byte evidence allowance. Packed-byte reporting counts the
actual memory/reference text and separating newline; 512 additional bytes remain
reserved for provider wrapping. These are UTF-8 byte limits, not model-token limits. Existing memory packet/receipt compilation remains intact.

Automatic retrieval never rebuilds a cold or older-version index. It reports
`index_not_ready`; use **Rebuild Index** in workspace search settings. Pending
embeddings do not block keyword search. No retrieval setting downloads a model.

The chat inspector's **Retrieval for this turn** section shows source types,
rounds, delivery state, citation identities/versions, omissions, fallbacks,
packed bytes, and duration. `GET /api/retrieval/trace?run_id=…` applies current
access checks. Persisted retrieval traces contain no query text or source bodies;
“submitted” describes delivery, not proof that the model used the evidence.

## Evaluation

The separate [mixed-source fixture](../agent/tests/fixtures/adaptive_retrieval_v1/README.md)
contains five canonical memories and six source files, including valid Python
code and an extracted CSV document. Eight questions cover memory-to-code and
memory-to-document lookup, competing versions, a direct preference, irrelevant
evidence, a changed file, an expired memory, and an unanswerable question.

Run from `agent/`:

```sh
python -m ollama_code.adaptive_retrieval_evaluation --output /tmp/adaptive-report.json
python -m pytest tests/test_adaptive_retrieval_evaluation.py
```

The [saved offline report](Benchmarks/adaptive-retrieval-v1.json) compares actual
coordinator behavior with one pass versus authored focused follow-ups:

| Metric | One pass | Authored follow-up |
| --- | ---: | ---: |
| Mean judged evidence recall | 75% | 100% |
| Combined MRR | 1.00 | 1.00 |
| Memory / workspace / document MRR | 1.00 / 0.50 / 0.00 | 1.00 / 1.00 / 1.00 |
| Citation validity | 100% | 100% |
| Follow-up rate | 0% | 75% |
| Largest packed evidence | 953 bytes | 1,282 bytes |

Combined MRR follows actual delivery order: selected memory packet items, then
packed workspace/document results. Per-source MRR restricts that order to one
source type. A relevant pointer can rank first while the answer-bearing code is
still missing, so MRR complements evidence recall. Citation validity checks
current source hashes/revisions and exact source text/locators independently of
relevance. One irrelevant-source question intentionally retrieves evidence;
retrieval abstention is not answer-model abstention.

This is a small authored regression fixture, not held-out accuracy evidence or an
answer-quality claim. The deterministic follow-ups are supplied by the fixture,
not chosen by a model. A fresh run of the unchanged 22-question lexical fixture
also retained 100% recall and citation validity, with unchanged MRR and nDCG;
its original [saved report](Benchmarks/workspace-retrieval-v1.json) is preserved.
Timings in both reports are diagnostic local samples, not latency guarantees.

Optional live evaluation uses an explicitly selected, already-installed local
Ollama model:

```sh
python -m ollama_code.adaptive_retrieval_evaluation \
  --live-model YOUR_SELECTED_MODEL --live-host http://localhost:11434 \
  --output /tmp/adaptive-live-report.json
```

It compares single-pass answers with model-selected follow-ups, allowing one
follow-up only. Grounding checks use authored answer phrases plus exact quotes
from supplied evidence; they are transparent string checks, not general semantic
entailment or a model judge. Decisions, claims, citations, abstentions, errors and
forbidden answer phrases remain available for inspection. No real live-model
results are included in the saved offline report.

Both modes run in a disposable worker/profile with the real coordinator, memory
adapter and engine. Fixture host capabilities exclude external memory providers
and Keychain discovery. Proposals, auto-saving, archival and generated-answer
learning are not invoked; the evaluator verifies canonical memory records and
revisions remain unchanged. It never downloads models or opens the user's
knowledge/memory databases.
