import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Session-overview telemetry: task-conversation updates, identity and
/// plan sync, tool-activity and file-effect recording, the run
/// file-capture window, and turn completion of the overview.
extension AppModel {
    func updateTaskConversation(
        state: TeamRunState,
        event: [String: Any],
        taskID: String? = nil
    ) {
        guard !currentSessionID.isEmpty else { return }
        let previous = taskConversationStates[currentSessionID]
        let updated = TaskConversationState(
            sessionID: currentSessionID,
            taskID: taskID ?? activeTaskRecord?.id ?? previous?.taskID,
            teamID: (event["team_id"] as? String) ?? previous?.teamID,
            workerID: (event["worker_id"] as? String) ?? activeWorkerID ?? previous?.workerID,
            runID: (event["run_id"] as? String) ?? orchestrationRunID ?? previous?.runID,
            state: state,
            updatedAt: Date()
        )
        if previous?.taskID == updated.taskID,
           previous?.teamID == updated.teamID,
           previous?.workerID == updated.workerID,
           previous?.runID == updated.runID,
           previous?.state == updated.state
        {
            return
        }
        taskConversationStates[currentSessionID] = updated
        if let runID = updated.runID {
            lifecycleJournal?.record(sessionID: currentSessionID, runID: runID, state: state)
        }
    }

    static var sessionTimestamp: Int {  // internal(for: AppModel+UITestFixtures)
        Int(Date().timeIntervalSince1970 * 1_000)
    }

    var sessionOverviewWorkspace: SessionWorkspaceIdentity {  // internal(for: AppModel+UITestFixtures)
        let path = workspacePath
        let git: SessionWorkspaceIdentity.Git? = gitWorkspace.isGitRepository
            ? SessionWorkspaceIdentity.Git(
                branch: gitWorkspace.gitBranch?.nilIfEmpty ?? "detached",
                dirty: gitWorkspace.gitChanges.count,
                ahead: gitWorkspace.gitAhead > 0 ? gitWorkspace.gitAhead : nil,
                behind: gitWorkspace.gitBehind > 0 ? gitWorkspace.gitBehind : nil
            )
            : nil
        return SessionWorkspaceIdentity(
            name: URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty ?? path,
            path: path,
            git: git
        )
    }

    private func sessionOverviewModel(for info: SessionInfo) -> SessionModelIdentity {
        let published = activeAccount?.kind.publishedContextWindow(for: info.model)
            ?? SessionModelMetadata.lookup(info.model)?.contextWindow
        return SessionModelIdentity(
            provider: activeAccount?.kind.rawValue ?? info.provider ?? "local",
            id: info.model,
            // A live provider value is authoritative. The metadata map is only
            // the fallback that prevents known models from reading "unknown".
            contextWindow: info.contextLimit > 0 ? info.contextLimit : published
        )
    }

    func activateSessionOverview(_ info: SessionInfo, reset: Bool = false) {
        let model = sessionOverviewModel(for: info)
        let initial = SessionState.empty(
            workspacePath: info.workspaceRoot ?? info.cwd,
            modelID: info.model,
            provider: model.provider
        )
        var seeded = initial
        seeded.workspace = sessionOverviewWorkspace
        seeded.model = model
        seeded.resources.messages = info.messages
        if reset {
            sessionOverview.reset(sessionID: info.sessionID, initial: seeded)
            sessionOverview.emit(
                .status(status: .idle, reason: nil, at: Self.sessionTimestamp),
                sessionID: info.sessionID
            )
        } else {
            sessionOverview.activate(sessionID: info.sessionID, initial: seeded)
        }
        sessionOverview.synchronize(
            workspace: sessionOverviewWorkspace,
            model: model,
            messages: info.messages,
            sessionID: info.sessionID
        )
        let cost = SessionModelMetadata.lookup(info.model)?.estimatedCost(
            promptTokens: info.promptTokens,
            completionTokens: info.completionTokens
        )
        sessionOverview.emit(
            .tokens(
                used: info.approxTokens,
                window: model.contextWindow,
                costUsd: cost,
                at: Self.sessionTimestamp
            ),
            sessionID: info.sessionID
        )
        synchronizeSessionPlan(todos)
    }

    func synchronizeSessionIdentity() {
        guard !sessionOverview.activeSessionID.isEmpty else { return }
        let model = sessionInfo.map(sessionOverviewModel(for:))
        sessionOverview.synchronize(workspace: sessionOverviewWorkspace, model: model)
    }

    func synchronizeSessionPlan(_ source: [TodoItem]) {
        guard !sessionOverview.activeSessionID.isEmpty else { return }
        let now = Self.sessionTimestamp
        let desired = source.enumerated().map { index, todo in
            let state: SessionPlanStep.State = switch todo.status {
            case .pending: .pending
            case .inProgress: .running
            case .completed: .done
            }
            return SessionPlanStep(
                id: "\(index)-\(todo.content)",
                label: todo.content,
                state: state,
                startedAt: nil,
                endedAt: nil
            )
        }
        let current = sessionOverview.state.plan
        if current.map(\.id) != desired.map(\.id) {
            let pending = desired.map {
                SessionPlanStep(
                    id: $0.id,
                    label: $0.label,
                    state: .pending,
                    startedAt: nil,
                    endedAt: nil
                )
            }
            sessionOverview.emit(.planCreated(steps: pending, at: now))
        }
        for step in desired where sessionOverview.state.plan.first(where: { $0.id == step.id })?.state != step.state {
            sessionOverview.emit(.stepState(stepID: step.id, state: step.state, at: now))
        }
    }

    func recordSessionToolActivity(_ event: [String: Any]) {
        guard !sessionOverview.activeSessionID.isEmpty else { return }
        let toolID = event["id"] as? String
        let payload = toolID.flatMap { id in
            blocks.reversed().compactMap(\.tool).first(where: { $0.toolID == id })
        }
        let tool = (event["tool"] as? String ?? payload?.tool ?? "").lowercased()
        let summary = event["summary"] as? String ?? payload?.summary ?? ""
        let detail = event["detail"] as? String ?? payload?.detail ?? ""
        let result = event["result"] as? String ?? payload?.result ?? ""
        let now = Self.sessionTimestamp
        let succeeded = (event["ok"] as? Bool) == true && (event["denied"] as? Bool) != true
        switch SessionSourceClassifier.classify(tool: tool) {
        case .webFetch:
            let raw = detail.nilIfEmpty
                ?? (summary.hasPrefix("fetch ") ? String(summary.dropFirst("fetch ".count)) : summary)
            guard succeeded, let url = Self.recordableWebURL(raw) else { return }
            recordURLSource(url, at: now)
            return
        case .browserNavigate:
            // "browser back" and friends carry an empty detail, and about:blank
            // is a reset, not a source — nothing to record for either.
            guard succeeded, let url = Self.recordableWebURL(detail) else { return }
            if BrowserScheme.isLoopback(url) {
                emitWebsiteOutput(url)
            } else {
                recordURLSource(url, at: now)
            }
            return
        case .backgroundService:
            // Only a start is this session's output. A status listing echoes
            // every managed server in the backend (other chats' and exited
            // ones, tails included), and a stop produces nothing.
            if succeeded, result.hasPrefix("Started "),
               let url = SessionSourceClassifier.loopbackURL(in: result) {
                emitWebsiteOutput(url)
            }
            return
        case .mcp(let server, let toolName):
            guard succeeded else { return }
            if SessionSourceClassifier.isWebSearchTool(toolName) {
                sessionOverview.emit(.sourceUsed(kind: .webSearch, label: "Web search", target: nil, at: now))
            }
            sessionOverview.emit(.sourceUsed(kind: .tool, label: server, target: nil, at: now))
            return
        case .other:
            break
        }
        if tool == "update_plan" {
            // Codex-native runs report plan changes as a tool call. The plan
            // itself arrives through `todo_update`, so resync from it rather
            // than letting the path heuristics read step text as file activity.
            synchronizeSessionPlan(todos)
            return
        }
        // The agent states what it touched, so prefer that over reading prose.
        // Deliberately before the shell branch and without returning: a shell
        // call is still a command worth recording, it just never carries
        // effects of its own.
        let recordedEffects = recordSessionFileEffects(event, at: now)
        if tool.contains("command") || tool.contains("shell") || tool.contains("terminal")
            || tool == "bash" || tool == "exec" {
            let command = summary.nilIfEmpty ?? detail.nilIfEmpty ?? tool
            sessionOverview.emit(.command(
                cmd: command,
                exitCode: (event["ok"] as? Bool) == true ? 0 : 1,
                at: now
            ))
            return
        }
        guard !recordedEffects else { return }
        guard let path = sessionActivityPath(in: [summary, detail, result]) else { return }
        if tool.contains("read") || tool.contains("view") {
            sessionOverview.emit(.fileRead(path: path, at: now))
        } else if tool.contains("create") || tool.contains("write") {
            sessionOverview.emit(.fileCreate(path: path, at: now))
        } else if tool.contains("edit") || tool.contains("patch") {
            sessionOverview.emit(.fileEdit(path: path, added: 0, removed: 0, at: now))
        }
    }

    /// Records the file changes a tool reported. Returns whether it said
    /// anything, so the prose fallback only runs for an agent too old to send
    /// `file_effects`.
    @discardableResult
    private func recordSessionFileEffects(_ event: [String: Any], at now: Int) -> Bool {
        guard let effects = event["file_effects"] as? [[String: Any]], !effects.isEmpty else {
            return false
        }
        var recorded = false
        for effect in effects {
            guard let raw = effect["path"] as? String,
                  let path = sessionRelativePath(raw)
            else { continue }
            switch effect["effect"] as? String {
            case "create":
                sessionOverview.emit(.fileCreate(path: path, at: now))
            case "edit":
                sessionOverview.emit(.fileEdit(path: path, added: 0, removed: 0, at: now))
            case "delete":
                // Nothing to open, and the Outputs list is about what exists.
                continue
            default:
                continue
            }
            recorded = true
        }
        return recorded
    }

    /// An http(s) URL with a real host — the only kind worth listing as a
    /// link source or website output.
    static func recordableWebURL(_ raw: String) -> URL? {
        guard let url = BrowserScheme.normalize(raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Resolves a path the way session events store them: workspace-relative
    /// normally, absolute when a tool named a file outside the workspace.
    func sessionFileURL(_ path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: workspacePath).appending(path: path)
    }

    /// The one spelling of a file that session events are keyed by.
    ///
    /// Three feeds report the same file three ways — git gives repository-root
    /// relative, a tool gives whatever the model wrote, the workspace watcher
    /// gives an absolute path — so without a single normalizer one produced PDF
    /// becomes two or three Outputs rows. Returns nil for anything outside the
    /// workspace, which is also what keeps a symlink from smuggling one in.
    func sessionRelativePath(_ raw: String, relativeTo base: String? = nil) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        if trimmed.hasPrefix("/") || base == nil {
            candidate = trimmed
        } else {
            candidate = URL(fileURLWithPath: base!, isDirectory: true)
                .appending(path: trimmed)
                .path(percentEncoded: false)
        }
        guard let url = MarkdownLinkPolicy.containedWorkspaceFileURL(
            candidate,
            workspacePath: workspacePath
        ) else { return nil }
        // Containment resolves symlinks, so the relative path has to be taken
        // against an equally resolved root. Otherwise a workspace reached
        // through one — /tmp, which is /private/tmp — leaves every path
        // absolute, and the three feeds stop agreeing on how to spell a file.
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
        return WorkspaceIndex.relativePath(url, root: root).nilIfEmpty
    }

    /// The start of a request, for everything the Overview scopes to one:
    /// which file activity is attributed to this run, and where its activity
    /// list begins. Both send paths — a new message and a retry — come
    /// through here.
    func beginSessionFileCapture() {
        synchronizeSessionIdentity()
        sessionOverview.emit(.requestStarted(at: Self.sessionTimestamp))
        fileCaptureSessionID = sessionOverview.activeSessionID
        fileCaptureStartedAt = Self.sessionTimestamp
        fileCaptureUntil = .max
        sessionOutputWatchTeardown?.cancel()
        sessionOutputWatchTeardown = nil
        guard persistenceEnabled else { return }
        let started = Date()
        let root = workspacePath
        sessionOutputWatcher.start(path: root, since: started) { [weak self] changes in
            Task { @MainActor [weak self] in
                self?.recordWatchedFileChanges(changes, watchedRoot: root)
            }
        }
    }

    /// Closes it with a grace period rather than instantly: the watcher batches
    /// on a 0.35s latency and a git refresh is a round trip, so the events that
    /// describe a run's own output arrive slightly after it ends.
    private func endSessionFileCapture() {
        guard fileCaptureUntil == .max else { return }
        fileCaptureUntil = Self.sessionTimestamp + 4_000
        sessionOutputWatchTeardown?.cancel()
        sessionOutputWatchTeardown = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.sessionOutputWatcher.stop()
        }
    }

    /// Files the workspace watcher saw during a run. The watcher is
    /// path-accurate but has no idea which chat asked for the work, so
    /// attribution is decided here.
    private func recordWatchedFileChanges(
        _ changes: [SessionOutputWatcher.Change],
        watchedRoot: String
    ) {
        guard watchedRoot == workspacePath,
              let sessionID = sessionFileCaptureTarget
        else { return }
        let now = Self.sessionTimestamp
        for change in changes {
            guard let path = sessionRelativePath(change.path) else { continue }
            switch change.effect {
            case .created:
                sessionOverview.emit(.fileCreate(path: path, at: now), sessionID: sessionID)
            case .edited:
                sessionOverview.emit(
                    .fileEdit(path: path, added: 0, removed: 0, at: now),
                    sessionID: sessionID
                )
            }
        }
    }

    /// Whether a file event now belongs to a run, and which session owns it.
    var sessionFileCaptureTarget: String? {  // internal(for: AppModel extension files)
        guard !fileCaptureSessionID.isEmpty,
              Self.sessionTimestamp <= fileCaptureUntil
        else { return nil }
        return fileCaptureSessionID
    }

    private func recordURLSource(_ url: URL, at timestamp: Int) {
        let target = url.absoluteString
        sessionOverview.emit(.sourceUsed(
            kind: .url,
            label: SessionSource.urlLabel(target),
            target: target,
            at: timestamp
        ))
    }

    /// Records a dev-server URL as a website output exactly once per session;
    /// refreshes and repeated navigations must not duplicate it.
    func emitWebsiteOutput(_ url: URL, sessionID: String? = nil) {
        let id = sessionID ?? sessionOverview.activeSessionID
        let target = SessionOutput.normalize(url.absoluteString)
        guard !id.isEmpty, !target.isEmpty,
              sessionOverview.states[id]?.outputs.contains(where: { $0.target == target }) != true
        else { return }
        sessionOverview.emit(.websiteOutput(url: target, at: Self.sessionTimestamp), sessionID: id)
    }

    /// What a send hands the agent as user-provided material: the attachments
    /// dispatched with the message plus the context pack — the latter only
    /// when the mode actually forwards it (see `decoratedPrompt`).
    static func providedSourceItems(
        attachments: [ChatAttachment],
        contextFiles: [ContextFile],
        mode: WorkMode,
        liveApplication: ApplicationTarget? = nil,
        simulator: SimulatorTarget? = nil
    ) -> [SessionProvidedItem] {
        var items: [SessionProvidedItem] = []
        var seen: Set<String> = []
        for attachment in attachments {
            let onDisk = attachment.overrideName == nil
            let path = onDisk ? attachment.url.path(percentEncoded: false) : nil
            let kind: SessionSource.Kind = switch attachment.kind {
            case .text: .file
            case .image: .image
            case .applicationSnapshot: .application
            }
            let key = SessionSource.key(kind: kind, label: attachment.name, target: path)
            guard seen.insert(key).inserted else { continue }
            items.append(SessionProvidedItem(name: attachment.name, path: path, kind: kind))
        }
        if mode != .ask {
            for file in contextFiles where file.isIncluded && file.isAvailable {
                let path = file.displayPath
                let key = SessionSource.key(kind: .file, label: file.name, target: path)
                guard seen.insert(key).inserted else { continue }
                items.append(SessionProvidedItem(name: file.name, path: path, kind: .file))
            }
        }
        if let liveApplication, mode != .ask {
            let label = "\(liveApplication.name) — \(liveApplication.windowTitle.nilIfEmpty ?? "Selected window")"
            let target = "\(liveApplication.bundleIdentifier) · PID \(liveApplication.processIdentifier)"
            let key = SessionSource.key(kind: .application, label: label, target: target)
            if seen.insert(key).inserted {
                items.append(SessionProvidedItem(name: label, path: target, kind: .application))
            }
        }
        if let simulator, mode != .ask {
            let label = simulator.device.name
            let target = "\(simulator.device.runtime) · \(simulator.udid)"
            let key = SessionSource.key(kind: .simulator, label: label, target: target)
            if seen.insert(key).inserted {
                items.append(SessionProvidedItem(name: label, path: target, kind: .simulator))
            }
        }
        return items
    }

    static func attachmentIDsToClear(
        _ dispatched: [ChatAttachment],
        deliverySucceeded: Bool
    ) -> Set<UUID> {
        Set(dispatched.compactMap { attachment in
            attachment.kind != .applicationSnapshot || deliverySucceeded
                ? attachment.id : nil
        })
    }

    private func sessionActivityPath(in values: [String]) -> String? {
        let root = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        for value in values where !value.isEmpty {
            if let indexed = workspaceFiles.files
                .map({ WorkspaceIndex.relativePath($0, root: workspacePath) })
                .filter({ value.contains($0) })
                .max(by: { $0.count < $1.count }) {
                return indexed
            }
            for raw in value.split(whereSeparator: { $0.isWhitespace }) {
                let token = String(raw).trimmingCharacters(
                    in: CharacterSet(charactersIn: "`'\"(),:[]{}")
                )
                if token.hasPrefix(root) { return String(token.dropFirst(root.count)) }
                guard !token.contains("://"), !token.hasPrefix("-"),
                      let ext = URL(fileURLWithPath: token).pathExtension.nilIfEmpty
                else { continue }
                if token.contains("/") { return token }
                // A bare `report.pdf` at the workspace root has no directory
                // component to recognise it by, so require that it be a
                // deliverable that actually exists. Existence is what stops a
                // merely-mentioned filename becoming a phantom Outputs row.
                guard ContextFileTypes.deliverableExtensions.contains(ext.lowercased()),
                      let relative = sessionRelativePath(token),
                      FileManager.default.fileExists(atPath: sessionFileURL(relative).path)
                else { continue }
                return relative
            }
        }
        return nil
    }

    func finishSessionOverview(reason: String, durationMilliseconds: Int?) {
        let now = Self.sessionTimestamp
        synchronizeSessionPlan(todos)
        let state = sessionOverview.state
        let failedReason = state.statusReason
        let outcome: SessionRunSummary.Outcome = reason == "complete"
            ? (state.plan.allSatisfy { $0.state == .done } ? .completed : .partial)
            : .failed
        let assistantText = blocks.last(where: { $0.kind == .assistant })?.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = String((assistantText?.nilIfEmpty
            ?? (outcome == .completed ? "The requested work completed." : "The run stopped before every step completed."))
            .prefix(180))
        let run = SessionRunSummary(
            completedSteps: state.plan.filter { $0.state == .done }.count,
            totalSteps: state.plan.count,
            durationMs: durationMilliseconds
                ?? turnStartedAt.map { max(Int(Date().timeIntervalSince($0) * 1_000), 0) }
                ?? 0,
            endedAt: now,
            summary: summary,
            outcome: outcome
        )
        // Recommendations are derived locally from the complete state snapshot
        // so their ranking stays current as git, tests, plans, or runtime state
        // changes. Keep the legacy payload slot nil for wire/persistence
        // compatibility rather than storing a second stale source of truth.
        sessionOverview.emit(.runFinished(summary: run, suggestions: nil, at: now))
        endSessionFileCapture()
        if outcome == .failed {
            sessionOverview.emit(.status(
                status: .error,
                reason: failedReason ?? "The run stopped with \(reason.replacingOccurrences(of: "_", with: " ")).",
                at: now
            ))
        }
    }
}
