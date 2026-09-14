# Agents experience audit — September 14, 2026

The highest-value design change is one home for each saved agent, with its
readiness, automatic work, latest result, and recovery actions visible together.
The current interface makes people move between chats, profile editing,
automation management, the inspector, and Activity Center to understand a
single agent. Appearance is secondary to making its actual state trustworthy.

This audit combines inspection of the installed macOS interface, source review,
read-only inspection of relevant run metadata, and isolated regression tests.
No real email was sent, schedule run, model called, or account setting changed.
The single-agent overview described below is now implemented in the working
branch, alongside the targeted reliability fixes. Remaining recommendations
are identified separately.

## The reported failures

**Email after Claude became unavailable.** A native dispatch failure posted
`pause_trigger: true`, disabling future arrivals. Signing back in restores the
model account but does not enable that trigger. A second problem affected
workflow-backed deliveries: the model run was cancelled, while its workflow
and chat reservation still appeared active. The chat could therefore remain
busy even after the trigger was resumed. Local stored metadata contains this
combination; isolated tests reproduce the failure and recovery paths.

The fix separates an unsuccessful attempt from the user's Pause setting,
records which exact run failed, and releases a failed workflow's reservation
when no live work remains. Retrying a step must reacquire the reservation
atomically. Old failure callbacks must not stop a newer attempt. Failed work
remains visible and requires an explicit retry; it is not silently replayed.

**Scheduled weather with Claude.** The observed scheduled runs did receive
Locus tools and successfully used some of them. The weather agent had a
read-only access ceiling with networking enabled. The tool inventory wrongly
treated “read-only” as “requires no permission,” hiding `web_fetch`, even though
fetching is already classified as a read operation. Browser navigation was
also unavailable, leaving browser-reading tools unable to open a weather source.

The fix includes semantically read-only tools in that inventory. It preserves
the networking setting, normal permission checks, and restrictions on writing,
commands, and browser interaction. A mocked Claude tool roundtrip verifies
retrieval; this does not claim a live weather run was performed.

Implementation evidence: [native dispatch](../Locus/AppModel+RunQueueAndActivity.swift),
[event failure endpoint](../agent/ollama_code/api/event_triggers.py),
[workflow state and reservations](../agent/ollama_code/runstore.py),
[tool inventory and dispatch](../agent/ollama_code/tool_registry.py).

A separate background-service issue was also reproduced: a saved Solo agent
could be rejected because a delegation-eligibility flag was mistaken for a team
runner. The service now checks the actual runner while preserving its saved
profile, model, account, and permissions. This was not the cause of the observed
weather run, which did execute. See [background admission](../agent/ollama_code/runtime_automation.py).

## Implemented: one overview per agent

Selecting a saved agent now opens its overview in the main workspace. It does
not create or resume a chat, change the active model, replace an unsent draft,
or interrupt a running task. New Chat and existing conversation links remain
explicit actions; agent chats have an Overview return button.

The shared overview includes:

- **Connection health:** the saved agent's exact model account and relevant
  event/action connections. Unchecked availability is shown as unverified,
  rather than treating the foreground chat's account as proof of readiness.
- **Automations:** owned schedules, incoming events, and price rules; current
  state, next scheduled time, latest attempt, editing, Pause, and visible Resume
  controls for disabled rules.
- **Latest result:** the latest owned run or saved conversation result. A final
  assistant answer is loaded read-only from its verified profile/session, with
  an exact run match for run-backed results. Missing output never falls back to
  another run's answer, and failures retain their recovery explanation.
- **Recovery:** review the exact model account, review service connections,
  inspect the failed attempt, or resume future automatic starts. Workflow retry
  remains in its existing focused review flow; viewing an overview never
  replays work or changes a paused rule.

Wide layouts place connection health and results beside each other; narrow
layouts stack them. Chats and collapsible instructions remain below the primary
status and automation information. The same component works in the inspector
and Captain's Quarters. Map actions retain the selected resident and project;
read-only activity can be inspected without borrowing another chat's workspace
tools. New automation drafts capture their originating project.

## Remaining recommended changes, in order

| Priority | Change | Why it matters |
| --- | --- | --- |
| First | Make readiness explicit: Ready, Running, Waiting for approval, Needs connection, Paused, Failed. Show the reason and next action. | A saved profile currently looks Ready independently of its account and automation health. “Locus ready” also describes the local service, not whether an agent can do its work. |
| Next | Extend the overview with effective tools/access and a clearer settings hierarchy. | The new overview now covers health, automations, results, recovery, and chats; deeper access diagnostics remain a separate follow-up. |
| First | Use “agent” only for the saved assistant; call email rules, schedules, and price alerts “automations.” | The observed sidebar showed four agents while its footer announced seven configured. The footer counts profiles plus automatic jobs, while the main list groups jobs under profiles. |
| First | Add a preflight check and a clearly separated “Test automation” action. | Check model sign-in, required tools, connection health, matching input, and output destination before enabling automatic work. Current workflow simulation skips the model and connected actions, so it cannot prove readiness. |
| Next | Put Reconnect, Retry failed run, and Resume future runs beside the failure, with distinct meanings. | Reconnecting an account, dismissing a warning, retrying one delivery, and resuming an automation are different actions. The current interface makes them easy to confuse. |
| Next | Display effective tools and access, including why a tool is unavailable. | A chat's Full access label can coexist with a saved profile's stricter ceiling. Show “Read websites: available,” “Send email: approval required,” or “Browser interaction: disabled by this agent,” using the actual combined policy. |
| Next | Show a compact run receipt: trigger → started → tools/actions → result, with timestamps and the exact stopping point. | A user should see whether an email matched, whether Claude started, whether a tool was blocked, and whether output was delivered without reading a debugging log. Show last success and next scheduled run separately from latest failure. |
| Next | Repair connections and receiving chats in place. | Connection management exposes Remove rather than a direct repair flow; lost-chat instructions can tell users to delete and recreate the agent. Reconnect the same connection ID or create a replacement receiving chat while retaining settings and history. |
| Later | Add templates such as “Summarize matching email” and “Daily weather,” with an explicit destination and timezone. | Templates can establish the necessary tools and output expectations. Preserve an advanced editor for complex workflows. |

The overview now starts with the agent's name, a plain-language purpose,
model/account readiness, and a small number of relevant actions. Below that,
its automations show their own status, last result, next run, and Pause/Resume
controls. A live preflight Test action remains future work. Recent results stay on the same page. Selecting a chat is now an
intentional navigation action.

## Simplify or remove

- Rename the “Agents” tab inside “Manage [agent]” to **Automations**. Rename
  “Find an Agent,” “All Agents,” and “Open Agent” where they actually mean a
  rule, filter, or receiving conversation.
- Remove duplicate agent counts and competing selectors. Count saved agents
  consistently; show their automation count separately.
- Move Runtime configuration, team tuning, and workflow internals into
  **Advanced**. Keep “Runs on this Mac; keep Locus open” visible as a short
  operational note, with details available when needed.
- Replace generic “Add…” with **Add automation** and a choice of Schedule,
  Incoming event, or Price alert. Keep **New agent** and **New chat with [name]**
  as distinct actions.
- Stop dismissing management when opening run details or editing a profile.
  Preserve selection and back navigation so the user can return to the failure
  they were investigating.
- Remove blame or promises the system cannot substantiate. “You paused this
  agent” was displayed after the stored reason had been cleared. Disabled event
  triggers also do not guarantee a replayable record of every skipped email.
- Keep Crew Chat and the map as useful alternate views of the same agents.
  Avoid introducing another independent set of agent controls or status rules.

Source evidence: [sidebar identity and counts](../Locus/SessionSidebarView.swift),
[Agent destination](../Locus/AppModel+SessionLifecycle.swift),
[saved profile overview](../Locus/SavedAgentInspectorView.swift),
[management and connection controls](../Locus/EventAutomationsView.swift),
[simulation scope](../Locus/AutomationWorkflowEditorView.swift),
[connection creation](../Locus/EventAutomationModel.swift),
[lost-chat recovery copy](../Locus/InspectorAgentTab.swift).

## Targeted usability fixes included

Managing one profile previously defaulted its Activity view to runs from all
profiles. Activity is now scoped to the selected profile before status and
automation filters apply. Typed schedule/event identities prevent collisions,
and known archived ownership retains historical results.

Paused-state text is now neutral: **Automatic starts are paused**. It no longer
claims the user caused the pause or promises that paused email rules continue
recording every event. These fixes accompany the implemented overview. The remaining recommendations
above are not claimed as completed.

## Existing data and rollout

A follow-up read-only check at approximately 02:00 on September 14 found the
affected existing email rules enabled, with their saved warnings cleared. Their
old failed delivery receipts remain as history. Startup repair has failed the
abandoned workflow steps and released their session leases. Viewing this data
did not change rules, replay email, or dismiss earlier work. Messages skipped
while a rule was disabled are not guaranteed to be recoverable from its delivery
history.

Validation passed: 142 native tests (including overview ownership, output
matching, navigation, map recovery, and captured automation project cases); 101 focused event/workflow/store/inspector
tests; 89 relevant backend dispatch selections; read-only tool and Claude adapter
checks; and background-runner regression cases. These selected backend suites
overlap, so their counts are not an aggregate unique-test total. Checks cover
sign-in recovery, later arrivals, explicit Pause, stale callbacks, active work,
restart repair, competing retries, retained permission checks, and profile-scoped
history. Python lint and whitespace checks also passed. The final app build
succeeded. Wide, narrow, and ocean-themed layouts were rendered from the actual
SwiftUI component using synthetic, in-memory data and visually checked.

Xcode's LaunchServices route could not launch the native test host alongside the
installed app. The exact compiled test bundle was successfully run with Xcode's
direct `xctest` runner instead. No installed app process was stopped. The new
build still needs to replace or be launched instead of the installed version;
this audit did not perform that rollout or replay real automatic work.

## Follow-up: recovered account still shown as unavailable

The overview was treating the most recent failed delivery's historical error as
current automation health, even after the rule's saved warning was cleared and
its account reconnected. A duplicate generic conversation warning obscured the
actual workflow recovery. The overview now distinguishes these states:

- Current model/account, connection, and saved automation warnings remain visible.
- A failed receipt remains in the result history without reviving a cleared warning.
- An unresolved workflow or run gets an explicit recovery action scoped to that
  exact item. A recovered account shows **Connected now. Earlier work still needs
  review.** Reviewing an item does not retry it or resume paused rules.
- The map's recovery button opens the same focused Activity Center in a sheet.
- Detailed workflow recovery actions take precedence over generic run failures,
  so the workflow retains its exact Retry/Cancel flow. Focused run lookups also
  preserve hyphens in IDs instead of double-encoding them. Live questions retain
  their answer controls.
- Current waiting runs remain actionable if the attention inbox is temporarily
  unavailable; completed and historical failed receipts do not recreate those
  approval requests.

Claude's model discovery also returned a generic `default` fallback when SDK
metadata could not be read. Treating that fallback as a complete list could
incorrectly reject a saved `opus[1m]` model. The backend now identifies incomplete
catalogs; the app preserves the last discovered list instead of replacing it
with picker defaults. Picker fallbacks remain available without becoming routing
restrictions. Real, complete catalogs still validate saved model choices.
The overview refresh also refreshes account information, with the normal cache
limit for periodic refreshes and a fresh check on explicit Refresh.

Follow-up validation: **168 selected native tests** passed, including recovered
account health, retained historical errors, exact recovery actions, ownership,
current approvals, detailed workflow recovery, and complete/incomplete catalog
and picker cases. **38 Claude backend tests** passed.
Python lint and whitespace checks passed. The build was made in the separate
`build/agent-recovery` directory so it did not overwrite an active app bundle.
No live model request or email replay was used to validate these changes.

## Implemented: hybrid agent workspaces

Each saved agent now defaults future chats to a personal **Agent home**. The
home uses the profile's stable UUID, so changing its name does not move files.
The directory is created only when used or explicitly opened; viewing an
overview does not create files. On macOS it lives in the edition's Application
Support directory under `AgentHomes/<profile-id>/Workspace`.

Projects stay independent. An agent can link existing project folders and choose
one as its default. Several agents can link the same project. The overview and
profile editor show **New chats start in**, with a per-chat override beside New
Chat. Adding a project uses the native folder chooser and retains folder access.
Changing defaults or unlinking a project does not move old chats or delete files.

New chat allocation follows the selected workspace:

| Choice | Where the chat works | Output folder |
| --- | --- | --- |
| Agent home | A separate `Tasks/<session-id>` folder beneath its home | `Outputs` inside that task folder |
| Git project | A separate managed working copy, initialized from the current project checkout | A dedicated output directory inside that copy |
| Other project folder | The explicitly selected shared folder | `Outputs/<session-id>` within that project |

The home is stable across chats; each chat's execution folder is separate.
Non-Git projects share input files intentionally, so per-chat output directories
prevent output-name collisions but do not isolate edits to shared project files.
The overview exposes the saved chat folder and an Open outputs action. The
backend tells new chats where to save deliverables; that hint is accepted only
from matching saved workspace metadata.

Automations explicitly show **Working in**. New general automations start from
the agent's home unless opened from a fixed project map. Schedules retain their
saved folder and execution choice. Incoming event rules use an owned receiving
chat: select an eligible existing conversation or create one when saving the
rule. Merely opening the editor does not create a conversation. Retargeting a
rule preserves its previous transcript, files, and run history. New side chats
receive their own task allocation, including when the primary uses a worktree.

Existing conversations and automation folders are not migrated automatically.
Explicit schedule edits take precedence over the original transcript folder
when the chat resumes. Missing or invalid execution folders produce a clear
error instead of switching silently to another project. Returning a schedule
to a previously allocated home task reuses its recorded folder and outputs.

Agent World and Crew Chat retain their fixed project and profile identities.
If a selected project is a subfolder of a Git repository, its exact source
folder remains associated with the map while tools and the queue use the real
repository root and isolated execution path. An unrelated folder or profile
cannot use that source association.

Validation passed: **227 native tests**, **644 consolidated backend tests**, and
**75 event/schedule tests** after the final output-preservation changes. The
backend selections overlap and are not an aggregate unique-test count. Wide,
narrow, and ocean-themed layouts were rendered from the actual SwiftUI view
with synthetic data and checked after compacting the folder controls. Tests
cover fixed agent homes, shared defaults, retained old paths, separate task
folders, output preservation, exact automation retargets, and map ownership.
Python lint and whitespace checks pass.

Validation uses isolated temporary folders, mocked native backend responses,
and in-memory SwiftUI previews. No real email was replayed, model called, or
installed app restarted during this implementation.

Implementation: [workspace preferences and native selection](../Locus/AppModel+SavedAgents.swift),
[workspace allocation and validation](../agent/ollama_code/agent_workspaces.py),
[overview controls](../Locus/SavedAgentInspectorView.swift),
[automations](../agent/ollama_code/api/schedules.py).
