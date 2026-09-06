# Contextual Agent inspector

Implemented September 4, 2026. The Agent tab follows an explicit fleet, agent,
chat, incoming event, scheduled occurrence, or execution selection. Selecting
an agent preserves the conversation open in the central workspace. Opening a
chat is a separate action.

## Reading order and actions

- Agent: name and purpose, status and controls, work in progress or next start,
  readable activity totals, exact incoming events or scheduled occurrences,
  chats, then a collapsed explanation of its configuration.
- Chat: its role as receiving chat or side conversation, status and chat preview,
  recent saved work, and chat outputs. Side conversations explicitly explain
  that they do not receive events or scheduled work.
- Event or occurrence: what started it, separate delivery and execution state,
  source content marked untrusted, a supported recovery action, and every
  retained execution link. A skipped schedule slot is not counted as failure
  or completion.
- Execution: current state and next action, saved result or progress, exact
  output versions linked to that run, available duration and usage, and
  secondary identifiers inside Details.

Back navigation retains the originating event, occurrence, or chat. Scroll
position and disclosure state belong to that exact context. Namespaced
identities distinguish an event agent and schedule with the same raw ID.
Session summaries carry an optional `agent_kind`, preserving old decoding.
Sidebar grouping, the footer, chat counts and New Chat use typed ownership.
Legacy metadata resolves only from a unique matching definition or durable
target/schedule provenance. Ambiguous saved chats remain accessible, but are
not guessed into an agent's chat list or used to route a new side conversation.
Configuration, pause/resume, warning acknowledgement, retry, and opening a
conversation remain separate controls. Duplicate enable and retry requests
are suppressed while pending.

Resume preserves a stored warning. Retrying a failed event queues only that
event and keeps the agent's pause state and warning. Its explicitly requested
attempt can dispatch while ordinary paused arrivals remain held. A paused
connector still blocks dispatch. Clear warning acknowledges the warning
without resuming the agent. Existing normal dispatch outcomes continue to
update the agent's latest run and current error.

## Data boundaries

`AgentInspectorModel` owns selection and scoped loading. Both a context
generation and request identity reject late results, including an A → B → A
navigation. A failed refresh retains only the last successful information for
the same object, with a visible refresh error. A new context never displays an
unrelated object's data. Up to 64 successful context snapshots are cached.

Agent event and schedule history is filtered in SQLite before keyset paging.
The cursor includes agent kind, exact agent ID, timestamp, creation time and
record ID, so tied timestamps do not omit or duplicate records. Counts and
page rows share a read transaction. The displayed counts describe retained
history, not all-time activity. Workflow approval and execution state take
precedence over the handoff state of a completed child run.
Paused work and computer-access requests count toward attention; planning,
advancing and awaiting a run count as active. Queued and skipped work do not
count as completed.
Refreshing a parent reloads every page through the previous visible boundary,
including when new arrivals shift page boundaries or the old tail is deleted.
Older visible rows are replaced with fresh records while selection and scroll
remain attached to stable IDs. A failed page refresh retains the previous
complete snapshot with an error rather than mixing fresh and stale pages.

Run-store schema 12 adds durable execution links. Migration recovers links
from existing delivery/occurrence pointers and retained run provenance. Retry
links survive pointer clearing and relaunch; generic run retries inherit their
parent's item links. Workflow step attempts join the same execution view.
Missing historical run records remain unavailable instead of linking to
another run.

Read-only APIs:

- `GET /api/event-triggers/{id}/history`
- `GET /api/schedules/{id}/history`
- `GET /api/event-deliveries/{id}`
- `GET /api/schedule-occurrences/{id}`
- `GET /api/attention?run_id={id}` or `?workflow_execution_id={id}`

Item responses carry delivery state, execution state, workflow identity and
retained execution links. Native detail loading verifies the requested owner
and execution membership. Attention filtering occurs before its result limit;
the inspector opens the selected run or workflow's requests, with Show all
available. Ordinary Activity Center opening clears that focus.

Saved output rows use the Library's immutable version identity and recorded
origins, including a second run that generated unchanged bytes. A later
version from another run is not substituted. Version loading is cancelled on
selection change. The generic Library route remains available to inspect all
outputs associated with the run. Unknown legacy origin is not guessed.

## Verification

Focused Python verification passed **113 tests** across agent inspector,
event triggers, schedules, run-store and automation workflows. Added cases
exercise a busy unrelated agent, tied pagination, invalid cross-agent cursors,
scoped state totals, exact old-record access, schedule handoff state, workflow
approval, durable retries and migration, independent pause/retry/warning
actions, and Attention filtering before its page limit.
An extended backend run also passed **433 tests**, covering additive session
identity, both orders of creating same-ID event and schedule agents, separate
side chats, deletion guards, ambiguous legacy metadata, and existing HTTP
backend behavior. These overlapping test counts are not additive.

Native `AgentInspectorTests` covers namespaced identity, exact back paths,
truthful state totals, stale response rejection, scoped failed refreshes,
pagination, per-object presentation/cache restoration, missing versus reported
usage and duration, and exact Attention focus. The recorded native product run
passed **407 unit tests**, including 11 AgentInspector and 35 AgentOverview
tests, with dedicated identity and visible-page refresh regressions. Evidence:
`/tmp/locus-library-product-tests.log`.

After the final disclosure fix, all **6 Agent UI tests passed**: the three
contextual inspector tests, both legacy whole-agent/schedule tests, and the
expanded configuration accessibility audit. Evidence:
`/tmp/locus-library-agent-ui-qualified.log`; result bundle:
`/tmp/locus-library-derived/Logs/Test/Test-Locus-2026.09.04_19-20-36--0400.xcresult`.

`AgentInspectorUITests` exercises exact clicked event identity, its execution
and back paths, selecting a parent while preserving the workspace conversation
title, and side-chat detail. It attaches rendered screenshots named Exact
incoming event, Exact event execution, Scheduled agent overview, and Agent
task detail. Legacy overview tests now open the collapsed configuration and
scroll to content deliberately. Initial rendered review identified small
metric tiles, a truncated scope caption and insufficient purpose text; those
were replaced with labelled rows, wrapping scope copy and a purpose preview.
The side-chat header now states Working, its relevant saved state, or Idle;
the stored first-message preview is labelled Chat preview, not a latest
conversation summary. Chat context consistently uses chat terminology.
Rendered review of the legacy UI regression recording confirmed that metric
rows were visible while child identifiers were flattened; explicit
accessibility containment and metric labels address that lookup failure.
Subsequent recordings showed that clicking either the configuration container
or its native disclosure element landed on the title while the triangle
remained closed. Configuration now uses a full-row button with an explicit
Expanded/Collapsed accessibility value, preserving the same saved per-agent
state. The legacy tests assert expansion before checking the source.
`testAgentConfigurationPassesAccessibilityAudit` expands configuration,
verifies its cadence, captures the accessibility tree and rendered state, and
audits the source and instructions with the existing native audit helper.
The final capture verifies the visible inspector and accompanies the passing
accessibility checks. A stale Finder alert and a permissions panel obstruct
the central conversation in that capture, so it is not evidence of an
unobstructed full-window visual review. The documented manual verification
matrix remains separate from these automated results.

## Deliberate limits

Task history is labelled Recent work and shows the most recent 30 saved runs.
Execution progress uses the latest 100 saved events and labels file effects as
recent activity. An unavailable summary is not invented. Completed duration
requires actual admission and completion timestamps; time spent waiting in
the queue is not presented as execution duration. Missing usage is reported
as not reported. Historic links that were never persisted cannot be recovered
from a currently selected or newer event.
