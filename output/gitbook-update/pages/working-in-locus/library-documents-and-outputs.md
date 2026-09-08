# Library, Documents & Outputs

Open **Library** from the sidebar or press **⇧⌘L**. Documents and Outputs open without replacing your selected conversation or its draft.

## Add document knowledge

Turn on **Document knowledge** for the workspace to discover supported documents. This is separate from text and code indexing. **Import** copies external files into the visible `Locus Documents` folder and chooses a new name if one already exists.

| Format | What is indexed |
| --- | --- |
| PDF | Page text, with local text recognition for pages without useful text |
| DOCX | Body paragraphs and tables, with source locations |
| XLSX | Visible sheets and cells using cached formula values |
| CSV and TSV | UTF-8 delimited tables |

Convert older DOC and XLS files first. Word headers, footers, footnotes, endnotes, and text in images are not indexed. Hidden spreadsheet sheets and formulas without saved values are omitted with warnings; Locus does not calculate formulas.

For PDFs with an unreliable text layer, use **Recognize all pages**. Recognition runs locally and depends on scan quality; it does not reconstruct the original page layout or tables.

Attaching a document to a chat uses temporary extraction and does not opt the workspace into persistent document knowledge.

## Search and check sources

Search results identify the source and location. PDF results open the cited page; Word and table results open the extracted section. Locus identifies a source that has changed since it was cited. Document previews offer **Open in App** and **Reveal**.

Extraction supports files up to 100 MB, 500 PDF pages, 200,000 spreadsheet cells, and 5 MB of extracted text. Partial results and failures remain visible. Cancel or retry a job as needed. Unchanged files are skipped during refresh; failed files retry after their contents change or you choose Retry. Temporary jobs expire after 24 hours.

## Keep output versions

Outputs saves immutable snapshots of captured deliverables and links them to their source chats. Identical content does not create another version. The default storage budget is **2 GB per workspace**, adjustable in Outputs, with a **100 MB per-file limit**.

If a storage limit is reached, existing history remains available and Locus identifies content it could not save. History is never silently purged. Removing output history does not delete the original workspace file.

Earlier output entries with an available source file receive **Imported current version**. Missing files remain visible as unavailable entries; older versions are not reconstructed. Websites remain live links, while local HTML files can be saved as snapshots.

## Review or revise a deliverable

1. Select an output and version to preview or export it.
2. Compare it with a previous version when available.
3. Choose **Revise** to open a draft in the output's workspace with the selected snapshot attached and the destination stated.
4. Review and send the draft through the normal agent workflow.

The saved reference stays unchanged. A successful edit can produce a new version for later comparison.
