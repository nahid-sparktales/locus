# The Inspector

Keep overview, files, diffs, terminal, browser, notes, runs, routing, and proxies beside the conversation.

The right rail keeps high-frequency tools reachable even when the inspector is collapsed. Open Side Chat, Overview, Terminal, Browser, or Notes directly; use the overflow menu for the remaining panels. Panels you open appear in a closable tab strip, and Locus remembers the selection and width.

| Panel            | What it shows                                                                                               |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| **Overview**     | Collapsible Plan, Outputs, Subagents, Background Processes, and Sources, with Context Window pinned below   |
| **Changes**      | Git status, per-file and per-hunk diffs, staging, discard, branches, sync, commit, and pull-request handoff |
| **Files**        | All file types and generated folders, path search, explicit hidden-file visibility, previews, and context actions                                               |
| **Terminal**     | A retained PTY for interactive commands                                                                     |
| **Browser**      | Shared responsive tabs, dev servers, screenshots, console, network, device controls, and guarded Autofill   |
| **Notes**        | The current chat or shared note, using the same document as Notebook                                        |
| **Checkpoints**  | On-demand named session rollback points                                                                     |
| **Runs**         | Durable Solo and team history, run-scoped evidence, attempts, budgets, recovery, and exports                |
| **Instructions**    | Durable workspace instructions and starter sections                                                         |
| **Model Router** | Route scorecards across quality, privacy, reliability, latency, cost, and footprint                         |
| **Proxies**      | Named proxy profiles, assignments, strict tunnel, health, and failover                                      |

![Planning and context in the Locus inspector](https://831891047-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FdQ03BivzJFZ7fKsPFhiD%2Fuploads%2F32XidrEy7OgDjkWCxOys%2Flocus-v2-plan.png?alt=media)

Overview shows only sections that have content. Outputs catches files created through direct tools and shell commands, including gitignored results and work outside a Git repository. Clicking a produced document opens the Mac app associated with that file type.

The Runs panel has its own icon; the three-node orchestration symbol is reserved for the team dispatcher. When one run is open while another continues, Overview and Activity remain scoped to the selected run. Files created and deleted within the same run are not reported as created, and expanded request/details state resets when you switch runs.

A run never steals the selected panel. Attention appears as a badge. Use ⌘1–⌘5 and ⌘7–⌘9 for numbered panels, ⌘6 for checkpoints, ⌘⌥I to show or hide the inspector, and ⌘⌥E to expand or restore it.

Open the Notebook separately with ⇧⌘9 to search and edit all notes without changing the Notes panel's current owner.

## Overview, Agent, and Runs

**Overview** follows the current request in the open conversation: the request summary, plan, sources, outputs, tool activity, helpers, and completion state. It does not combine every request into one plan.

The **Agent** panel describes the selected persistent Agent, including instructions, trigger health, environment, access, and recent activity. Selecting an Agent and selecting one of its chats are separate actions. An Agent being active means it is enabled; it does not necessarily mean a chat is currently running.

**Runs** opens the current chat's executions and keeps exact event, occurrence, attempt, and output records. A received event is not proof of a successful execution. Use record details to distinguish waiting, skipped, failed, cancelled, and completed work.

**Instructions** is the workspace `AGENTS.md` panel. Reusable specialist profiles are configured through **Specialists & teams**.
