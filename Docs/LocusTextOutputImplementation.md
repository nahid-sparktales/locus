# Locus text output implementation

Implementation notes for the September 7, 2026 text-output audit. See [the original audit](LocusTextOutputAudit-2026-09-07.md) for the screenshot findings and design rationale.

## User-visible changes

- **Answers and progress:** shared response rules favor a direct answer, useful detail, and optional file descriptions. They no longer require a repeated inventory recap or more prose merely because more tools ran. Completed commentary appears under “Progress update”; current work and actionable failures retain their existing visibility.
- **Text fidelity:** provider reasoning is handled separately from answer text. Legacy reasoning-tag handling preserves literal tags in Markdown examples, and streaming boundaries account for nested fence lengths. Copy uses the same answer interpretation as display.
- **File presentation and sources:** ordinary file references stay inline, inventories use one grouped collection, and deliverables receive an artifact presentation. A collection derives its count from verified metadata and offers “Show in Files.” Source details retain web or document/page destinations. Artifact actions distinguish the current file from a saved version associated with the originating run.
- **Files browser:** Files now lists all file types in a folder tree, including generated directories. Expand folders as needed, search paths across the visible workspace, and include hidden files through File visibility. Text preview and document/media preview use their existing appropriate viewers. A separate action adds eligible text to context or attaches a supported document/image to the message.
- **Reusable writing:** explicit writing parts have Copy, Edit/Done, original/edited views, and text or rich-text export. Editing creates a local draft; the original answer remains available. Email parts can include a subject.
- **Tables and prompt preview:** Copy table exports every row as tab-separated text, including collapsed rows; Table actions offers CSV export. In agent behavior settings, the preview fetches the effective backend instructions for the selected mode. Profile previews use that profile’s provider/model, while Primary Agent uses the current conversation route. Loading, failure, and Retry are explicit.

## Response data and compatibility

The backend’s `attach_output_parts` tool stages presentation metadata for the next completed answer. The supported kinds are `markdown`, `file_collection`, `writing`, `artifact`, `sources`, and, since 2.7, `image` and `interactive` (see [the image and interactive answers note](LocusImageAndInteractiveAnswersImplementation.md)). File metadata is checked by the runtime; model descriptions remain descriptive text. The tool currently accepts up to 40 parts, 500 entries/references per collection, and a 1 MB serialized document. The complete wire contract and validation rules are in [RESPONSE_PARTS_PROTOCOL.md](../agent/RESPONSE_PARTS_PROTOCOL.md).

Completed classic and native events carry additive `response_parts: {"version": 1, "parts": [...]}` together with a stable item ID and run ID. The ordinary message content remains a complete Markdown fallback for older clients, session export, model context, and recovery. Swift renders supported parts only after completion; absent, malformed, or unsupported metadata falls back to ordinary content. Duplicate completion events reuse the same transcript item. An authoritative replacement updates its text and metadata; changed text without replacement metadata clears obsolete rich parts.

Writing drafts and artifact bindings use canonical workspace, session, provider item, and part identity, rather than the view’s transient UUID. Drafts use the existing Notes store. Artifact bindings use the Outputs Library and require origin/run agreement when resolving a saved version; an arbitrary newer copy of the same path is not substituted. File existence and workspace containment are checked again when an action is used.

`POST /api/response-preview` accepts `agent_config`, `mode`, and optional `provider`, `model`, and `native_mode` overrides. It composes instructions on a cloned core and returns provider/model/mode/route, named layers, effective text, and a base-prompt explanation. It neither changes the active account nor sends a model request. A requested native route without the required runtime reports an error instead of silently presenting another route’s prompt.

## Files browser lifecycle and limits

`WorkspaceBrowserModel` owns the browser; `WorkspaceFileModel` and `WorkspaceIndex` continue to own the text-only composer candidate index. A browser refresh does not widen that index to include binaries.

The provider reads directory metadata off the main thread and only lists immediate children for an expanded node. Directory rows are shown in pages of 200, with explicit load-more controls. Packages and directory symlinks remain leaves. Search scans beneath the workspace independently of expansion, including generated directories and following the same hidden-file setting as the tree. It debounces input by 250 ms, consumes traversal in bounded batches, presents results in pages of 200, and pauses at 10,000 matches with an explicit Continue action. Inaccessible paths are reported as partial search results.

Native filesystem events invalidate affected loaded directories with debouncing. Dropped events trigger full invalidation of loaded nodes. Workspace generations and request identities reject obsolete results after navigation or cancellation; unopened folders load their current contents when expanded. The text candidate index is marked stale for a later composer request. Each directory has loading, ready, empty, and failed/retry states.

Context actions follow the existing input paths: eligible text up to 256 KB enters the context pack; larger supported text up to 500 KB and images up to 15 MB use message attachments; PDF/DOCX/XLSX/CSV/TSV use Library extraction with its 100 MB input limit. Aggregate message/context budgets and extraction warnings still apply. Visibility in Files does not itself grant context eligibility.

## Verification status

Release verification ran against the combined 2.6 checkout outside Documents:

- **1,344 native tests passed**, including response output/events, rendering, workspace browsing, transcript selection, native browser input, and Agent regression coverage.
- **1,992 backend tests passed**, including response policy, protocol, persistence, cancellation, and effective-preview request validation.
- Mobile formatting, analysis, all **14 tests**, Android, and unsigned iOS simulator builds passed before [mobile PR #1](https://github.com/nahid-sparktales/locus-mobile/pull/1) merged.
- Native app/test builds, Python lint, dependency audit, protocol manifest, all repository shell syntax checks, generated-project consistency, design-system audit, credential scan, and whitespace checks passed. The advisory reviewability report was reviewed; the broad scope is intentional for this combined release.
- Manual inspection covered file collections, PDFs, writing editing/undo/save/copy/original recovery, complete table copying, and immutable artifact versions. Light/dark appearances and narrow layouts were inspected with synthetic data. No provider runs or user document writes were needed.

Local UI automation is unavailable with Developer Mode disabled. Hosted CI runs the complete native UI suites for both editions; exact results and artifacts are available in [release PR #75](https://github.com/nahid-sparktales/locus/pull/75). Publication is gated on successful CI at the merged main revision. These automated assertions and the manual checks do not establish a complete VoiceOver usability review.
