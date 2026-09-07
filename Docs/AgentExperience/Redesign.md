# Locus Agent experience redesign

## Product model established by the audit

Locus has two distinct concepts that were both described as Agents:

- A persistent Agent is backed by an event/price trigger or a schedule. It owns saved instructions, a model route, its receiving conversation, and additional side conversations. Its definition remains separate from the currently open chat.
- A specialist profile supplies reusable behavior, model settings and access ceilings for teams. It is not a persistent automation or a trigger.

Connections are shared sources and service credentials. Individual triggers choose which connections may perform actions. The app’s tool approval mode is shared across chats and worker runtimes; it is not an independent setting for each Agent. Workspace/environment boundaries and individual tool/service restrictions still apply.

Scheduled and event work is coordinated locally while Locus is open. A hosted model does not make the Agent a cloud background service. The backend currently represents one trigger per persistent Agent; this redesign does not pretend to offer multiple independent triggers on a single Agent.

## Implemented information architecture

The Manage Agents sheet now opens the Agent collection, with a navigation column for:

1. **Agents** — searchable/filterable collection and a detail view with instructions, trigger, access/environment, controls, and recent activity.
2. **Activity** — a combined recent timeline across schedules and incoming events, with Agent/status filters, exact-record inspection, and supported retry actions.
3. **Connections** — shared source discovery, connection health, last check, and Agent usage. In-use connections explain why removal is unavailable.
4. **Runtime** — shared concurrency and local execution context, with a route to specialists/teams.

“New Agent” opens three clear ways to start work: schedule, incoming event, or price condition. These choices are separate from configured Agents. Creation then uses one editable form, rather than a long wizard.

## Surface changes

### Sidebar and Agent selector

- Configured Agents appear even before they have chats.
- Search finds Agent names and their conversations.
- Status filters and compact recent conversations keep larger collections usable.
- Parent selection is distinct from selecting a chat; the current conversation remains visible.
- A searchable selector supports arrow keys and Return, shows the chosen Agent/environment, and explains the open chat’s ownership.
- Agent actions include creation, editing, pause/resume, new chat and deletion confirmation.

### Creation and configuration

- Event Agents begin with name and instructions, then source/matching conditions.
- Advanced environment, workflow and service actions use disclosures.
- An event Agent can be created paused before automatic execution is enabled.
- Required sources, receiving chats and price symbols/thresholds are validated before Save is enabled.
- Schedule creation puts instructions and cadence first, with model/environment/runner details available below.
- The instruction field and first workflow step stay synchronized.
- Cancellation protects edited drafts; fixed footers keep actions reachable.
- Specialist settings distinguish conversation behavior, reusable profiles and teams, with search and validation.

### Right inspector

- Agent detail exposes trigger health, permissions/environment and activity without burying everything under advanced setup.
- Live work is distinguished from an Agent being ready to listen or paused.
- The Agent panel covers the selected Agent; Overview covers the open conversation.
- Runs has a direct rail entry in Agent mode and describes the current chat’s executions.
- The workspace AGENTS.md panel is labeled Instructions, avoiding confusion with persistent Agents.
- Record inspection preserves exact event, occurrence, chat and run provenance.
- Loading, unavailable data and failures have explicit states and retry/navigation paths.
- Goals and planning remain available from the composer, with clearer descriptions of their scope.
- Goal editing explains why an allowance is invalid and that saving pauses current work. Approval choices keep their scope readable, and long plan previews scroll without displacing the decision controls.

### Permissions and context

- The composer describes the shared tool approval policy with a plain-language explanation for each level.
- Context is labeled as information included in the chat, with an explicit distinction from file access.
- Clearing all connected-service action toggles now persists an empty action list. Previously, Save could silently add the source connection back.
- Webhook/price-feed and missing connection IDs cannot be saved as action grants.

## Reliability and validation

Presentation and request-body tests cover typed Agent identity, zero-chat Agents, search/filtering, source health, mixed activity ordering, event receipt versus execution status, skipped occurrences, retry eligibility, empty permission grants, schedule loading/error recovery, and nested creation presentation. Live third-party triggers are not fired during validation.

The native app and UI-test targets compile. The final targeted regression run passed **150 tests with zero failures**, including the final consistency fixes. Manual inspection in a synthetic native fixture checked the sidebar, right Agent inspector, Manage Agents collection/detail, creation chooser, and incoming-event form, including its disabled initial Save state and cancellation. That review led to smaller forms and more explicit accessibility boundaries.

The updated native UI tests cover navigation, inspector context, creation forms, schedule validation, and specialist editing. Their final execution and the final on-screen polish check are pending: the Mac locked during validation, blocking macOS automation before any UI test ran. These UI checks must not be reported as passed. The fixture has no live automation backend, so refreshing it intentionally exposes an unavailable-server error rather than concealing failures.

The activity page describes recent loaded records. Durable pagination and execution outputs remain in the contextual inspector. Duration and tool/command/output details are shown only when the stored execution provides them; receipt timestamps are not presented as fabricated run durations.

Existing model wire values, persisted navigation IDs, and backend routing are retained. Changes were made around the in-progress response/output work already present in the checkout.
