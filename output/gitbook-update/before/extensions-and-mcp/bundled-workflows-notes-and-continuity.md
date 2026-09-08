> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/extensions-and-mcp/bundled-workflows-notes-and-continuity.md).

# Bundled Workflows, Notebook & Continuity

Use bundled development workflows, Notebook and Notes, and private cross-chat continuity.

Locus includes development workflows that can start automatically in Work, Plan, and Grill chats.

## Bundled workflows

The built-in suite includes Task Observer, Superpowers, lightweight workflow routers, and the Grill Me and Grilling methods. Grill mode uses the bundled grilling skill to ask one focused question at a time and does not modify the project before shared understanding is confirmed. Global and workspace controls live in Settings → Extensions. Just Chat keeps its no-tools boundary and does not load these workflows.

Skills narrow how an agent approaches a task; they do not expand the selected permission mode or bypass hard safety rules. Review third-party provenance and notices from Settings or the repository inventory.

## Notebook and Notes

Each chat has an automatically saved Notes document in the right rail, and every workspace has its own note alongside the shared note. Use headings, lists, emphasis, links, and color to keep working material beside the conversation.

Open **Notebook** from the sidebar gear, the Locus menu, the command palette, or ⇧⌘9. It presents a searchable list of every workspace, chat, shared, and unlinked legacy note. Select any note to edit it in the full editor. A note and its Notes-panel copy are the same document, so they cannot disagree.

Notes are stored locally under a one-way hash of their owner. Locus records a readable name while that workspace or chat still exists. Older notes that can no longer be matched are preserved under **Unlinked**.

When Notes access is enabled for an agent, Locus resolves the current workspace and chat itself; the model does not choose an arbitrary notes owner. If a note's plain-text mirror is missing, 2.1 restores its content from the formatting archive instead of opening and overwriting it as blank.

## Private continuity

Encrypted, workspace-local continuity snapshots preserve goals, plans, checkpoints, changed files, final outcomes, and pending work across development chats without another model call. Inspect, remove, or disable them in Settings → Memory & Knowledge.

Use $context-handoff when you want an explicit handoff. Approved long-term memory remains a separate user-controlled feature.
