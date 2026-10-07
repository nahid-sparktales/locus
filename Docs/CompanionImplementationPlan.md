# Companion: persistent assistant implementation

The Companion is one saved agent with one clearable conversation, shared across the main chat, inspector, menu bar and desktop window. Locus remains the owner of sessions, tasks, runs, memory and permissions. This plan extends those owners rather than creating another assistant runtime.

The normal agent sidebar shows the current manual Companion chat. Earlier chats remain accessible through search, Show Archived Sessions and profile history; automation activity remains visible. No existing transcript is deleted by this presentation change.

The character is horizontally centered at the top of both the main Companion chat and the right tab, including an empty chat. Both use an 80-point character. Pointer reactions are limited to the cursor being inside the right tab. The desktop starts at 80 points with independent 64/80/112/144-point size choices. Archived chats remain recoverable after clearing; they are not selectable as parallel Companion chats.

## Delivery sequence

1. Add explicit context sharing and saved-progress catch-up (#3, #4), including captured conversation ownership across asynchronous operations.
2. Add desktop presence and session-addressed voice (#1, #2), then validated animation packs (#10).
3. Add activity preferences, memory review, structured sessions, specialist visibility and application guidance (#5–#9). These can be implemented in parallel against existing owners.
4. Integrate all surfaces, regenerate the Xcode project, build, run focused native/backend/UI checks and record the actual results below.

## Features and acceptance criteria

| # | Feature and implementation | Existing owner | Acceptance |
| --- | --- | --- | --- |
| 1 | A movable native panel, character size choices, edge snapping, optional always-on-top and Control–Option–Command–C summon/hide. Character opens the shared chat. | `CompanionDesktopController` owns presentation only; `CompanionPanelModel` and session workers own chat. | Closing/hiding never cancels work. Same identity, conversation and draft; no cursor tracking outside right tab. |
| 2 | Push-to-talk, visible microphone state, spoken replies and interruption. Listening/speaking poses derive from voice activity. | `VoiceControlModel`, existing voice clients/settings and saved-agent send path. | Voice stays bound to the captured Companion session if the center chat changes; failures preserve recognized text. No automatic microphone start. |
| 3 | “Look at this” captures pasted text/errors, files, the current browser page, an application snapshot or a selected screenshot region. Review before attaching; removable context chips state their scope. | `ChatAttachmentLoader`, `ApplicationContextService`, `BrowserService`, existing worker transport. | Nothing sends before preview approval and message submission. A chat clear or profile change invalidates late captures. Central workspace attachments and live-control permissions are not inherited. |
| 4 | “Where we left off” projects the saved objective, decisions, progress, verification and next action, with resume/review/source controls. | `/api/sessions/{id}/task`, session transcript, goal/capsule/run action owners. | Saved plans and unverified conversation excerpts are labelled accurately. Resume revalidates current record/action. |
| 5 | Grouped Companion activity with source selection, priority, explanation, snooze and local quiet hours. | `ActivityCenterModel`, existing attention items and orchestration runs. | Approval and completion are deduplicated; snooze does not resolve requests or mark unread results read. Notification policy does not duplicate event storage. |
| 6 | “What you know about me” reviews and proposes memories, confirms scope, and exposes edit/forget/source/update controls. | Existing memory vault APIs and attribution fields. | Explicit Companion workspace/profile/session attribution; unavailable or protected vaults fail visibly; no separate memory database. |
| 7 | Focus/learning sessions agree a goal, deliverable, duration and checkpoints; learning offers explanation/exercise/hint/answer and evidence-based summary. | Existing persistent goal record with user-paced session metadata. | Sessions remain paused for autonomous scheduling. Progress/evidence survive reload; timer/check-in does not dispatch a model turn. |
| 8 | Specialist cards show task, recorded shared input, state, results and uncertainties; inspection and synthesis use the existing run and Companion conversation. | Existing worker/agent activity and run records. Bounded input previews are projected from the run event ledger. | Solo work can be stopped as a turn; supported team branches use existing branch cancellation. Historic input is explicitly unavailable when not recorded. Hosted previews identify orchestrator input without claiming visibility into internal worker prompts. No independent agent ledger. |
| 9 | Guided MCP setup, recurring-agent setup and waiting-task explanation, with highlights on actual controls and a persistent status/Stop banner in setup views. | Existing settings/schedule/task state plus presentation-only guide state. | State determines the next step; existing configuration skips completed steps. Errors stop highlighting while retaining the explanation and Stop control. Highlights/navigation never approve permissions or save settings. |
| 10 | Art-and-metadata animation packs with preview for each state, bounded dimensions/decoded memory, idle fallback and reduced motion. | Existing avatar/appearance persistence and character renderer. | Reject scripts, traversal, malformed grids and excessive resources. Imported art remains owned locally; static portrait support remains. |

## Integration and validation

Feature models initialize without starting work. AppModel supplies narrow callbacks and composes shared owners. Asynchronous operations capture session, profile and workspace, then revalidate before mutation or delivery. The central send path and background saved-agent path both use approved immutable attachment snapshots.

Companion tools are reached from the character/chat and inspector options. Context and voice sit near the composer; catch-up is collapsible; memory, focus, handoffs, activity preferences and guidance have dedicated tool views. The 80-point character stays at the top of the inspector while its transcript remains available below.

Focused checks cover wrong-owner and late callbacks, preview approval and limits, verification labels, memory attribution, notification grouping/quiet hours, manual focus persistence and scheduler exclusion, specialist identity/cancellation, guide transitions, desktop snapping, voice targeting and animation pack resource validation. Builds use the repository's generated Xcode project; backend tests cover any added goal API behavior. UI verification uses fixture conversations and no live model calls.

## Delivery record

All ten features are implemented and connected to the shared Companion conversation. The final character layout uses 80 points in the main chat and right tab, horizontally centered at the top even before the first message. Desktop sizing is independently adjustable and defaults to 80 points.

| Check | Recorded result |
| --- | --- |
| Native build | Succeeded. |
| Focused native tests | 297 executed across the Companion and sidebar catalog suites, one explicit skip, zero failures. |
| Backend regression tests | 140 passed, including goal/focus, specialist/run records, and memory boundaries. |
| Final UI verification | All 12 Companion UI cases passed with no failures or skips, including the compact character above empty and populated chats, shared drafts/context, desktop tools, menu-bar reopening and MCP guidance. |

After the sidebar history correction, the two main-chat layout cases passed again, including an assertion that only the current manual chat appears. Saved screenshots were inspected for the 80-point top placement and single-chat sidebar. The sidebar catalog's 17 passing checks include history recovery through search, archived sessions, and unresolved initial selection, plus preservation of automation and running activity.

### Integration with automatic memory and retrieval — 2026-10-07

The combined branches passed the full native suite (2,043 tests, two skips, zero failures), the full Python suite (3,652 tests and 31 subtests), CI Ruff, runtime package verification and the Agent Worlds host boundary check. Three targeted UI cases passed against an isolated test-app identity: context ownership, desktop tools, and the single top-aligned main chat. The normal test-app identity could not launch while another Locus build was running.

The native skips require a verified external Agent Worlds artifact and an active hosted pointer-test window. The pointer test also skipped in isolation when macOS would not activate its window. The merge adds an explicit view-bounds check for out-of-tab pointer events, direct voice-state observation, and memory edits that send the reviewed revision. Cancellation now takes precedence when plugin or portrait work finishes during a disconnect. Deterministic tests reproduced the cancellation race before the fix and passed afterward. Backend fixtures now isolate extraction shutdown state between tests and match the extracted runtime worker contract.

The backend coverage includes saved-agent focus API admission, workspace mismatch rejection, checkpoint revision/evidence validation, pause/resume timing, exclusion from autonomous goal claims, and specialist input persistence/redaction through the existing event ledger. Context previews honor content-omission export policy. Native coverage includes captured session ownership, activity preferences, focus timing, guidance cancellation, desktop presentation, voice targeting and animation-pack validation.

UI checks use isolated fixture conversations. They do not establish live-provider behavior. Actual microphone capture, macOS Screen Recording permission flows, and live model/provider calls were not exercised. Voice-state and routing tests use controlled inputs. Fixture errors remain visible, and MCP/schedule guidance retains a Stop control when an error removes its highlight.

Focus and learning progress is explicitly user-reported; time elapsed is never proof of completion. Memory scope changes use existing create/forget operations with rollback on a reported failure, but an interrupted change is not atomic and requires reviewing the refreshed records. These limits are part of the implemented behavior, not claims of independent verification or a second permission authority.
