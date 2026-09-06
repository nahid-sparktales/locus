# Library, setup, and contextual Agent verification

Implementation and verification performed on September 4, 2026 on Apple silicon.
The working tree contains the implementation; no release was published.

## Delivered surfaces

- Workspace Library with persistent Documents and immutable Outputs versions.
- Local PDF text recognition, Office/tabular extraction, bounded durable jobs,
  opt-in indexing, temporary attachments, and structured source citations.
- Resumable Getting Started with document and coding examples and completion
  tied to the exact successful run and captured output.
- Contextual Agent inspection and durable origin/attempt history, with scoped
  actions and direct links to saved output versions.

See [the user guide](LibraryAndGettingStarted.md) for behavior and limits,
[the Agent audit](AgentInspectorAudit.md) for navigation/data findings, and
[the backend protocol](../agent/PROTOCOL.md) for routes and helper records.

## Automated and rendered checks

The final focused backend regression suite passed 485 tests covering the existing
backend, knowledge, extraction jobs, app factory, Agent inspection, event
triggers, schedules, and workflows. The run completed with `485 passed in
35.23s` (execution session 10255, final output chunk 519fe0; no separate log file
was retained). It used:

```sh
agent/.venv/bin/python -m pytest \
  agent/tests/test_backend.py agent/tests/test_knowledge.py \
  agent/tests/test_document_library.py agent/tests/test_app_factory.py \
  agent/tests/test_agent_inspector.py agent/tests/test_event_triggers.py \
  agent/tests/test_schedules.py agent/tests/test_automation_workflows.py \
  agent/tests/test_agent_session_identity.py -q
```

The native PDF helper separately passed
embedded text, scanned and rotated OCR, forced OCR, location records, and
the 500-page limit against generated real PDFs.

The final focused Swift run passed 407 tests, including extraction/citation decoding,
snapshot immutability and origin identity, quota behavior, shutdown capture,
setup persistence and canonical completion, inspector navigation and async
isolation, authoritative history, Attention scoping, and independent recovery
actions. A broader native run exposed two unrelated intermittent tests: a
stream-buffer test host exit and a wallet fixture count mismatch. Both passed
when rerun in an earlier focused suite; the broad run is not represented as green.
An existing native source-enumeration test later stalled inside macOS directory
opening and was stopped. Its unchanged source rules were independently checked
across all 196 Swift source files and 43 feature-access patterns and passed.
The native publication-isolation test also passed with all four new models.

Across the final focused native UI runs, all 14 distinct tests passed,
including two actual accessibility audits. These runs exercise setup
Back/Skip/resume and keyboard navigation,
preserving an unsent draft across Library tabs, page navigation in a real
scanned PDF, and comparing two immutable output versions after deleting the
original. Image/text preview replacement and closing the Library passed after
fixing embedded Quick Look ownership and preventing transient previews while
text loads. Agent UI tests cover exact incoming-event and execution selection,
back navigation, side chats, and selecting a parent without replacing the
open conversation, as well as schedule configuration and stopped versus paused
states. The final Agent-only rerun passed all six tests, including the expanded
configuration accessibility audit. These counts describe distinct coverage
across focused runs, not one uninterrupted 14-test run.

Rendered captures were inspected for PDF content, readability, hierarchy, and
visible controls. A stale desktop application alert overlays the conversation
in the final expanded-configuration capture; the inspector remains visible.
That capture is not evidence of an unobstructed full-window visual review.

Protocol-manifest compatibility, the design-system audit, and whitespace
checks passed. Dependency locks and bundled third-party notices include the
document parsers.
After the final document reconciliation error-message adjustment, all 31
document/knowledge tests passed again. The scoped backend lint check passed.

## Real-model evidence

An isolated backend run using the already-installed local model completed in
80.01 seconds. It indexed a mixed PDF, found the scanned page's marker through
document search, and wrote a summary with a page-and-hash citation. The tool
event identified the created file and originating run; both `turn_done` and
the canonical run record reported completion with the expected chat and
workspace. Evidence and source/output files are retained at
`/tmp/locus-connected-completed-acceptance`.

This verifies the live extraction/search/generation path. The setup controls,
capture persistence, revision preparation, and version comparisons also have
focused coverage; this is not a claim that every acceptance-matrix combination
was performed as one uninterrupted manual session.

## Distribution qualification

The final arm64 direct-download package is verified with the available
Developer ID certificate (`SparkTales Inc.`, team `4X4RJA7GMD`), embedded native
helper, bundled parser import check, sealed bundle verification, and ZIP
extraction round trip. The signed helper from that final package also passed
the generated-PDF extraction/OCR fixtures. The Mac App Store
arm64 configuration also built successfully with the available Apple Development
identity (team `4X4RJA7GMD`). Its deep/strict signature verification and
distribution audit passed. Entitlement checks confirmed the app sandbox and
the document helper's sandbox inheritance. This is a development-signed MAS
configuration, not an App Store distribution export.

Public notarization and App Store distribution export/submission are separate
release steps and have not been performed. Automated accessibility checks and
keyboard tests do not replace a full manual VoiceOver, larger-text, theme,
and reduced-motion acceptance pass. The existing sandbox workspace-switch
path restarts the coordinator after a newly selected folder grant; setup does
the same before its first task. This late-grant path was inspected in code,
but was not exercised against a live signed MAS backend. Existing UI fixtures
bypass backend bootstrap, while a normal launch uses the person's actual
sandbox data, so they cannot establish an isolated result for this case.

Before App Store release, use a disposable macOS account or VM to launch the
signed app, wait for its backend, and select a fresh external workspace after
startup. Confirm the backend restarts, then import a scanned PDF, search its
recognized text, open its cited page, quit, and reopen the same records. This
is a remaining release acceptance check, not a verified outcome of this run.

## Evidence locations

These are local verification artifacts in `/tmp`, not published releases.

| Evidence | Location |
| --- | --- |
| Release build | `/tmp/locus-library-release-qualified.log` |
| Developer ID signing, parser imports, ZIP round trip | `/tmp/locus-library-direct-qualified.log` |
| Signed direct-download app | `/tmp/locus-library-final-direct/Locus.app` |
| Private verification ZIP | `/tmp/locus-library-final-direct/Locus-library-verification.zip` |
| Final signed PDF helper fixtures | `/tmp/locus-library-final-signed-helper.log` |
| Mac App Store configuration build | `/tmp/locus-library-mas-qualified.log` |
| MAS distribution audit | `/tmp/locus-library-mas-audit.log` |
| MAS signing identity | `/tmp/locus-library-mas-identity.log` |
| MAS app and helper entitlement records | `/tmp/locus-library-mas-app-entitlements.plist`, `/tmp/locus-library-mas-helper-entitlements.plist` |
| Development-signed MAS app | `/tmp/locus-library-derived/Build/Products/ReleaseMAS/Locus.app` |
| Focused native unit run | `/tmp/locus-library-product-tests.log` |
| Library, preview, and Agent UI run | `/tmp/locus-library-ui-qualified.log` |
| Final Agent UI and expanded-configuration accessibility rerun | `/tmp/locus-library-agent-ui-qualified.log` |
| Final document/knowledge rerun | `/tmp/locus-library-document-qualified.log` |
| Exact Agent UI result bundle | `/tmp/locus-library-derived/Logs/Test/Test-Locus-2026.09.04_19-20-36--0400.xcresult` |
| Live extraction/search/generation evidence | `/tmp/locus-connected-completed-acceptance` |

The private ZIP SHA-256 is
`1862c3d2514f7f9a5576353ad0591520be8bbdbd7f9838a12b9f8127dee85bd0`.
