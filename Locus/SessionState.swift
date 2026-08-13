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
            suggestions: []
        )
    }

    var completedStepCount: Int { plan.filter { $0.state == .done }.count }

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

    var timestamp: Int {
        switch self {
        case .planCreated(_, let at), .stepState(_, _, let at),
             .fileEdit(_, _, _, let at), .fileRead(_, let at),
             .fileCreate(_, let at), .command(_, _, let at),
             .message(_, let at), .tokens(_, _, _, let at),
             .status(_, _, let at), .runFinished(_, _, let at):
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

        case .fileRead(let path, let at):
            upsertFile(in: &next, path: path, kind: .read, added: 0, removed: 0, at: at)

        case .fileCreate(let path, let at):
            upsertFile(in: &next, path: path, kind: .create, added: 0, removed: 0, at: at)

        case .command:
            break

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
        persist()
    }

    func emit(_ event: SessionEvent, sessionID: String? = nil) {
        let id = sessionID ?? activeSessionID
        guard !id.isEmpty, let current = states[id] else { return }
        if case .tokens(let used, let window, let cost, _) = event,
           case .tokens(let previousUsed, let previousWindow, let previousCost, _)? = current.events.last,
           used == previousUsed, window == previousWindow, cost == previousCost {
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
        persist()
    }

    private func persist() {
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
