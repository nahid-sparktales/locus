> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/working-in-locus/conversations-and-context.md).

# Conversations & Context

Organize, search, split, export, and give models the right project context.

## Organize project chats

Each workspace owns its conversation group. Create nested chat folders without changing where chats run, drag or move chats between folders, and reorder them. Removing a folder keeps its chats and moves them up one level.

Chats can be named, pinned, archived, duplicated, exported, or deleted into recoverable storage. **Duplicate with Worktree** creates an isolated Git-backed copy when you want a separate implementation path.

Sidebar search matches titles, folders, and transcript content. ⇧⌘F focuses the cross-conversation search; selecting a result opens the exact message.

## Side Chat

Open Side Chat from the right rail to place two saved conversations side by side. Each pane keeps its own draft, attachments, mode, selected team, context, search, and active run status. The split and divider position restore across launches.

## Transcript behavior

Reasoning and tool activity remain in the order they happened. Collapsed mode uses quiet inline disclosures at real activity boundaries; Expanded reasoning and Verbose tools keep the detailed cards.

Text selection now spans the entire conversation, survives scrolling, supports Shift-click extension and edge scrolling, and keeps links clickable. Command-C copies exactly the selected text, including content that has scrolled out of view. Copy and Search in Google remain available from the context menu; the floating Copy/Quote buttons have been removed.

Agent questions can appear in a focused popup after the turn, with choices and a free-text answer. This is especially common in Grill mode. Your answer returns to the chat as an ordinary user message.

## Attachments, outputs, and exports

Type @ to mention a workspace file, drag files into either pane, or paste an image. Export a chat as Markdown, plain text, or PDF. The export sheet can include attachments, provider-supplied reasoning, and full tool details; sensitive data should be reviewed before sharing.

Files produced by agent tools or shell commands are detected even when they are gitignored or the folder is not a Git repository. Produced documents open in their normal Mac app; source files open in the Files inspector; every detected result is listed in Overview → Outputs.

{% hint style="warning" %}
Attachment bytes are not stored in the normal transcript. A restored chat retains names only. Include attachments in an export only when you intend to copy those bytes into the exported artifact.
{% endhint %}

## Persistent context

Use **Context** or /context to add files and folders to the context pack. Locus refreshes selected files immediately before sending and trims them to a model-aware budget. The Files inspector can add a file, mention it, reveal it in Finder, or copy its relative path.

The header meter measures the conversation against the usable model window after tool schemas and reply room. Local Ollama windows are measured when resident and remembered per host and model; hosted accounts use provider metadata, a configured value, or a marked estimate.

## Notebook, knowledge, and continuity

Press ⇧⌘9, choose Notebook from the sidebar gear or Locus menu, or use the command palette to open every note in one searchable page. The Notebook groups workspace, chat, shared, and unlinked legacy notes. Opening a note uses the same full editor and same document as its Notes-panel copy.

Eligible agentic modes can query a bounded local workspace index; retrieved snippets are labeled untrusted. Long-term memory is added only when you explicitly approve it. Encrypted continuity snapshots carry development state across chats without a model call.

Just Chat does not receive workspace tools, skills, knowledge retrieval, or continuity.
