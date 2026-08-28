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
- `WorkspaceFileModel`: workspace file indexing, query and preview state, and
  the scan/preview tasks whose results are scoped to one workspace.
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
- `api/workspace.py` owns both the Git inspection route map and its request
  handlers. `api/evaluations.py` owns evaluation HTTP behavior, while
  `evaluation_runtime.py` owns suite execution and receives the team runner
  through the concrete application composition boundary.
- `api/system.py` owns health, tools, permissions, configuration, and managed
  service handlers. `api/providers.py` owns provider selection, model discovery,
  routing samples, and ChatGPT account handlers.
- `api/knowledge.py` owns workspace knowledge and approved-memory HTTP behavior.
  `api/sessions.py` owns session lifecycle and chat-organization HTTP behavior;
  shared request-independent state lives in `memory_runtime.py` and
  `session_runtime.py`.
- `api/continuity.py`, `schedules.py`, `runs.py`, and `extensions.py` own their
  HTTP route maps and remain the handler-ownership backlog.
- `api/chat_transport.py` owns the WebSocket route map.

API modules resolve request-owned services through `api/dependencies.py` and
must not import `server.py` or a module-global application. A temporary handler
module parameter is allowed only for named compatibility handlers while a
domain migrates. New routes and their ordinary request behavior belong in the
matching domain module. `server.app` exists as the uvicorn/import compatibility
entry point; tests and embedders should construct an isolated app with
`create_app()`.

## Reviewable changes

Keep a refactor and a behavior change in separate commits whenever either can
stand alone. Each commit should build and have the narrowest relevant tests.
Route moves retain the contract snapshot; feature ownership moves retain
characterization tests until consumers use the new boundary directly.

`python3 Tools/ReviewabilityReport.py` reports large production files, large
diff slices, architecture-boundary drift, and additions of published state or
view-facing actions to `AppModel` and registered route handlers to `server.py`.
Its findings are advisory: they surface review questions but never fail CI. A
large file is not itself a defect; adding another unrelated responsibility to
one is the signal to stop and choose an owner.
