# Clean chat context

Choose **Clean chat context** in the Context inspector or enter `/compact`.
The command and WebSocket operation remain named `compact` for compatibility.
The visible chat history stays available while Locus shortens the working context
sent with later messages.

Existing automatic compaction uses this same workflow. Memory-saving settings
remain authoritative, and the routing change applies to new captures only;
existing memories are not moved or reclassified.

Cleanup extracts durable user preferences, user-confirmed decisions, and lessons
supported by verification receipts from the eligible conversation. General user
preferences belong to personal memory; project-specific preferences, facts, and
decisions belong to the current workspace; reusable verified specialist lessons
belong to the saved agent. Temporary task constraints stay in the unfinished-work
checkpoint. Existing memory settings and scope permissions still apply.
Approved or already-saved records can be recalled later. Pending suggestions remain
in the Memory Inbox until approved and are not treated as approved memory.

Locus confirms the save outcomes and commits a checkpoint for unfinished work
before replacing the working conversation with a shorter context. The checkpoint
preserves the objective, active constraints, and remaining work. A committed
context generation establishes the replay boundary, including after restart.
Managed provider threads are reset so the next request uses the cleaned context.

The selected chat model prepares the extraction with no task tools. The host
checks ownership, original source IDs and hashes, and current verification
receipts before writing. Ambiguous ownership stays in the checkpoint. Interrupted
cleanup can resume its prepared operation without duplicating confirmed saves.

Adaptive RAG keeps its existing per-turn allowance and revalidates evidence before
delivery. On a later “Continue” request, the checkpoint objective supplies the
search query; a specific new question keeps its own focused query. Cleanup grants
no additional search rounds, and pending memories are never approved retrieval
evidence.

The result reports **saved**, **pending review**, and **skipped** counts alongside
checkpoint status. If cleanup fails before the checkpoint is committed, the result
says **Cleanup failed — chat context retained**. Any completed memory saves are
still reported; a failed cleanup does not imply those records were rolled back.

The Context inspector's **Cleanup receipt** shows the operation ID, context
generation, and memory outcome IDs, revisions, scopes, and statuses. This metadata
stays with its chat result. The receipt excludes extracted memory text, checkpoint
contents, and the generated summary. Use Settings → Memory to review pending
suggestions or edit saved memories, and the existing **Memory for this turn**
inspector to inspect memory supplied to a provider.

The backend `slash_result` response supplies this display through `data`:

```json
{
  "cleanup_operation_id": "cleanup-operation-id",
  "context_generation": 4,
  "checkpoint_status": "saved",
  "counts": {"saved": 2, "pending": 1, "skipped": 0},
  "outcomes": [
    {"status": "approved", "id": "memory-id", "revision": 1, "scope": "workspace"}
  ]
}
```

Automatic cleanup emits `context_cleanup` with the same fields at the top level.
The desktop shows the same receipt without interrupting the active turn. Manual
cleanup also emits this event; its later command result updates the receipt with
the same operation ID instead of adding a duplicate. Neither receipt becomes
synthetic conversation input on resume.

`checkpoint_status: "not_committed"` accompanies an uncommitted cleanup failure.
The desktop retains compatibility with older command responses that provide only
`text`. Unknown counts or checkpoint states are shown as unavailable, not success.
