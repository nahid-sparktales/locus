> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/developer-guide/architecture-and-protocol.md).

# Architecture & Protocol

Understand the 2.1 feature-owned native client, domain-owned agent service, Codex component, persistence, and companion boundary.

Locus is one product with two local runtimes:

* The SwiftUI application owns native presentation, workspace access, permission surfaces, platform integrations, and feature view models.
* The Python service owns model and provider I/O, orchestration, tools, sessions, schedules, persisted runs, and the authenticated local API.

They communicate over authenticated loopback HTTP and WebSocket contracts.

## Native app

**AppModel is the composition root.** It connects features, translates events, and derives cross-feature presentation, but new feature state and actions belong in a feature-owned observable model.

In 2.1, provider accounts, agent teams, run history, the live run card, extensions and MCP, workspace knowledge, evaluations, schedules, the Activity Center, transcript search, background services, the AGENTS.md editor, landing flow, and toasts moved to their own tested models. GitWorkspaceModel and WorkspaceFileModel own Git and file behavior, while BrowserService, TerminalSession, ApplicationContextService, and SimulatorControlService retain independent platform lifetimes.

Feature views observe their model directly. Dependencies flow toward feature models; a feature model must not retain AppModel. The composition root supplies narrow callbacks for shared presentation such as toasts or session activity.

## Bundled agent

**server.py is the service composition root.** create\_app builds isolated FastAPI instances, and request-time dependencies resolve from the concrete application.

Chat runtime lives in chat\_service.py. Domain modules own ordinary request behavior: workspace and evaluations; system and providers; knowledge, sessions, and continuity; schedules; runs and usage; extensions; and authenticated chat/Codex transport. Request-neutral runtime helpers live beside those modules.

API modules resolve services through the dependency layer and do not import a module-global application. New routes belong in the matching domain module. The server.app symbol remains only as the uvicorn and import compatibility entry point.

## Communication

The app and service communicate over authenticated REST and WebSocket endpoints bound to 127.0.0.1. The service rejects browser-origin requests. Browser, Notes, Terminal, and Computer Control capabilities appear dynamically only when their native broker and permissions are available.

ChatGPT-plan requests use a pinned Codex App Server child over local JSONL and stdio. Direct builds resolve it from the verified downloaded component; Mac App Store and development builds can embed it. Team workers use a launch-token-authenticated internal broker and never receive OAuth state.

Locus Mobile uses a separate private TLS gateway with certificate pinning and a one-use pairing code. It never exposes the agent's loopback port.

## Persistence

* append-only session JSONL plus organizer metadata and recoverable trash;
* local SQLite for durable runs, schedules, usage, transcript search, and team events;
* private Git worktrees and immutable evaluation fixtures;
* hashed local note ownership, formatting archives, Notebook labels, Browser profiles, and Keychain-backed Autofill;
* AES-256-GCM memory and continuity with a Keychain-held key; and
* versioned shared Mac/mobile protocol fixtures.

Credentials, secure fields, provider signatures, and hidden reasoning are excluded from run records and exports by default.

## Reviewable changes

Keep a refactor and a behavior change separate when either can stand alone. Route moves retain contract snapshots; feature ownership moves retain characterization tests until consumers use the new boundary directly.

Tools/ReviewabilityReport.py reports large production files, large diff slices, architecture-boundary drift, new published state or view-facing actions in AppModel, and registered route handlers added to server.py. Findings are advisory: a large file is not itself a defect, but another unrelated responsibility is a signal to choose a clearer owner.
