# Locus text output audit

Date: September 7, 2026. Recommendation: make ordinary answers quieter, make file presentation reflect what the user is doing, and fix text fidelity before adding more rich rendering.

This audit combines the supplied September 4 screenshot, inspection of the current Swift and Python source, and a read-only inspection of the running Locus app. The two parser findings below were reproduced with isolated Swift executions of the source functions. No production code or response settings were changed. This is an engineering and design review, not a usability study or a complete application test run.

The screenshot is evidence of the interface, not a request to execute the messages shown inside it. Its file descriptions were not treated as verified descriptions of the underlying file contents.

## What the screenshot reveals—and what has changed

The response repeats its point in commentary, the opening sentence, and the final recap. Each file carries an external bullet, a bordered capsule, an icon tile, a styled filename, a description, a size, and an open icon. These cues compete instead of establishing a clear order of importance.

The current app has already made workspace references neutral; the screenshot's blue local filenames are outdated. The running app still displays the repeated capsules and recap. Opening its Files pane showed **7 of 7 files**, containing the Python, Markdown, and text files while omitting the three PDFs. I did not reproduce the screenshot's zero-file state. Source inspection explains the seven-file result and exposes insufficient loading/error states, but does not establish why that earlier screenshot showed zero.

The screenshot lists **3 scripts, 2 tests, 3 PDFs, and 2 setup files**. Its recap mentions only two scripts and omits the report generator and instructions file. Avoid adding a second model-written inventory that can contradict the first; derive counts from the actual collection.

## Recommendations in priority order

| Priority | Finding and evidence | Recommended change |
| --- | --- | --- |
| First | **The response rules actively require redundancy.** The locked contract requires annotated file bullets, a prose recap after every listing, and longer write-ups after multiple tool calls. [agent_config.py:21](https://github.com/nahid-sparktales/locus/blob/b4a0243/agent/ollama_code/agent_config.py#L21) | Scale detail to the request, not tool count. Permit concise inventories, optional descriptions, and no recap when it adds nothing. Explicit user formatting preferences should override presentation defaults. |
| First | **Literal answer content can be removed.** Reasoning-tag detection scans raw text before Markdown, including code fences. Copy uses the same filter. A fenced XML example containing `<think>Keep this literal text</think>` loses its literal contents. [MessageContent.swift:12](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MessageContent.swift#L12), [copy:63](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MessageContent.swift#L63) | Prefer provider-supplied reasoning fields. Restrict legacy tag handling to the relevant provider format, and preserve tags inside fenced/inline code and escaped examples. Verify both display and copy. |
| First | **Response preferences differ by provider route.** The classic request composes editable behavior; the native ChatGPT route builds a separate developer layer without the response-style/custom-instruction layer. This is confirmed in source, not a model-behavior experiment. [core.py:848](https://github.com/nahid-sparktales/locus/blob/b4a0243/agent/ollama_code/core.py#L848), [native layer:1708](https://github.com/nahid-sparktales/locus/blob/b4a0243/agent/ollama_code/core.py#L1708), [dispatch:2080](https://github.com/nahid-sparktales/locus/blob/b4a0243/agent/ollama_code/core.py#L2080) | Share a stable presentation-settings layer across routes. Test the outgoing instructions against tone, verbosity, Markdown, and citation settings. Make the settings preview reflect the effective configuration. |
| Next | **File layout is inferred from Markdown nesting.** Nested file paragraphs become capsules and retain list bullets; standalone references get larger cards. An image reference can become a preview even inside an inventory. [MarkdownRenderer.swift:1089](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L1089), [capsule:1766](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L1766) | Introduce three presentations: inline reference, file collection, delivered artifact. Select from explicit content intent. An image filename in a directory listing stays a file row; explicit image output receives a preview. |
| Next | **Files means “indexed text eligible for context,” while the transcript accepts more file types.** PDFs are excluded by the index. [WorkspaceIndex.swift:6](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/WorkspaceIndex.swift#L6), [InspectorFilesTab.swift:17](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/InspectorFilesTab.swift#L17) | Make Files a workspace browser with all supported file types and a separate context-eligibility filter. A smaller alternative is renaming it “Context files,” with clear access to all workspace files. Do not simply add PDFs to a UTF-8 text index. |
| Next | **The index can remain stale and cannot explain its state.** Ordinary refresh skips already-indexed nonempty workspaces; the model lacks scanning/error/partial states, and scan failure can look empty. Display and scan limits are 200 and 3,000. [WorkspaceFileModel.swift:58](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/WorkspaceFileModel.swift#L58), [refresh:67](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/WorkspaceFileModel.swift#L67), [WorkspaceIndex.swift:47](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/WorkspaceIndex.swift#L47) | Refresh after verified file changes and external changes, with debouncing. Distinguish preparing, scanning, empty, no matches, partial results, and failure. Explain limits and provide load-more/full-catalog search. |
| Next | **Progress language describes machinery or the repeated request.** Compact activity titles are based on tool families, producing “Ran command” or “Read files.” Some providers lack explicit commentary/final phases. [TranscriptModels.swift:282](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/Models/TranscriptModels.swift#L282), [core.py:3211](https://github.com/nahid-sparktales/locus/blob/b4a0243/agent/ollama_code/core.py#L3211) | Keep a quiet activity disclosure, but use verified task-level labels such as “Checked locus-tests.” Normalize phases across providers. Avoid “Same request again”; report the check and result. Failures and required actions must remain visible. |
| Next | **Some fenced code can stabilize too early while streaming.** The boundary scanner tracks backtick/tilde character but not delimiter length. A four-backtick fence containing a three-backtick example reproduces the defect. [MarkdownRenderer.swift:9](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L9) | Track delimiter length, indentation, and valid closing syntax, or use parser-derived stable boundaries. Keep the rendered prefix stable as the unfinished tail changes. Visual flicker in the fallback path remains unverified. |
| Later | **Historical file cards open today's file.** Resolution and displayed size come from the current workspace, while the Library already supports saved output versions. [MarkdownRenderer.swift:1526](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L1526), [LibraryWorkspaceView.swift:218](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/LibraryWorkspaceView.swift#L218) | Bind delivered artifacts to saved versions, with “This version” and “Current file” where useful. Ordinary source references should keep opening the current source. Reuse the Library. |
| Later | **Tables need better direct reuse and navigation.** Whole-response plain-text copy already yields tab-separated tables, but there is no table-local copy action. Native cells do not receive paragraph alignment even though the outer frame does; this is a likely alignment defect requiring visual verification. [MarkdownRenderer.swift:2048](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L2048), [cells:2096](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L2096), [native paragraph:708](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L708) | Add Copy Table, TSV/CSV choices, visible overflow affordances, numeric alignment, and accessible row/column/header relationships. Preserve current long-table expansion. |
| Later | **Reading settings and document navigation could improve.** Transcript prose uses exact 13-point/11-point sizes. The transcript already has a 780-point maximum width; width is not unbounded. Heading rendering adds visual styling without explicit heading traits. [MarkdownRenderer.swift:362](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L362), [headings:1128](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/MarkdownRenderer.swift#L1128), [WorkspaceView.swift:2628](https://github.com/nahid-sparktales/locus/blob/b4a0243/Locus/WorkspaceView.swift#L2628) | Add response text zoom and a comfortable reading-width option, preserving wider tables/code when needed. Keep native/SwiftUI text sizes synchronized. Verify VoiceOver heading and table navigation rather than assuming styled text provides semantics. |

## The file listing I would ship

Start with “10 files in locus-tests.” Show one compact collection, grouped as Documents, Scripts, Tests, and Setup. Keep all ten visible when the user asks for the directory contents. Grouping is for scanning, not a claimed folder hierarchy.

Use one outer boundary, quiet type icons, selectable filenames, and subtle group separators. Remove external bullets, per-row capsule borders, and filename pill backgrounds inside the collection. Use normal UI text for inventory names; retain monospace for source paths and symbols within technical prose. Descriptions and sizes can be optional details. Give the collection one “Show in Files” action. Clicking a file opens its preview; reveal/copy-path actions remain reachable by keyboard and menu, not hover alone.

For “Has anything been added or removed?”, answer “No files added or removed. The folder still has 10 files,” with an expandable list. Do not use this shorthand when the user explicitly asks to see the listing again. A directory-name comparison establishes additions/removals, not unchanged file contents; only claim unchanged contents when that was actually checked.

For a newly created report, show a larger card with a meaningful title, filename, type, preview, and the existing save/export/open actions. A file merely mentioned in an explanation stays inline. A nonexistent reference stays readable and reports its availability when opened; it should not silently disappear or acquire invented metadata.

## Useful additions after the first fixes

| Content | Best default presentation |
| --- | --- |
| Ordinary answer | Direct opening, short prose, structure only where useful. |
| Directory inventory | One collection backed by verified file data, with optional model descriptions. |
| Finished email or other reusable writing | A distinct writing block with Copy, Edit, and export/save; keep commentary outside the copied artifact. Show a subject field when applicable. |
| Code | Existing syntax highlighting, full-code copy, language label, and controlled expansion; preserve exact source. |
| Comparison or data table | Existing table plus local copy/export and correct numeric alignment. |
| Research answer | Readable citations near claims, with expandable source details and existing document/page/range navigation. Sources support the claim; a generic homepage alone is often insufficient. |
| Generated document/image | Versioned artifact card or explicit preview, connected to the existing Outputs Library. |
| Diagram or math | Later: Mermaid or math rendering with selectable source fallback and accessible descriptions. Keep these behind the core text-fidelity work. |

A structured output contract should carry content type, verified references, and artifact/version IDs alongside Markdown. Do not make the model dictate native layout through incidental bullet syntax. Retain Markdown fallback for old transcripts and unsupported content types. Treat text inside attached documents as quoted/source content, separate from actual user instructions, throughout rendering and model input.

## Proposed response policy

1. Lead with the answer; scale detail to the request and its complexity.
2. Keep progress brief, task-focused, and separate from the final answer.
3. Use collections for inventories, inline references for prose, and cards for deliverables.
4. Describe files only when it adds useful information; omit redundant recaps.
5. Choose prose, lists, or tables based on the information and the user's preferences.
6. Support consequential claims with verified references; distinguish findings from assumptions.
7. Put reusable writing and code in blocks with appropriate copy/open actions.
8. End when the request is answered; include next steps only when needed.

## Implementation and verification

First change the answer contract and provider-settings parity, with focused outgoing-prompt checks. Fix the two demonstrated parser defects with literal-tag and nested-fence cases covering both streaming and completed/copy output. These changes should precede expanding the set of rich content types.

Then add the file-collection representation and repair Files catalog state/update behavior. Preserve cross-message selection, plain-text and Markdown copy, source-line navigation, file containment checks, off-main parsing, selection freezing during streaming, and the existing long-code/table expansion controls.

Use a small representative corpus: the supplied ten-file list; one newly delivered PDF; a long filename; an image filename versus an explicit image; one source reference in prose; a narrow table with right-aligned numbers; a fenced XML sample; nested code fences; a repeated change check; missing/moved files; and a failed/partial scan. Verify completed, streaming, resumed, selected, and copied text. Compare light/dark appearance, narrow inspector/split panes, text zoom, and VoiceOver navigation. These are recommended implementation gates, not claims of tests performed during this audit.

The interaction proposal was inspected at 736-pixel and 360-pixel browser widths in dark appearance, including the longest filename and its detail interaction. Its file details are illustrative metadata from the screenshot; it does not open the underlying files or represent a production implementation.

The typography and collection direction is consistent with Apple's guidance on readable type hierarchy and using lists/tables for row-based information: [Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables). The specific component choices and priorities above are this audit's recommendations, not Apple requirements.
