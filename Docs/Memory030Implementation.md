# Locus Memory 0.3.0 integration

Reusable memory behavior remains in the `locus-memory` package. Locus supplies the
inspector/review UI, authenticated agent identity, local Ollama calls, actual task verification,
approved disposable evaluation execution and the signed macOS Keychain helper.

The required [0.3.0 dependency is published](https://github.com/nahid-sparktales/locus-memory/releases/tag/v0.3.0)
and all three dependency declarations plus the distribution audit pin the same
verified wheel. Its SHA-256 is
`aafdbdf72b04aa2e83589cf0b88f1f9c8493b6ab9e97b65b6deac6dd5802d4b6`.
Desktop and remote build probes now check the newly required APIs and backend
imports. The completed canonical cutover was not repeated; no real user profile
was changed during verification.

The user authorized release verification on October 5, superseding the earlier
RAM-related pause. The exact wheel passed 1,590 package tests on Python 3.10.22
(one optional historical parity fixture skipped), 46 focused release regressions
on Python 3.14.6 and 218 host memory/runtime tests. Both interpreters passed all
75 package imports and standalone CLI/quickstart checks. Two builds were
byte-identical; public download bytes match the recorded hash.

Five frozen held-out synthetic seeds passed retrieval/privacy gates: recall@5
0.9737–1.0, abstention accuracy 1.0, zero false abstentions and zero scope, deletion,
corrected-history or plaintext leaks. The [full package validation record](https://github.com/nahid-sparktales/locus-memory/blob/v0.3.0/docs/release-0.3.0.md)
preserves the original benchmark and exact commands. The first live local campaign
still passed 2/6 tasks in both arms; no live-task quality gain is claimed, and no
new live-model or semantic quality campaign was run. Semantic search remains
optional with keyword retrieval as the default. App build/UI verification is
recorded separately with the Locus 4.0.0 release.

New user surfaces:

- Memory on chat turns and agent runs: references to the final revalidated submission,
  current authorized content, matching/exclusion reasons and delivery state.
- Per-agent native Codex memory control; allowed memory search/proposal tools only.
- Remember workspace discoveries from helper results using the agent's saving setting.
- Local semantic model settings; installed-model selection, no automatic download.
- Verified learning: task episodes, procedure nomination, explicit test-suite approval,
  evaluation and human approval. Approval does not install instructions.
- Restore-protection status; macOS Keychain custody and offline recovery tooling.

Raw transcript files stay outside saved-chat cache encryption. Prior provider context cannot
be retracted. Recovery checkpoints detect missing deletion history but cannot recreate it.

Procedure review carries the displayed suite's fingerprint back to the host. A suite edit
requires a fresh review before approval; execution remains bound to the approved procedure,
suite and workspace fixtures. A cancellation after admission is preserved even when the
evaluation worker has not started yet. These boundaries are covered by the final installed-wheel host test suite.

## Automatic memory defaults

Locus now defaults to automatic recall, learning, and saving. Native Codex memory
also defaults on for new or missing settings. Previously stored explicit values,
including `native_codex_enabled: false`, remain unchanged. Settings > Memory exposes
these controls for the primary agent and each saved agent, with changes taking
effect on the next turn. The advanced agent editor exposes the same policy.

The new host-only `auto_save_enabled` policy defaults to true. Models still have
only search/proposal authority. The host applies the user's standing setting to
new candidates, reloads their scoped contents, and approves the exact current
revision when there are no conflicts. Turning automatic saving off leaves new
suggestions in the Memory Inbox; turning learning off stops automatic capture and
model proposals. Existing pending candidates are not bulk-approved. Procedure
evaluation and approval remain separate.

Committed direct user statements such as “I prefer concise answers” are captured
without another model call, even with transcript archival off. This fallback is
deliberately conservative: questions, quoted/code content, multiline requests,
secrets, injected attachment context, helper assignments, private identity turns,
and evaluation turns are excluded. Broader confirmed facts and decisions can be
saved through the model's existing memory tool. Capture deduplicates existing
records and retains the package's deletion suppression. Ask mode excludes
workspace memory, and agent/workspace grants still constrain every write.

The approval preference belongs to Locus, so this change does not modify the
standalone package's authority model or its pinned release wheel. Manual analysis
of a selected historical chat remains an explicit review workflow.

## Editable Markdown and memory maintenance

Canonical Locus profiles now store editable memory documents under
`$OLLAMA_CODE_HOME/memories` (normally `~/.ollama-code/memories`):

- `USER.md` holds personal memories.
- `workspaces/<workspace-id>/MEMORY.md` holds workspace memories.
- `agents/<agent-hash>/MEMORY.md` holds agent memories.
- Each scope has a separate `PENDING.md` for suggestions awaiting approval.

This follows Hermes' editable Markdown approach. The files are plaintext, with
user-only file permissions. The encrypted SQLite engine remains the lifecycle,
revision-history, search, and deletion authority; this is not a SQL-free backend.
Existing approved records are projected on first use. Keep the record markers
when editing an existing note, append plain Markdown to add a note, or remove a
complete record block to forget it. Moving a pending block cannot approve it.
Missing files, malformed edits, simultaneous edits and database changes fail
closed and preserve the text for repair. Restoring an old Markdown file cannot
resurrect forgotten records. Legacy migration shadow profiles stay read-only;
their established canonical cutover remains required before Markdown ownership.

Saved memories and Markdown imports automatically consolidate conservative
duplicate wording within the same scope, kind, evidence authority and validity.
Versions, quantities, negation, paths, confidence and source fingerprints prevent
unsafe merges. Consolidation supersedes duplicates and preserves originals and
lineage in history. Settings also exposes a manual consolidation action.

Workspace facts can attach `source_paths` through the memory API/tool. Locus
also recognizes mentioned local filenames and dependency manifests for relevant
environment facts. It fingerprints allowed workspace files without following
symlinks or reading excluded secret paths. Changes or missing files mark a memory
stale before search/automatic recall and again before submitting recalled context.
Ordinary personal preferences do not become stale just because dependencies change.
Recheck after verification explicitly refreshes the displayed revision's sources;
it does not silently reapprove outdated facts or superseded duplicates.

## One memory host across devices

Settings > Remote Runtimes > Shared memory selects a connected host worker.
Both Macs use that worker's workspace and agent identity to view, save, edit and
delete the same host-owned memory. The existing authenticated SSH tunnel carries
requests; memory credentials and decryption keys remain on the host. The shared
editor rejects an edit if the displayed revision has changed on another device.

This follows the documented [Hermes remote backend](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend)
pattern: one running backend provides the same memory to connected clients.
The host must be online. Workers under that runtime inherit its profile; distinct
workspace paths retain separate workspace memories, while personal memory is
shared. Run agents on that host to use its memory. Local chats continue to use
their local profile. No offline replication, cloud memory service, or automatic
copying of keys or memory folders is configured by this change. Codex's documented
[execution modes](https://learn.chatgpt.com/docs/environments/modes) distinguish
local and cloud execution; they do not establish automatic replication of local
memory folders.

Implementation and verification use isolated temporary profiles. No live host
connection, real-profile migration, or installed-app replacement is performed by
the source change.

Verification for this change: 355 backend cases passed together, followed by 43
focused cases after the final source-limit fix (356 distinct backend cases in
total). The native build and 21 Swift model/transport-contract tests passed.
The shared-host test follows both controller forwarding and worker proxy paths
using in-process HTTP transport; it does not claim a live two-Mac SSH deployment.
