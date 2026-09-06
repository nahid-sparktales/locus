import AppKit
import CoreGraphics
import CoreText
import Foundation

extension AppModel {
    func configureOnboarding(defaults: UserDefaults?, existingInstallation: Bool) {
        onboarding.configure(
            defaults: defaults,
            isExistingInstallation: existingInstallation,
            autoPresent: persistenceEnabled && !isUITesting,
            readiness: { [weak self] in
                guard let self else { return .unknown }
                let detail = agentRuntimePhase.message ?? modelRuntimePhase.message
                    ?? (activeAccount == nil ? "Local Ollama is connected." : "Your selected account is connected.")
                return OnboardingReadiness(
                    agentReady: isAgentOnline, modelReady: isModelOnline,
                    modelName: selectedModel, detail: detail
                )
            },
            refresh: { [weak self] in
                guard let self else { return }
                if !isAgentOnline { await bootstrap() }
                if activeAccount == nil { await ensureLocalOllama(at: ollamaHost) }
                await providerAccountsModel.refreshLocalModels()
                _ = await applyProvider(verify: true, announce: false)
            },
            start: { [weak self] point, workspace in
                guard let self else { throw CocoaError(.userCancelled) }
                return try await startOnboardingTask(point, workspace: workspace)
            },
            observe: { [weak self] run in
                guard let self else { return .failed("Locus closed before this task could be checked.") }
                return await observeOnboardingTask(run)
            }
        )
    }

    func chooseOnboardingWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose your first workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard workspaceAccess.rememberAndActivate(url) else {
            onboarding.reportError("Locus could not retain access to that folder.")
            return
        }
        onboarding.selectWorkspace(url.resolvingSymlinksInPath().path, sample: false)
    }

    func chooseOnboardingSample() {
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(AppEdition.current.displayName)/Quickstart", isDirectory: true)
            let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try OnboardingSamples.create(at: root, startingPoint: onboarding.progress.startingPoint)
            guard workspaceAccess.rememberAndActivate(root) else {
                throw CocoaError(.fileReadNoPermission)
            }
            onboarding.selectWorkspace(root.path, sample: true)
        } catch {
            onboarding.reportError("Could not prepare the sample: \(error.localizedDescription)")
        }
    }

    private func startOnboardingTask(_ point: OnboardingStartingPoint, workspace: String) async throws -> OnboardingRun {
        guard !isBusy, !hasPendingPermission, !pendingSessionReset else {
            throw onboardingError("Finish the current task before starting the example.")
        }
        guard isAgentOnline, isModelOnline else {
            throw onboardingError("Connect a ready model before starting.")
        }
        guard workspaceAccess.activateStored(path: workspace) else {
            throw onboardingError("Choose this workspace again to restore access.")
        }
        if WorkspaceAccess.isSandboxed, backendProcess.isRunning {
            // A running child cannot inherit a folder grant obtained later.
            // Restart the coordinator after activating the chosen workspace.
            backend.disconnect()
            await backendProcess.stopAndWait()
            await bootstrap()
            guard isAgentOnline else { throw onboardingError("Reconnect the local agent, then retry this task.") }
        }
        let previousSession = currentSessionID
        startNewChat(in: workspace, environment: .local)
        let deadline = Date().addingTimeInterval(30)
        while currentSessionID == previousSession || pendingSessionReset {
            guard Date() < deadline else { throw onboardingError("The new chat did not become ready. Try again.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard SessionSummary.canonicalWorkspacePath(workspacePath) == SessionSummary.canonicalWorkspacePath(workspace) else {
            throw onboardingError("The workspace changed before the example could start.")
        }
        selectedMode = .work
        if point == .documents {
            let _: JSONValue = try await backend.post(
                "/api/knowledge/settings",
                body: ["workspace": workspace, "documents_enabled": true, "enabled": true], as: JSONValue.self
            )
            let _: JSONValue = try await backend.post(
                "/api/knowledge/reindex", body: ["workspace": workspace], as: JSONValue.self
            )
        }
        let taskDescription = point == .documents
            ? "Search the workspace document knowledge and read relevant local documents. Write a concise, useful summary with clickable citations to the source pages, paragraphs, or cells. If indexing is still in progress, check its progress before citing documents."
            : "Read the repository and identify its purpose, structure, setup instructions, and a few useful next steps. Write a concise guide with links to the files that support your findings. Do not change source code or install dependencies."
        let prompt = """
        \(taskDescription)
        Save the finished document as \(point.outputPath) in this workspace. This is a guided first task: keep the result short, explain any missing information honestly, and include a link to the saved file in your final answer.
        """
        let start = Date()
        let startingCompletionTokens = sessionInfo?.completionTokens
        let previousRequest = sessionOverview.state.requestStartedAt
        let starterSessionID = currentSessionID
        let previousBlockIDs = Set(blocks.map(\.id))
        send(prompt, preservingDraftOnFailure: false, includeAttachments: false, consumeMatchingDraft: false, allowLocalCommands: false)
        let routingDeadline = Date().addingTimeInterval(60)
        while sessionOverview.states[starterSessionID]?.requestStartedAt == previousRequest, isBusy {
            guard Date() < routingDeadline else { throw onboardingError("Choosing a model took too long. Open the chat to check the task.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard currentSessionID == starterSessionID else { throw onboardingError("The selected chat changed before the example started.") }
        guard isBusy || sessionOverview.state.requestStartedAt.map({ $0 >= Int(start.timeIntervalSince1970 * 1_000) - 1_000 }) == true else {
            throw onboardingError("The example could not start. Check the model connection and try again.")
        }
        guard let runID = blocks.first(where: { $0.kind == .user && !previousBlockIDs.contains($0.id) })?.runID,
              !runID.isEmpty else {
            throw onboardingError("The example’s task could not be identified. Open its chat before retrying.")
        }
        return OnboardingRun(
            sessionID: currentSessionID, workspace: workspace, outputPath: point.outputPath,
            startedAt: start, requestStartedAt: sessionOverview.state.requestStartedAt ?? Self.sessionTimestamp,
            startingCompletionTokens: startingCompletionTokens, runID: runID
        )
    }

    func observeOnboardingTask(_ run: OnboardingRun) async -> OnboardingRunObservation {
        if let runID = run.runID, !runID.isEmpty {
            do {
                let segment = runID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? runID
                let receipt = try await backend.get(
                    "/api/runs/\(segment)", timeout: 3, as: OnboardingRunReceipt.self
                )
                var savedOutput = false
                if receipt.state == "completed" {
                    savedOutput = await outputsLibrary.hasSavedVersion(
                        workspace: run.workspace, relativePath: run.outputPath,
                        sessionID: run.sessionID, since: run.startedAt, runID: runID
                    )
                }
                return receipt.observation(for: run, savedOutput: savedOutput)
            } catch {
                // The run is reserved in the visible user block before its
                // queue request reaches the agent. A brief 404 is expected;
                // connection failures must remain resumable across restart.
                if (error as NSError).code == 404, Date().timeIntervalSince(run.startedAt) > 30 {
                    return .failed("The example’s saved task is no longer available. Open its chat or retry the example.")
                }
                return .running
            }
        }
        // Progress written by older builds lacks the durable ID. Keep its
        // conservative receipt check without assigning a later chat's run.
        guard let state = sessionOverview.states[run.sessionID] else {
            return .failed("The example’s chat is no longer available. You can start a new example.")
        }
        if let finished = state.lastRun, finished.endedAt >= run.requestStartedAt {
            guard state.requestStartedAt == run.requestStartedAt else {
                return .failed("Another task replaced the example’s progress. Its saved result is still available in Outputs.")
            }
            guard finished.outcome == .completed else {
                return .failed(state.statusReason ?? "The task stopped before finishing. Open its chat or retry the example.")
            }
            if await outputsLibrary.hasSavedVersion(
                workspace: run.workspace, relativePath: run.outputPath,
                sessionID: run.sessionID, since: run.startedAt
            ) {
                let hasStart = state.events.contains { event in
                    if case .requestStarted(let at) = event { return at == run.requestStartedAt }
                    return false
                }
                let firstResponse = hasStart ? state.events.compactMap { event -> Int? in
                    if case .message(.assistant, let at) = event, at >= run.requestStartedAt {
                        return at - run.requestStartedAt
                    }
                    return nil
                }.min() : nil
                let info = taskWorkers[run.sessionID]?.sessionInfo
                    ?? (sessionInfo?.sessionID == run.sessionID ? sessionInfo : nil)
                var throughput: Double?
                if let baseline = run.startingCompletionTokens, let tokens = info?.completionTokens,
                   tokens > baseline, finished.durationMs > 0 {
                    throughput = Double(tokens - baseline) / (Double(finished.durationMs) / 1_000)
                }
                return .completed(durationMilliseconds: finished.durationMs,
                                  firstResponseMilliseconds: firstResponse, outputTokensPerSecond: throughput)
            }
            if Date().timeIntervalSince1970 * 1_000 - Double(finished.endedAt) > 30_000 {
                return .failed("The reply finished, but its output was not saved. Check the chat and Library storage, then retry.")
            }
            return .awaitingOutput(durationMilliseconds: finished.durationMs)
        }
        if state.status == .error { return .failed(state.statusReason ?? "The example could not finish.") }
        if !runningChatSessionIDs.contains(run.sessionID),
           Date().timeIntervalSince(run.startedAt) > 30, !pendingSessionReset {
            return .failed("The example was interrupted. Open its chat or retry to finish setup.")
        }
        return .running
    }

    private func onboardingError(_ text: String) -> NSError {
        NSError(domain: "Locus.Onboarding", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

enum OnboardingSamples {
    static func create(at root: URL, startingPoint: OnboardingStartingPoint) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if startingPoint == .documents {
            let documents = root.appendingPathComponent("Locus Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try """
            # Harbor project — sample documents

            These fictional documents are here to help you try Locus.
            Read Project Brief.pdf and Costs.csv, then make a short summary of the goal, budget, and open question.
            """.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try "Item,Estimated cost,Currency\nResearch,1200,CAD\nDesign,1800,CAD\nPrototype,2400,CAD\n".write(
                to: documents.appendingPathComponent("Costs.csv"), atomically: true, encoding: .utf8
            )
            try createPDF(at: documents.appendingPathComponent("Project Brief.pdf"))
        } else {
            try """
            # Pocket Checklist

            A small Swift sample for understanding a repository with Locus.
            `Checklist.swift` models a list and computes its completion count.
            There are no dependencies or build steps for this reading exercise.
            Next steps: add persistence and a simple interface.
            """.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try """
            struct ChecklistItem {
                var title: String
                var isComplete = false
            }

            struct Checklist {
                var items: [ChecklistItem] = []
                var completedCount: Int { items.filter(\\.isComplete).count }
            }
            """.write(to: root.appendingPathComponent("Checklist.swift"), atomically: true, encoding: .utf8)
        }
    }

    private static func createPDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        let lines = [
            "Harbor Project — Fictional Sample", "", "Goal", "Make a simple welcome experience for a community workshop.",
            "", "Timeline", "Research: one week. Design and prototype: two weeks.",
            "", "Budget", "The estimate is CAD 5,400. Costs.csv contains the breakdown.",
            "", "Open question", "Will visitors use the welcome experience on a phone or a shared screen?"
        ]
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: index == 0 ? 19 : 12), .foregroundColor: NSColor.black
            ])
            context.textPosition = CGPoint(x: 48, y: 735 - index * 28)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
    }
}
