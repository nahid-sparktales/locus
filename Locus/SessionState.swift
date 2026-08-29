import Combine
import Foundation

enum SessionStatus: String, Codable, Equatable {
    case idle
    case running
    case error
}

struct SessionPlanStep: Identifiable, Codable, Equatable {
    enum State: String, Codable, Equatable {
        case pending
        case running
        case done
        case failed
    }

    var id: String
    var label: String
    var state: State
    var startedAt: Int?
    var endedAt: Int?
}

struct SessionFileTouch: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case edit
        case read
        case create
        case delete
    }

    var path: String
    var kind: Kind
    var added: Int
    var removed: Int
    var lastTouchedAt: Int

    var id: String { path }
}

struct SessionRunSummary: Codable, Equatable {
    enum Outcome: String, Codable, Equatable {
        case completed
        case partial
        case failed
    }

    var completedSteps: Int
    var totalSteps: Int
    var durationMs: Int
    var endedAt: Int
    var summary: String
    var outcome: Outcome
}

/// A non-file result the agent produced during the session — today a website
/// (a loopback dev-server URL). File outputs are not stored here: they are
/// derived from `SessionState.files` where `kind == .create`.
struct SessionOutput: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case website
    }

    var kind: Kind
    /// Normalized absolute URL string (see `normalize`).
    var target: String
    var firstSeenAt: Int
    var lastSeenAt: Int

    /// Mirrors the Codex artifact key so the same website never lists twice.
    var key: String { "\(kind.rawValue):\(target)" }
    var id: String { key }

    /// Trim, add `http://` when no scheme was given, lowercase scheme and host,
    /// and drop a trailing slash so `localhost:3000/`, `HTTP://LOCALHOST:3000`
    /// and `docs.example/x/` vs `docs.example/x` collapse onto one entry.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value), let host = components.host,
              !host.isEmpty
        else { return value }
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? value
    }
}

/// Something the conversation drew on: a file, image, application snapshot,
/// simulator, URL, MCP server, or web search.
struct SessionSource: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case file
        case image
        case application
        case simulator
        case url
        case tool
        case webSearch
    }

    enum Activity: String, Codable, Equatable {
        case provided
        case read
        case created
        case updated
    }

    var kind: Kind
    /// Stable identity: `file:<abs path>`, `image:<name>`, `url:<normalized>`,
    /// `tool:<server>`, or `web-search`.
    var key: String
    var label: String
    /// Absolute path or absolute URL; nil for pasted images, tools, web search.
    var target: String?
    /// Unique, in first-seen order.
    var activities: [Activity]
    /// Times provided / fetched / invoked.
    var count: Int
    var firstSeenAt: Int
    var lastSeenAt: Int

    var id: String { key }

    static func key(kind: Kind, label: String, target: String?) -> String {
        switch kind {
        case .file: "file:\(target ?? label)"
        case .image: "image:\(target ?? label)"
        case .application: "application:\(target ?? label)"
        case .simulator: "simulator:\(target ?? label)"
        case .url: "url:\(SessionOutput.normalize(target ?? label))"
        case .tool: "tool:\(label)"
        case .webSearch: "web-search"
        }
    }

    /// `host/path` without scheme, query, or a trailing slash — the Codex
    /// fallback title for a link.
    static func urlLabel(_ raw: String) -> String {
        let normalized = SessionOutput.normalize(raw)
        guard let components = URLComponents(string: normalized), let host = components.host,
              !host.isEmpty
        else { return raw }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        let shownHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let port = components.port.map { ":\($0)" } ?? ""
        return shownHost + port + path
    }
}

/// One user-provided input, recorded when a message is sent.
struct SessionProvidedItem: Codable, Equatable {
    var name: String
    /// Absolute path; nil for pasted images that never touched disk.
    var path: String?
    /// A directly provided file, image, application snapshot, or simulator.
    var kind: SessionSource.Kind
}

struct SessionWorkspaceIdentity: Codable, Equatable {
    struct Git: Codable, Equatable {
        var branch: String
        var dirty: Int
        var ahead: Int?
        var behind: Int?
    }

    var name: String
    var path: String
    var git: Git?
}

struct SessionModelIdentity: Codable, Equatable {
    var provider: String
    var id: String
    var contextWindow: Int?
}

struct SessionResources: Codable, Equatable {
    var tokensUsed: Int
    var costUsd: Double
    var messages: Int
}

struct SessionState: Codable, Equatable {
    var status: SessionStatus
    var statusReason: String?
    var workspace: SessionWorkspaceIdentity
    var model: SessionModelIdentity
    var plan: [SessionPlanStep]
    var events: [SessionEvent]
    var files: [SessionFileTouch]
    var resources: SessionResources
    var lastRun: SessionRunSummary?
    var suggestions: [String]
    /// Website outputs, newest first. File outputs live in `files`.
    var outputs: [SessionOutput] = []
    /// Everything the conversation drew on; ordering is a view concern.
    var sources: [SessionSource] = []

    enum CodingKeys: String, CodingKey {
        case status, statusReason, workspace, model, plan, events, files, resources
        case lastRun, suggestions, outputs, sources
    }

    init(
        status: SessionStatus,
        statusReason: String?,
        workspace: SessionWorkspaceIdentity,
        model: SessionModelIdentity,
        plan: [SessionPlanStep],
        events: [SessionEvent],
        files: [SessionFileTouch],
        resources: SessionResources,
        lastRun: SessionRunSummary?,
        suggestions: [String],
        outputs: [SessionOutput] = [],
        sources: [SessionSource] = []
    ) {
        self.status = status
        self.statusReason = statusReason
        self.workspace = workspace
        self.model = model
        self.plan = plan
        self.events = events
        self.files = files
        self.resources = resources
        self.lastRun = lastRun
        self.suggestions = suggestions
        self.outputs = outputs
        self.sources = sources
    }

    /// States persisted before outputs/sources existed must keep decoding, so
    /// the new collections default instead of failing the whole session map.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(SessionStatus.self, forKey: .status)
        statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason)
        workspace = try container.decode(SessionWorkspaceIdentity.self, forKey: .workspace)
        model = try container.decode(SessionModelIdentity.self, forKey: .model)
        plan = try container.decodeIfPresent([SessionPlanStep].self, forKey: .plan) ?? []
        events = try container.decodeIfPresent([SessionEvent].self, forKey: .events) ?? []
        files = try container.decodeIfPresent([SessionFileTouch].self, forKey: .files) ?? []
        resources = try container.decode(SessionResources.self, forKey: .resources)
        lastRun = try container.decodeIfPresent(SessionRunSummary.self, forKey: .lastRun)
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        outputs = try container.decodeIfPresent([SessionOutput].self, forKey: .outputs) ?? []
        sources = try container.decodeIfPresent([SessionSource].self, forKey: .sources) ?? []
    }

    static func empty(
        workspacePath: String = "",
        modelID: String = "",
        provider: String = ""
    ) -> SessionState {
        SessionState(
            status: .idle,
            statusReason: nil,
            workspace: SessionWorkspaceIdentity(
                name: URL(fileURLWithPath: workspacePath).lastPathComponent,
                path: workspacePath,
                git: nil
            ),
            model: SessionModelIdentity(
                provider: provider,
                id: modelID,
                contextWindow: SessionModelMetadata.lookup(modelID)?.contextWindow
            ),
            plan: [],
            events: [],
            files: [],
            resources: SessionResources(tokensUsed: 0, costUsd: 0, messages: 0),
            lastRun: nil,
            suggestions: [],
            outputs: [],
            sources: []
        )
    }

    var completedStepCount: Int { plan.filter { $0.state == .done }.count }

    /// Files the agent brought into existence this session — the file half of
    /// the Outputs list. `files` is already newest first.
    var createdFiles: [SessionFileTouch] { files.filter { $0.kind == .create } }

    var contextFraction: Double? {
        guard let window = model.contextWindow, window > 0 else { return nil }
        return min(max(Double(resources.tokensUsed) / Double(window), 0), 1)
    }

    var summaryMarkdown: String {
        var lines = [
            "# Session summary",
            "",
            "- Status: \(status.rawValue.capitalized)",
            "- Workspace: \(workspace.name) (`\(workspace.path)`)",
            "- Model: \(model.id.isEmpty ? "Unknown" : model.id)",
            "- Context: \(resources.tokensUsed) tokens",
            "- Cost: $\(String(format: "%.2f", resources.costUsd))",
            "- Messages: \(resources.messages)",
        ]
        if !plan.isEmpty {
            lines += ["", "## Plan"]
            lines += plan.map { step in
                let mark = step.state == .done ? "x" : " "
                return "- [\(mark)] \(step.label) — \(step.state.rawValue)"
            }
        }
        if !files.isEmpty {
            lines += ["", "## Files"]
            lines += files.map { "- `\($0.path)` (+\($0.added) −\($0.removed))" }
        }
        if !createdFiles.isEmpty || !outputs.isEmpty {
            lines += ["", "## Outputs"]
            lines += createdFiles.map { "- `\($0.path)`" }
            lines += outputs.map { "- \($0.target)" }
        }
        if !sources.isEmpty {
            lines += ["", "## Sources"]
            lines += sources.map { source in
                source.target.map { "- \(source.label) (\($0))" } ?? "- \(source.label)"
            }
        }
        if let lastRun {
            lines += ["", "## Last run", lastRun.summary]
        }
        return lines.joined(separator: "\n")
    }
}

enum SessionEvent: Codable, Equatable {
    case planCreated(steps: [SessionPlanStep], at: Int)
    case stepState(stepID: String, state: SessionPlanStep.State, at: Int)
    case fileEdit(path: String, added: Int, removed: Int, at: Int)
    case fileRead(path: String, at: Int)
    case fileCreate(path: String, at: Int)
    case command(cmd: String, exitCode: Int?, at: Int)
    case message(role: SessionMessageRole, at: Int)
    case tokens(used: Int, window: Int?, costUsd: Double?, at: Int)
    case status(status: SessionStatus, reason: String?, at: Int)
    case runFinished(
        summary: SessionRunSummary,
        suggestions: [String]?,
        at: Int
    )
    /// The agent produced a website (a dev-server URL it started or opened).
    case websiteOutput(url: String, at: Int)
    /// The user sent files/images with a message (one event per send).
    case sourceProvided(items: [SessionProvidedItem], at: Int)
    /// The agent drew on a URL, MCP server, or web search.
    case sourceUsed(kind: SessionSource.Kind, label: String, target: String?, at: Int)

    var timestamp: Int {
        switch self {
        case .planCreated(_, let at), .stepState(_, _, let at),
             .fileEdit(_, _, _, let at), .fileRead(_, let at),
             .fileCreate(_, let at), .command(_, _, let at),
             .message(_, let at), .tokens(_, _, _, let at),
             .status(_, _, let at), .runFinished(_, _, let at),
             .websiteOutput(_, let at), .sourceProvided(_, let at),
             .sourceUsed(_, _, _, let at):
            at
        }
    }
}

enum SessionMessageRole: String, Codable, Equatable {
    case user
    case assistant
}

enum SessionStateReducer {
    static let eventLimit = 200
    static let outputLimit = 50
    static let sourceLimit = 100
    /// Files were the one list without a bound. That was survivable while the
    /// only feeds were a tool naming a path and git reporting a change; a
    /// workspace watcher can see a whole build tree, and every entry is
    /// persisted.
    static let fileLimit = 200

    static func reduce(_ state: SessionState, _ event: SessionEvent) -> SessionState {
        var next = state
        next.events.append(event)
        if next.events.count > eventLimit {
            next.events.removeFirst(next.events.count - eventLimit)
        }

        switch event {
        case .planCreated(let steps, _):
            next.plan = steps

        case .stepState(let stepID, let newState, let at):
            guard let index = next.plan.firstIndex(where: { $0.id == stepID }) else { break }
            let previous = next.plan[index].state
            next.plan[index].state = newState
            if newState == .running, previous != .running {
                next.plan[index].startedAt = at
                next.plan[index].endedAt = nil
            }
            if newState == .done || newState == .failed {
                next.plan[index].startedAt = next.plan[index].startedAt ?? at
                next.plan[index].endedAt = at
            } else if newState == .pending {
                next.plan[index].startedAt = nil
                next.plan[index].endedAt = nil
            }

        case .fileEdit(let path, let added, let removed, let at):
            upsertFile(
                in: &next,
                path: path,
                kind: .edit,
                added: added,
                removed: removed,
                at: at
            )
            markSourceActivity(in: &next, path: path, activity: .updated)

        case .fileRead(let path, let at):
            upsertFile(in: &next, path: path, kind: .read, added: 0, removed: 0, at: at)
            markSourceActivity(in: &next, path: path, activity: .read)

        case .fileCreate(let path, let at):
            upsertFile(in: &next, path: path, kind: .create, added: 0, removed: 0, at: at)
            markSourceActivity(in: &next, path: path, activity: .created)

        case .command:
            break

        case .websiteOutput(let url, let at):
            upsertWebsiteOutput(in: &next, url: url, at: at)

        case .sourceProvided(let items, let at):
            for item in items where item.kind == .file
                || item.kind == .image
                || item.kind == .application
                || item.kind == .simulator {
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let path = item.path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                guard !name.isEmpty || path != nil else { continue }
                upsertSource(
                    in: &next,
                    kind: item.kind,
                    label: name.nilIfEmpty ?? URL(fileURLWithPath: path ?? "").lastPathComponent,
                    target: path,
                    activity: .provided,
                    at: at
                )
            }

        case .sourceUsed(let kind, let label, let target, let at):
            guard kind == .url || kind == .tool || kind == .webSearch else { break }
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTarget = target?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            guard kind != .url || cleanTarget != nil else { break }
            upsertSource(
                in: &next,
                kind: kind,
                label: cleanLabel.nilIfEmpty
                    ?? (kind == .url ? SessionSource.urlLabel(cleanTarget ?? "") : "Web search"),
                target: kind == .url ? SessionOutput.normalize(cleanTarget ?? "") : nil,
                activity: kind == .url ? .read : nil,
                at: at
            )

        case .message:
            next.resources.messages += 1

        case .tokens(let used, let window, let costUsd, _):
            next.resources.tokensUsed = max(used, 0)
            if let window, window > 0 { next.model.contextWindow = window }
            if let costUsd { next.resources.costUsd = max(costUsd, 0) }

        case .status(let status, let reason, _):
            next.status = status
            next.statusReason = status == .error
                ? reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                : nil

        case .runFinished(let summary, let suggestions, _):
            next.lastRun = summary
            next.suggestions = Array((suggestions ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.prefix(3))
            next.status = .idle
            next.statusReason = nil
        }
        return next
    }

    private static func upsertFile(
        in state: inout SessionState,
        path rawPath: String,
        kind: SessionFileTouch.Kind,
        added: Int,
        removed: Int,
        at: Int
        ) {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        if let index = state.files.firstIndex(where: { $0.path == path }) {
            let existingKind = state.files[index].kind
            state.files[index].kind = switch (existingKind, kind) {
            case (.create, .edit), (.delete, .edit), (_, .read): existingKind
            default: kind
            }
            state.files[index].added += max(added, 0)
            state.files[index].removed += max(removed, 0)
            state.files[index].lastTouchedAt = max(state.files[index].lastTouchedAt, at)
        } else {
            state.files.append(SessionFileTouch(
                path: path,
                kind: kind,
                added: max(added, 0),
                removed: max(removed, 0),
                lastTouchedAt: at
            ))
        }
        state.files.sort {
            $0.lastTouchedAt == $1.lastTouchedAt
                ? $0.path < $1.path : $0.lastTouchedAt > $1.lastTouchedAt
        }
        // Already newest-first, so the tail is the least recently touched.
        if state.files.count > fileLimit {
            state.files.removeLast(state.files.count - fileLimit)
        }
    }

    private static func upsertWebsiteOutput(in state: inout SessionState, url: String, at: Int) {
        let target = SessionOutput.normalize(url)
        guard !target.isEmpty else { return }
        if let index = state.outputs.firstIndex(where: { $0.kind == .website && $0.target == target }) {
            state.outputs[index].lastSeenAt = max(state.outputs[index].lastSeenAt, at)
        } else {
            state.outputs.append(SessionOutput(
                kind: .website,
                target: target,
                firstSeenAt: at,
                lastSeenAt: at
            ))
        }
        state.outputs.sort {
            $0.lastSeenAt == $1.lastSeenAt
                ? $0.target < $1.target : $0.lastSeenAt > $1.lastSeenAt
        }
        if state.outputs.count > outputLimit {
            state.outputs.removeLast(state.outputs.count - outputLimit)
        }
    }

    private static func upsertSource(
        in state: inout SessionState,
        kind: SessionSource.Kind,
        label: String,
        target: String?,
        activity: SessionSource.Activity?,
        at: Int
    ) {
        let key = SessionSource.key(kind: kind, label: label, target: target)
        if let index = state.sources.firstIndex(where: { $0.key == key }) {
            state.sources[index].count += 1
            state.sources[index].lastSeenAt = max(state.sources[index].lastSeenAt, at)
            if !label.isEmpty { state.sources[index].label = label }
            if let target { state.sources[index].target = target }
            if let activity, !state.sources[index].activities.contains(activity) {
                state.sources[index].activities.append(activity)
            }
        } else {
            state.sources.append(SessionSource(
                kind: kind,
                key: key,
                label: label,
                target: target,
                activities: activity.map { [$0] } ?? [],
                count: 1,
                firstSeenAt: at,
                lastSeenAt: at
            ))
        }
        if state.sources.count > sourceLimit {
            // Drop the least recently seen so the ring keeps what still matters.
            let sorted = state.sources.sorted { $0.lastSeenAt > $1.lastSeenAt }
            let keep = Set(sorted.prefix(sourceLimit).map(\.key))
            state.sources.removeAll { !keep.contains($0.key) }
        }
    }

    /// A user-provided file that the agent later reads, creates, or edits
    /// picks up that activity — this feeds the "Read/Created/Updated during
    /// the chat" lines of the complete sources list. `lastSeenAt` stays the
    /// time the file was last *provided*, which is what Codex orders by.
    private static func markSourceActivity(
        in state: inout SessionState,
        path rawPath: String,
        activity: SessionSource.Activity
    ) {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let root = state.workspace.path.hasSuffix("/")
            ? state.workspace.path : state.workspace.path + "/"
        let candidates: Set<String> = [path, root + path]
        for index in state.sources.indices
        where (state.sources[index].kind == .file || state.sources[index].kind == .image)
            && state.sources[index].target.map({ candidates.contains($0) }) == true {
            if !state.sources[index].activities.contains(activity) {
                state.sources[index].activities.append(activity)
            }
        }
    }
}

struct SessionModelMetadata: Equatable {
    var contextWindow: Int?
    var inputCostPerMillion: Double
    var outputCostPerMillion: Double

    static let known: [String: SessionModelMetadata] = [
        "gpt-5.6": SessionModelMetadata(
            contextWindow: 1_050_000,
            inputCostPerMillion: 5,
            outputCostPerMillion: 30
        ),
        "gpt-5.6-sol": SessionModelMetadata(
            contextWindow: 1_050_000,
            inputCostPerMillion: 5,
            outputCostPerMillion: 30
        ),
        "gpt-5.6-terra": SessionModelMetadata(
            contextWindow: 1_050_000,
            inputCostPerMillion: 2,
            outputCostPerMillion: 12
        ),
        "gpt-5.6-luna": SessionModelMetadata(
            contextWindow: 1_050_000,
            inputCostPerMillion: 0.20,
            outputCostPerMillion: 1.20
        ),
    ]

    static func lookup(_ modelID: String) -> SessionModelMetadata? {
        let normalized = modelID.lowercased()
        if let exact = known[normalized] { return exact }
        return known.first(where: { normalized.hasPrefix($0.key + "-") })?.value
    }

    func estimatedCost(promptTokens: Int, completionTokens: Int) -> Double {
        (
            Double(max(promptTokens, 0)) * inputCostPerMillion
                + Double(max(completionTokens, 0)) * outputCostPerMillion
        ) / 1_000_000
    }
}

@MainActor
final class SessionStateEmitter: ObservableObject {
    @Published private(set) var states: [String: SessionState] = [:]
    @Published private(set) var activeSessionID = ""

    private var persistenceEnabled = false
    private var defaults: UserDefaults = .standard
    private var persistenceKey = "Locus.sessionOverviewStates.v1"
    private var persistTask: Task<Void, Never>?

    var state: SessionState {
        states[activeSessionID] ?? .empty()
    }

    func configurePersistence(
        enabled: Bool,
        defaults: UserDefaults = .standard,
        key: String = "Locus.sessionOverviewStates.v1"
    ) {
        persistenceEnabled = enabled
        self.defaults = defaults
        persistenceKey = key
        guard enabled,
              let data = defaults.data(forKey: key),
              let restored = try? JSONDecoder().decode([String: SessionState].self, from: data)
        else { return }
        states = restored.mapValues { value in
            var bounded = value
            bounded.events = Array(value.events.suffix(SessionStateReducer.eventLimit))
            bounded.suggestions = Array(value.suggestions.prefix(3))
            bounded.outputs = Array(value.outputs.prefix(SessionStateReducer.outputLimit))
            bounded.files = Array(
                value.files
                    .sorted { $0.lastTouchedAt > $1.lastTouchedAt }
                    .prefix(SessionStateReducer.fileLimit)
            )
            bounded.sources = Array(
                value.sources
                    .sorted { $0.lastSeenAt > $1.lastSeenAt }
                    .prefix(SessionStateReducer.sourceLimit)
            )
            return bounded
        }
    }

    func activate(sessionID: String, initial: SessionState) {
        guard !sessionID.isEmpty else { return }
        activeSessionID = sessionID
        if var existing = states[sessionID] {
            existing.workspace = initial.workspace
            existing.model.provider = initial.model.provider
            existing.model.id = initial.model.id
            if let reported = initial.model.contextWindow { existing.model.contextWindow = reported }
            states[sessionID] = existing
        } else {
            states[sessionID] = initial
        }
        persistNow()
    }

    func emit(_ event: SessionEvent, sessionID: String? = nil) {
        let id = sessionID ?? activeSessionID
        guard !id.isEmpty, let current = states[id] else { return }
        if case .tokens(let used, let window, let cost, _) = event,
           case .tokens(let previousUsed, let previousWindow, let previousCost, _)? = current.events.last,
           used == previousUsed, window == previousWindow, cost == previousCost {
            return
        }
        // Background-service refreshes report the same dev server many times;
        // a website already on record must not spend the event ring.
        if case .websiteOutput(let url, _) = event,
           current.outputs.contains(where: { $0.target == SessionOutput.normalize(url) }) {
            return
        }
        states[id] = SessionStateReducer.reduce(current, event)
        persist()
    }

    func synchronize(
        workspace: SessionWorkspaceIdentity? = nil,
        model: SessionModelIdentity? = nil,
        messages: Int? = nil,
        sessionID: String? = nil
    ) {
        let id = sessionID ?? activeSessionID
        guard !id.isEmpty, var current = states[id] else { return }
        if let workspace { current.workspace = workspace }
        if let model {
            let previousWindow = current.model.contextWindow
            current.model = model
            if current.model.contextWindow == nil { current.model.contextWindow = previousWindow }
        }
        if let messages { current.resources.messages = max(messages, 0) }
        states[id] = current
        persist()
    }

    func reset(sessionID: String, initial: SessionState) {
        guard !sessionID.isEmpty else { return }
        activeSessionID = sessionID
        states[sessionID] = initial
        persistNow()
    }

    /// Coalesces writes. Every event re-encodes the whole store, so a burst —
    /// a build the workspace watcher saw, a long turn's tool calls — used to
    /// mean one full JSON encode per event.
    private func persist() {
        guard persistenceEnabled else { return }
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Writes immediately, for the moments a debounce could lose: session
    /// switches, resets, and termination.
    func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        guard persistenceEnabled else { return }
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}

enum SessionQuickActionFiles {
    struct ProxyResolution: Equatable {
        var url: URL
        var created: Bool
    }

    static let proxyTemplate = """
    {
      "$schemaNote": "Locus proxy list v1. Keep disabled examples or replace them with your own entries.",
      "proxies": [
        {
          "_comment": "Example only — set enabled to true after adding a real proxy URL.",
          "enabled": false,
          "url": "http://user:password@proxy.example:8080"
        }
      ]
    }
    """

    static func resolveProxyConfig(
        workspacePath: String,
        appConfigDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ProxyResolution {
        let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let candidates = [
            workspace.appending(path: "config/proxies.json"),
            workspace.appending(path: "proxies.txt"),
        ]
        if let existing = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return ProxyResolution(url: existing, created: false)
        }
        let root = appConfigDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appending(path: ".config/Locus", directoryHint: .isDirectory)
        let fallback = root.appending(path: "proxies.json")
        if fileManager.fileExists(atPath: fallback.path) {
            return ProxyResolution(url: fallback, created: false)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((proxyTemplate + "\n").utf8).write(to: fallback, options: .atomic)
        return ProxyResolution(url: fallback, created: true)
    }

    static func logURL(
        sessionID: String,
        logsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let root = logsDirectory
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appending(path: "Logs/Locus", directoryHint: .isDirectory)
        let safeID = sessionID.isEmpty
            ? "current-session"
            : sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
                .reduce(into: "") { $0.append($1) }
        return root.appending(path: "\(safeID).log")
    }
}
