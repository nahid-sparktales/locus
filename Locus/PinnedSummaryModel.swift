import Foundation

/// Classifies backend tool names so `AppModel` can fold tool results into the
/// Overview's Outputs and Sources without string-matching at every call site.
enum SessionSourceClassifier {
    enum ToolClass: Equatable {
        case webFetch
        case browserNavigate
        case backgroundService
        case mcp(server: String, tool: String)
        case other
    }

    static func classify(tool rawName: String) -> ToolClass {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // MCP first: an `mcp__fetch__web_fetch` is an MCP tool whose detail is
        // JSON arguments, not a URL, and it must count as a tool source.
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
            let server = parts.first?.nilIfEmpty ?? "mcp"
            let tool = parts.dropFirst().joined(separator: "__")
            return .mcp(server: server, tool: tool)
        }
        if name == "web_fetch" || name.hasSuffix("web_fetch") { return .webFetch }
        if name == "browser_navigate" { return .browserNavigate }
        if name == "background_service" || name == "browser_dev_server" { return .backgroundService }
        return .other
    }

    /// Locus has no built-in web search; it only arrives through MCP servers.
    static func isWebSearchTool(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        let markers = [
            "web_search", "websearch", "search_web", "internet_search", "brave_search",
            "tavily", "exa_search", "perplexity", "google_search", "bing_search",
        ]
        return markers.contains { name.contains($0) }
    }

    /// The first loopback URL in free text — the dev-server tool reports
    /// `http://localhost:{port}` in its result.
    static func loopbackURL(in text: String) -> URL? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?:/[^\s)\]"'`]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text, options: [], range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text)
        else { return nil }
        var candidate = String(text[range])
        while let last = candidate.last, ".,;:".contains(last) { candidate.removeLast() }
        return URL(string: candidate)
    }
}

/// The "+" menu in the Outputs section: Codex inserts a creation prompt into
/// the composer for each of these and focuses it.
enum SummaryCreationKind: String, CaseIterable, Identifiable {
    case document
    case presentation
    case spreadsheet
    case site

    var id: String { rawValue }

    var title: String {
        switch self {
        case .document: "Create document"
        case .presentation: "Create presentation"
        case .spreadsheet: "Create spreadsheet"
        case .site: "Create site"
        }
    }

    var symbol: String {
        switch self {
        case .document: "doc.richtext"
        case .presentation: "play.rectangle"
        case .spreadsheet: "tablecells"
        case .site: "globe"
        }
    }

    /// Ends with a space so the person keeps typing the subject.
    var prompt: String {
        switch self {
        case .document:
            "Create a document in this workspace and save it as a Markdown file. It should cover "
        case .presentation:
            "Create a presentation in this workspace (a .pptx file, or slides in Markdown if that is not possible) about "
        case .spreadsheet:
            "Create a spreadsheet in this workspace and save it as a .csv file for "
        case .site:
            "Create a small website in this workspace (index.html plus assets), start it on a local dev server, and open it in the browser. It should "
        }
    }
}

/// Pure derivations that turn `SessionState` plus a few live `AppModel`
/// collections into what the pinned summary renders. Kept UI-free so the
/// ordering and status rules can be unit tested.
enum PinnedSummary {
    static let visibleItemLimit = 6
    static let visibleItemIncrement = 50
    static let visibleSourceLimit = 3

    struct OutputRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case file
            case localSite
            case website(loopback: Bool)
        }

        let key: String
        let kind: Kind
        let label: String
        let meta: String?
        /// Relative path for files, absolute URL string for websites.
        let target: String
        let timestamp: Int

        var id: String { key }
    }

    struct SourceRow: Identifiable, Equatable {
        let source: SessionSource
        let meta: String?
        let detailLines: [String]

        var id: String { source.key }
    }

    enum SubagentStatus: Equatable {
        case waiting
        case working
        case done
        case failed

        var title: String {
            switch self {
            case .waiting: "Waiting"
            case .working: "Working"
            case .done: "Done"
            case .failed: "Failed"
            }
        }

        var isTerminal: Bool { self == .done || self == .failed }
    }

    struct SubagentRow: Identifiable, Equatable {
        let id: String
        let name: String
        let status: SubagentStatus
        /// Set when the row came from a run; nil for live agent activities.
        let runID: String?
    }

    struct PlanRow: Equatable {
        let title: String
        let steps: [SessionPlanStep]
        var completed: Int { steps.filter { $0.state == .done }.count }
    }

    /// One thing the current — or most recently finished — request did.
    struct ActivityRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case command(failed: Bool)
            case file(SessionFileTouch.Kind)
        }

        let id: String
        let kind: Kind
        let label: String
        let meta: String?
        /// Workspace-relative path for file rows, so they can be opened; nil
        /// for commands, which have nothing to open.
        let target: String?
        let timestamp: Int
    }

    // MARK: Activity

    /// What this request did: the commands it ran and the files it touched,
    /// newest first.
    ///
    /// Bounded by `requestStartedAt` rather than by the run record, so it
    /// covers every turn and not only the ones that produced a run — and so a
    /// finished request stays on screen until the next one starts, which is
    /// the whole point of the section. Without a marker (a session persisted
    /// before this existed) there is no request to describe, so nothing shows
    /// rather than the entire session's history.
    static func activity(state: SessionState) -> [ActivityRow] {
        guard let since = state.requestStartedAt else { return [] }
        var commands: [String: ActivityRow] = [:]
        var commandCounts: [String: Int] = [:]
        var files: [String: ActivityRow] = [:]
        for event in state.events where event.timestamp >= since {
            switch event {
            case .command(let cmd, let exitCode, let at):
                let label = cmd
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                let count = (commandCounts[label] ?? 0) + 1
                commandCounts[label] = count
                var failed = (exitCode ?? 0) != 0
                // One failure in a repeated command is still a failure worth
                // showing, so the flag only ever goes one way.
                if case .command(true)? = commands[label]?.kind { failed = true }
                commands[label] = ActivityRow(
                    id: "command:\(label)",
                    kind: .command(failed: failed),
                    label: label,
                    meta: [failed ? "Failed" : nil, count > 1 ? "×\(count)" : nil]
                        .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                    target: nil,
                    timestamp: max(at, commands[label]?.timestamp ?? at)
                )
            case .fileRead(let path, let at):
                upsertActivityFile(&files, path: path, kind: .read, at: at)
            case .fileEdit(let path, _, _, let at):
                upsertActivityFile(&files, path: path, kind: .edit, at: at)
            case .fileCreate(let path, let at):
                upsertActivityFile(&files, path: path, kind: .create, at: at)
            default:
                continue
            }
        }
        return (Array(commands.values) + Array(files.values)).sorted {
            $0.timestamp == $1.timestamp ? $0.label < $1.label : $0.timestamp > $1.timestamp
        }
    }

    /// A file touched twice in one request is one row. Creating outranks
    /// editing, which outranks reading — the strongest thing that happened to
    /// it is what the row should say.
    private static func upsertActivityFile(
        _ files: inout [String: ActivityRow],
        path rawPath: String,
        kind: SessionFileTouch.Kind,
        at: Int
    ) {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        var resolved = kind
        if let existing = files[path], case .file(let previous) = existing.kind {
            resolved = activityRank(previous) >= activityRank(kind) ? previous : kind
        }
        files[path] = ActivityRow(
            id: "file:\(path)",
            kind: .file(resolved),
            label: URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty ?? path,
            meta: activityLabel(resolved),
            target: path,
            timestamp: max(at, files[path]?.timestamp ?? at)
        )
    }

    private static func activityRank(_ kind: SessionFileTouch.Kind) -> Int {
        switch kind {
        case .read: 0
        case .edit: 1
        case .delete: 2
        case .create: 3
        }
    }

    static func activityLabel(_ kind: SessionFileTouch.Kind) -> String {
        switch kind {
        case .read: "Read"
        case .edit: "Edited"
        case .create: "Created"
        case .delete: "Deleted"
        }
    }

    // MARK: Plan

    static func plan(state: SessionState, document: PlanDocument?) -> PlanRow? {
        guard !state.plan.isEmpty else { return nil }
        let title = document?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return PlanRow(title: title ?? "Plan", steps: state.plan)
    }

    // MARK: Outputs

    static let siteExtensions: Set<String> = ["html", "htm"]

    static func outputs(state: SessionState) -> [OutputRow] {
        var rows: [OutputRow] = []
        var seen: Set<String> = []
        for file in state.createdFiles {
            let key = file.path
            guard seen.insert(key).inserted else { continue }
            let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
            rows.append(OutputRow(
                key: key,
                kind: siteExtensions.contains(ext) ? .localSite : .file,
                label: URL(fileURLWithPath: file.path).lastPathComponent,
                meta: nil,
                target: file.path,
                timestamp: file.lastTouchedAt
            ))
        }
        for output in state.outputs where output.kind == .website {
            let key = output.key
            guard seen.insert(key).inserted else { continue }
            let url = URL(string: output.target)
            let loopback = url.map(BrowserScheme.isLoopback) ?? false
            rows.append(OutputRow(
                key: key,
                kind: .website(loopback: loopback),
                label: websiteLabel(target: output.target),
                meta: loopback ? url.flatMap(loopbackMeta) : nil,
                target: output.target,
                timestamp: output.lastSeenAt
            ))
        }
        return rows.sorted {
            $0.timestamp == $1.timestamp ? $0.label < $1.label : $0.timestamp > $1.timestamp
        }
    }

    /// Codex labels loopback sites "Local preview"; other links show host/path.
    static func websiteLabel(target: String) -> String {
        if let url = URL(string: target), BrowserScheme.isLoopback(url) { return "Local preview" }
        if !target.contains("://") {
            let name = URL(fileURLWithPath: target).lastPathComponent
            return name.isEmpty ? target : name
        }
        return SessionSource.urlLabel(target)
    }

    private static func loopbackMeta(_ url: URL) -> String? {
        guard let host = url.host else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    // MARK: Sources

    /// Codex order: user-provided files (most recently provided first) →
    /// links (most recently opened first) → tools (most recently called
    /// first) → the single web-search row.
    static func sources(state: SessionState) -> [SourceRow] {
        let provided = state.sources
            .filter {
                $0.kind == .file || $0.kind == .image
                    || $0.kind == .application || $0.kind == .simulator
            }
            .sorted {
                if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
                if $0.firstSeenAt != $1.firstSeenAt { return $0.firstSeenAt > $1.firstSeenAt }
                return $0.label < $1.label
            }
        let links = state.sources
            .filter { $0.kind == .url }
            .sorted { $0.lastSeenAt == $1.lastSeenAt ? $0.label < $1.label : $0.lastSeenAt > $1.lastSeenAt }
        let tools = state.sources
            .filter { $0.kind == .tool }
            .sorted { $0.lastSeenAt == $1.lastSeenAt ? $0.label < $1.label : $0.lastSeenAt > $1.lastSeenAt }
        let web = state.sources.filter { $0.kind == .webSearch }.prefix(1)
        return (provided + links + tools + Array(web)).map { source in
            SourceRow(source: source, meta: sourceMeta(source), detailLines: detailLines(for: source))
        }
    }

    static func sourceMeta(_ source: SessionSource) -> String? {
        switch source.kind {
        case .file, .image, .application, .simulator: source.target
        case .url: source.target
        case .tool: "MCP server"
        case .webSearch: nil
        }
    }

    static func detailLines(for source: SessionSource) -> [String] {
        switch source.kind {
        case .file, .image, .application, .simulator:
            if source.target == nil { return ["Attached to the conversation"] }
            let lines = source.activities.map { activity -> String in
                switch activity {
                case .provided: "Provided in the conversation"
                case .read: "Read during the chat"
                case .created: "Created during the chat"
                case .updated: "Updated during the chat"
                }
            }
            return lines.isEmpty ? ["Provided in the conversation"] : lines
        case .url:
            return [source.count == 1 ? "Opened once" : "Opened \(source.count) times"]
        case .webSearch:
            return [source.count == 1 ? "Searched once" : "Searched \(source.count) times"]
        case .tool:
            return [source.count == 1 ? "\(source.label) once" : "\(source.label) \(source.count) times"]
        }
    }

    // MARK: Background processes

    static func backgroundProcesses(_ services: [BackgroundServiceRecord]) -> [BackgroundServiceRecord] {
        services.filter(\.running)
    }

    static func processLabel(_ service: BackgroundServiceRecord) -> String {
        service.command.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? service.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Background terminal"
    }

    // MARK: Subagents

    static func subagentStatus(_ rawState: String) -> SubagentStatus? {
        switch rawState.lowercased() {
        case "queued", "dispatching", "waiting_permission", "waiting_computer",
             "waiting_dispatch_approval", "paused":
            .waiting
        case "running", "reviewing":
            .working
        case "completed", "solo-swarm-completed", "solo-swarm-empty", "stopped":
            .done
        case "failed", "interrupted", "cancelled", "canceled":
            .failed
        default:
            nil
        }
    }

    /// Live agent activities describe the current session's subagents while a
    /// team runs; once they are gone, the session's team runs stand in. Plain
    /// and non-delegating solo turns are excluded — every chat turn is a run,
    /// and eligibility (`isSoloSwarm`) alone is not delegation.
    static func subagents(
        activities: [AgentActivity],
        runs: [OrchestrationRun],
        sessionID: String
    ) -> [SubagentRow] {
        let live = activities.compactMap { activity -> SubagentRow? in
            let name = activity.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let status = subagentStatus(activity.state.rawValue) else { return nil }
            return SubagentRow(id: activity.id, name: name, status: status, runID: nil)
        }
        if !live.isEmpty { return live }
        guard !sessionID.isEmpty else { return [] }
        return runs
            .filter { $0.sessionID == sessionID && ($0.runKind == "team" || $0.didDelegateWorkers) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { run -> SubagentRow? in
                guard let status = subagentStatus(run.state) else { return nil }
                let name = run.teamName?.nilIfEmpty
                    ?? (run.isSoloSwarm ? "Solo" : run.request.nilIfEmpty)
                    ?? "Subagent"
                return SubagentRow(id: run.id, name: name, status: status, runID: run.id)
            }
    }

    /// Codex only auto-collapses once every agent is done; a failure stays
    /// in view.
    static func autoCollapsesSubagents(_ rows: [SubagentRow]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { $0.status == .done }
    }
}
