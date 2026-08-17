---
name: context-handoff
description: Save an explicit encrypted development-session handoff for a later Locus chat in the same workspace. Use only when the user invokes $context-handoff or directly asks to capture the current goal, outcome, decisions, changed files, and pending work for another chat.
disable-model-invocation: true
---

# Context Handoff

Summarize only the state already established in this session. Do not invent decisions or treat uncertain work as completed.

1. Identify the current goal and the concrete outcome so far.
2. Capture remaining work or the next checkpoint plainly.
3. Call `capture_context_snapshot` once. Locus automatically adds the accepted plan, current todos, and changed-file inventory and encrypts the result in application data.
4. Confirm what was captured without exposing storage keys or ciphertext.

The snapshot is workspace-isolated and replaces this session's earlier rolling snapshot. Do not create handoff files in the repository.

The native implementation was informed by Context Mode and Claude Mem, but bundles none of their services, hooks, workers, or databases. See `REFERENCES.md` for attribution.
