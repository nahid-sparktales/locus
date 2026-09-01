# AppModel publication-graph optimization

## Outcome

Complete the performance extraction started by `SessionCatalogModel` and
`TranscriptPresentationModel` in one implementation run, on one branch, and in
one pull request. The work remains split into reviewable commits, but it has no
mid-run product or architecture decision gate.

This is a behavior-preserving native-app refactor. It does not change backend
routes, persistence formats, session data, provider behavior, or user-facing
interaction.

## Audited baseline

The first extraction removed sidebar hierarchy construction and transcript
presentation construction from broad `AppModel` invalidations. The remaining
cost is the publication graph around the composition root:

- `AppModel.swift` is 1,784 lines and declares 81 `@Published` properties.
- `AppModel` republishes 18 child `ObservableObject` publishers through
  `objectWillChange` or equivalent capability callbacks.
- Native views contain 93 `@EnvironmentObject AppModel` declarations.
- The broadest subscribed source files are `WorkspaceView.swift` (4,440
  lines), `InspectorView.swift` (3,461), `Sheets.swift` (3,357), and
  `ComposerView.swift` (1,961).
- Existing feature models already own Git, files, providers, teams, runs,
  schedules, activity, extensions, knowledge, evaluations, voice, landing,
  background services, and instructions. Their changes are nevertheless
  forwarded into `AppModel`, invalidating unrelated workspace consumers.
- `SessionCatalogModel`, `TranscriptPresentationModel`, `NotebookModel`,
  `TerminalSession`, and `BrowserService` prove that direct feature observation
  works without republishing the composition root.

The main optimization target is therefore invalidation scope, not collection
algorithm speed. Large Swift files are secondary unless splitting them creates
a smaller observation boundary.

## Target ownership

`AppModel` remains the composition root and turn/session orchestrator. It wires
backend events and cross-feature callbacks, but it is no longer the observable
container for feature state or workspace presentation.

The completed boundary has four kinds of owner:

1. Existing feature models remain authoritative for their domains and are
   observed directly by the smallest view that renders them.
2. `WorkspacePresentationModel` owns window chrome and navigation state:
   sidebar/inspector visibility and sizes, inspector tabs and zoom, split-chat
   presentation, sheet/dialog destinations, and one-shot navigation tokens.
3. `ComposerSessionModel` owns composer-local state: draft, mode, history,
   queued messages, attachments/context selection, focus, notices, and the
   transcript-search presentation controls that sit beside the composer.
4. `TurnPresentationModel` publishes one immutable snapshot of active-session
   runtime state: session identity/info, busy and permission status, todos,
   plan/question prompts, runtime phases, steering/work status, lifecycle
   notices, and the active orchestration summary. Backend workflow and worker
   ownership may remain in `AppModel`; explicit commits update this snapshot.

Each extracted model has internal state, explicit mutations, an immutable
snapshot where several fields must change transactionally, and compatibility
accessors in `AppModel` while extension files migrate. None of these models
retain or import `AppModel`.

## Single-run implementation

### 1. Pin the publication budget

- Add a DEBUG-only `AppModel` publication counter and reset/read helpers for
  tests. Do not add production payload logging.
- Add a source manifest listing the temporary composition-root properties and
  the views allowed to observe `AppModel`; make the manifest check deterministic
  in CI.
- Characterize current turn, split-pane, composer, inspector, sheet, and
  settings behavior before moving ownership.
- Retain the existing session-catalog and transcript build counters as
  regression gates.

Commit boundary: tests and measurement only.

### 2. Stop forwarding feature publications

- Inject existing child models at the scene boundary only where a scene needs
  them, or pass them as `@ObservedObject` dependencies to the owning subview.
- Migrate reactive reads of providers, teams, live team runs, landing, runs,
  evaluations, knowledge, activity, schedules, background services,
  extensions, Git, files, instructions, voice, application context, toasts,
  and the downloadable component away from `AppModel` observation.
- Keep actions on the owning feature model. For true cross-feature actions,
  pass a narrow closure from a composition view; do not create another global
  observable action facade.
- Remove every child-to-`AppModel.objectWillChange` forwarding bridge. Replace
  subscriptions that also perform a capability side effect with a dedicated
  callback that performs only that side effect.
- Preserve temporary computed feature facades only for non-reactive extension
  code, and mark them for deletion in the final cleanup commit.

Deterministic gate: publishing every child model in isolation produces zero
`AppModel.objectWillChange` events and does not rebuild either existing
snapshot model.

Commit boundary: direct feature observation and bridge removal.

### 3. Extract workspace presentation

- Add `@MainActor WorkspacePresentationModel: ObservableObject` with private
  state and a snapshot for coupled layout values.
- Move sidebar collapse/width, inspector selection/open tabs/collapse/width,
  inspector zoom, split-chat restoration/ratio/focus, and workspace-level
  sheet/dialog/navigation destinations into it.
- Move the existing UserDefaults-backed layout persistence into this model,
  retaining every current key and the unit-test persistence isolation rules.
- Route multi-value transitions—Just Chat inspector restoration, inspector
  zoom/sidebar restoration, closing selected tabs, and split-pane focus—through
  one commit so each interaction publishes once.
- Back `AppModel` compatibility accessors with the new owner until all
  extensions compile against the boundary.
- Split `WorkspaceView`, `InspectorView`, and the workspace-owned portions of
  `Sheets.swift` into small observation wrappers. A wrapper observes only the
  presentation or feature model needed for that subtree.

Deterministic gates: each compound transition publishes one presentation
snapshot; repeated reads publish zero; feature and transcript updates publish
zero workspace-presentation changes.

Commit boundary: workspace chrome and navigation ownership.

### 4. Extract composer/session-local state

- Add `@MainActor ComposerSessionModel: ObservableObject` and move draft,
  selected mode, prompt history, queued messages, attachments, context files,
  loading/notice state, composer focus, and conversation-search presentation
  into it.
- Keep send orchestration in `AppModel`; provide a narrow immutable send input
  assembled by the composer model and explicit callbacks for send, steer,
  stop, and retry.
- Make attachment ingestion, slash/mention/skill completion, voice transcript
  acceptance, history navigation, and split-pane draft save/restore mutate the
  composer owner rather than manually sending `AppModel.objectWillChange`.
- Preserve workspace draft persistence, queue ordering, search selection,
  focus behavior, and all keyboard shortcuts.
- Split `ComposerView` into observation-scoped input, context, routing, voice,
  and queue subviews. Existing feature models remain direct dependencies.

Deterministic gates: draft edits do not publish the workspace presentation,
Git/files/provider/team changes do not publish composer state, and one
transactional split-pane restore publishes once.

Commit boundary: composer state and composer UI observation.

### 5. Publish turn presentation at one boundary

- Add `@MainActor TurnPresentationModel: ObservableObject` with a complete,
  immutable `TurnPresentationSnapshot` for state rendered by the conversation
  header, work-status strip, plan/question/permission prompts, and session
  overview.
- Update it only through explicit turn-lifecycle commits: session activation,
  send start, backend event batch, permission/question/plan transition,
  completion/interruption, runtime recovery, and active-worker switch.
- Batch fields that currently change together so a backend event causes at most
  one turn-presentation publication. Transcript blocks continue to publish only
  through `TranscriptPresentationModel`.
- Keep backend services, task-worker registry, optimistic session mutations,
  and lifecycle orchestration in `AppModel` for this optimization run.
- Migrate `WorkspaceView` header/status, conversation prompts, session overview,
  menu disabled states, and command availability to observe the snapshot at
  their smallest owning wrappers.

Deterministic gates: one representative backend event produces no more than one
turn snapshot, streaming transcript updates do not republish `AppModel`, and an
unrelated feature publication changes neither turn nor catalog snapshots.

Commit boundary: active-turn presentation ownership.

### 6. Remove compatibility observation and verify the complete graph

- Delete migrated `AppModel` published storage, bridge cancellables, manual
  `objectWillChange.send()` calls used only for UI refresh, and obsolete feature
  facades.
- Leave `AppModel` observation only in an explicit composition-root allowlist.
  Leaf feature views must observe a feature/presentation model or receive value
  inputs and action closures.
- Update `Docs/Architecture.md` with the final ownership and publication rules.
- Add production-safe signposts for workspace-presentation and turn-snapshot
  construction. Record counts and duration only—never prompt text, titles,
  paths, provider credentials, or message contents.
- Run the full verification matrix below from a clean worktree and audit the
  generated project diff before opening the pull request.

Commit boundary: compatibility deletion, documentation, and final guards.

## Verification matrix

### Unit and structural tests

- Existing session-catalog and transcript-presentation suites.
- Workspace presentation: layout persistence, Just Chat restoration, inspector
  tabs/zoom, split-pane focus/ratio, sheets and navigation tokens.
- Composer session: history, queue, attachments, context, mentions/skills,
  focus, search, split-pane restoration, and persistence isolation.
- Turn presentation: runtime recovery, permission/plan/question state machine,
  worker switching, event batching, completion, interruption, and stale-event
  rejection.
- Publication graph:
  - child feature publication -> 0 `AppModel` publications;
  - unrelated feature publication -> 0 catalog/transcript/workspace/composer/
    turn rebuilds;
  - repeated snapshot reads -> 0 rebuilds;
  - each documented compound mutation -> exactly 1 owner publication.
- Structural allowlists for `@Published` members on `AppModel`, remaining
  `@EnvironmentObject AppModel` declarations, and direct
  `objectWillChange.send()` calls.

### Advisory fixtures

- Keep the 500-session, multi-workspace nested-folder fixture.
- Add a realistic active workspace fixture with 500 sessions, 2,000 transcript
  blocks, 20 changed files, 12 provider/team records, and 100 simulated turn
  events.
- Measure initial construction, search, split restoration, draft editing, Git
  refresh, team progress, and event-batch updates. Timings remain advisory;
  publication and rebuild limits are the CI failures.

### Project gates

1. Generate the Xcode project and require a clean generated diff.
2. Run `Tools/AuditDesignSystem.sh`.
3. Run `Tools/ProtocolManifest.py` and the shared iOS wire-type typecheck.
4. Run the full Swift unit suite.
5. Run focused sidebar, composer, inspector, split-pane, plan/question,
   permission, accessibility, and keyboard UI tests.
6. Compile direct-download and App Store release configurations.
7. Run the Python, mobile, wallet-signer, and full protected CI jobs before
   merge.

## One-PR constraints

- Work on `codex/appmodel-optimization-next` from the merge commit containing
  the session-catalog extraction.
- Keep the six commit boundaries above; every commit must compile and pass its
  narrow suite.
- Do not mix backend APIs, persistence migrations, visual redesign, or feature
  behavior with this refactor.
- Preserve user-owned working-tree changes by doing all work in an isolated
  worktree.
- If a behavior cannot be characterized, add the characterization test before
  moving it; do not defer the uncertainty to final integration.

## Completion criteria

The run is complete when all six commits are on one pull request, protected CI
is green, and all of the following are true:

- no child model republishes `AppModel`;
- no manual UI-refresh bridge remains;
- leaf views do not observe `AppModel`;
- session, transcript, workspace, composer, and turn owners rebuild only from
  their documented inputs;
- current persistence keys and backend contracts are unchanged; and
- the generated project, design audit, protocol manifest, unit tests, focused
  UI tests, and both release configurations pass from the exact PR head.
