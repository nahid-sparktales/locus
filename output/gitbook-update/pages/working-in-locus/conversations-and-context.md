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

Open **Notebook…** from the sidebar menu or press **⇧⌘9**. Create a standalone note with **New Note**, search full note text, pin or duplicate a note, and export text or RTF. Workspace, chat, and shared notes keep their existing ownership. Standalone notes are not automatically included in agent context.

Deleted notes remain in **Recently Deleted** until you explicitly remove them. You can preview and restore them. Permanent deletion requires confirmation; no automatic deadline applies.

Eligible agentic modes can query enabled workspace knowledge. [Document knowledge](library-documents-and-outputs.md) is a separate opt-in. Long-term memory is added only after explicit approval, and encrypted continuity preserves development state across chats.

Ask mode does not receive workspace tools, skills, knowledge retrieval, or continuity.

## Writing drafts and structured answers

Answers can include verified file collections, reusable writing, deliverables, and source references with a complete Markdown fallback. Editable writing drafts support copying, export, and recovery of the original text. Table copy and CSV export include all rows even when the displayed table is collapsed.

Context controls choose information included in the chat; they do not grant broader file access. File access still follows the workspace and permission boundaries.

## Saved deliverable history

Use [Library → Outputs](library-documents-and-outputs.md) to revisit saved versions, compare changes, export a snapshot, or prepare a revision. Opening Library preserves the current chat and draft. Saved snapshots remain available when the original workspace file is removed, provided the version was captured successfully.
