# Companion and Locus performance audit

Scope: the 4.2.2 source, including the main, inspector, menu-bar, and desktop companion send paths; local HTTP and WebSocket transport; worker setup; provider selection; transcript rendering; animation and activity observation; sidebar/catalog refresh; and the existing repository checks. This is a performance and reliability audit, not a claim that every application feature or external model was exhaustively exercised.

## Findings and changes

1. **The inspector waited for network work before acknowledging Send.** Its draft stayed in the composer through two full-history reads, queue admission, worker/provider setup, and acceptance. Submission now clears the exact submitted draft and displays a pending user message synchronously. One lightweight metadata read still validates the durable conversation owner, workspace, and archived status before execution. Canonical run IDs reconcile the pending message with the saved transcript. Failures and cancellation restore an untouched draft without overwriting later typing or an intentional clear, including edits from another composer. When restoration would replace a newer draft, the submitted text stays copyable with an explicit not-sent label. Attachments are consumed only after acceptance. The desktop's foreground composer now uses the normal foreground send pipeline.
2. **Send validation scaled with conversation length.** The new `/api/sessions/{id}/execution-context` route reads the session header and metadata rather than reconstructing, sanitizing, and serializing the transcript and its activity. The existing full-history API still serves actual history views. Ownership checks remain authoritative; no client catalog cache substitutes for them.
3. **Repeated provider selection threw away warm state.** Identical effective Ollama/API configurations now retain the client and discovered context information. Changes to credentials, account, endpoint, model, auth style, context settings, or reasoning settings invalidate that reuse. Transport validation still runs, and explicit verification still checks the endpoint. ChatGPT/Claude account validation is unchanged.
4. **REST response decoding ran on the UI actor.** JSON decoding now runs on the generic executor, keeping large chat/catalog responses off the main thread. Connection state and callers remain on the main actor; HTTP and decoding errors retain their behavior.
5. **Companion activity invalidated every visible avatar repeatedly.** Updates from eight model owners now coalesce, reuse one derived presentation per profile, and publish only when visible activity actually changes. Tests cover a 100-update burst and reads during a source's pre-assignment notification.
6. **Short companion transcripts always used estimated lazy layout.** The inspector now shares the main chat's established policy: eager layout through 40 rows, lazy layout for longer histories. This avoids the previously documented long-Markdown resize loop without removing history virtualization.
7. **A failed foreground send could overwrite the next draft.** Failure recovery now checks the composer revision. If the user typed or deliberately cleared another draft, the submitted message remains available in the transcript for manual retry and the newer draft stays intact.

## Measurements and regression method

Run `python agent/benchmarks/companion_send_context.py --messages 10000` in the agent environment. It creates and deletes its own synthetic chat without opening user history or contacting a model. For a 20.9 MB, 10,000-message fixture on this Mac:

| Local preflight work | Median reconstruction + JSON serialization | Response size |
| --- | ---: | ---: |
| Full session detail | 166.027 ms | 20,594,778 bytes |
| Execution context | 0.229 ms | 392 bytes |

These figures measure local preparation only, not time to a model's first token. The inspector previously paid the full-detail cost twice before dispatch. A separate provider test shows four identical selections issuing one metadata-discovery request rather than four.

The Debug UI live-resize probe produced nine samples at a final width of 1,003 points, with 35.13 ms p95/max instrumented main-thread work. This run checked resize lifecycle and final geometry; the optional Release timing-budget enforcement was not enabled, so it is not evidence of meeting a frame-time budget.

Send regression tests hold validation or dispatch responses deliberately, then assert the message is visible and the composer is clear before releasing the response. They also cover cancellation, stale ownership, failure, later edits, repeated messages, handoff, and run-ID reconciliation. A native decoding probe checks the thread executing every REST response decoder. The UI fixture delays validation for ten seconds while checking immediate presentation and cancel/recovery; no real provider is used.

## Remaining performance boundaries

Cold worker launch, account validation, admission behind active work, provider network latency, context preparation, and model generation can still delay a reply. The changes above keep submission feedback independent of that work and preserve durable acknowledgement and permission checks.

Source review also identified candidates for subsequent measurement: synchronous filesystem probes when rebuilding the sidebar catalog; agent grouping inside sidebar view evaluation; first-use sprite decoding; repeated custom portrait decoding; and a one-entry imported animation cache that can thrash with multiple custom characters. They were not changed without a measured regression. Bundled sprite frames are already cached; pointer reactions and playback already respect visibility. Broad metadata refresh remains sequential, but it no longer gates the companion's accepted-send feedback.

## Verification

- Backend: full suite ran with 3,699 passing tests and 31 passing subtests. Its only failure identified the new endpoint missing from the expected route snapshot; after updating that fixture, all 31 app-factory and new regression tests passed.
- Native: the full `LocusTests` target executed 2,081 tests with zero failures and two skips (the external Agent Worlds packaged fixture was absent, and a hosted pointer fixture could not activate its window). After the last draft-recovery change, a fresh build and 75 focused native tests passed without failures or skips. All six UI tests passed: delayed send/cancel, independent drafts, shared main/panel conversation, pinned long-history scrolling, activity-window visibility, and live transcript resizing.
- Repository checks: Ruff, design-system source audit, transport-security audit, protocol manifest, pinned runtime verification, Agent Worlds host boundary, and `git diff --check` passed. The advisory reviewability report flags existing large production files.
- Runtime dependency audit: no known vulnerabilities among the packages it could audit. The pinned URL package `locus-memory` and private `locus-runtime` wheel are outside the advisory database's coverage.

The macOS test hosts use separate bundle identities and synthetic data. Tests do not send prompts to a real model. Provider time-to-first-token, live-account startup, signed release packaging, and every optional product integration were not benchmarked by this audit.

Local evidence from this run:

- Backend full run: `/tmp/locus-performance-agent-full.log`; corrected contract/new-regression rerun: `/tmp/locus-performance-agent-focused.log`.
- Full native result: `/tmp/locus-chat-model-native.591pNs/host.KqLgvD/tests.xcresult`.
- Final native regressions: `/tmp/locus-chat-model-native.LJVP0Y/host.jIT3yX/tests.xcresult`.
- UI result: `/tmp/locus-distribution-ui.n881Bd/tests.xcresult`; screens were reviewed locally.
