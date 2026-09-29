# Activity Center audit and redesign proposal

Audited September 29, 2026. Scope: the current local implementation, native UI-test screenshots at compact and wide window sizes, task/attention models, saved outputs, and run APIs. This is a design and implementation proposal; the application has not been redesigned in this pass. The interactive concept uses illustrative tasks, not live activity.

## Recommendation

Make Activity Center a place to understand and review work without repeatedly leaving for a chat. Keep its warm surfaces, olive accent, three primary views, and responsive reader. Improve the information hierarchy: show the task and its most useful update in each row, then reveal evidence and controls in a consistent detail pane.

The guiding rule is **a useful summary first, supporting evidence one click away**. This follows Apple's guidance to keep frequently used controls visible and reveal advanced functions when needed ([Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)).

## What already works

- Needs attention, In progress, and Completed are an understandable starting structure.
- Attention already supports decisions, questions, recoveries, and configuration warnings; inline question answering should remain.
- Completed work has an independent reader, saved output previews, copy, read/unread state, and revision requests. These should be improved rather than rebuilt as new features.
- Wide windows already support a list beside the result; compact windows switch to a full-width reader.
- Run identity, stable accessibility identifiers, lazy lists, and the existing theme/type system provide useful foundations. `Font.locus` maps small nominal sizes to semantic styles, so the raw size arguments alone are not evidence of tiny fixed text.

## Findings, ordered by impact

### 1. Active rows say too little about the actual work — high priority

The row leads with the chat title, a status, agent, workspace, and a generic sentence such as “Working on your task…”. Duration, execution location, and queue position are in the overflow menu. A user cannot quickly distinguish useful progress from a quiet or blocked task.

**Change:** lead with the specific task; show one current milestone or latest meaningful event, agent/workspace, elapsed execution time, and when that update occurred. Show queue position directly for queued tasks. For teams, show “2 of 4 jobs completed” only when those counts exist. Counts of jobs are not a reliable estimate of time remaining; do not turn them into an invented completion percentage or ETA. Use a neutral “No recent update” state separately from an actual failure.

Evidence: `Locus/WorkspaceView.swift:1855`, `:1950`, `:2015`, `:2023`; `Locus/AgentTeams.swift:1694`.

### 2. Detail navigation changes behavior between tabs — high priority

Selecting a completed task opens an in-place reader. Selecting an active task opens its chat and dismisses Activity Center. Inspecting several tasks therefore requires repeated navigation and makes it harder to keep a mental overview.

**Change:** selection in every tab opens the same detail region. Show Overview, Timeline, and Outputs there; make “Open chat” an explicit secondary action. On narrow windows, replace the list with that detail and preserve the originating tab, filter, scroll position, and focused row when returning. On wide windows, retain the list beside it. Detail loading must not change the globally selected chat or Runs inspector.

Evidence: `Locus/WorkspaceView.swift:1600`; `Locus/AppModel+RunQueueAndActivity.swift:807` and `:862`.

### 3. Finished rows omit the outcome — high priority

Completed rows contain the original request, agent, date, task type, and workspace. They provide no answer preview, saved-output count, or review state, so every result must be opened to understand its value.

**Change:** add a short factual outcome excerpt and saved-output count, with separate unread and review indicators. Example: “Updated the hero copy and shortened signup · 2 outputs”. Group finished work by Today, Yesterday, and Earlier. Opening a result can mark it read; “Reviewed” remains a deliberate user action. Keep the full final answer and original request available in detail.

Use existing final-answer content for excerpts, bounded and cached. Do not add a model call for every row. A list endpoint or summary cache is needed to avoid loading a full session and scanning its output library per row.

Evidence: `Locus/WorkspaceView.swift:1646`, `:2135`; `Locus/AppModel+RunQueueAndActivity.swift:796`; `Locus/AgentInspectorDetailView.swift:605`; `Locus/AgentWorkLedger.swift:14`.

### 4. “Needs attention” is broader than “needs an action” — high priority

`attentionRuns` includes every terminal run whose state is not completed and which has no corresponding attention request. That can put intentionally stopped or discarded work in the attention tab. The sidebar attention count also uses a different population from the tab count. These are classification issues visible in the code; the screenshots reviewed do not demonstrate a populated stopped-task scenario.

**Change:** reserve Needs attention for unresolved decisions, actionable failures, and configuration problems. Rename Completed to **Finished**, containing successful, failed, and stopped history with explicit outcome labels. Keep an actionable failure in Needs attention until resolved; retain its historical outcome afterward. Use a shared classification/count model so badges and lists agree. Read status must never resolve an outstanding permission or question.

Evidence: `Locus/ActivityCenterModel.swift:63`, `:144`, `:150`; `Locus/WorkspaceView.swift:1314`.

### 5. The compact reader spends too much space on controls — high priority

The 720 × 620 scenario shows a large title area, full-width tab strip, search row, filter row, and an always-visible revision composer competing with the answer. The wide screenshot likewise has substantial empty space around a very short result.

**Change:** use a compact header with freshness state; keep search and a single Filters control on one row. Expand Agent, Workspace, Time, Type, and Outcome filters only when requested, showing active filters as removable chips. Hide list-only controls while reading a result in compact mode. Reveal the revision composer from “Request changes” and preserve its draft. Keep action targets comfortably usable; compactness should come from removing repeated chrome, not shrinking text.

Evidence: `Locus/WorkspaceView.swift:1430`, `:1456`, `:2119`, `:2210`; screenshots from `testActivityCompletedResultOpensOnlyOutputAndCanBeMarkedUnread` and `testActivityCompletedInboxHasWideReadingPane`.

### 6. Revision actions and draft lifetime need repair — high priority

Any filter change sets `selectedResultID` to nil. The reader stores its revision in local `@State`, so removing the reader can lose an unsent draft. The composer is also offered for every completed run, while sending requires a resolvable saved agent, workspace, and available session. A team or ordinary chat result can invite typing and only explain the limitation after submission.

**Change:** preserve drafts by run ID across selection, filters, and closing/reopening the center; keep selection during harmless filtering, or explicitly indicate that the selected task is outside the filtered list. Determine revision availability before showing the composer. When unavailable, offer “Continue in original chat” with the reason. Avoid clearing a submitted draft until dispatch is confirmed, and preserve text on failure. Give revision attempts an explicit link to the source result; the current ledger updates its run association and is not a complete revision history.

Evidence: `Locus/WorkspaceView.swift:1352`, `:2076`, `:2210`; `Locus/AppModel+AgentWork.swift:66`.

### 7. Search and history are limited to the loaded window — medium priority

Activity refresh loads the latest 200 runs and up to 500 attention items. Filters then operate locally. “Any time” and “Last 30 days” can appear comprehensive even when older matching work was never loaded. Search currently checks task/session/agent/workspace metadata, not final answers or output names.

**Change:** add a Workspace picker, paged history, and explicit loaded/search coverage. Reuse existing backend state, workspace, and cursor parameters; extend the API for server-side text/date filtering and stable pagination where needed. Result-content and output-name search should be a separately scoped enhancement, not a claim made by the initial metadata search.

Evidence: `Locus/ActivityCenterModel.swift:209`, `:411`; `Locus/WorkspaceView.swift:1551`; `agent/ollama_code/api/runs.py:123`.

### 8. Explain decisions and failures more clearly — medium priority

Attention cards already show a title, detail, age, supported actions, and some inline question controls. Generic action labels and similarly styled buttons can still make the next step ambiguous.

**Change:** show “What is waiting”, “Why your input is needed”, and the scope or consequence of the decision when that information is present. Choose one contextual primary action such as “Review file access”, “Answer question”, or “Resume from checkpoint”. Preserve the actual supported action set and permission boundaries. For failures, distinguish retrying a failed step, resuming a checkpoint, and starting the task again; display the recorded cause, attempt history, and saved partial outputs. Keep raw logs under Technical details.

Evidence: `Locus/WorkspaceView.swift:1700`, `:1763`; `Locus/Models/BackendResponses.swift:151`; existing workflow retry confirmation at `Locus/WorkspaceView.swift:1361`.

### 9. Freshness and elapsed time need precise meanings — medium priority

The center refreshes approximately every two seconds plus request time, republishes the run list, and sorts active rows by update time. Duration currently subtracts creation time, which can include queue waiting. On failure it reports that old updates are being shown but does not show the last successful refresh time. The warning in the inspected UI-test screenshots is fixture behavior, not evidence that production refresh is broken.

**Change:** distinguish queued time, execution time from admission, last task event, and last successful list refresh. A selected task should stay visually stable during refresh. Prefer existing events for selected-run updates, with a bounded polling fallback and slower refresh when idle. Compare snapshots before publishing unchanged data. Expose stale state quietly, with a retry action; never label cached data “Live”. Measure redraw cost before treating this as a demonstrated performance bottleneck.

Evidence: `Locus/WorkspaceView.swift:1354`, `:1820`, `:2015`; `Locus/ActivityCenterModel.swift:209`; `Locus/OrchestrationRunsModel.swift:257`.

## Proposed information hierarchy

| Level | Information | Actions |
|---|---|---|
| List | Task, outcome/current step, agent and workspace, meaningful age, state | Select task; contextual overflow |
| Overview | Full result or current work, trigger, elapsed/queued time, job counts where valid, selected action | Review, answer, resume, pause, request changes as supported |
| Timeline | Concise milestones, decisions, attempts and recoveries, exact timestamps | Expand event; open original chat |
| Outputs | Actual run-linked documents, images, links and versions, availability | Preview or open output |
| Technical details | Run ID, execution location, model/provider, tokens and recorded usage, raw events | Copy details |

Keep detailed usage out of the default list. If cost is shown, use recorded estimates and their coverage; absent pricing must read “Unavailable”, never zero. Use the existing library ownership checks for output links. Do not present arbitrary URLs as saved outputs.

## What can reuse current data

| Addition | Existing source | Extra work |
|---|---|---|
| Duration, queue position, trigger, job counts | `OrchestrationRun` and list response | Presentation and precise time semantics |
| Timeline and attempt history | Run detail and `/api/runs/{id}/events` | Independent selected-run state; human-readable event mapping |
| Saved outputs and previews | `AgentInspectorRunOutputs`, Outputs Library | Reusable view/model; cached list summaries |
| Outcome excerpt | Selected final answer | Bounded summary cache or batched list projection |
| Read versus reviewed | Activity read bookkeeping; `AgentWorkLedger.reviewed` | Review support for runs outside explicit assignments |
| Search through older history | Existing run cursor/state/workspace API | UI paging, text/date filters, coverage and tie-safe pagination |
| Revision history | Existing request-revision action; retry parent for retries | Durable revision-parent relationship; do not confuse retries with revisions |

## Delivery order

**First pass — clarity and correctness:** fix task classification/counts, revision capability and draft preservation, compact header/filter layout, consistent selection/detail navigation, visible duration and queue position, and restrained row summaries. Reuse existing components and APIs.

**Second pass — evidence and history:** integrate selected-run timeline and outputs, add cached outcome/output summaries, explicit reviewed state, history pagination and workspace filtering, and failure/retry context.

**Later, only with a demonstrated need:** optional “Open in separate window” for monitoring many agents, saved filter views, richer revision comparison, and search inside results. Avoid a dashboard of charts, model costs on every row, a raw event firehose, or fabricated progress estimates.

## Verification before implementation ships

- Native compact and wide layouts, light/dark appearance, larger text, reduced motion, and increased contrast.
- Keyboard navigation across tabs/list/detail, visible focus, Escape returning one level, and VoiceOver summaries that include state and next action.
- Mixed tasks: permission, question, workflow failure, intentional stop, queued/paused/live work, missing agent, missing output, and offline/stale data.
- A revision draft survives selection/filter changes and failed submission; unsupported revision actions are explained before typing.
- Opening a run detail does not switch chat. Reading a result does not mark it reviewed or resolve an outstanding request.
- Pagination and counts work with more than 200 runs, equal timestamps, cross-workspace tasks, and new events arriving during browsing.
- Refresh preserves row focus/scroll position and cannot erase a selected result or draft.
- Keep the CI fix to use typed static-text queries for prose assertions; preserve stable accessibility identifiers rather than replacing regression coverage with timeouts.

Implementation should extract Activity Center rows and detail into focused view types instead of adding another large section to `WorkspaceView.swift`. Keep live dependencies near the relevant row/detail, and keep the detail model independent from current-chat navigation.
