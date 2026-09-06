# Library and Getting Started

The workspace Library opens from the sidebar or **Workspace Library** command
(Shift–Command–L). Opening it preserves the selected conversation and draft.
It contains **Documents** and **Outputs**.

## Documents

Turn on **Document knowledge** to discover supported documents in this workspace.
Text and code indexing keep their existing settings. The document formats are
PDF, DOCX, XLSX, CSV, and TSV; older DOC and XLS files require conversion first.
**Import** copies external files into the visible `Locus Documents` folder and
chooses a new filename when one already exists. Chat attachments use temporary
extraction and do not opt the workspace into persistent knowledge.

PDF extraction uses the bundled PDFKit/[Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images) helper locally. Embedded text is
read page by page; pages without useful text are recognized. **Recognize all
pages** retries unreliable text layers. Recognition quality depends on the scan;
this indexes text, without reconstructing the original page layout or tables.
Word extraction preserves body paragraph and table locations. Headers, footers,
footnotes, endnotes, and text inside images are not part of the Word text index.
Spreadsheet extraction names visible sheets and cells and reads cached values.
Hidden sheets and cells without saved formula values are omitted, with warnings;
formulas are never calculated. CSV and TSV files must use UTF-8 encoding.

Search results carry the workspace, source hash, and location. PDF results open
their page; Word and table results open the extracted section. A source that has
changed since the citation was made is identified rather than silently treated
as the cited version. General document previews are owned embedded [Quick Look](https://developer.apple.com/documentation/quicklookui/qlpreviewview)
views, with Open in App and Reveal actions.

Processing is bounded to two concurrent jobs globally and one per workspace,
100 MB source files, 500 PDF pages, 200,000 spreadsheet cells, and 5 MB extracted
text. Partial extraction and individual errors are visible. Jobs can be
cancelled or retried; exclusions and removal also remove searchable content.
Temporary jobs expire after 24 hours and are cleaned up on restart.
Unchanged files are skipped during background refresh. Failed files retry when
their contents change or when Retry is selected. Within a workspace, identical
file contents can reuse a completed extraction with matching format and OCR
settings; expired temporary results and older extractor versions are not reused.

## Outputs

The Outputs store keeps serialized SQLite metadata separately from immutable,
content-hashed snapshots under Application Support. Identical content does not
create another version. Capture combines tool results with filesystem changes
and flushes pending work before the next task writes files.

The default budget is 2 GB per workspace, adjustable in Outputs, with a 100 MB
per-file limit. Reaching a limit preserves saved history and identifies content
that could not be saved. History is never silently purged. Removing library
history does not delete the original file.

Old session output entries migrate once. Existing files receive **Imported
current version**; missing files remain unavailable entries. No earlier versions
are reconstructed. Websites stay live links; local HTML files can be snapshots.

Choose a version to preview or export it, compare it with a previous version,
or prepare a revision. **Revise** opens a draft in the output's workspace with
the selected snapshot attached and the destination stated. Send it through the
normal agent workflow to make changes. The saved reference stays immutable.

## Getting Started

New installations open setup automatically. Existing users can open it from
**Help → Getting Started**. Its four steps are: choose a starting point, connect
a model, choose a workspace, and complete a first task. Back and Skip preserve
progress; failed connection and task checks remain retryable.

Local Ollama is the default. Existing connection editors, account authentication,
model downloads, and model recommendations are reused. Hosted service costs and
local downloads are described beside their choices.

The document example writes `Locus Summary.md` with citations. The coding example
writes `Repository Overview.md`. Both can use bundled sample material or a
chosen workspace. Nothing runs until **Run first task** is selected. Completion
requires the original task's durable completed record and a saved Outputs version
attributed to that same run and chat. Follow-up messages and workspace changes
do not replace this evidence. A completed task allows 30 seconds for its output
to be saved before reporting a retryable failure. Task time describes this run,
not model quality. Skipping never records successful completion.

## Distribution and verification

`Tools/BuildDocumentExtractor.sh` compiles and signs the native helper for both
app targets. App Store helpers inherit the containing application's sandbox.
The main backend coordinates restored document jobs; per-chat workers share
durable jobs and cross-process concurrency locks without independently restoring
the catalog. External workspaces selected after startup require refreshed
backend access; setup restarts the coordinator after obtaining the folder grant.

See the document protocol fixtures and focused extraction, output-store,
onboarding, and Agent-inspector tests for deterministic coverage. Native UI
tests exercise Library draft preservation and setup navigation. Release
qualification also requires signed direct-download and App Store builds and
the connected scanned-PDF → citation → output → revision flow with a real model.
See [the implementation verification report](LibraryImplementationVerification.md)
for completed checks, retained evidence, and remaining release acceptance work.
