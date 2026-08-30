import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Overview-tab actions: git-status capture into the session overview,
/// session quick actions, workspace artifact opening, recommendations,
/// and pinned-summary activation.
extension AppModel {
    // MARK: - Inspector

    /// Seven tab labels need almost the full inspector width; below this the
    /// icon-first strip keeps every target comfortably clickable.

    func handleGitStatusApplied(
        previous: [String: GitChange],
        current: [GitChange]
    ) {
        synchronizeSessionIdentity()
        guard let sessionID = sessionFileCaptureTarget else { return }
        let now = Self.sessionTimestamp
        // Porcelain paths are relative to the repository root, which is only
        // the workspace when the workspace is opened on the repo itself.
        let base = gitWorkspace.repositoryRoot ?? workspacePath
        for change in current {
            guard let path = sessionRelativePath(change.path, relativeTo: base) else { continue }
            let old = previous[change.path]
            let added = max((change.additions ?? 0) - (old?.additions ?? 0), 0)
            let removed = max((change.deletions ?? 0) - (old?.deletions ?? 0), 0)
            if old == nil, change.status == .added || change.status == .untracked {
                sessionOverview.emit(.fileCreate(path: path, at: now), sessionID: sessionID)
            }
            if added > 0 || removed > 0 || (old == nil && change.status != .untracked) {
                sessionOverview.emit(.fileEdit(
                    path: path,
                    added: added,
                    removed: removed,
                    at: now
                ), sessionID: sessionID)
            }
        }
    }

    /// Inserts an `@path` mention into the composer draft.
    func mentionFileInComposer(_ url: URL) {
        let relative = WorkspaceIndex.relativePath(url, root: workspacePath)
        let separator = draftText.isEmpty || draftText.hasSuffix(" ") ? "" : " "
        draftText += "\(separator)@\(relative) "
        showToast("Mentioned \(url.lastPathComponent)")
    }

    /// Reveals a workspace-relative path in Finder.
    func revealInFinder(_ relativePath: String) {
        NSWorkspace.shared.activateFileViewerSelecting([sessionFileURL(relativePath)])
    }

    func revealSessionWorkspace() {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: sessionOverview.state.workspace.path, isDirectory: true),
        ])
    }

    func revealSessionProxyConfig() {
        do {
            let resolution = try SessionQuickActionFiles.resolveProxyConfig(
                workspacePath: sessionOverview.state.workspace.path
            )
            NSWorkspace.shared.activateFileViewerSelecting([resolution.url])
            showToast(resolution.created ? "Created the proxy config template" : "Opened proxy config")
        } catch {
            showToast("Could not open proxy config: \(error.localizedDescription)")
        }
    }

    func revealSessionLogs() {
        let url = SessionQuickActionFiles.logURL(sessionID: currentSessionID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let output = [backendLogHint, backendProcess.recentOutput]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            let contents = output.isEmpty
                ? "No local agent log output has been captured for this session yet.\n"
                : output + "\n"
            try Data(contents.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showToast("Could not open session logs: \(error.localizedDescription)")
        }
    }

    func copySessionOverview() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionOverview.state.summaryMarkdown, forType: .string)
        showToast("Session summary copied")
    }

    func clearSessionOverviewContext() {
        contextFiles = contextFiles.map { file in
            var updated = file
            updated.isIncluded = false
            return updated
        }
        chatAttachments = []
        showToast("Attached context cleared")
    }

    func openSessionModelSettings() {
        settingsPage = .accounts
        settingsPresented = true
    }

    /// Opens a file the session touched, addressed by its workspace-relative
    /// path. Classifying it first is what lets an Outputs row for a PDF behave
    /// like the same file's link in the transcript; the peek can only render
    /// UTF-8 text, so handing it a binary used to print "not readable".
    func openSessionFile(_ relativePath: String) {
        let url = sessionFileURL(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("That file is no longer on disk")
            return
        }
        if let reference = WorkspaceArtifactReference.classify(
            relativePath,
            workspacePath: workspacePath
        ) {
            openWorkspaceArtifact(reference, at: url)
            return
        }
        selectInspectorTab(.files)
        workspaceFiles.preview(url)
    }

    func openWorkspaceReference(_ reference: WorkspaceArtifactReference) {
        // Re-checked rather than trusted: the reference was classified when the
        // message rendered, and this is the security boundary at activation.
        guard let contained = MarkdownLinkPolicy.containedWorkspaceFileURL(
            reference.relativePath,
            workspacePath: workspacePath
        ),
        contained == reference.url.standardizedFileURL.resolvingSymlinksInPath(),
        FileManager.default.fileExists(atPath: contained.path)
        else {
            showToast("That file is no longer available in this workspace")
            return
        }
        openWorkspaceArtifact(reference, at: contained)
    }

    /// The one place that decides what activating a produced file does.
    private func openWorkspaceArtifact(
        _ reference: WorkspaceArtifactReference,
        at url: URL
    ) {
        switch WorkspaceArtifactOpener.destination(for: reference) {
        case .filesTab(let line, let column):
            selectInspectorTab(.files)
            workspaceFiles.preview(url, line: line, column: column)
        case .defaultApp:
            guard WorkspaceArtifactOpener.openInDefaultApp(url) else {
                showToast("No app is set to open \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }
    }

    func prefillSessionSuggestion(_ suggestion: String) {
        prefillComposer(with: suggestion)
    }

    var locusRecommendations: [LocusRecommendation] {
        RecommendationEngine.recommendations(for: recommendationContext)
    }

    var recommendationContext: RecommendationContext {
        let state = sessionOverview.state
        return RecommendationContext(
            runtimeUnavailable: agentRuntimePhase.isUnavailable,
            modelUnavailable: modelRuntimePhase.isUnavailable,
            lastRunFailed: state.lastRun?.outcome == .failed,
            changedFileCount: gitWorkspace.changedFileCount,
            hasPendingPlanSteps: state.plan.contains { $0.state != .done },
            hasTestFiles: workspaceContainsTests,
            projectKind: workspaceProjectKind,
            memoryConflictCount: memoryCandidates.filter(\.hasConflicts).count,
            legacySuggestions: state.suggestions
        )
    }

    func activateRecommendation(_ recommendation: LocusRecommendation) {
        switch recommendation.intent {
        case .prefill(let prompt):
            prefillComposer(with: prompt)
        case .openInspector(let tab):
            selectInspectorTab(tab)
        case .openSettings(let page):
            settingsPage = page
            settingsPresented = true
        case .openModelLibrary:
            modelLibraryPresented = true
        }
    }

    /// AppKit may commit the TextEditor's pre-layout buffer while the
    /// inspector is collapsing. Re-applying after one main-actor turn makes
    /// the editable prefill deterministic without ever submitting it.
    private func prefillComposer(with prompt: String, collapsingInspector: Bool = true) {
        if collapsingInspector { inspectorCollapsed = true }
        draftText = prompt
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.draftText = prompt
            self.composerFocusToken = UUID()
        }
    }

    // MARK: - Pinned summary (Overview tab)

    /// Codex's Outputs "+" menu inserts a creation prompt and focuses the
    /// composer while the summary stays on screen.
    func insertCreationPrompt(_ kind: SummaryCreationKind) {
        prefillComposerFromSummary(kind.prompt)
    }

    func prefillComposerFromSummary(_ prompt: String) {
        prefillComposer(with: prompt, collapsingInspector: false)
    }

    /// Opens a URL in the in-app Browser tab, toasting when the preview
    /// refuses the scheme.
    func openURLInBrowserTab(_ url: URL) {
        selectInspectorTab(.preview)
        if !browser.userNavigate(url.absoluteString, sessionID: currentSessionID) {
            showToast("That address can't be opened in the browser tab")
        }
    }

    /// "Search in Google" on highlighted conversation text. A Locus Browser
    /// tab is not used when the user has turned browsing off, or in Ask mode
    /// where the inspector refuses to open one — the search still has to land
    /// somewhere, so it falls back to the default browser.
    func searchWebForSelection(_ selection: String) {
        guard let url = WebSearchQuery.url(for: selection) else { return }
        let wantsBrowserTab = settings.resolvedWebSearchDestination == .locusBrowser
        if wantsBrowserTab, settings.browserEnabled, !justChatEnabled {
            openURLInBrowserTab(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openSummaryOutput(_ row: PinnedSummary.OutputRow) {
        switch row.kind {
        case .file:
            openSessionFile(row.target)
        case .localSite:
            // The in-app browser only serves http(s); a local site renders in
            // the default browser, the way Codex previews a produced site.
            let url = sessionFileURL(row.target)
            guard FileManager.default.fileExists(atPath: url.path) else {
                showToast("That file is no longer on disk")
                return
            }
            NSWorkspace.shared.open(url)
        case .website:
            guard let url = BrowserScheme.normalize(row.target) else { return }
            openURLInBrowserTab(url)
        }
    }

    func openSummarySource(_ source: SessionSource) {
        switch source.kind {
        case .file, .image:
            guard let target = source.target else { return }
            let root = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
            if source.kind == .file, target.hasPrefix(root) {
                openSessionFile(String(target.dropFirst(root.count)))
            } else if FileManager.default.fileExists(atPath: target) {
                NSWorkspace.shared.open(URL(fileURLWithPath: target))
            } else {
                showToast("That file is no longer on disk")
            }
        case .url:
            guard let target = source.target, let url = BrowserScheme.normalize(target) else { return }
            openURLInBrowserTab(url)
        case .tool:
            settingsPage = .extensions
            settingsPresented = true
        case .application:
            showToast("Application snapshots are attached to the conversation")
        case .simulator:
            selectInspectorTab(.simulator)
        case .webSearch:
            break
        }
    }

    /// Opens a subagent row: live agents surface in the Runs tab of this
    /// session; a finished run selects itself there.
    func openSummarySubagent(_ row: PinnedSummary.SubagentRow) {
        selectInspectorTab(.runs, selecting: row.runID)
    }

    private var workspaceProjectKind: LocusProjectKind {
        let names = workspaceFiles.files.map { $0.lastPathComponent.lowercased() }
        let paths = workspaceFiles.files.map { $0.path.lowercased() }
        if names.contains("package.swift") || paths.contains(where: { $0.hasSuffix(".swift") }) {
            return .swift
        }
        if names.contains("package.json")
            || paths.contains(where: { $0.hasSuffix(".tsx") || $0.hasSuffix(".jsx") }) {
            return .web
        }
        if names.contains("pyproject.toml") || names.contains("requirements.txt")
            || paths.contains(where: { $0.hasSuffix(".py") }) {
            return .python
        }
        return .general
    }

    private var workspaceContainsTests: Bool {
        workspaceFiles.files.contains { url in
            let path = url.path.lowercased()
            let name = url.lastPathComponent.lowercased()
            return path.contains("/tests/")
                || path.contains("/uitests/")
                || name.hasPrefix("test_")
                || name.contains("tests.")
                || name.hasSuffix("test.swift")
                || name.hasSuffix("spec.ts")
                || name.hasSuffix("spec.tsx")
        }
    }

    func viewSessionTranscript() {
        let target = blocks.last(where: {
            $0.kind == .assistant || $0.kind == .error || $0.completion != nil
        })?.id
        requestTranscriptJump(target)
        inspectorCollapsed = true
    }

    func jumpToSessionEvent(_ event: SessionEvent) {
        let target: ChatBlock?
        switch event {
        case .fileEdit(let path, _, _, _), .fileRead(let path, _), .fileCreate(let path, _):
            target = blocks.reversed().first(where: {
                $0.tool.map { tool in
                    tool.summary.contains(path) || tool.detail.contains(path)
                        || (tool.result?.contains(path) == true)
                } == true
            })
        case .command(let command, _, _):
            target = blocks.reversed().first(where: {
                $0.tool.map { $0.summary.contains(command) || $0.detail.contains(command) } == true
            })
        case .message(let role, _):
            let kind: ChatBlock.Kind = role == .user ? .user : .assistant
            target = blocks.reversed().first(where: { $0.kind == kind })
        case .websiteOutput(let url, _):
            target = blocks.reversed().first(where: {
                $0.tool.map { $0.detail.contains(url) || ($0.result?.contains(url) == true) } == true
            })
        case .sourceUsed(_, let label, let urlTarget, _):
            let needle = urlTarget ?? label
            target = blocks.reversed().first(where: {
                $0.tool.map { $0.summary.contains(needle) || $0.detail.contains(needle) } == true
            })
        case .sourceProvided:
            target = blocks.reversed().first(where: { $0.kind == .user })
        case .runFinished, .status, .tokens, .planCreated, .stepState:
            target = blocks.reversed().first(where: {
                $0.kind == .assistant || $0.kind == .error || $0.completion != nil
            })
        }
        guard let target else { return }
        requestTranscriptJump(target.id)
        inspectorCollapsed = true
    }

    private func requestTranscriptJump(_ target: UUID?) {
        transcriptJumpTarget = nil
        DispatchQueue.main.async { [weak self] in self?.transcriptJumpTarget = target }
    }

    /// Adds a workspace-relative path to the context pack.
    func addWorkspaceFileToContext(_ relativePath: String) {
        let url = sessionFileURL(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("That file is no longer on disk")
            return
        }
        loadContext(from: [url])
    }
}
