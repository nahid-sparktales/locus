# macOS task details and selective restoration

The task detail surface brings the request, saved plan, execution evidence,
blocker, outputs, review findings, and recovery history together. Goal, Capsule,
Plan inspector, and run history open this surface. Recipe settings remain an
advanced control. Switching between the task and recipe sheets waits for the
first sheet to dismiss.

## State and compatibility contract

`GET /api/sessions/{session_id}/task` is a read-only projection. It can display
a saved plan before an execution exists without creating a run. Reopening the
view or restarting the app does not dispatch a model, retry a check, accept a
result, or restore a file.

The additive response includes `interface_version`, `schema_version`,
`owner_kind`, `run_id`, `actions`, `outputs`, and `recovery_history`. Capsule
responses include their current saved plan and attempt. The server computes
available actions from persisted state. A state label, stale desktop cache, or
old completed goal cannot authorize a later task's actions. Unsettled capsule
actions retain their existing recovery owner and do not expose Resume, Accept,
or Run again as a shortcut around reconciliation.

Desktop controls use existing Goal, Capsule, and run lifecycle endpoints.
Acceptance remains explicit and distinct from machine verification. Legacy
responses without action capabilities still render history, but do not enable
new mutating controls. Existing mobile endpoints and models remain compatible;
unknown response fields are additive. Legacy plan steps remain sequential
writers, absent evidence remains unverified, and absent cost stays unknown.

The database migrates successively from schema 14 through 20. The independent
runtime owns migrations 15–17; task links and evidence use 18, task usage and
spans use 19, and file history/restoration uses 20. Migration regressions start
from schemas 14 and 17, retain the legacy run and runtime limits, and confirm
that reading an upgraded task does not start execution or invent evidence.

## Restoration contract

Only captured task-owned edits are eligible. Structured edits, artifact writes,
and helper integrations supply explicit capture boundaries. Opaque commands,
interrupted ownership, unsafe paths, and exceeded limits are listed as exclusions.

1. Select a captured change for each file and request a preview with `change_ids`.
2. Review the proposed reversals and conflicts; select the ready files to apply.
3. Apply with the preview `token`, expected task `revision`, `selected_paths`,
   and exact per-file `fingerprints` returned by the preview.

A stale token, revision, selection, or fingerprint is rejected before writing.
Another active chat in the same execution location blocks restoration. File
history changes also advance the task revision. Each file is checked again
immediately before its atomic write. Protected directory traversal prevents
symlink redirection during both capture and restoration.

Text reversal preserves unrelated later edits when the captured reversal has a
unique match. Conflicting files remain unchanged and can be left out of the
selection. Binary files require the exact recorded post-edit contents. Created
and deleted files are also supported in Git workspaces and ordinary folders.

Recovery content and a durable journal are saved before changes are applied.
A crash after a file write but before its journal update is recoverable without
replaying execution. Reopening only shows the journal. Explicit recovery or
Undo restoration restores previous files only when their current contents still
match the recorded restoration; later conflicting edits require manual review.
Completed and recovered entries remain visible in restoration history. External
actions and conversation history are not part of file restoration.

The limits remain 4,096 candidate files, 64 MiB per file, and 128 MiB per
restoration batch including recovery copies. Captured content is bounded too.

## Acceptance gates

| Gate | Coverage |
| --- | --- |
| Task details open without dispatch | Backend projection and desktop rendering tests |
| Persisted controls and lifecycle ownership | Work, Goal, Capsule, uncertainty, and sheet routing regressions |
| Schema-14/17 and legacy compatibility | Real migration, additive decoding, and legacy step defaults |
| Selective reversal preserves later edits | API preview/apply with selected and conflicting files |
| Stale previews cannot write | Revision, fingerprint, path, duplicate apply, and intervening edit regressions |
| Restart during restoration | Crash after atomic write, inert reopening, and explicit recovery |
| Bounds and unsupported ownership | Candidate and batch exclusions, binary checks, and symlink traversal |
| Desktop accessibility and restoration flow | Model/render checks and UI preview, selection, apply, and undo |

The final integrated checkout passed **2,316 backend tests** and **50 desktop
model/routing tests**. The independent-worker fixture exercised task details,
current verification, restoration, and undo through its HTTP connection. A
tracked-source secret scan and lint also passed.

The integrated macOS UI gate remains **open**: three attempts stopped before
executing tests because XCTest timed out enabling automation mode. The earlier
pre-integration snapshot passed **11 UI tests**; those results are retained and
are not counted as a pass for the integrated revision. No system permissions
were changed. The earlier restoration capture is
[available here](../output/task-reliability-2026-09-09/TaskRestoration-macOS.png).

Current raw results and limitations are in
[task-restoration-integration-validation.json](../output/task-reliability-2026-09-09/task-restoration-integration-validation.json).
The preceding snapshot is retained in
[task-restoration-validation.json](../output/task-reliability-2026-09-09/task-restoration-validation.json).
The broader implementation and earlier validation are described in
[Task reliability](TaskReliability.md). Live-provider recovery and comparative
campaign gates remain **deferred, not passed**. This task-view follow-up does
not run campaigns or expand evaluation/accounting work.
