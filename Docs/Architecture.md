# Locus architecture and ownership boundaries

Locus is one product with two local runtimes:

- The SwiftUI application owns native presentation, workspace access,
  permission surfaces, platform integrations, and feature view models.
- The Python service owns model/provider I/O, agent orchestration, tools,
  sessions, schedules, persisted runs, and the authenticated local API.

They communicate over authenticated loopback HTTP and WebSocket contracts.
Public route compatibility is characterized in
`agent/tests/fixtures/server-routes.txt`.

## Native application

`AppModel` is the composition root. It may connect features, translate events,
and derive cross-feature presentation, but new feature state and actions should
not be added to it.

Feature ownership currently includes:

- `GitWorkspaceModel`: Git status, diff selection, branch and remote state,
  staging, hunk operations, commit drafting, and the tasks that perform them.
- `BrowserService`, `TerminalSession`, `ApplicationContextService`, and
  `SimulatorControlService`: platform-specific runtime state with independent
  lifetimes.
- `Models/`: domain value types grouped by schedule, planning, inspector,
  agent, provider, session, transcript, settings, and extension concerns.

Views for a feature should observe its feature model directly. A composition
view may read a child model through `AppModel`; when it does, `AppModel` must
deliberately bridge publication rather than assuming nested observable objects
invalidate their parent.

Dependencies flow toward feature models. A feature model must not import or
retain `AppModel`; the composition root supplies narrow callbacks for shared
presentation such as toasts or session activity.

## Local Python service

`server.py` is the application composition root and compatibility handler
surface. `create_app()` creates isolated FastAPI instances, and request-time
dependencies resolve from the concrete request application.

- `chat_service.py` owns stateful chat and orchestration runtime behavior.
- `api/dependencies.py` owns per-application service resolution.
- `api/system.py`, `providers.py`, `continuity.py`, `knowledge.py`,
  `evaluations.py`, `sessions.py`, `schedules.py`, `runs.py`, `workspace.py`,
  and `extensions.py` own the HTTP route map for their domains.
- `api/chat_transport.py` owns the WebSocket route map.

API modules receive explicit handler/dependency surfaces and must not import
`server.py` or a module-global application. New routes belong in the matching
domain module. `server.app` exists as the uvicorn/import compatibility entry
point; tests and embedders should construct an isolated app with `create_app()`.

## Reviewable changes

Keep a refactor and a behavior change in separate commits whenever either can
stand alone. Each commit should build and have the narrowest relevant tests.
Route moves retain the contract snapshot; feature ownership moves retain
characterization tests until consumers use the new boundary directly.

`python3 Tools/ReviewabilityReport.py` reports large production files, large
diff slices, and architecture-boundary drift. Its thresholds are advisory:
they surface review questions but never fail CI. A large file is not itself a
defect; adding another unrelated responsibility to one is the signal to stop
and choose an owner.
