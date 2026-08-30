import XCTest
@testable import Locus

private final class OrchestrationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedURLs: [URL] = []
    static var responseDelay: (URL) -> TimeInterval = { _ in 0 }

    static func reset() {
        lock.lock()
        recordedURLs = []
        responseDelay = { _ in 0 }
        lock.unlock()
    }

    static var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recordedURLs.append(url)
        let delay = Self.responseDelay(url)
        Self.lock.unlock()

        let complete = { [weak self] in
            guard let self else { return }
            let data = Self.responseData(for: url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: complete)
        } else {
            complete()
        }
    }

    override func stopLoading() {}

    private static func responseData(for url: URL) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? url.path
        let parts = path.split(separator: "/")
        let runID = parts.count >= 3 ? String(parts[2]) : "run-1"
        let run = runJSON(id: runID)
        if path == "/api/orchestrations" {
            let sessionID = components?.queryItems?
                .first(where: { $0.name == "session_id" })?.value
            let runs = sessionID == "session-empty" ? [] : [runJSON(id: "run-1")]
            return try! JSONSerialization.data(withJSONObject: [
                "runs": runs,
                "read_only": false,
            ])
        }
        if path.hasSuffix("/events") {
            let after = Int(components?.queryItems?.first(where: { $0.name == "after_seq" })?.value ?? "0") ?? 0
            let events: [[String: Any]] = after < 65 ? [
                ["event_id": "event-65", "run_id": runID, "seq": 65, "type": "agent_job_completed", "state": "completed"],
            ] : []
            return try! JSONSerialization.data(withJSONObject: [
                "run_id": runID,
                "events": events,
                "last_seq": max(after, 65),
            ])
        }
        return try! JSONSerialization.data(withJSONObject: run)
    }

    private static func runJSON(id: String) -> [String: Any] {
        [
            "id": id,
            "session_id": "session-1",
            "team_id": "team-1",
            "team_name": "Codex Team",
            "worker_id": "worker-1",
            "workspace_root": "/tmp",
            "execution_path": "/tmp",
            "state": "completed",
            "request": "Check stock",
            "created_at": 1.0,
            "updated_at": 2.0,
            "completed_at": 2.0,
            "last_seq": 65,
            "pinned": false,
            "legacy": false,
            "recoverable": false,
        ]
    }
}

private final class ProviderHandoffURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedProviderBodies: [[String: Any]] = []
    private static var recordedPaths: [String] = []
    static var providerStatusCode = 200
    static var providerReady = true
    static var providerError: String?

    static func reset() {
        lock.lock()
        recordedProviderBodies = []
        recordedPaths = []
        providerStatusCode = 200
        providerReady = true
        providerError = nil
        lock.unlock()
    }

    static var providerBodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProviderBodies
    }

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        Self.lock.lock()
        Self.recordedPaths.append("\(url.host ?? "")\(path)")
        Self.lock.unlock()
        var status = 200
        var body: [String: Any]
        switch path {
        case "/api/provider":
            var requestData = request.httpBody ?? Data()
            if requestData.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    requestData.append(contentsOf: buffer.prefix(count))
                }
            }
            if !requestData.isEmpty,
               var decoded = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]
            {
                decoded["__test_host"] = url.host ?? ""
                Self.lock.lock()
                Self.recordedProviderBodies.append(decoded)
                Self.lock.unlock()
            }
            status = Self.providerStatusCode
            body = status == 200
                ? [
                    "provider": "remote",
                    "host": "https://api.kimi.com/coding/v1",
                    "model": "k3",
                    "remote_base_url": "https://api.kimi.com/coding/v1",
                    "remote_model": "k3",
                    "has_api_key": true,
                ]
                : ["detail": "provider handoff temporarily unavailable"]
        case "/api/health":
            body = [
                "ok": true,
                "version": "test",
                "ollama": Self.providerReady,
                "host": "https://api.kimi.com/coding/v1",
                "model": "k3",
            ]
            if let error = Self.providerError { body["error"] = error }
        case "/api/models":
            body = ["models": [], "current": "k3"]
        case "/api/sessions":
            body = ["sessions": [], "current": "session-1"]
        default:
            status = 404
            body = ["detail": "not part of this provider handoff test"]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AppModelTests: XCTestCase {
    @MainActor
    private func orchestrationModel() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrchestrationURLProtocol.self]
        let service = BackendService(
            baseURL: URL(string: "http://locus.test")!,
            authToken: "test",
            session: URLSession(configuration: configuration)
        )
        let model = AppModel(startImmediately: false, backendOverride: service)
        model.currentSessionID = "session-1"
        return model
    }

    override func setUp() {
        super.setUp()
        OrchestrationURLProtocol.reset()
        ProviderHandoffURLProtocol.reset()
    }

    @MainActor
    func testDuplicateSessionInfoAndCompletionPerformOneIncrementalRefresh() async throws {
        let model = orchestrationModel()
        await model.loadOrchestrationRun("run-1")
        OrchestrationURLProtocol.reset()

        var info = sessionInfo(id: "session-1")
        info["type"] = "session_info"
        model.handleEventForTesting(info)
        model.handleEventForTesting(info)
        let completed: [String: Any] = [
            "type": "orchestration_completed",
            "event_id": "event-66",
            "seq": 66,
            "run_id": "run-1",
            "state": "completed",
        ]
        model.handleEventForTesting(completed)
        model.handleEventForTesting(completed)

        for _ in 0..<50 where OrchestrationURLProtocol.requests.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let urls = OrchestrationURLProtocol.requests
        XCTAssertEqual(urls.filter { $0.path == "/api/orchestrations" }.count, 1)
        XCTAssertEqual(urls.filter { $0.path == "/api/orchestrations/run-1" }.count, 1)
        let eventURLs = urls.filter { $0.path.hasSuffix("/events") }
        XCTAssertEqual(eventURLs.count, 1)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(eventURLs.first), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after_seq" })?.value,
            "66"
        )
    }

    @MainActor
    func testSessionOverviewFoldsProviderEventsWithoutReadingTheProvider() {
        let model = AppModel(startImmediately: false)
        var info = sessionInfo(id: "overview-session")
        info["type"] = "session_info"
        info["model"] = "gpt-5.6-sol"
        info["provider"] = "openai"
        info["context_limit"] = 64_000
        info["approx_tokens"] = 24_100
        model.handleEventForTesting(info)

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [
                ["content": "Inspect", "status": "completed"],
                ["content": "Implement", "status": "in_progress"],
            ],
        ])
        model.handleEventForTesting([
            "type": "tool_call_proposed",
            "id": "read-one",
            "tool": "read_file",
            "summary": "Read Sources/App.swift",
            "detail": "Sources/App.swift",
            "auto": true,
        ])
        model.handleEventForTesting([
            "type": "tool_result",
            "id": "read-one",
            "ok": true,
            "result": "File inspected",
        ])

        XCTAssertEqual(model.sessionOverview.state.model.provider, "openai")
        XCTAssertEqual(model.sessionOverview.state.model.contextWindow, 64_000)
        XCTAssertEqual(model.sessionOverview.state.resources.tokensUsed, 24_100)
        XCTAssertEqual(model.sessionOverview.state.plan.map(\.state), [.done, .running])
        XCTAssertEqual(model.sessionOverview.state.files.first?.path, "Sources/App.swift")

        model.handleEventForTesting(["type": "error", "message": "Endpoint unavailable"])
        XCTAssertEqual(model.sessionOverview.state.status, .error)
        XCTAssertEqual(model.sessionOverview.state.plan.last?.state, .failed)
        model.handleEventForTesting(["type": "turn_done", "reason": "error", "duration_ms": 25])
        XCTAssertEqual(model.sessionOverview.state.status, .error)
        XCTAssertEqual(model.sessionOverview.state.lastRun?.outcome, .failed)
    }

    @MainActor
    func testConcurrentRunRefreshesCoalesce() async {
        let model = orchestrationModel()
        let first = Task { await model.refreshOrchestrationRuns(select: "run-1") }
        let second = Task { await model.refreshOrchestrationRuns(select: "run-1") }
        await first.value
        await second.value

        let urls = OrchestrationURLProtocol.requests
        XCTAssertEqual(urls.filter { $0.path == "/api/orchestrations" }.count, 1)
        XCTAssertEqual(urls.filter { $0.path == "/api/orchestrations/run-1" }.count, 1)
        XCTAssertEqual(urls.filter { $0.path.hasSuffix("/events") }.count, 1)
    }

    @MainActor
    func testOpenTeamRunUsesOneCoordinatedRefresh() async throws {
        let model = orchestrationModel()

        model.openTeamRun("run-1")
        model.openTeamRun("run-1")
        model.openTeamRun("run-1")

        for _ in 0..<50 where OrchestrationURLProtocol.requests.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let urls = OrchestrationURLProtocol.requests
        XCTAssertEqual(urls.filter { $0.path == "/api/orchestrations" }.count, 1)
        XCTAssertEqual(urls.filter { $0.path == "/api/orchestrations/run-1" }.count, 1)
        XCTAssertEqual(urls.filter { $0.path.hasSuffix("/events") }.count, 1)
    }

    @MainActor
    func testLiveRunningStateRejectsStaleDurableRecoveryControls() {
        let presentation = AppModel.resolveTeamRunPresentation(
            runID: "run-1",
            currentRunID: "run-1",
            liveState: .running,
            isBusy: true,
            durableState: .interrupted,
            durableRecoverable: true
        )

        XCTAssertEqual(presentation.state, .running)
        XCTAssertTrue(presentation.canPause)
        XCTAssertTrue(presentation.canStop)
        XCTAssertFalse(presentation.canRecover)
    }

    @MainActor
    func testInterruptedLiveStateWaitsForDurableRecoveryConfirmation() {
        let presentation = AppModel.resolveTeamRunPresentation(
            runID: "run-1",
            currentRunID: "run-1",
            liveState: .interrupted,
            isBusy: false,
            durableState: .running,
            durableRecoverable: true
        )

        XCTAssertFalse(presentation.canRecover)
        XCTAssertFalse(presentation.canPause)
        XCTAssertFalse(presentation.canStop)
    }

    @MainActor
    func testPausedRunOffersRecoveryOnlyAfterWorkerStops() {
        let stillStopping = AppModel.resolveTeamRunPresentation(
            runID: "run-1",
            currentRunID: "run-1",
            liveState: .paused,
            isBusy: true,
            durableState: .paused,
            durableRecoverable: true
        )
        let stopped = AppModel.resolveTeamRunPresentation(
            runID: "run-1",
            currentRunID: "run-1",
            liveState: .paused,
            isBusy: false,
            durableState: .paused,
            durableRecoverable: true
        )

        XCTAssertFalse(stillStopping.canRecover)
        XCTAssertTrue(stopped.canRecover)
        XCTAssertFalse(stopped.canPause)
        XCTAssertFalse(stopped.canStop)
    }

    @MainActor
    func testPickerOptionsRetainASelectedRunMissingFromTheLatestList() async {
        let model = orchestrationModel()
        await model.loadOrchestrationRun("run-missing")

        let options = AppModel.orchestrationPickerRuns(
            model.orchestrationRuns,
            selected: model.selectedOrchestrationRun
        )

        XCTAssertEqual(options.map(\.id), ["run-missing"])
    }

    @MainActor
    func testChangingSessionsClearsASelectionOwnedByThePreviousSession() async {
        let model = orchestrationModel()
        await model.loadOrchestrationRun("run-1")
        XCTAssertEqual(model.selectedOrchestrationRun?.sessionID, "session-1")

        model.currentSessionID = "session-empty"
        await model.refreshOrchestrationRuns()

        XCTAssertNil(model.selectedOrchestrationRun)
        XCTAssertTrue(model.orchestrationEvents.isEmpty)
    }

    @MainActor
    func testLateRunResponseCannotReplaceNewerSelection() async throws {
        OrchestrationURLProtocol.responseDelay = { url in
            url.path.contains("run-old") ? 0.2 : 0
        }
        let model = orchestrationModel()
        let old = Task { await model.loadOrchestrationRun("run-old") }
        try await Task.sleep(for: .milliseconds(20))
        let new = Task { await model.loadOrchestrationRun("run-new") }
        await new.value
        await old.value

        XCTAssertEqual(model.selectedOrchestrationRun?.id, "run-new")
    }

    func testIncrementalEventMergeDeduplicatesAndDropsTransientStreams() throws {
        func event(_ json: String) throws -> OrchestrationEvent {
            try JSONDecoder().decode(OrchestrationEvent.self, from: Data(json.utf8))
        }
        let one = try event(#"{"event_id":"one","seq":1,"type":"orchestration_started"}"#)
        let duplicate = try event(#"{"event_id":"one","seq":1,"type":"orchestration_started"}"#)
        let stream = try event(#"{"event_id":"stream","seq":2,"type":"agent_job_stream"}"#)
        let three = try event(#"{"event_id":"three","seq":3,"type":"orchestration_completed"}"#)

        XCTAssertEqual(
            AppModel.mergeOrchestrationEvents([one], with: [duplicate, stream, three]).map(\.id),
            ["one", "three"]
        )
    }

    @MainActor
    func testOrchestrationControlsResolveTheWorkerThatOwnsTheRun() {
        let oldRun = TaskConversationState(
            sessionID: "old-session",
            taskID: nil,
            teamID: "team",
            workerID: "worker-old",
            runID: "run-old",
            state: .waitingDispatchApproval,
            updatedAt: Date()
        )
        let currentRun = TaskConversationState(
            sessionID: "current-session",
            taskID: nil,
            teamID: "team",
            workerID: "worker-current",
            runID: "run-current",
            state: .dispatching,
            updatedAt: Date()
        )
        let states = [
            oldRun.sessionID: oldRun,
            currentRun.sessionID: currentRun,
        ]

        XCTAssertEqual(
            AppModel.orchestrationOwnerSessionID(
                for: "run-old",
                currentSessionID: "current-session",
                currentRunID: "run-current",
                states: states
            ),
            "old-session"
        )
        XCTAssertEqual(
            AppModel.orchestrationOwnerSessionID(
                for: "run-current",
                currentSessionID: "current-session",
                currentRunID: "run-current",
                states: [:]
            ),
            "current-session"
        )
    }

    @MainActor
    func testCompletedForegroundRunDoesNotShowQuitWarningForStaleSnapshot() {
        let stale = TaskConversationState(
            sessionID: "current-session",
            taskID: "task-1",
            teamID: "team-1",
            workerID: "worker-1",
            runID: "run-1",
            state: .running,
            updatedAt: Date()
        )

        XCTAssertFalse(AppModel.shouldWarnBeforeQuit(
            isBusy: false,
            hasPendingPermission: false,
            currentSessionID: stale.sessionID,
            orchestrationState: .completed,
            taskConversationStates: [stale.sessionID: stale],
            liveWorkerSessionIDs: [stale.sessionID]
        ))
        XCTAssertTrue(AppModel.shouldWarnBeforeQuit(
            isBusy: true,
            hasPendingPermission: false,
            currentSessionID: stale.sessionID,
            orchestrationState: .completed,
            taskConversationStates: [stale.sessionID: stale],
            liveWorkerSessionIDs: [stale.sessionID]
        ), "a newly-started turn must override the previous run's terminal state")
    }

    @MainActor
    func testQuitWarningRequiresLiveNonTerminalBackgroundWorker() {
        let background = TaskConversationState(
            sessionID: "background-session",
            taskID: "task-2",
            teamID: "team-1",
            workerID: "worker-2",
            runID: "run-2",
            state: .running,
            updatedAt: Date()
        )
        let arguments = (
            isBusy: false,
            hasPendingPermission: false,
            currentSessionID: "current-session",
            orchestrationState: TeamRunState.completed,
            taskConversationStates: [background.sessionID: background]
        )

        XCTAssertFalse(AppModel.shouldWarnBeforeQuit(
            isBusy: arguments.isBusy,
            hasPendingPermission: arguments.hasPendingPermission,
            currentSessionID: arguments.currentSessionID,
            orchestrationState: arguments.orchestrationState,
            taskConversationStates: arguments.taskConversationStates,
            liveWorkerSessionIDs: []
        ))
        XCTAssertTrue(AppModel.shouldWarnBeforeQuit(
            isBusy: arguments.isBusy,
            hasPendingPermission: arguments.hasPendingPermission,
            currentSessionID: arguments.currentSessionID,
            orchestrationState: arguments.orchestrationState,
            taskConversationStates: arguments.taskConversationStates,
            liveWorkerSessionIDs: [background.sessionID]
        ))
    }

    @MainActor
    func testDispatcherRepairAndFallbackMessagesUpdateProgress() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "dispatcher_started",
            "run_id": "run-1",
            "agent_name": "Qwen Dispatcher",
        ])
        model.handleEventForTesting([
            "type": "dispatcher_plan_rejected",
            "run_id": "run-1",
            "stage": "initial",
            "reason": "dispatcher plan has no jobs",
            "message": "Correcting dispatcher plan…",
        ])

        XCTAssertEqual(model.dispatcherActivity?.state, .running)
        XCTAssertEqual(model.dispatcherActivity?.output, "Correcting dispatcher plan…")

        let fallback = "Dispatcher plan could not be validated after repair: dispatcher plan has no jobs. Continuing safely with Kimi Writer only."
        model.handleEventForTesting([
            "type": "dispatcher_plan_rejected",
            "run_id": "run-1",
            "stage": "repair",
            "reason": "dispatcher plan has no jobs",
            "message": fallback,
        ])
        model.handleEventForTesting([
            "type": "dispatcher_completed",
            "run_id": "run-1",
            "state": "completed",
            "outcome": "fallback",
            "message": fallback,
        ])

        XCTAssertEqual(model.dispatcherActivity?.state, .completed)
        XCTAssertEqual(model.dispatcherActivity?.output, fallback)
    }

    @MainActor
    func testGlobalAgentConcurrencyStaysWithinApplicationCeiling() {
        let model = AppModel(startImmediately: false)
        model.globalAgentConcurrency = 99
        XCTAssertEqual(model.globalAgentConcurrency, 8)
        model.globalAgentConcurrency = 0
        XCTAssertEqual(model.globalAgentConcurrency, 1)
    }

    @MainActor
    func testLocalTeamManifestContainsOnlyEnabledMembersAndNoPersistedSecrets() throws {
        let model = AppModel(startImmediately: false)
        let dispatcher = AgentProfile(
            name: "Dispatch",
            model: "qwen3",
            role: .dispatcher
        )
        let writer = AgentProfile(
            name: "Writer",
            model: "qwen3-code",
            role: .implementer,
            accessCeiling: .workspaceWrite
        )
        model.agentTeamsModel.saveAgentProfile(dispatcher)
        model.agentTeamsModel.saveAgentProfile(writer)
        let team = AgentTeam(
            name: "LocalTeam",
            dispatcherID: dispatcher.id,
            fallbackDispatcherID: nil,
            memberIDs: [dispatcher.id, writer.id],
            defaultWriterID: writer.id
        )
        model.agentTeamsModel.saveAgentTeam(team)
        model.agentTeamsModel.selectAgentTeam(team.id)

        let manifest = try XCTUnwrap(model.teamManifest(for: "Implement this"))
        let profiles = try XCTUnwrap(manifest["profiles"] as? [[String: Any]])
        let teamPayload = try XCTUnwrap(manifest["team"] as? [String: Any])
        XCTAssertEqual(Set(profiles.compactMap { $0["id"] as? String }), Set(team.memberIDs.map(\.uuidString)))
        XCTAssertEqual(teamPayload["dispatch_approval_mode"] as? String, "preview")
        let budget = try XCTUnwrap(teamPayload["budget"] as? [String: Any])
        XCTAssertEqual(budget["call_budget_mode"] as? String, "automatic")
        XCTAssertEqual(budget["max_model_calls"] as? Int, 100)
        let swarm = try XCTUnwrap(teamPayload["swarm_policy"] as? [String: Any])
        XCTAssertEqual(swarm["engine"] as? String, "locus_managed")
        XCTAssertEqual(swarm["delegation_mode"] as? String, "read_only_children")
        XCTAssertEqual(swarm["max_total_agents"] as? Int, 8)
        XCTAssertEqual(swarm["max_depth"] as? Int, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(manifest))
        let encoded = try JSONSerialization.data(withJSONObject: manifest)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("api_key"))
    }

    @MainActor
    func testQuickTeamCreationCommitsOnceAndSelectsTheResult() throws {
        let model = AppModel(startImmediately: false)
        let dispatcher = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "qwen-dispatch"
        )
        let lead = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "qwen-code"
        )

        let result = model.agentTeamsModel.createAndSelectQuickTeam(QuickTeamDraft(
            name: "Quick Team",
            dispatcher: dispatcher,
            leadEditor: lead
        ))
        let team = try result.get()

        XCTAssertEqual(model.agentProfiles.count, 2)
        XCTAssertEqual(model.agentTeams, [team])
        XCTAssertEqual(model.selectedAgentTeamID, team.id)
        XCTAssertFalse(model.soloSwarmEnabled)
        XCTAssertEqual(model.agentTeamsModel.suggestedQuickTeamName(), "Quick Team 2")

        let profilesBeforeFailure = model.agentProfiles
        let teamsBeforeFailure = model.agentTeams
        let duplicate = model.agentTeamsModel.createAndSelectQuickTeam(QuickTeamDraft(
            name: "quick team",
            dispatcher: dispatcher,
            leadEditor: lead
        ))
        XCTAssertEqual(duplicate, .failure(.duplicateTeamName))
        XCTAssertEqual(model.agentProfiles, profilesBeforeFailure)
        XCTAssertEqual(model.agentTeams, teamsBeforeFailure)
    }

    @MainActor
    func testQuickTeamCreationNeverGrantsHostedRoutingConsentImplicitly() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(
            model,
            kind: .claude,
            name: "Quick Team",
            preferredModel: "claude-sonnet"
        )
        let choice = QuickTeamModelChoice(
            route: .providerAccount(account.id),
            providerName: account.displayName,
            providerShortName: account.shortName,
            model: "claude-sonnet"
        )

        let result = model.agentTeamsModel.createAndSelectQuickTeam(QuickTeamDraft(
            name: "Hosted Team",
            dispatcher: choice,
            leadEditor: choice
        ))

        XCTAssertEqual(result, .failure(.routingConsentRequired(account.displayName)))
        XCTAssertFalse(model.teamRoutingConsentAccountIDs.contains(account.id))
        XCTAssertTrue(model.agentProfiles.isEmpty)
        XCTAssertTrue(model.agentTeams.isEmpty)
    }

    @MainActor
    func testTeamDispatchProgressBecomesOneTimePlanApproval() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.handleEventForTesting([
            "type": "orchestration_started",
            "run_id": "run-once",
            "state": "dispatching",
        ])

        XCTAssertTrue(model.shouldShowTeamDispatchProgress)
        XCTAssertFalse(model.shouldShowTeamDispatchApproval)

        model.handleEventForTesting([
            "type": "dispatcher_started",
            "run_id": "run-once",
            "agent_name": "Qwen Dispatcher",
            "provider": "vLLM",
            "model": "qwen",
        ])
        model.handleEventForTesting([
            "type": "dispatcher_plan_rejected",
            "run_id": "run-once",
            "reason": "writer job was missing",
            "message": "Correcting dispatcher plan…",
        ])
        XCTAssertEqual(model.dispatcherValidationReason, "writer job was missing")

        model.handleEventForTesting([
            "type": "dispatch_plan_ready",
            "run_id": "run-once",
            "state": "waiting_dispatch_approval",
            "plan": [
                "summary": "Implement once",
                "jobs": [[
                    "id": "write",
                    "agent_id": UUID().uuidString,
                    "goal": "Implement the request",
                    "dependencies": [],
                    "kind": "writer",
                ]],
            ],
        ])

        XCTAssertFalse(model.shouldShowTeamDispatchProgress)
        XCTAssertTrue(model.shouldShowTeamDispatchApproval)
        XCTAssertEqual(model.pendingDispatchPlan?.jobs.count, 1)
    }

    @MainActor
    func testMessagesEnteredDuringTeamPlanApprovalQueueForTheNextTurn() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.handleEventForTesting([
            "type": "orchestration_state",
            "state": "waiting_dispatch_approval",
        ])
        model.draftText = "Add documentation after this run"

        model.submitDraft()

        XCTAssertEqual(model.queuedMessages, ["Add documentation after this run"])
        XCTAssertTrue(model.draftText.isEmpty)
    }

    @MainActor
    func testIncompleteCodingJobBecomesPausedWithoutCompletion() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "agent_job_started",
            "run_id": "run-1",
            "job_id": "writer",
            "agent_id": "writer-agent",
            "agent_name": "Backend Writer",
            "role": "implementer",
            "provider": "Kimi",
            "model": "kimi-for-coding",
            "goal": "Implement the backend",
            "writer_job_id": "writer",
            "writer_position": 1,
            "writer_total": 2,
        ])
        model.handleEventForTesting([
            "type": "agent_job_incomplete",
            "run_id": "run-1",
            "job_id": "writer",
            "state": "paused",
            "message": "Call budget reached before this coding job finished.",
            "model_calls": 12,
            "limit": 12,
            "result": [
                "job_id": "writer",
                "elapsed_ms": 2_000,
                "prompt_tokens": 20,
                "completion_tokens": 10,
            ],
            "usage": ["model_calls": 12],
        ])

        XCTAssertEqual(model.orchestrationState, .paused)
        XCTAssertEqual(model.agentActivities.first?.state, .paused)
        XCTAssertEqual(model.agentActivities.first?.output, "Call budget reached before this coding job finished.")
        XCTAssertEqual(model.teamModelCalls, 12)
    }

    @MainActor
    func testSwarmSpawnReplayDeduplicatesNodeAndBranchStopUpdatesIt() {
        let model = AppModel(startImmediately: false)
        let spawned: [String: Any] = [
            "type": "agent_spawned",
            "run_id": "run-1",
            "job_id": "inspect.1",
            "node_id": "inspect.1",
            "parent_node_id": "inspect",
            "depth": 1,
            "execution_engine": "locus_managed",
            "agent_name": "API specialist",
            "role": "researcher",
            "provider": "vLLM",
            "model": "qwen3",
            "goal": "Verify the API contract",
        ]

        model.handleEventForTesting(spawned)
        model.handleEventForTesting(spawned)

        XCTAssertEqual(model.agentActivities.count, 1)
        XCTAssertEqual(model.agentActivities.first?.nodeID, "inspect.1")
        XCTAssertEqual(model.agentActivities.first?.parentNodeID, "inspect")
        XCTAssertEqual(model.agentActivities.first?.depth, 1)

        model.handleEventForTesting([
            "type": "agent_branch_stopped",
            "run_id": "run-1",
            "node_id": "inspect.1",
            "message": "Branch stopped at a safe boundary.",
        ])

        XCTAssertEqual(model.agentActivities.first?.state, .interrupted)
        XCTAssertEqual(
            model.agentActivities.first?.output,
            "Branch stopped at a safe boundary."
        )
    }

    func testWorkModeInstructionsAreDistinct() {
        XCTAssertEqual(Set(WorkMode.allCases.map(\.instruction)).count, WorkMode.allCases.count)
        XCTAssertTrue(WorkMode.ask.instruction.contains("explicitly attached"))
        XCTAssertTrue(WorkMode.ask.instruction.contains("Do not inspect attachment paths"))
        XCTAssertTrue(WorkMode.plan.instruction.contains("do not modify"))
        XCTAssertTrue(WorkMode.grill.instruction.contains("Do not modify"))
        XCTAssertTrue(WorkMode.work.instruction.contains("Choose whether"))
        // The `$` mention is what makes the runtime preload the grilling skill.
        XCTAssertEqual(WorkMode.grill.title, "Grill")
        XCTAssertEqual(WorkMode.grill.rawValue, "grill")
        XCTAssertTrue(WorkMode.grill.instruction.contains("$grilling"))
    }

    func testRetiredBuildModeStillDecodesOntoWork() throws {
        // "build" was GSD's raw value. Profiles and manifests that stored it
        // land on Work — the mode that kept its implement-things behavior —
        // while anything unrecognized still fails loudly.
        let decoded = try JSONDecoder().decode(
            [WorkMode].self,
            from: Data(#"["build", "grill", "plan"]"#.utf8)
        )
        XCTAssertEqual(decoded, [.work, .grill, .plan])
        XCTAssertEqual(WorkMode.canonical("build"), .work)
        XCTAssertNil(WorkMode.canonical("construct"))
        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkMode.self, from: Data(#""construct""#.utf8)
        ))
    }

    @MainActor
    func testAdaptiveWorkIsTheNeutralDefault() {
        let model = AppModel(startImmediately: false)
        XCTAssertEqual(model.selectedMode, .work)
        XCTAssertTrue(model.soloSwarmEnabled)
    }

    @MainActor
    func testSoloDelegationAndTeamRoutesAreMutuallyExclusive() {
        let model = AppModel(startImmediately: false)
        model.agentTeamsModel.selectSoloRoute()
        XCTAssertTrue(model.soloSwarmEnabled)
        XCTAssertNil(model.selectedAgentTeamID)

        model.agentTeamsModel.selectAgentTeam(UUID())
        XCTAssertFalse(model.soloSwarmEnabled)
        XCTAssertNotNil(model.selectedAgentTeamID)

        model.agentTeamsModel.selectAgentTeam(nil)
        XCTAssertTrue(model.soloSwarmEnabled)
        XCTAssertNil(model.selectedAgentTeamID)
    }

    @MainActor
    func testSessionsAreGroupedUnderTheirFolderBackedWorkspaces() {
        let model = AppModel(startImmediately: false)
        let firstPath = "/tmp/locus-workspace-one"
        let secondPath = "/tmp/locus-workspace-two"
        model.workspaceProfiles = [
            WorkspaceProfile(
                path: firstPath,
                lastOpened: Date(timeIntervalSince1970: 20),
                model: "",
                accountID: nil,
                mode: .work,
                previewURL: "",
                contextFiles: [],
                draft: ""
            ),
            WorkspaceProfile(
                path: secondPath,
                lastOpened: Date(timeIntervalSince1970: 10),
                model: "",
                accountID: nil,
                mode: .work,
                previewURL: "",
                contextFiles: [],
                draft: ""
            ),
        ]
        model.sessions = [
            SessionSummary(
                id: "one",
                name: "one.jsonl",
                preview: "First",
                mtime: 30,
                size: 1,
                cwd: firstPath
            ),
            SessionSummary(
                id: "legacy",
                name: "legacy.jsonl",
                preview: "Legacy",
                mtime: 5,
                size: 1
            ),
        ]

        let groups = model.workspaceChatGroups
        XCTAssertEqual(groups.first(where: { $0.id == firstPath })?.chats.map(\.id), ["one"])
        XCTAssertNotNil(groups.first(where: { $0.id == secondPath }), "empty workspaces remain visible")
        XCTAssertEqual(
            groups.first(where: { $0.id == AppModel.otherWorkspaceID })?.chats.map(\.id),
            ["legacy"]
        )
    }

    @MainActor
    func testWorkspaceExpansionCanBePersistentlyToggledInMemory() {
        let model = AppModel(startImmediately: false)
        model.setWorkspaceExpanded("/tmp/example", expanded: true)
        XCTAssertTrue(model.isWorkspaceExpanded("/tmp/example"))
        model.setWorkspaceExpanded("/tmp/example", expanded: false)
        XCTAssertFalse(model.isWorkspaceExpanded("/tmp/example"))
    }

    @MainActor
    func testRemoveWorkspaceFromSidebarDropsProfilesButProtectsTheActiveWorkspace() {
        let model = AppModel(startImmediately: false)
        let idlePath = "/tmp/locus-workspace-idle"

        func profile(_ path: String) -> WorkspaceProfile {
            WorkspaceProfile(
                path: path,
                lastOpened: Date(timeIntervalSince1970: 10),
                model: "",
                accountID: nil,
                mode: .work,
                previewURL: "",
                contextFiles: [],
                draft: ""
            )
        }

        model.workspaceProfiles = [profile(idlePath)]
        let idleGroup = model.workspaceChatGroups.first { $0.id == idlePath }
        XCTAssertNotNil(idleGroup)
        model.removeWorkspaceFromSidebar(idleGroup!)
        XCTAssertFalse(model.workspaceProfiles.contains { $0.path == idlePath })

        let activePath = model.activeWorkspaceID
        model.workspaceProfiles = [profile(activePath)]
        let activeGroup = model.workspaceChatGroups.first { $0.id == activePath }
        XCTAssertNotNil(activeGroup)
        model.removeWorkspaceFromSidebar(activeGroup!)
        XCTAssertTrue(
            model.workspaceProfiles.contains { $0.path == activePath },
            "the active workspace cannot be removed from the sidebar"
        )
    }

    func testOlderSessionSummaryWithoutWorkspaceStillDecodes() throws {
        let summary = try JSONDecoder().decode(
            SessionSummary.self,
            from: Data(
                #"{"id":"old","name":"old.jsonl","preview":"hello","mtime":1,"size":4,"title":null,"pinned":false,"archived":false}"#.utf8
            )
        )
        XCTAssertNil(summary.cwd)
        XCTAssertNil(summary.workspacePath)
    }

    func testTranscriptFollowDetachesAndReattachesOnlyFromUserIntent() {
        var state = TranscriptFollowState()
        XCTAssertTrue(state.permitsAutomaticScroll)

        state.userScrolled(upward: true)
        XCTAssertFalse(state.permitsAutomaticScroll)
        state.updateBottom(isNear: true)
        XCTAssertFalse(state.permitsAutomaticScroll, "streaming cannot reclaim a detached viewport")

        state.userScrolled(upward: false)
        XCTAssertTrue(
            state.permitsAutomaticScroll,
            "a user who scrolls back within the bottom threshold restores following"
        )
        state.userScrolled(upward: true)

        state.jumpToLatest()
        XCTAssertTrue(state.permitsAutomaticScroll)
        state.updateBottom(isNear: false)
        XCTAssertTrue(
            state.permitsAutomaticScroll,
            "content growth must not be mistaken for an upward user scroll"
        )
        XCTAssertTrue(state.showsJumpToLatest)
        state.userScrolled(upward: true)
        XCTAssertFalse(state.permitsAutomaticScroll)
    }

    func testTranscriptJumpStaysVisibleUntilTheViewportReachesLatest() {
        var state = TranscriptFollowState()
        state.updateBottom(isNear: false)
        state.detach()

        state.jumpToLatest()

        XCTAssertTrue(state.permitsAutomaticScroll)
        XCTAssertTrue(
            state.showsJumpToLatest,
            "requesting a jump must not claim the viewport moved before it actually does"
        )

        state.updateBottom(isNear: true)
        XCTAssertFalse(state.showsJumpToLatest)
    }

    func testTranscriptScrollMetricsHandleFlippedAndUnflippedDocuments() {
        let document = CGRect(x: 0, y: 0, width: 600, height: 2_000)
        let flippedVisible = CGRect(x: 0, y: 1_500, width: 600, height: 400)
        XCTAssertEqual(
            TranscriptScrollMetrics.bottomDistance(
                documentBounds: document,
                visibleRect: flippedVisible,
                isFlipped: true
            ),
            100
        )
        XCTAssertEqual(
            TranscriptScrollMetrics.bottomOriginY(
                documentBounds: document,
                viewportHeight: 400,
                isFlipped: true
            ),
            1_600
        )
        let unflippedVisible = CGRect(x: 0, y: 75, width: 600, height: 400)
        XCTAssertEqual(
            TranscriptScrollMetrics.bottomDistance(
                documentBounds: document,
                visibleRect: unflippedVisible,
                isFlipped: false
            ),
            75
        )
    }

    func testTranscriptWheelRoutingFallsBackToLegacyAppKitDeltas() {
        XCTAssertEqual(
            TranscriptScrollMetrics.dominantVerticalWheelDelta(
                scrollingDeltaX: 0,
                scrollingDeltaY: 0,
                legacyDeltaX: 0,
                legacyDeltaY: -4
            ),
            -4
        )
        XCTAssertEqual(
            TranscriptScrollMetrics.dominantVerticalWheelDelta(
                scrollingDeltaX: 1,
                scrollingDeltaY: 6,
                legacyDeltaX: 20,
                legacyDeltaY: 20
            ),
            6,
            "precise scrolling deltas take precedence when AppKit supplies them"
        )
        XCTAssertNil(
            TranscriptScrollMetrics.dominantVerticalWheelDelta(
                scrollingDeltaX: 8,
                scrollingDeltaY: 2,
                legacyDeltaX: 0,
                legacyDeltaY: 0
            ),
            "horizontal gestures must keep reaching nested code views"
        )
    }

    func testPlanDocumentDecodesOlderPartialPayloads() throws {
        let document = try JSONDecoder().decode(
            PlanDocument.self,
            from: Data(#"{"title":"Older plan","steps":["Inspect","Verify"]}"#.utf8)
        )
        XCTAssertEqual(document.title, "Older plan")
        XCTAssertEqual(document.steps, ["Inspect", "Verify"])
        XCTAssertTrue(document.summary.isEmpty)
        XCTAssertTrue(document.tests.isEmpty)
        XCTAssertFalse(document.id.isEmpty)
    }

    func testPlanFallbackRequiresACompletedActionablePlan() {
        let plan = PlanSignalDetector.document(from: "# Plan\n1. Inspect the view\n2. Fix scrolling")
        XCTAssertEqual(plan?.steps, ["Inspect the view", "Fix scrolling"])
        XCTAssertNil(PlanSignalDetector.document(from: "# Plan\n1. Inspect the view"))
        XCTAssertNil(PlanSignalDetector.document(
            from: "I made a preliminary list.\nWhich behavior should it use?",
            changedTodos: [TodoItem(content: "Inspect the view", status: .pending)]
        ))
        XCTAssertEqual(
            PlanSignalDetector.document(
                from: "<proposed_plan>\n- Inspect the view\n- Verify the fix\n</proposed_plan>"
            )?.steps,
            ["Inspect the view", "Verify the fix"]
        )
        XCTAssertNotNil(PlanSignalDetector.document(
            from: "# Plan\n1. Inspect the view\n2. Verify the fix\nWould you like me to proceed?"
        ))
    }

    func testUserQuestionDecodesPartialPayloadsAndStringOptions() throws {
        let question = try JSONDecoder().decode(
            UserQuestion.self,
            from: Data(#"{"question":"Which store?","options":["SQLite",{"label":"Core Data","detail":"Heavier"}]}"#.utf8)
        )
        XCTAssertEqual(question.title, "Question")
        XCTAssertEqual(question.question, "Which store?")
        XCTAssertEqual(question.options.map(\.label), ["SQLite", "Core Data"])
        XCTAssertEqual(question.options.last?.detail, "Heavier")
        XCTAssertTrue(question.recommended.isEmpty)
        XCTAssertFalse(question.id.isEmpty)

        let recommended = UserQuestion(
            options: [UserQuestionOption(label: "SQLite")],
            recommended: "sqlite"
        )
        XCTAssertEqual(recommended.recommendedOptionIndex, 0, "label matching is case-insensitive")
    }

    func testQuestionDetectorParsesTheGrillBlock() throws {
        let text = """
        Mapping the design tree first.

        ❓ **Q1** - **Reddit scope**: Should "latest posts" mean the site-wide feed or one subreddit?

        - Site-wide /new feed
        - A subreddit argument

        ➡️ Site-wide /new feed
        """
        let question = try XCTUnwrap(QuestionSignalDetector.question(from: text))
        XCTAssertEqual(question.title, "Reddit scope")
        XCTAssertEqual(
            question.question,
            #"Should "latest posts" mean the site-wide feed or one subreddit?"#
        )
        XCTAssertEqual(
            question.options.map(\.label),
            ["Site-wide /new feed", "A subreddit argument"]
        )
        XCTAssertEqual(question.recommended, "Site-wide /new feed")
        XCTAssertEqual(question.recommendedOptionIndex, 0)
    }

    func testQuestionDetectorNeedsTheMarkerAndSurvivesSparseBlocks() throws {
        XCTAssertNil(
            QuestionSignalDetector.question(from: "Should the retries back off exponentially?"),
            "prose ending in a question mark is not the Grill block"
        )
        XCTAssertNil(QuestionSignalDetector.question(from: ""))

        // No options, no recommendation, multi-paragraph body.
        let sparse = try XCTUnwrap(QuestionSignalDetector.question(
            from: "❓ **Q3** - **Storage**: Where should results persist?\n\nThe workspace has no database yet."
        ))
        XCTAssertEqual(sparse.title, "Storage")
        XCTAssertTrue(sparse.question.contains("no database yet"))
        XCTAssertTrue(sparse.options.isEmpty)
        XCTAssertTrue(sparse.recommended.isEmpty)

        // Missing the bold title convention entirely.
        let untitled = try XCTUnwrap(QuestionSignalDetector.question(
            from: "❓ Which port should the server bind?\n➡️ 8791"
        ))
        XCTAssertEqual(untitled.title, "Question")
        XCTAssertEqual(untitled.question, "Which port should the server bind?")
        XCTAssertEqual(untitled.recommended, "8791")

        // The emoji markers come in both grapheme forms: with the variation
        // selector and without. Models emit both.
        let withSelector = try XCTUnwrap(QuestionSignalDetector.question(
            from: "\u{2753}\u{FE0F} **Q2** - **Port**: Which port?\n\u{27A1}\u{FE0F} 8791"
        ))
        XCTAssertEqual(withSelector.title, "Port")
        XCTAssertEqual(withSelector.recommended, "8791")
        let bareArrow = try XCTUnwrap(QuestionSignalDetector.question(
            from: "\u{2753} **Q2** - **Port**: Which port?\n\u{27A1} 8791"
        ))
        XCTAssertEqual(bareArrow.title, "Port")
        XCTAssertEqual(bareArrow.recommended, "8791")
    }

    @MainActor
    func testAdaptiveWorkPromptDecorationNamesTheNeutralMode() {
        let model = AppModel(startImmediately: false)
        let prompt = model.decoratedPrompt("Fix the sidebar", mode: .work)
        XCTAssertTrue(prompt.contains("[Locus mode: Work]"))
        XCTAssertTrue(prompt.contains(WorkMode.work.instruction))
        XCTAssertTrue(prompt.hasSuffix("User request:\nFix the sidebar"))
    }

    @MainActor
    func testLegacyBuildProfilesDecodeOntoWorkWithoutChangingPlan() throws {
        func profile(_ mode: WorkMode, path: String) -> WorkspaceProfile {
            WorkspaceProfile(
                path: path,
                lastOpened: Date(),
                model: "qwen",
                accountID: nil,
                mode: mode,
                previewURL: "",
                contextFiles: [],
                draft: ""
            )
        }
        // Migration happens at decode time now: a stored "build" profile
        // comes back as Work without a separate migration pass.
        let stored = try JSONEncoder().encode([
            profile(.grill, path: "/tmp/grill"),
            profile(.plan, path: "/tmp/plan"),
            profile(.work, path: "/tmp/work"),
        ])
        let json = String(decoding: stored, as: UTF8.self)
            .replacingOccurrences(of: #""grill""#, with: #""build""#)
        let migrated = try JSONDecoder().decode(
            [WorkspaceProfile].self, from: Data(json.utf8)
        )
        XCTAssertEqual(migrated.map(\.mode), [.work, .plan, .work])
    }

    @MainActor
    func testDecoratedPromptCarriesAttachmentSectionsInEveryMode() {
        let model = AppModel(startImmediately: false)
        let attachments = [
            ChatAttachment(
                url: URL(fileURLWithPath: "/tmp/notes.txt"),
                kind: .text,
                textContent: "A supplied note"
            ),
            ChatAttachment(
                url: URL(fileURLWithPath: "/tmp/bug.png"),
                kind: .image,
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                mimeType: "image/png"
            ),
        ]

        for mode in [WorkMode.work, .plan, .grill] {
            let prompt = model.decoratedPrompt(
                "Fix it", mode: mode, chatAttachments: attachments
            )
            XCTAssertTrue(prompt.contains("Attached file: notes.txt"), "\(mode)")
            XCTAssertTrue(prompt.contains("A supplied note"), "\(mode)")
            XCTAssertTrue(prompt.contains("bug.png"), "\(mode)")
            XCTAssertFalse(
                prompt.contains("access any other workspace data"),
                "the Just Chat isolation contract must stay ask-only in \(mode)"
            )
        }

        let askPrompt = model.decoratedPrompt(
            "Fix it", mode: .ask, chatAttachments: attachments
        )
        XCTAssertTrue(askPrompt.contains("access any other workspace data"))
        XCTAssertTrue(askPrompt.contains("without accessing their paths"))
    }

    @MainActor
    func testPastedImagesGetUniqueNamesAndCountAgainstTheCaps() {
        let model = AppModel(startImmediately: false)
        let payload = (data: Data([0x89, 0x50, 0x4e, 0x47]), mimeType: "image/png")

        model.addPastedImages([payload, payload])
        XCTAssertEqual(model.chatAttachments.count, 2)
        XCTAssertEqual(Set(model.chatAttachments.map(\.name)).count >= 1, true)
        XCTAssertEqual(Set(model.chatAttachments.map(\.url)).count, 2)
        XCTAssertTrue(model.chatAttachments.allSatisfy { $0.name.hasPrefix("Pasted image ") })
        XCTAssertTrue(model.chatAttachments.allSatisfy(\.isAvailable))

        model.chatAttachments = (0..<10).map { index in
            ChatAttachment(
                url: URL(fileURLWithPath: "/tmp/full-\(index).png"),
                kind: .image,
                imageData: Data([0x89]),
                mimeType: "image/png"
            )
        }
        model.addPastedImages([payload])
        XCTAssertEqual(model.chatAttachments.count, 10)
        XCTAssertEqual(
            model.chatAttachmentNotice,
            "A chat message can include up to 10 attachments."
        )

        model.chatAttachments = []
        model.chatAttachmentNotice = nil
        let oversized = (data: Data(count: 15_000_001), mimeType: "image/png")
        model.addPastedImages([oversized])
        XCTAssertTrue(model.chatAttachments.isEmpty)
        XCTAssertEqual(model.chatAttachmentNotice, "Skipped or limited: 1 over the size limit.")
    }

    func testModelInfoDecodesVisionCapabilityTolerantly() throws {
        let decoder = JSONDecoder()
        let seeing = try decoder.decode(
            ModelInfo.self,
            from: Data(#"{"name": "seeing:latest", "vision": true}"#.utf8)
        )
        let blind = try decoder.decode(
            ModelInfo.self,
            from: Data(#"{"name": "blind:latest", "vision": false}"#.utf8)
        )
        let older = try decoder.decode(
            ModelInfo.self,
            from: Data(#"{"name": "older:latest"}"#.utf8)
        )
        XCTAssertEqual(seeing.visionCapable, true)
        XCTAssertEqual(blind.visionCapable, false)
        XCTAssertNil(older.visionCapable)
    }

    func testTranscriptSearchHitDecodesAndYieldsItsMatchedTerm() throws {
        let payload = """
        {
          "session_id": "2026-08-09-abc", "title": "Retry bug", "pinned": false,
          "mtime": 1754700000.0, "message_index": 4, "role": "assistant",
          "snippet": "…the retry loop backs off…", "highlights": [[5, 5], [11, 4]],
          "score": 1.0
        }
        """
        let hit = try JSONDecoder().decode(TranscriptSearchHit.self, from: Data(payload.utf8))

        XCTAssertEqual(hit.sessionID, "2026-08-09-abc")
        XCTAssertEqual(hit.messageIndex, 4)
        XCTAssertEqual(hit.id, "2026-08-09-abc:4")
        XCTAssertEqual(hit.firstMatchedTerm, "retry")

        let bare = try JSONDecoder().decode(
            TranscriptSearchHit.self,
            from: Data("""
            {"session_id": "s", "title": null, "pinned": true, "mtime": 1.0,
             "message_index": 0, "role": "user", "snippet": "", "highlights": [],
             "score": 0.5}
            """.utf8)
        )
        XCTAssertNil(bare.firstMatchedTerm)

        // Offsets are Python str positions — Unicode scalars. The flag emoji
        // is one grapheme but two scalars, so grapheme-based math would land
        // one short on every highlight after it.
        let emoji = try JSONDecoder().decode(
            TranscriptSearchHit.self,
            from: Data("""
            {"session_id": "s", "title": null, "pinned": false, "mtime": 1.0,
             "message_index": 0, "role": "user",
             "snippet": "\\uD83C\\uDDEB\\uD83C\\uDDF7 fix the retry bug",
             "highlights": [[11, 5]], "score": 1.0}
            """.utf8)
        )
        XCTAssertEqual(emoji.firstMatchedTerm, "retry")
    }

    @MainActor
    func testBlocksFromMessagesCarryHistoryIndexAcrossDroppedMessages() throws {
        let messages = try JSONDecoder().decode([HistoryMessage].self, from: Data("""
        [
          {"role": "user", "content": "first question"},
          {"role": "assistant", "content": ""},
          {"role": "assistant", "content": "the searchable answer"},
          {"role": "system", "content": "never rendered"},
          {"role": "user", "content": "second question"}
        ]
        """.utf8))

        let blocks = ChatTranscriptBuilder.blocks(from: messages)

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].historyIndex, 0)
        XCTAssertEqual(blocks[1].historyIndex, 2)
        XCTAssertEqual(blocks[1].text, "the searchable answer")
        XCTAssertEqual(blocks[2].historyIndex, 4)
    }

    func testUsageSummaryDecodesSnakeCasePayload() throws {
        let payload = """
        {
          "since": 0, "generated_at": 1754700000.5, "read_only": false,
          "orchestration": {"runs": 3, "model_calls": 24, "metered_tokens": 90000,
                            "estimated_cost": 2.75},
          "by_day": [{"day": "2026-08-09", "runs": 2, "metered_tokens": 60000,
                      "estimated_cost": 2.0}],
          "by_workspace": [{"workspace_root": "/tmp/ws", "runs": 3,
                            "estimated_cost": 2.75}],
          "by_model": [{"provider": "anthropic", "model": "claude-sonnet-5",
                        "attempts": 5, "prompt_tokens": 40000,
                        "completion_tokens": 9000}],
          "by_agent": [{"agent_id": "6B2BB0A5-7B5A-4E24-B47C-1D8E64B1B1F1",
                        "samples": 5, "estimated_cost": 2.75, "local": false}],
          "evaluations": {"cases": 4, "estimated_cost": 0.5},
          "solo": {"turns": 2, "prompt_tokens": 300, "completion_tokens": 120,
                   "recorded_since": 1754600000.0},
          "expensive_runs": [{"id": "run-1", "team_name": "Core Team",
                              "workspace_root": "/tmp/ws",
                              "created_at": 1754650000.0, "state": "completed",
                              "estimated_cost": 1.5}]
        }
        """
        let summary = try JSONDecoder().decode(UsageSummary.self, from: Data(payload.utf8))

        XCTAssertEqual(summary.orchestration.runs, 3)
        XCTAssertEqual(summary.orchestration.meteredTokens, 90_000)
        XCTAssertEqual(summary.orchestration.estimatedCost, 2.75, accuracy: 0.001)
        XCTAssertEqual(summary.byModel.first?.model, "claude-sonnet-5")
        XCTAssertEqual(summary.byAgent.first?.local, false)
        XCTAssertEqual(summary.solo.turns, 2)
        XCTAssertNotNil(summary.solo.recordedSince)
        XCTAssertEqual(summary.expensiveRuns.first?.teamName, "Core Team")
        XCTAssertFalse(summary.readOnly)
    }

    func testUsageWindowCutoffsAreOrderedAndAllMeansEverything() {
        XCTAssertEqual(UsageWindow.all.since, 0)
        let week = UsageWindow.week.since
        let month = UsageWindow.month.since
        let quarter = UsageWindow.quarter.since
        XCTAssertGreaterThan(week, month)
        XCTAssertGreaterThan(month, quarter)
        XCTAssertGreaterThan(quarter, 0)
    }

    func testChatAttachmentRepresentsTextAndImageInputs() {
        let text = ChatAttachment(
            url: URL(fileURLWithPath: "/tmp/notes.txt"),
            kind: .text,
            textContent: "A supplied note"
        )
        let image = ChatAttachment(
            url: URL(fileURLWithPath: "/tmp/photo.png"),
            kind: .image,
            imageData: Data([0x89, 0x50, 0x4e, 0x47]),
            mimeType: "image/png"
        )

        XCTAssertTrue(text.isAvailable)
        XCTAssertEqual(text.name, "notes.txt")
        XCTAssertTrue(text.detail.contains("tokens"))
        XCTAssertTrue(image.isAvailable)
        XCTAssertEqual(image.mimeType, "image/png")
    }

    func testContextTokenEstimateUsesReadableMinimum() {
        let file = ContextFile(
            url: URL(fileURLWithPath: "/tmp/example.swift"),
            content: "let answer = 42"
        )
        XCTAssertGreaterThan(file.estimatedTokens, 0)
        XCTAssertEqual(file.name, "example.swift")
    }

    func testContextCheckpointPersistsReferencesWithoutSourceContents() throws {
        let file = ContextFile(
            url: URL(fileURLWithPath: "/tmp/private-source.swift"),
            content: "private let secret = \"never persist this\""
        )

        let data = try JSONEncoder().encode(file)
        let encoded = String(decoding: data, as: UTF8.self)
        let restored = try JSONDecoder().decode(ContextFile.self, from: data)

        XCTAssertFalse(encoded.contains("never persist this"))
        XCTAssertEqual(restored.url, file.url)
        XCTAssertTrue(restored.content.isEmpty)
    }

    func testReconnectBackoffMatchesReliabilitySchedule() {
        XCTAssertEqual((0...6).map(BackendService.reconnectDelay), [1, 2, 4, 8, 15, 15, 15])
    }

    func testHuggingFaceRepositoryURLsAreNormalized() {
        let service = ModelLibraryService()
        XCTAssertEqual(
            service.normalizeRepository("https://huggingface.co/DavidAU/Defiant-GGUF?tab=files"),
            "DavidAU/Defiant-GGUF"
        )
        XCTAssertEqual(
            service.normalizeRepository("hf.co/owner/model/"),
            "owner/model"
        )
    }

    func testGGUFQuantizationAndRecommendationAreRecognized() {
        let file = HuggingFaceModelFile(
            rfilename: "Example-MTP-Q4_K_M.gguf",
            size: 6_979_975_392
        )
        let variant = HuggingFaceVariant(
            quantization: file.quantization ?? "",
            fileName: file.rfilename,
            approximateSize: file.size ?? 0
        )

        XCTAssertEqual(file.quantization, "Q4_K_M")
        XCTAssertTrue(variant.isRecommended)
        XCTAssertFalse(variant.sizeLabel.isEmpty)
    }

    func testMemoryFitClassifiesAgainstTheGivenMachine() {
        let ram32 = UInt64(32) * 1_073_741_824
        // The observed failure: a 22 GB Q4_K_M on a 32 GB Mac loads, but
        // starves the machine and the context window.
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 21_972_752_792, physicalMemory: ram32), .tight
        )
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 7_900_000_000, physicalMemory: ram32), .fits
        )
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 26_000_000_000, physicalMemory: ram32), .exceeds
        )
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 0, physicalMemory: ram32), .fits,
            "an unknown size must not cry wolf"
        )
    }

    func testRecommendedVariantIsRamAwareNotJustQ4KM() {
        let big = HuggingFaceVariant(
            quantization: "Q4_K_M", fileName: "big-Q4_K_M.gguf", approximateSize: 22_000_000_000
        )
        let small = HuggingFaceVariant(
            quantization: "Q3_K_M", fileName: "big-Q3_K_M.gguf", approximateSize: 14_000_000_000
        )
        let ram32 = UInt64(32) * 1_073_741_824

        XCTAssertEqual(
            HuggingFaceVariant.recommendedVariant(in: [big, small], physicalMemory: ram32)?
                .quantization,
            "Q3_K_M",
            "the usual Q4_K_M pick must lose to a quant that actually fits"
        )
        XCTAssertEqual(
            HuggingFaceVariant.recommendedVariant(
                in: [big, small], physicalMemory: UInt64(128) * 1_073_741_824
            )?.quantization,
            "Q4_K_M",
            "with room to spare the quality-priority order stands"
        )
        XCTAssertEqual(
            HuggingFaceVariant.recommendedVariant(
                in: [big], physicalMemory: UInt64(16) * 1_073_741_824
            )?.quantization,
            "Q4_K_M",
            "when nothing fits, the first variant is still offered — warned, not hidden"
        )
    }

    // MARK: - Settings

    @MainActor
    func testApplyingSettingsDoesNotDismissTheirPresentation() {
        let model = AppModel(startImmediately: false)
        model.presentSettings(.extensions)
        XCTAssertEqual(model.settingsPage, .extensions)
        var updated = model.settings
        updated.showContextUsageInHeader.toggle()

        model.applySettings(updated, showConfirmation: false)

        XCTAssertTrue(model.settingsPresented)
        XCTAssertEqual(
            model.settings.showContextUsageInHeader,
            updated.showContextUsageInHeader
        )
        XCTAssertNil(model.toastMessage)
    }

    @MainActor
    func testAppearancePreviewIsImmediateButOnlySaveCommitsIt() {
        let model = AppModel(startImmediately: false)
        var lightSettings = model.settings
        lightSettings.appearanceRaw = AppAppearance.light.rawValue
        model.applySettings(lightSettings)

        model.previewAppearance(AppAppearance.dark.rawValue)
        XCTAssertEqual(model.effectiveAppearance, .dark)
        XCTAssertEqual(model.settings.resolvedAppearance, .light)

        model.clearAppearancePreview()
        XCTAssertEqual(model.effectiveAppearance, .light)
        XCTAssertNil(model.appearancePreview)

        model.previewAppearance(AppAppearance.dark.rawValue)
        var darkSettings = model.settings
        darkSettings.appearanceRaw = AppAppearance.dark.rawValue
        model.applySettings(darkSettings)
        XCTAssertEqual(model.settings.resolvedAppearance, .dark)
        XCTAssertEqual(model.effectiveAppearance, .dark)
        XCTAssertNil(model.appearancePreview)
    }

    @MainActor
    func testApplyingAccentUpdatesTheLiveThemeRuntime() {
        let previous = LocusAccentRuntime.shared.currentSelection()
        defer { LocusAccentRuntime.shared.configure(previous) }

        let model = AppModel(startImmediately: false)
        var updated = model.settings
        updated.accentPresetRaw = LocusAccentPreset.blue.rawValue
        model.applySettings(updated, showConfirmation: false)

        XCTAssertEqual(model.settings.resolvedAccent.preset, .blue)
        XCTAssertEqual(LocusAccentRuntime.shared.currentSelection().preset, .blue)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                XCTFail("Missing test appearance \(appearanceName.rawValue)")
                continue
            }
            var actionHex: String?
            var successHex: String?
            appearance.performAsCurrentDrawingAppearance {
                actionHex = LocusAccentSelection.hexString(for: NSColor(LocusTheme.signalDeep))
                successHex = LocusAccentSelection.hexString(for: NSColor(LocusTheme.success))
            }
            let expectedHex = LocusAccentSelection.hexString(
                for: model.settings.resolvedAccent.actionNSColor(for: appearance)
            )
            XCTAssertEqual(actionHex, expectedHex)
            XCTAssertEqual(successHex, expectedHex)
        }
    }

    // MARK: - Provider accounts

    /// Adds an account through the real save path, with its key, and cleans up
    /// the local credential-file entry afterwards.
    @MainActor
    private func seedAccount(
        _ model: AppModel,
        kind: ProviderKind,
        name: String,
        preferredModel: String = "",
        key: String = "sk-test"
    ) -> ProviderAccount {
        let account = ProviderAccount(kind: kind, name: name, preferredModel: preferredModel)
        model.saveProviderAccount(account, apiKey: key)
        addTeardownBlock { CredentialStore.remove(account: account.credentialAccount) }
        return model.providerAccounts.first { $0.id == account.id } ?? account
    }

    /// A minimal profile for the workspace under test. Seeded explicitly because
    /// profiles are read from the real defaults even with persistence off.
    private func seededProfile(path: String) -> WorkspaceProfile {
        WorkspaceProfile(
            path: path,
            lastOpened: Date(),
            model: "",
            accountID: nil,
            mode: .grill,
            previewURL: "",
            contextFiles: [],
            draft: ""
        )
    }

    @MainActor
    private func providerHandoffService(
        host: String = "provider-handoff.test"
    ) -> BackendService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderHandoffURLProtocol.self]
        return BackendService(
            baseURL: URL(string: "http://\(host)")!,
            authToken: "test",
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func providerHandoffModel() -> AppModel {
        AppModel(startImmediately: false, backendOverride: providerHandoffService())
    }

    @MainActor
    func testSavingAProxyPublishesItBeforeAnythingCanUseIt() {
        let model = AppModel(startImmediately: false)
        XCTAssertNil(ProxyRuntime.shared.current, "a test model starts with no proxy")

        var updated = model.settings
        updated.proxyModeRaw = ProxyMode.manual.rawValue
        updated.proxyHost = "  HTTP://Proxy.Corp:9/  "
        updated.proxyPort = 3128
        model.applySettings(updated)

        // The snapshot is what every session and the relaunched agent read, so
        // it has to be current the moment applySettings returns — not after
        // the restart it kicks off.
        XCTAssertEqual(ProxyRuntime.shared.current?.host, "proxy.corp")
        XCTAssertEqual(ProxyRuntime.shared.current?.port, 3128)
        XCTAssertEqual(model.settings.proxyHost, "  HTTP://Proxy.Corp:9/  ",
                       "normalization is the settings sheet's job, not applySettings'")

        var cleared = model.settings
        cleared.proxyModeRaw = ProxyMode.off.rawValue
        model.applySettings(cleared)
        XCTAssertNil(ProxyRuntime.shared.current, "switching off must not leave a live proxy behind")
    }

    @MainActor
    func testProviderRequestBodyCarriesTheAccountCredentials() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(
            model,
            kind: .claude,
            name: "Work",
            preferredModel: "claude-sonnet-4-5",
            key: "sk-ant-secret"
        )

        // Local until an account is chosen.
        XCTAssertEqual(model.providerRequestBody()["provider"] as? String, "ollama")
        XCTAssertNil(model.providerRequestBody()["api_key"])

        model.settings.activeAccountID = account.id.uuidString
        let body = model.providerRequestBody()

        XCTAssertEqual(body["provider"] as? String, "remote")
        XCTAssertEqual(body["base_url"] as? String, "https://api.anthropic.com/v1")
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(body["api_key"] as? String, "sk-ant-secret")
        XCTAssertEqual(body["auth_style"] as? String, "anthropic")
        XCTAssertEqual(body["account_label"] as? String, "Claude — Work")
    }

    @MainActor
    func testSuccessfulConnectionTestReappliesTheSavedActiveCredential() async {
        let model = providerHandoffModel()
        let account = seedAccount(
            model,
            kind: .kimiCode,
            name: "Membership",
            preferredModel: "k3",
            key: "kimi-saved-key"
        )
        model.settings.activeAccountID = account.id.uuidString

        let followUp = await model.reconnectAfterSuccessfulConnectionTest(
            account: account,
            usedSavedCredential: true
        )

        XCTAssertEqual(followUp, .reconnected)
        XCTAssertEqual(
            ProviderHandoffURLProtocol.providerBodies.last?["api_key"] as? String,
            "kimi-saved-key"
        )
        XCTAssertEqual(model.accountStatus[account.id], .keySaved)
    }

    @MainActor
    func testNewChatWorkerReceivesSavedKeyBeforeProviderReadinessCheck() async {
        let model = providerHandoffModel()
        let account = seedAccount(
            model,
            kind: .kimiCode,
            name: "Membership",
            preferredModel: "k3",
            key: "kimi-worker-key"
        )
        model.settings.activeAccountID = account.id.uuidString

        let failure = await model.prepareChatWorkerProvider(
            using: providerHandoffService(host: "chat-worker-provider.test")
        )

        XCTAssertNil(failure)
        let workerPaths = ProviderHandoffURLProtocol.paths.filter {
            $0.hasPrefix("chat-worker-provider.test")
        }
        XCTAssertEqual(Array(workerPaths.prefix(2)), [
            "chat-worker-provider.test/api/provider",
            "chat-worker-provider.test/api/health",
        ])
        XCTAssertEqual(
            ProviderHandoffURLProtocol.providerBodies.last(where: {
                $0["__test_host"] as? String == "chat-worker-provider.test"
            })?["api_key"] as? String,
            "kimi-worker-key"
        )
    }

    @MainActor
    func testNewChatWorkerRejectsAnAnsweringButUnreadyProvider() async {
        let model = providerHandoffModel()
        let account = seedAccount(
            model,
            kind: .kimiCode,
            name: "Membership",
            preferredModel: "k3",
            key: "kimi-worker-key"
        )
        model.settings.activeAccountID = account.id.uuidString
        ProviderHandoffURLProtocol.providerReady = false
        ProviderHandoffURLProtocol.providerError = "no API key is loaded for this provider"

        let failure = await model.prepareChatWorkerProvider(
            using: providerHandoffService(host: "chat-worker-provider.test")
        )

        XCTAssertEqual(failure, "no API key is loaded for this provider")
        let workerPaths = ProviderHandoffURLProtocol.paths.filter {
            $0.hasPrefix("chat-worker-provider.test")
        }
        XCTAssertEqual(Array(workerPaths.prefix(2)), [
            "chat-worker-provider.test/api/provider",
            "chat-worker-provider.test/api/health",
        ])
    }

    @MainActor
    func testSuccessfulDraftKeyTestRequiresSaveBeforeReconnect() async {
        let model = providerHandoffModel()
        let account = seedAccount(
            model,
            kind: .kimiCode,
            name: "Membership",
            preferredModel: "k3"
        )
        model.settings.activeAccountID = account.id.uuidString

        let followUp = await model.reconnectAfterSuccessfulConnectionTest(
            account: account,
            usedSavedCredential: false
        )

        XCTAssertEqual(followUp, .saveRequired)
        XCTAssertTrue(ProviderHandoffURLProtocol.providerBodies.isEmpty)
    }

    @MainActor
    func testFailedProviderHandoffIsReportedForRecovery() async {
        let model = providerHandoffModel()
        let account = seedAccount(
            model,
            kind: .kimiCode,
            name: "Membership",
            preferredModel: "k3"
        )
        model.settings.activeAccountID = account.id.uuidString
        ProviderHandoffURLProtocol.providerStatusCode = 503

        let followUp = await model.reconnectAfterSuccessfulConnectionTest(
            account: account,
            usedSavedCredential: true
        )

        XCTAssertEqual(followUp, .reconnectFailed)
        XCTAssertFalse(model.isModelOnline)
        XCTAssertTrue(model.accountStatus[account.id]?.summary.contains("temporarily unavailable") == true)
    }

    @MainActor
    func testCredentialWriteFailureDoesNotPublishAnAccount() {
        let model = AppModel(
            startImmediately: false,
            providerCredentialWriter: { _, _ in false }
        )
        let account = ProviderAccount(kind: .kimiCode, name: "Membership")

        XCTAssertFalse(model.saveProviderAccount(account, apiKey: "one-time-key"))
        XCTAssertTrue(model.providerAccounts.isEmpty)
        XCTAssertTrue(model.toastMessage?.contains("Could not save the API key") == true)
    }

    @MainActor
    func testChatGPTProviderRequestBodyContainsOnlyManagedAccountMetadata() {
        let model = AppModel(startImmediately: false)
        let account = ProviderAccount(
            kind: .chatGPT,
            name: "Personal",
            preferredModel: "gpt-5.3-codex"
        )
        model.saveProviderAccount(account, apiKey: "must-not-be-used")
        model.settings.activeAccountID = account.id.uuidString

        let body = model.providerRequestBody()

        XCTAssertEqual(body["provider"] as? String, "chatgpt")
        XCTAssertEqual(body["account_id"] as? String, account.id.uuidString)
        XCTAssertEqual(body["account_label"] as? String, "ChatGPT plan — Personal")
        XCTAssertEqual(body["model"] as? String, "gpt-5.3-codex")
        XCTAssertNil(body["api_key"])
        XCTAssertNil(body["base_url"])
        XCTAssertNil(body["context_window"])
        XCTAssertFalse(CredentialStore.has(account: account.credentialAccount))
    }

    @MainActor
    func testSeveralChatGPTPlanAccountsEachGetTheirOwnCredentialHome() {
        let model = AppModel(startImmediately: false)
        model.saveProviderAccount(ProviderAccount(kind: .chatGPT, name: "Work"), apiKey: nil)
        model.saveProviderAccount(ProviderAccount(kind: .chatGPT, name: "Personal"), apiKey: nil)

        let accounts = model.providerAccounts.filter { $0.kind == .chatGPT }
        XCTAssertEqual(accounts.map(\.name), ["Work", "Personal"])
        // The home is the identity. Two plans sharing one would mean signing
        // into the second silently replaced the first.
        let homes = accounts.map(\.codexHomeIdentifier)
        XCTAssertEqual(Set(homes).count, 2)
        XCTAssertFalse(homes.contains(""), "a new account must not claim the legacy home")
    }

    @MainActor
    func testAChatGPTAccountStoredBeforeMultiAccountKeepsTheOriginalHome() throws {
        // Decoding deliberately bypasses the initialiser that hands out homes:
        // an account written by an older build has no home of its own, and
        // moving it would sign the user out on upgrade.
        let stored = Data(#"""
        [{"id":"11111111-2222-3333-4444-555555555555","kindRaw":"chatgpt","name":"Existing",
          "preferredModel":"gpt-5","createdAt":0}]
        """#.utf8)
        let accounts = ProviderAccountStore.decode(stored)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertNil(accounts.first?.codexHomeID)
        XCTAssertEqual(accounts.first?.codexHomeIdentifier, "")
    }

    @MainActor
    func testChatGPTRoutingNamesTheAccountsOwnCredentialHome() {
        let model = AppModel(startImmediately: false)
        model.saveProviderAccount(ProviderAccount(kind: .chatGPT, name: "Work"), apiKey: nil)
        let account = try! XCTUnwrap(model.providerAccounts.first)
        model.settings.activeAccountID = account.id.uuidString

        let body = model.providerRequestBody()
        XCTAssertEqual(body["provider"] as? String, "chatgpt")
        XCTAssertEqual(body["account_id"] as? String, account.id.uuidString)
        XCTAssertEqual(body["codex_home_id"] as? String, account.codexHomeIdentifier)
        // All three always travel: the backend keeps its current value for a
        // missing field, so omitting one would freeze a stale choice. A newly
        // created account routes under the Locus contract, so parity is off.
        XCTAssertEqual(body["native_mode"] as? Bool, false)
        XCTAssertEqual(body["web_search"] as? Bool, false)
        XCTAssertEqual(body["reasoning_effort"] as? String, "")
    }

    @MainActor
    func testChatGPTRoutingCarriesTheStoredParityChoices() {
        let model = AppModel(startImmediately: false)
        var account = ProviderAccount(kind: .chatGPT, name: "Work")
        account.codexNativeMode = false
        account.codexWebSearch = true
        account.codexReasoningEffort = "xhigh"
        model.saveProviderAccount(account, apiKey: nil)
        model.settings.activeAccountID = account.id.uuidString

        let body = model.providerRequestBody()
        XCTAssertEqual(body["native_mode"] as? Bool, false)
        XCTAssertEqual(body["web_search"] as? Bool, true)
        XCTAssertEqual(body["reasoning_effort"] as? String, "xhigh")
    }

    @MainActor
    func testRemoteRouteSendsAnEffortOnlyForModelsThatAcceptOne() {
        // Sending an effort to a model without an effort control fails the turn
        // rather than being ignored, so the value is filtered against the same
        // published table the picker is drawn from.
        let model = AppModel(startImmediately: false)
        let account = seedAccount(
            model,
            kind: .claude,
            name: "Work",
            preferredModel: "claude-opus-5"
        )
        model.settings.activeAccountID = account.id.uuidString
        // Seeded explicitly: profiles are read from the real defaults even with
        // persistence off, so leaving this to the machine's own state would make
        // the test pass or fail depending on which workspaces it has open.
        model.workspaceProfiles = [seededProfile(path: model.workspacePath)]

        XCTAssertEqual(
            model.providerRequestBody()["reasoning_effort"] as? String, "",
            "no choice yet means the model's own default"
        )

        model.setReasoningEffort("xhigh")
        XCTAssertEqual(model.providerRequestBody()["reasoning_effort"] as? String, "xhigh")

        // The same stored choice against a model that takes no effort sends
        // nothing at all, instead of a value that endpoint would reject.
        var haiku = account
        haiku.preferredModel = "claude-haiku-4-5"
        model.saveProviderAccount(haiku, apiKey: nil)

        XCTAssertEqual(model.providerRequestBody()["reasoning_effort"] as? String, "")
        XCTAssertTrue(
            model.reasoningEffortOptions.isEmpty,
            "and the header picker is hidden for it"
        )
    }

    @MainActor
    func testChoosingAutoOverridesTheAccountsOwnDefaultEffort() {
        // The regression test for nil-versus-empty. A workspace that has never
        // chosen defers to the account; one that chose Auto has to beat it, or
        // picking Auto on a ChatGPT account with a stored effort does nothing.
        let model = AppModel(startImmediately: false)
        var account = ProviderAccount(kind: .chatGPT, name: "Work")
        account.preferredModel = "gpt-5.3-codex"
        account.codexReasoningEffort = "high"
        model.saveProviderAccount(account, apiKey: nil)
        model.settings.activeAccountID = account.id.uuidString
        model.workspaceProfiles = [seededProfile(path: model.workspacePath)]

        XCTAssertEqual(
            model.resolvedReasoningEffort, "high",
            "no workspace choice defers to the account"
        )

        model.setReasoningEffort("")

        XCTAssertEqual(model.resolvedReasoningEffort, "")
        XCTAssertEqual(
            model.providerRequestBody()["reasoning_effort"] as? String, "",
            "and the model's own default is what gets sent"
        )
    }

    @MainActor
    func testAnEffortTheChatGPTCatalogDoesNotListIsNotSent() {
        // The choice belongs to the workspace, so it outlives a switch between
        // accounts: "max" set on a Claude model is still stored when the same
        // workspace routes to a ChatGPT plan, which tops out at "xhigh".
        let model = AppModel(startImmediately: false)
        var account = ProviderAccount(kind: .chatGPT, name: "Work")
        account.preferredModel = "gpt-5.3-codex"
        model.saveProviderAccount(account, apiKey: nil)
        model.settings.activeAccountID = account.id.uuidString
        var profile = seededProfile(path: model.workspacePath)
        profile.reasoningEffort = "max"
        model.workspaceProfiles = [profile]

        // With no catalog yet there is nothing to check against, and the helper
        // is the authority — the choice travels rather than being dropped.
        XCTAssertEqual(model.providerRequestBody()["reasoning_effort"] as? String, "max")

        model.applyAccountModelCatalogForTesting(
            [
                ChatGPTModelsResponse.Model(
                    id: "gpt-5.3-codex",
                    displayName: "GPT-5.3 Codex",
                    description: "",
                    isDefault: true,
                    supportedReasoningEfforts: [
                        .init(effort: "low", description: nil),
                        .init(effort: "high", description: nil),
                        .init(effort: "xhigh", description: nil),
                    ],
                    defaultReasoningEffort: "high"
                )
            ],
            for: account.id
        )

        XCTAssertEqual(
            model.providerRequestBody()["reasoning_effort"] as? String, "",
            "an effort this model rejects would fail the turn, so send none"
        )
    }

    @MainActor
    func testProviderRequestBodySendsTheUsersWindowAndThePublishedOneSeparately() {
        // The regression test for the bug at the layer that caused it. These two
        // facts used to be collapsed into one field, so our own table's figure
        // reached the agent looking like a number the user had pinned — and a
        // stale entry could then outrank what the endpoint reported about itself.
        let model = AppModel(startImmediately: false)
        let account = seedAccount(
            model,
            kind: .claude,
            name: "Work",
            preferredModel: "claude-sonnet-5"
        )
        model.settings.activeAccountID = account.id.uuidString

        var body = model.providerRequestBody()
        XCTAssertEqual(body["context_window"] as? Int, 0, "the user pinned nothing")
        XCTAssertEqual(body["published_context_window"] as? Int, 1_000_000)

        var withWindow = account
        withWindow.contextWindow = 64_000
        model.saveProviderAccount(withWindow, apiKey: nil)
        body = model.providerRequestBody()

        XCTAssertEqual(body["context_window"] as? Int, 64_000)
        XCTAssertEqual(
            body["published_context_window"] as? Int, 1_000_000,
            "both travel: the agent clamps one by the other"
        )
    }

    @MainActor
    func testSwitchingAccountsMidTurnIsHeldUntilTheTurnFinishes() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(model, kind: .kimi, name: "", preferredModel: "kimi-k2")
        model.isBusy = true

        model.selectModel(account: account, model: "kimi-k2")

        // The agent refuses to swap its client mid-turn, so nothing moves yet.
        XCTAssertNil(model.settings.activeAccountID)
        XCTAssertEqual(model.settings.provider, .ollama)

        model.isBusy = false
        model.applyPendingProviderSwitchIfNeeded()

        XCTAssertEqual(model.settings.activeAccountID, account.id.uuidString)
        XCTAssertEqual(model.settings.provider, .remote)
    }

    @MainActor
    func testAProviderSwitchTheAgentRejectsDoesNotLeaveTheAccountSelected() async {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(model, kind: .kimiCode, name: "Kimi", preferredModel: "k3")

        model.selectModel(account: account, model: "k3")
        // The route is committed up front because the provider request body is
        // built from it.
        XCTAssertEqual(model.settings.activeAccountID, account.id.uuidString)

        // No agent is listening, so the provider call fails. The app must fall
        // back to the route that is still live rather than claim this one.
        for _ in 0..<80 where model.settings.activeAccountID != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(
            model.settings.activeAccountID,
            "an account the agent never adopted must not stay selected"
        )
        XCTAssertEqual(model.settings.provider, .ollama)
    }

    @MainActor
    func testTheClosedPickerNeverPairsAnAccountWithAnotherProvidersModel() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(model, kind: .kimiCode, name: "Kimi", preferredModel: "k3")
        model.settings.activeAccountID = account.id.uuidString
        model.settings.provider = .remote
        // What the agent reports while it is still on the previous route.
        model.sessionInfo = SessionInfo(
            model: "gpt-5.6-sol", host: "h", cwd: "/tmp", session: "s", sessionID: "s",
            messages: 1, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            contextLimit: 0, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )

        XCTAssertEqual(
            model.modelPickerLabel, "Kimi · k3",
            "the chip must not advertise a route that does not exist"
        )
        XCTAssertEqual(model.routedModel(for: account), "k3")

        // Once the agent is really on this account, its own report wins.
        model.sessionInfo = SessionInfo(
            model: "kimi-for-coding", host: "h", cwd: "/tmp", session: "s", sessionID: "s",
            messages: 1, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            contextLimit: 0, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )
        XCTAssertEqual(model.modelPickerLabel, "Kimi · kimi-for-coding")
    }

    @MainActor
    func testChoosingAnAccountWithNoKeyOpensSettingsInsteadOfSwitching() {
        let model = AppModel(startImmediately: false)
        let account = ProviderAccount(kind: .codex, name: "Unconfigured")
        model.saveProviderAccount(account, apiKey: nil)

        model.selectModel(account: account, model: "gpt-5")

        XCTAssertNil(model.settings.activeAccountID, "an account with no key cannot be used")
        XCTAssertTrue(model.settingsPresented)
    }

    @MainActor
    func testRemovingTheActiveAccountFallsBackToLocalOllama() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(model, kind: .claude, name: "Personal")
        model.settings.activeAccountID = account.id.uuidString
        model.settings.provider = .remote

        model.removeProviderAccount(account)

        XCTAssertFalse(model.providerAccounts.contains { $0.id == account.id })
        XCTAssertNil(model.settings.activeAccountID)
        XCTAssertEqual(model.settings.provider, .ollama)
        XCTAssertNil(CredentialStore.get(account: account.credentialAccount), "the key goes with it")
    }

    @MainActor
    func testTheCurrentRouteDistinguishesAccountsOfferingTheSameModel() {
        let model = AppModel(startImmediately: false)
        let work = seedAccount(model, kind: .claude, name: "Work")
        let personal = seedAccount(model, kind: .claude, name: "Personal")
        model.settings.activeAccountID = work.id.uuidString
        model.sessionInfo = nil
        model.models = [
            ModelInfo(name: "claude-sonnet-4-5", size: 0, parameterSize: "", contextLength: 0)
        ]

        XCTAssertTrue(model.isCurrentRoute(account: work, model: "claude-sonnet-4-5"))
        XCTAssertFalse(model.isCurrentRoute(account: personal, model: "claude-sonnet-4-5"))
        XCTAssertFalse(model.isCurrentRoute(account: nil, model: "claude-sonnet-4-5"))
        XCTAssertEqual(model.modelPickerLabel, "Work · claude-sonnet-4-5")
    }

    @MainActor
    func testModelPickerLabelShowsTheSelectedTeamAndDistinctModelCount() {
        let model = AppModel(startImmediately: false)
        let dispatcher = AgentProfile(
            name: "Dispatcher",
            model: "qwen",
            role: .dispatcher
        )
        let planner = AgentProfile(name: "Planner", model: "qwen", role: .planner)
        let writer = AgentProfile(
            name: "Writer",
            model: "kimi",
            role: .implementer,
            accessCeiling: .workspaceWrite
        )
        model.agentTeamsModel.saveAgentProfile(dispatcher)
        model.agentTeamsModel.saveAgentProfile(planner)
        model.agentTeamsModel.saveAgentProfile(writer)
        let team = AgentTeam(
            name: "Codex Team",
            dispatcherID: dispatcher.id,
            fallbackDispatcherID: nil,
            memberIDs: [dispatcher.id, planner.id, writer.id],
            defaultWriterID: writer.id
        )
        model.agentTeamsModel.saveAgentTeam(team)
        model.agentTeamsModel.selectAgentTeam(team.id)

        XCTAssertEqual(model.selectedTeamModelNames, ["qwen", "kimi"])
        XCTAssertEqual(model.modelPickerLabel, "Codex Team · 2 models")
    }

    @MainActor
    func testDuplicateAccountNamesAreResolvedOnSave() {
        let model = AppModel(startImmediately: false)
        _ = seedAccount(model, kind: .claude, name: "Work")
        let second = seedAccount(model, kind: .claude, name: "Work")

        XCTAssertEqual(model.providerAccounts.count, 2)
        XCTAssertEqual(second.name, "Work 2")
        XCTAssertEqual(Set(model.providerAccounts.map(\.displayName)).count, 2)
    }

    @MainActor
    func testProviderLabelNamesTheAccountInUse() {
        let model = AppModel(startImmediately: false)
        model.modelRuntimePhase = .online
        XCTAssertEqual(model.providerLabel, "Ollama ready")

        let account = seedAccount(model, kind: .claude, name: "Work")
        model.settings.activeAccountID = account.id.uuidString
        XCTAssertEqual(model.providerLabel, "Claude ready")
    }

    @MainActor
    func testSessionFilteringFindsPreviewText() {
        let model = AppModel(startImmediately: false)
        model.sessions = [
            SessionSummary(
                id: "one",
                name: "one.json",
                preview: "Fix authentication redirect",
                mtime: 1,
                size: 10
            ),
            SessionSummary(
                id: "two",
                name: "two.json",
                preview: "Polish onboarding",
                mtime: 2,
                size: 20
            ),
        ]

        model.searchQuery = "auth"
        XCTAssertEqual(model.filteredSessions.map(\.id), ["one"])
    }

    @MainActor
    func testCheckpointCapturesCurrentSessionState() {
        let previousCheckpoints = UserDefaults.standard.data(forKey: "Locus.checkpoints")
        defer {
            if let previousCheckpoints {
                UserDefaults.standard.set(previousCheckpoints, forKey: "Locus.checkpoints")
            } else {
                UserDefaults.standard.removeObject(forKey: "Locus.checkpoints")
            }
        }
        UserDefaults.standard.removeObject(forKey: "Locus.checkpoints")
        let model = AppModel(startImmediately: false)
        model.blocks = [ChatBlock(kind: .user, text: "Make the header calmer")]
        model.todos = [TodoItem(content: "Audit header", status: .pending)]
        model.handleEventForTesting([
            "type": "plan_ready",
            "plan": [
                "id": "checkpoint-plan",
                "title": "Header plan",
                "summary": "",
                "steps": ["Audit header"],
                "tests": [],
            ],
        ])

        model.createCheckpoint(title: "Before header pass")

        XCTAssertEqual(model.checkpoints.first?.title, "Before header pass")
        XCTAssertEqual(model.checkpoints.first?.blocks.count, 1)
        XCTAssertEqual(model.checkpoints.first?.todos.count, 1)
        XCTAssertEqual(model.checkpoints.first?.activePlan?.title, "Header plan")
    }

    @MainActor
    func testClearAcknowledgementChangesSessionAndClearsTransientUI() {
        let model = AppModel(startImmediately: false)
        model.blocks = [ChatBlock(kind: .user, text: "old conversation")]
        model.todos = [TodoItem(content: "old task", status: .pending)]

        model.handleEventForTesting([
            "type": "session_started",
            "reason": "clear_chat",
            "session_info": sessionInfo(id: "fresh-session"),
        ])

        XCTAssertEqual(model.currentSessionID, "fresh-session")
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertTrue(model.todos.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testRetryAcknowledgementBranchesAtLatestUserMessage() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .user, text: "first"),
            ChatBlock(kind: .assistant, text: "one"),
            ChatBlock(kind: .user, text: "second"),
            ChatBlock(kind: .assistant, text: "two"),
        ]

        model.handleEventForTesting([
            "type": "session_started",
            "reason": "retry",
            "session_info": sessionInfo(id: "retry-branch"),
        ])

        XCTAssertEqual(model.currentSessionID, "retry-branch")
        XCTAssertEqual(model.blocks.map(\.text), ["first", "one", "second"])
        XCTAssertTrue(model.isBusy)
    }

    @MainActor
    func testPromptHistoryNavigatesSubmittedPrompts() {
        let model = AppModel(startImmediately: false)
        model.promptHistory = ["newest", "older"]

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "newest")
        model.previousPrompt()
        XCTAssertEqual(model.draftText, "older")
        model.nextPrompt()
        XCTAssertEqual(model.draftText, "newest")
        model.nextPrompt()
        XCTAssertTrue(model.draftText.isEmpty)
    }

    /// A `CADisplayLink` goes quiet whenever its display does — asleep,
    /// unplugged, or a Mac running with the lid shut — without cancelling
    /// itself or reporting anything. A flush that only waited for the next
    /// frame would then wait forever, and since a pending request suppresses
    /// further ones, streamed text stopped appearing until something flushed
    /// directly. This is that machine, which no test host can otherwise be.
    @MainActor
    func testStreamStillFlushesWhenNoDisplayFrameEverArrives() async throws {
        var flushes = 0
        let driver = DisplaySynchronizedFlushDriver(synchronizesWithDisplay: false) {
            flushes += 1
        }
        driver.request()
        XCTAssertEqual(flushes, 0, "the flush must still coalesce, not run per request")

        try await Task.sleep(
            for: .milliseconds(DisplaySynchronizedFlushDriver.frameDeadlineMilliseconds * 3)
        )
        XCTAssertEqual(flushes, 1, "a dark display left the flush waiting for a frame forever")

        // And it keeps working: the watchdog is re-armed per request rather
        // than being a one-shot that leaves the next flush stranded.
        driver.request()
        try await Task.sleep(
            for: .milliseconds(DisplaySynchronizedFlushDriver.frameDeadlineMilliseconds * 3)
        )
        XCTAssertEqual(flushes, 2)

        // A cancelled request must not fire late and flush a stream that has
        // already been committed.
        driver.request()
        driver.cancelPending()
        try await Task.sleep(
            for: .milliseconds(DisplaySynchronizedFlushDriver.frameDeadlineMilliseconds * 3)
        )
        XCTAssertEqual(flushes, 2)
        driver.invalidate()
    }

    @MainActor
    func testTwoThousandStreamTokensAreBuffered() async throws {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start"])

        for _ in 0..<2_000 {
            model.handleEventForTesting(["type": "token", "text": "x"])
        }
        XCTAssertEqual(model.streamRevision, 0)

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertLessThanOrEqual(model.streamRevision, 2)
        XCTAssertEqual(model.streamingReply.snapshot.text.count, 2_000)
        XCTAssertTrue(model.blocks.last?.text.isEmpty == true)
        model.handleEventForTesting(["type": "message_end"])
        XCTAssertEqual(model.blocks.last?.text.count, 2_000)
        XCTAssertLessThanOrEqual(model.streamRevision, 3)
    }

    @MainActor
    func testErrorEventFinalizesStreamingBlock() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "partial"])
        model.handleEventForTesting(["type": "error", "message": "model crashed"])

        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.blocks.contains(where: \.isStreaming))
        XCTAssertEqual(model.blocks.last?.kind, .error)

        model.handleEventForTesting(["type": "turn_done", "reason": "error"])
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testCommandErrorDoesNotEndTheActiveTurn() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "still streaming"])

        model.handleEventForTesting([
            "type": "command_error",
            "operation": "set_model",
            "message": "Agent is busy",
        ])

        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.blocks.contains(where: \.isStreaming))
        XCTAssertEqual(model.blocks.last?.kind, .error)
    }

    @MainActor
    func testTurnDoneWithoutMessageEndFinalizesStreamingBlock() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "partial"])
        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.blocks.contains(where: \.isStreaming))
        XCTAssertEqual(model.blocks.last?.text, "partial")
    }

    @MainActor
    func testTokensWithoutMessageStartCreateAssistantBlock() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "token", "text": "orphan"])
        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertEqual(model.blocks.last?.kind, .assistant)
        XCTAssertEqual(model.blocks.last?.text, "orphan")
    }

    @MainActor
    func testSendWhileBusyQueuesInsteadOfDropping() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.isBusy = true

        model.send("follow-up request")

        XCTAssertEqual(model.queuedMessages, ["follow-up request"])
        model.removeQueuedMessage(at: 0)
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    @MainActor
    func testQueueDrainsAfterTurnDone() async throws {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.isBusy = true
        model.send("queued message")
        XCTAssertEqual(model.queuedMessages.count, 1)

        model.draftText = "typed while waiting"
        model.handleEventForTesting(["type": "turn_done"])
        try await Task.sleep(for: .milliseconds(200))

        // With no live socket the drained message returns to the queue —
        // writing it into the draft would destroy what the user typed since.
        XCTAssertEqual(model.queuedMessages, ["queued message"])
        XCTAssertEqual(model.draftText, "typed while waiting")
    }

    @MainActor
    func testHistoryRecallPreservesUnsentDraft() {
        let model = AppModel(startImmediately: false)
        model.promptHistory = ["older prompt"]
        model.draftText = "work in progress"

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "older prompt")
        XCTAssertTrue(model.isBrowsingPromptHistory)

        model.nextPrompt()
        XCTAssertEqual(model.draftText, "work in progress")
        XCTAssertFalse(model.isBrowsingPromptHistory)
    }

    @MainActor
    func testHistoryCursorResetsWhenDraftEdited() {
        let model = AppModel(startImmediately: false)
        model.promptHistory = ["first", "second"]

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "first")
        model.draftText = "first edited"
        XCTAssertFalse(model.isBrowsingPromptHistory)

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "first")
    }

    @MainActor
    func testLocalSlashCommandExecutesWithoutSending() {
        let model = AppModel(startImmediately: false)
        model.draftText = "/plan"

        model.send("/plan")

        XCTAssertEqual(model.selectedMode, .plan)
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.draftText.isEmpty)
    }

    @MainActor
    func testWorkSlashCommandReturnsToAdaptiveMode() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .grill

        model.send("/work")

        XCTAssertEqual(model.selectedMode, .work)
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testPermissionRequestWithoutProposalStillShowsCard() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-1",
            "tool": "write_file",
            "request_id": "req-9",
        ])

        XCTAssertTrue(model.hasPendingPermission)
        XCTAssertEqual(model.blocks.last?.tool?.requestID, "req-9")
        XCTAssertEqual(model.activePermissionRequest?.requestID, "req-9")
    }

    @MainActor
    func testPermissionRequestWithoutRequestIDDoesNotLockTheUI() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-x",
            "tool": "bash",
        ])

        XCTAssertFalse(
            model.hasPendingPermission,
            "an unanswerable request must not arm the state that disables send and clear"
        )
        XCTAssertNil(model.activePermissionRequest)
        XCTAssertEqual(model.blocks.last?.kind, .error)
    }

    @MainActor
    func testPermissionRequestAttachesToTheNewestMatchingCard() {
        let model = AppModel(startImmediately: false)
        for _ in 0..<2 {
            model.handleEventForTesting([
                "type": "tool_call_proposed",
                "id": "t-dup",
                "tool": "bash",
                "summary": "$ ls",
                "auto": true,
            ])
        }

        model.handleEventForTesting([
            "type": "permission_request",
            "id": "t-dup",
            "tool": "bash",
            "request_id": "req-2",
        ])

        XCTAssertNil(model.blocks[0].tool?.requestID)
        XCTAssertEqual(model.blocks[1].tool?.requestID, "req-2")
    }

    @MainActor
    func testPermissionRequestUpgradePublishesTheToolCardChange() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "tool_call_proposed",
            "id": "t-1",
            "tool": "bash",
            "summary": "$ make",
            "auto": false,
        ])
        let revisionBefore = model.streamRevision

        model.handleEventForTesting([
            "type": "permission_request",
            "id": "t-1",
            "tool": "bash",
            "request_id": "req-1",
        ])

        XCTAssertGreaterThan(
            model.streamRevision, revisionBefore,
            "an in-place upgrade must still publish its changed status"
        )
    }

    @MainActor
    func testPermissionRequestReadsNestedPreviewFallback() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-p",
            "tool": "bash",
            "request_id": "req-p",
            "preview": ["summary": "$ ls", "detail": "ls -la"],
        ])

        XCTAssertEqual(model.blocks.last?.tool?.summary, "$ ls")
        XCTAssertEqual(model.blocks.last?.tool?.detail, "ls -la")
    }

    @MainActor
    func testActivePermissionRequestAdvancesOldestFirst() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "t1", tool: "bash", summary: "$ a", detail: "",
                status: .awaitingPermission, requestID: "req-1"
            )),
            ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "t2", tool: "bash", summary: "$ b", detail: "",
                status: .awaitingPermission, requestID: "req-2"
            )),
        ]

        XCTAssertEqual(model.activePermissionRequest?.requestID, "req-1")

        model.blocks[0].tool?.status = .running
        XCTAssertEqual(model.activePermissionRequest?.requestID, "req-2")

        model.blocks[1].tool?.status = .denied
        XCTAssertNil(model.activePermissionRequest)
    }

    @MainActor
    func testClearChatConfirmedRefusesWhilePermissionPending() {
        let model = AppModel(startImmediately: false)
        model.blocks = [ChatBlock(kind: .user, text: "hello")]
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-1",
            "tool": "bash",
            "request_id": "req-1",
        ])

        model.clearChatConfirmed()

        XCTAssertTrue(model.hasPendingPermission)
        XCTAssertEqual(model.blocks.first?.text, "hello", "the transcript must survive")
        XCTAssertNotNil(model.toastMessage)
    }

    @MainActor
    func testTurnDoneResolvesDanglingPermissionCards() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-1",
            "tool": "bash",
            "request_id": "req-1",
        ])
        XCTAssertTrue(model.hasPendingPermission)

        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertFalse(model.hasPendingPermission, "no card may stay awaiting after the turn ends")
        XCTAssertEqual(model.blocks.last?.tool?.status, .error)
    }

    @MainActor
    func testTodoUpdateBadgesTheTabInsteadOfSwitchingToIt() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.terminal)

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])

        XCTAssertEqual(model.inspectorTab, .terminal, "a run must not yank the panel")
        XCTAssertTrue(model.planHasUnseenUpdate)

        model.selectInspectorTab(.plan)
        XCTAssertFalse(model.planHasUnseenUpdate, "opening the tab clears the badge")
    }

    func testChangesBadgeOnlyLightsForPathsTheUserHasNotSeen() {
        let seen = GitChange(path: "Locus/AppModel.swift", status: .modified)
        let fresh = GitChange(path: "README.md", status: .modified)

        XCTAssertFalse(
            GitWorkspaceModel.changesAreUnseen(
                previous: ["Locus/AppModel.swift"],
                current: [seen, fresh],
                changesTabVisible: true
            ),
            "nothing is unseen while the user is looking straight at it"
        )
        XCTAssertTrue(
            GitWorkspaceModel.changesAreUnseen(
                previous: ["Locus/AppModel.swift"],
                current: [seen, fresh],
                changesTabVisible: false
            )
        )
        XCTAssertFalse(
            GitWorkspaceModel.changesAreUnseen(
                previous: ["Locus/AppModel.swift"],
                current: [seen],
                changesTabVisible: false
            ),
            "re-editing a file you already know about must not re-badge"
        )
    }

    @MainActor
    func testProposedToolNoLongerHijacksTheInspector() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.files)

        model.handleEventForTesting([
            "type": "tool_call_proposed",
            "id": "t1",
            "tool": "write_file",
            "summary": "write a.txt",
            "auto": true,
        ])

        XCTAssertEqual(model.inspectorTab, .files)
    }

    @MainActor
    func testSelectingATabExpandsACollapsedInspector() {
        let model = AppModel(startImmediately: false)
        model.inspectorCollapsed = true

        model.selectInspectorTab(.changes)

        XCTAssertFalse(model.inspectorCollapsed)
        XCTAssertEqual(model.inspectorTab, .changes)
        XCTAssertEqual(model.openInspectorTabs, [.changes])
        XCTAssertEqual(model.settings.inspectorLastTab, "changes")
        XCTAssertEqual(model.settings.inspectorOpenTabs, ["changes"])
    }

    @MainActor
    func testSelectingInspectorTabsAppendsInOpeningOrderWithoutDuplicates() {
        let model = AppModel(startImmediately: false)

        model.selectInspectorTab(.changes)
        model.selectInspectorTab(.files)
        model.selectInspectorTab(.plan)
        model.selectInspectorTab(.files)

        XCTAssertEqual(model.openInspectorTabs, [.changes, .files, .plan])
        XCTAssertEqual(model.inspectorTab, .files)
        XCTAssertEqual(model.settings.inspectorOpenTabs, ["changes", "files", "plan"])
    }

    @MainActor
    func testSelectingLegacyCheckpointDestinationOpensManagerWithoutAddingATab() {
        let model = AppModel(startImmediately: false)

        model.selectInspectorTab(.checkpoints)

        XCTAssertTrue(model.checkpointPresented)
        XCTAssertFalse(model.openInspectorTabs.contains(.checkpoints))
    }

    @MainActor
    func testClosingInspectorTabsSelectsRightThenLeftAndCollapsesWhenEmpty() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.changes)
        model.selectInspectorTab(.files)
        model.selectInspectorTab(.plan)

        model.selectInspectorTab(.files)
        model.closeInspectorTab(.files)
        XCTAssertEqual(model.openInspectorTabs, [.changes, .plan])
        XCTAssertEqual(model.inspectorTab, .plan, "the tab to the right fills the closed slot")
        XCTAssertFalse(model.inspectorCollapsed)

        model.closeInspectorTab(.plan)
        XCTAssertEqual(model.openInspectorTabs, [.changes])
        XCTAssertEqual(model.inspectorTab, .changes, "the rightmost tab falls back to its left")

        model.closeInspectorTab(.changes)
        XCTAssertTrue(model.openInspectorTabs.isEmpty)
        XCTAssertTrue(model.inspectorCollapsed)
        XCTAssertEqual(model.inspectorTab, .changes, "the last destination remains available to reopen")
    }

    @MainActor
    func testClosingAnInactiveInspectorTabKeepsTheCurrentSelection() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.changes)
        model.selectInspectorTab(.files)
        model.selectInspectorTab(.plan)

        model.closeInspectorTab(.changes)

        XCTAssertEqual(model.openInspectorTabs, [.files, .plan])
        XCTAssertEqual(model.inspectorTab, .plan)
        XCTAssertFalse(model.inspectorCollapsed)
    }

    @MainActor
    func testGeneralInspectorButtonRestoresWorkspaceTabInsteadOfPlanOrBrowser() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.files)
        model.selectInspectorTab(.preview)

        model.toggleInspector()

        XCTAssertEqual(model.inspectorTab, .files)
        XCTAssertFalse(model.inspectorCollapsed)

        model.toggleInspector()
        XCTAssertTrue(model.inspectorCollapsed, "a second press on the workspace panel closes it")

        model.toggleInspector()
        XCTAssertEqual(model.inspectorTab, .files)
        XCTAssertFalse(model.inspectorCollapsed)
    }

    @MainActor
    func testPanelToggleDefaultsToOverviewAndReopensTheLastClosedTab() {
        let untouched = AppModel(startImmediately: false)
        untouched.inspectorCollapsed = true

        untouched.toggleInspectorPanel()

        XCTAssertEqual(untouched.inspectorTab, .plan)
        XCTAssertFalse(untouched.inspectorCollapsed)

        let restored = AppModel(startImmediately: false)
        restored.selectInspectorTab(.simulator)
        restored.closeInspectorTab(.simulator)
        XCTAssertTrue(restored.inspectorCollapsed)
        XCTAssertTrue(restored.openInspectorTabs.isEmpty)

        restored.toggleInspectorPanel()

        XCTAssertEqual(restored.inspectorTab, .simulator)
        XCTAssertEqual(restored.openInspectorTabs, [.simulator])
        XCTAssertFalse(restored.inspectorCollapsed)

        restored.toggleInspectorPanel()
        XCTAssertTrue(restored.inspectorCollapsed)
        restored.toggleInspectorPanel()
        XCTAssertEqual(restored.inspectorTab, .simulator)
        XCTAssertFalse(restored.inspectorCollapsed)
    }

    @MainActor
    func testSoloAndTeamInspectorChoicesAreAskedAndPersistedIndependently() {
        let model = AppModel(startImmediately: false)
        model.inspectorCollapsed = true

        model.presentInspectorForSentRequest(isTeam: false)

        XCTAssertEqual(model.automaticInspectorPrompt?.tab, .plan)
        XCTAssertTrue(model.inspectorCollapsed, "the one-time question decides whether to open")

        model.answerAutomaticInspectorPrompt(showEveryTime: true)
        XCTAssertEqual(
            model.settings.resolvedSoloPlanPresentation,
            .always
        )
        XCTAssertEqual(model.settings.resolvedTeamRunsPresentation, .ask)
        XCTAssertNil(model.automaticInspectorPrompt)
        XCTAssertEqual(model.inspectorTab, .plan)
        XCTAssertEqual(model.openInspectorTabs, [.plan])
        XCTAssertFalse(model.inspectorCollapsed)

        model.inspectorCollapsed = true
        model.presentInspectorForSentRequest(isTeam: true, runID: "run-1")
        XCTAssertEqual(model.automaticInspectorPrompt?.tab, .runs)
        XCTAssertTrue(model.inspectorCollapsed, "the team choice has not been answered yet")

        model.answerAutomaticInspectorPrompt(showEveryTime: false)
        XCTAssertEqual(model.settings.resolvedTeamRunsPresentation, .never)
        XCTAssertEqual(model.settings.resolvedSoloPlanPresentation, .always)
    }

    @MainActor
    func testRunsDeepLinksSelectDetailWhileGeneralNavigationReturnsToList() {
        let model = AppModel(startImmediately: false)

        model.selectInspectorTab(.runs, selecting: "solo-swarm-1")
        XCTAssertEqual(model.runsNavigationRequest?.runID, "solo-swarm-1")
        XCTAssertFalse(model.inspectorCollapsed)

        model.selectInspectorTab(.runs)
        XCTAssertNil(model.runsNavigationRequest)
    }

    @MainActor
    func testDecliningSoloInspectorStillAsksAboutTeamRuns() {
        let model = AppModel(startImmediately: false)
        model.inspectorCollapsed = true
        model.presentInspectorForSentRequest(isTeam: false)

        model.answerAutomaticInspectorPrompt(showEveryTime: false)
        model.presentInspectorForSentRequest(isTeam: true, runID: "run-2")

        XCTAssertEqual(model.settings.resolvedSoloPlanPresentation, .never)
        XCTAssertEqual(model.settings.resolvedTeamRunsPresentation, .ask)
        XCTAssertTrue(model.inspectorCollapsed)
        XCTAssertEqual(model.automaticInspectorPrompt?.tab, .runs)
    }

    @MainActor
    func testJustChatDoesNotConsumeAutomaticInspectorChoice() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .ask

        model.presentInspectorForSentRequest(isTeam: false)

        XCTAssertNil(model.automaticInspectorPrompt)
        XCTAssertEqual(model.settings.resolvedSoloPlanPresentation, .ask)
        XCTAssertEqual(model.settings.resolvedTeamRunsPresentation, .ask)
    }

    func testSoloAndTeamInspectorPromptsHaveDistinctSettingsAwareCopy() {
        let solo = AutomaticInspectorPrompt(tab: .plan, runID: nil)
        let team = AutomaticInspectorPrompt(tab: .runs, runID: "run-3")

        XCTAssertNotEqual(solo.title, team.title)
        XCTAssertNotEqual(solo.message, team.message)
        XCTAssertTrue(solo.title.contains("Context & Plan"))
        XCTAssertTrue(team.title.contains("team requests"))
        XCTAssertTrue(solo.message.contains("Settings → General → Conversation"))
        XCTAssertTrue(team.message.contains("Settings → General → Conversation"))
    }

    @MainActor
    func testDefaultBusySubmissionQueuesForTheNextTurn() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.draftText = "Run this after the current task"

        model.submitDraft()

        XCTAssertEqual(model.queuedMessages, ["Run this after the current task"])
        XCTAssertTrue(model.draftText.isEmpty)
    }

    @MainActor
    func testInspectorWidthPersistsOnlyWhenCommitted() {
        let model = AppModel(startImmediately: false)
        let original = model.settings.inspectorWidth

        model.setInspectorWidth(700)
        XCTAssertEqual(model.inspectorWidth, 520, "clamped to the maximum")
        XCTAssertEqual(model.settings.inspectorWidth, original, "a drag must not persist per frame")

        model.commitInspectorWidth()
        XCTAssertEqual(model.settings.inspectorWidth, 520)
    }

    @MainActor
    func testZoomOpensThePanelAndCollapseClearsZoom() {
        let model = AppModel(startImmediately: false)
        model.inspectorCollapsed = true

        model.setInspectorZoomed(true)
        XCTAssertFalse(model.inspectorCollapsed, "zooming opens a collapsed panel first")
        XCTAssertTrue(model.inspectorZoomed)

        model.inspectorCollapsed = true
        XCTAssertFalse(model.inspectorZoomed, "closing the panel never leaves a hidden-but-zoomed limbo")
    }

    @MainActor
    func testToggleInspectorTabCollapsesOnSecondClickAndSwitchesOtherwise() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.plan)
        XCTAssertFalse(model.inspectorCollapsed)

        model.toggleInspectorTab(.preview)
        XCTAssertEqual(model.inspectorTab, .preview, "a different tab switches without collapsing")
        XCTAssertFalse(model.inspectorCollapsed)

        model.toggleInspectorTab(.preview)
        XCTAssertTrue(model.inspectorCollapsed, "the open tab's own icon closes the panel")
        XCTAssertEqual(model.openInspectorTabs, [.plan, .preview], "collapsing does not close tabs")

        model.toggleInspectorTab(.preview)
        XCTAssertFalse(model.inspectorCollapsed, "and reopens it")
        XCTAssertEqual(model.inspectorTab, .preview)
        XCTAssertEqual(model.openInspectorTabs, [.plan, .preview])
    }

    @MainActor
    func testZoomBorrowsTheSidebarAndGivesItBack() {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = false

        model.setInspectorZoomed(true)
        XCTAssertTrue(model.sidebarCollapsed, "zoom borrows the sidebar's room")

        model.setInspectorZoomed(false)
        XCTAssertFalse(model.sidebarCollapsed, "un-zooming returns what zoom took")
    }

    @MainActor
    func testZoomsBorrowedSidebarCollapseIsNeverPersisted() {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = false
        XCTAssertFalse(model.settings.sidebarCollapsed)

        model.setInspectorZoomed(true)
        XCTAssertTrue(model.sidebarCollapsed, "the borrow is visual")
        XCTAssertFalse(
            model.settings.sidebarCollapsed,
            "the borrow must not reach settings — a quit-while-zoomed would otherwise lose the sidebar for good"
        )

        model.setInspectorZoomed(false)
        XCTAssertFalse(model.sidebarCollapsed)
        XCTAssertFalse(model.settings.sidebarCollapsed)
    }

    @MainActor
    func testZoomLeavesAUserReopenedSidebarAlone() {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = false

        model.setInspectorZoomed(true)
        model.sidebarCollapsed = false

        model.setInspectorZoomed(false)
        XCTAssertFalse(model.sidebarCollapsed, "the user's explicit reopen stands")
    }

    @MainActor
    func testZoomDoesNotReopenASidebarTheUserAlreadyKeptClosed() {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = true

        model.setInspectorZoomed(true)
        model.setInspectorZoomed(false)
        XCTAssertTrue(model.sidebarCollapsed, "zoom only returns what it actually took")
    }

    @MainActor
    func testZoomedChatWidthPersistsOnlyWhenCommitted() {
        let model = AppModel(startImmediately: false)
        let original = model.settings.inspectorZoomedChatWidth

        model.setZoomedChatWidth(50)
        XCTAssertEqual(model.zoomedChatWidth, 360, "clamped to the minimum")
        XCTAssertEqual(
            model.settings.inspectorZoomedChatWidth,
            original,
            "a drag must not persist per frame"
        )

        model.commitZoomedChatWidth()
        XCTAssertEqual(model.settings.inspectorZoomedChatWidth, 360)
    }

    @MainActor
    func testZoomIsInertInJustChatAndClearedByEnteringIt() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.preview)
        model.setInspectorZoomed(true)

        model.setJustChatEnabled(true)
        XCTAssertFalse(model.inspectorZoomed, "Just Chat clears the zoom with the panel")

        model.setInspectorZoomed(true)
        XCTAssertFalse(model.inspectorZoomed, "zoom stays inert in Just Chat")

        model.setJustChatEnabled(false)
        XCTAssertFalse(model.inspectorCollapsed, "leaving Just Chat restores the open panel")
        XCTAssertFalse(model.inspectorZoomed, "restored open, never zoomed")
    }

    @MainActor
    func testBackendNoteEventsBecomeVisibleBlocks() {
        let model = AppModel(startImmediately: false)

        model.handleEventForTesting([
            "type": "note",
            "text": "Context is nearly full — compacting the conversation.",
        ])
        model.handleEventForTesting(["type": "note", "text": "went wrong", "error": true])
        model.handleEventForTesting(["type": "note", "text": "   "])

        XCTAssertEqual(model.blocks.count, 2, "blank notes must not create blocks")
        XCTAssertEqual(model.blocks.first?.kind, .note)
        XCTAssertEqual(model.blocks.last?.kind, .error)
    }

    @MainActor
    func testThinkingEventIsStoredSeparatelyFromTheAnswer() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "thinking", "text": "weighing options"])
        model.handleEventForTesting(["type": "token", "text": "answer"])
        model.handleEventForTesting(["type": "message_end"])

        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks.first?.text, "answer")
        XCTAssertEqual(model.blocks.first?.reasoningText, "weighing options")
    }

    @MainActor
    func testStructuredAssistantItemsKeepReasoningCommentaryAndFinalAnswerSeparate() {
        let model = AppModel(startImmediately: false)

        model.handleEventForTesting([
            "type": "assistant_item_start", "item_id": "reason-1", "kind": "reasoning",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_delta", "item_id": "reason-1", "kind": "reasoning",
            "section_index": 0, "text": "draft",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_end", "item_id": "reason-1", "kind": "reasoning",
            "sections": ["**Loading skill**", "**Fetching data**"],
        ])
        model.handleEventForTesting([
            "type": "assistant_item_start", "item_id": "commentary-1", "kind": "message",
            "phase": "commentary",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_delta", "item_id": "commentary-1", "kind": "message",
            "phase": "commentary", "text": "Using **weather**.",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_end", "item_id": "commentary-1", "kind": "message",
            "phase": "commentary", "text": "Using **weather** to check.",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_delta", "item_id": "final-1", "kind": "message",
            "text": "joined draft",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_end", "item_id": "final-1", "kind": "message",
            "phase": "final_answer", "text": "- **Seoul:** 25°C\n- **Dubai:** 33°C",
        ])

        XCTAssertEqual(model.blocks.count, 3)
        XCTAssertEqual(model.blocks[0].sourceItemID, "reason-1")
        XCTAssertEqual(model.blocks[0].reasoningSections, ["**Loading skill**", "**Fetching data**"])
        XCTAssertEqual(model.blocks[0].reasoningText, "**Loading skill**\n\n**Fetching data**")
        XCTAssertEqual(model.blocks[1].assistantPhase, .commentary)
        XCTAssertEqual(model.blocks[1].text, "Using **weather** to check.")
        XCTAssertEqual(model.blocks[2].assistantPhase, .finalAnswer)
        XCTAssertEqual(model.blocks[2].text, "- **Seoul:** 25°C\n- **Dubai:** 33°C")
        XCTAssertFalse(model.blocks.contains(where: \.isStreaming))

        let presentation = TranscriptPresentation.items(
            from: model.blocks,
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )
        guard case .thinkingGroup(_, let entries) = presentation.first else {
            return XCTFail("reasoning should remain a distinct thought-process group")
        }
        XCTAssertEqual(entries.map(\.text), ["**Loading skill**", "**Fetching data**"])
        XCTAssertEqual(presentation.compactMap { item -> AssistantPhase? in
            guard case .assistantSegment(let segment) = item else { return nil }
            return segment.sourceBlock.assistantPhase
        }, [.commentary, .finalAnswer])
    }

    @MainActor
    func testStructuredItemCompletionIsAuthoritativeAndIdempotent() {
        let model = AppModel(startImmediately: false)
        let completion: [String: Any] = [
            "type": "assistant_item_end", "item_id": "final-1", "kind": "message",
            "text": "- first item",
        ]

        model.handleEventForTesting([
            "type": "assistant_item_delta", "item_id": "final-1", "kind": "message",
            "text": "partial without a start",
        ])
        model.handleEventForTesting(completion)
        model.handleEventForTesting(completion)

        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].text, "- first item")
        XCTAssertEqual(model.blocks[0].sourceItemID, "final-1")
        XCTAssertEqual(model.blocks[0].assistantPhase, .finalAnswer)
    }

    @MainActor
    func testInterruptedStructuredItemFinalizesPartialSections() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "assistant_item_start", "item_id": "reason-partial", "kind": "reasoning",
        ])
        model.handleEventForTesting([
            "type": "assistant_item_delta", "item_id": "reason-partial", "kind": "reasoning",
            "section_index": 0, "text": "**Partial summary**",
        ])

        model.handleEventForTesting(["type": "turn_done", "reason": "interrupted"])

        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].sourceItemID, "reason-partial")
        XCTAssertEqual(model.blocks[0].reasoningSections, ["**Partial summary**"])
        XCTAssertFalse(model.blocks[0].isStreaming)
    }

    @MainActor
    func testHundredKilobyteStreamIsCoalescedIntoOneActiveRow() async throws {
        let model = AppModel(startImmediately: false)
        let historical = (0..<160).map { index in
            ChatBlock(kind: index.isMultiple(of: 2) ? .user : .assistant, text: "History \(index)")
        }
        model.blocks = historical
        let historicalIDs = model.blocks.map(\.id)
        model.handleEventForTesting(["type": "message_start"])

        let chunk = String(repeating: "x", count: 100)
        for _ in 0..<1_000 {
            model.handleEventForTesting(["type": "token", "text": chunk])
        }
        XCTAssertEqual(model.streamRevision, 0, "token events stay buffered until the display refresh")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(model.streamingReply.snapshot.text.count, 100_000)
        XCTAssertTrue(model.blocks.last?.text.isEmpty == true)
        XCTAssertEqual(Array(model.blocks.dropLast()).map(\.id), historicalIDs)
        XCTAssertEqual(model.streamRevision, 0, "active text does not republish the transcript array")

        model.handleEventForTesting(["type": "message_end"])
        XCTAssertEqual(model.blocks.last?.text.count, 100_000)
    }

    @MainActor
    func testPreviewURLRequiresARealHost() {
        let model = AppModel(startImmediately: false)
        model.settings.previewURL = ""
        XCTAssertNil(model.normalizedPreviewURL)
        model.settings.previewURL = "localhost:3000"
        XCTAssertEqual(model.normalizedPreviewURL?.host, "localhost")
    }

    func testSessionPreviewStripsPromptDecoration() {
        XCTAssertEqual(
            SessionSummary.cleanPreview(
                "[Locus mode: Build]\nImplement the request.\n\nUser request:\nFix the login flow"
            ),
            "Fix the login flow"
        )
        XCTAssertEqual(SessionSummary.cleanPreview("Plain preview"), "Plain preview")
        XCTAssertEqual(SessionSummary.cleanPreview("[Locus mode: Build]\nImplement the requ"), "")
    }

    @MainActor
    func testPinnedSessionsSortFirst() {
        let model = AppModel(startImmediately: false)
        model.sessions = [
            SessionSummary(id: "new", name: "n", preview: "p", mtime: 100, size: 1),
            SessionSummary(id: "pinned-old", name: "n", preview: "p", mtime: 1, size: 1, pinned: true),
        ]
        XCTAssertEqual(model.filteredSessions.map(\.id), ["pinned-old", "new"])
    }

    // MARK: - Correctness fixes

    @MainActor
    func testCompactCommandDoesNotRecurse() {
        // /compact used to be re-sent through send(), which re-matched the
        // slash command and recursed until the stack overflowed.
        let model = AppModel(startImmediately: false)
        model.send("/compact")

        XCTAssertTrue(model.blocks.isEmpty, "not connected, so nothing was sent")
        XCTAssertFalse(model.isBusy)
        XCTAssertNotNil(model.toastMessage)
    }

    @MainActor
    func testStopWithoutConnectionKeepsBusyStateForRecovery() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true

        model.stop()

        XCTAssertTrue(
            model.isBusy,
            "an undeliverable interrupt leaves cleanup to recoverFromLostConnection"
        )
        XCTAssertNotNil(model.toastMessage)
    }

    @MainActor
    func testOrphanToolResultBecomesAVisibleCard() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "tool_result",
            "id": "never-proposed",
            "ok": true,
            "result": "42 files checked",
        ])

        XCTAssertEqual(model.blocks.last?.tool?.status, .done)
        XCTAssertEqual(model.blocks.last?.tool?.result, "42 files checked")
    }

    @MainActor
    func testGitRefreshFailureKeepsTheLastKnownChanges() throws {
        let model = AppModel(startImmediately: false)
        let response = try JSONDecoder().decode(
            GitStatusResponse.self,
            from: Data(#"{"is_repo": true, "branch": "main", "files": [{"path": "a.swift"}]}"#.utf8)
        )
        model.gitWorkspace.applyStatus(response)
        XCTAssertEqual(model.gitWorkspace.gitChanges.map(\.path), ["a.swift"])
        XCTAssertFalse(model.gitWorkspace.lastGitRefreshFailed)

        model.gitWorkspace.applyStatusFailure()
        XCTAssertEqual(model.gitWorkspace.gitChanges.map(\.path), ["a.swift"], "a transient failure must not wipe the list")
        XCTAssertTrue(model.gitWorkspace.lastGitRefreshFailed)

        model.gitWorkspace.applyStatus(response)
        XCTAssertFalse(model.gitWorkspace.lastGitRefreshFailed, "a successful refresh clears the stale flag")
    }

    func testRemoteEndpointBaseURLNormalization() {
        XCTAssertEqual(
            RemoteEndpointTester.normalizeBaseURL("https://x.aws.endpoints.huggingface.cloud"),
            "https://x.aws.endpoints.huggingface.cloud/v1"
        )
        XCTAssertEqual(RemoteEndpointTester.normalizeBaseURL("example.com/v1/"), "https://example.com/v1")
        XCTAssertEqual(
            RemoteEndpointTester.normalizeBaseURL("https://example.com/v1/chat/completions"),
            "https://example.com/v1"
        )
        XCTAssertEqual(
            RemoteEndpointTester.normalizeBaseURL("https://api.anthropic.com/v1/messages"),
            "https://api.anthropic.com/v1"
        )
        XCTAssertEqual(RemoteEndpointTester.normalizeBaseURL("   "), "")
    }

    func testProviderCredentialsRequireHTTPSExceptOnLoopback() {
        XCTAssertNotNil(
            RemoteEndpointTester.securityError(
                baseURL: "http://provider.example/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNil(
            RemoteEndpointTester.securityError(
                baseURL: "http://127.0.0.1:8000/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNotNil(
            RemoteEndpointTester.securityError(
                baseURL: "http://127.attacker.example/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNil(
            RemoteEndpointTester.securityError(
                baseURL: "https://provider.example/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNotNil(
            RemoteEndpointTester.securityError(
                baseURL: "https://name:secret@provider.example/v1",
                apiKey: ""
            )
        )
    }

    func testLocalBackendCapabilityIsFreshAndHeaderSafe() {
        XCTAssertEqual(BackendSecurity.header, "X-Locus-Token")
        XCTAssertEqual(BackendSecurity.launchToken.count, 32)
        XCTAssertNil(BackendSecurity.launchToken.range(of: "[^A-Fa-f0-9]", options: .regularExpression))
    }

    func testQueryValuesEncodeCharactersStarletteWouldMangle() {
        XCTAssertEqual(BackendService.encodeQueryValue("a&b+c=d?e"), "a%26b%2Bc%3Dd%3Fe")
        XCTAssertEqual(BackendService.encodeQueryValue("Sub dir/héllo.swift"), "Sub%20dir/h%C3%A9llo.swift")
        XCTAssertEqual(BackendService.encodeQueryValue("plain.swift"), "plain.swift")
    }

    // MARK: - Git quick actions

    func testGitClientRoundTripsARealRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "locus-gitclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GitClient(workspaceRoot: root.path)

        try await client.run(["init", "-q"])
        try await client.run(["config", "user.email", "tests@example.invalid"])
        try await client.run(["config", "user.name", "Locus Tests"])
        // A hostile-ish filename: the space and ampersand exercise the
        // literal-pathspec handling end to end.
        try "hello\n".write(
            to: root.appending(path: "a & b.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await client.run(["add", "--", "a & b.txt"])
        let staged = try await client.run(["status", "--porcelain"])
        XCTAssertTrue(staged.stdout.contains("a & b.txt"), "unexpected status: \(staged.stdout)")

        try await client.run(["commit", "-q", "-m", "Add a & b"])
        let clean = try await client.run(["status", "--porcelain"])
        XCTAssertTrue(clean.stdout.isEmpty)
    }

    func testGitClientThrowsStderrForFailedCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "locus-gitclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GitClient(workspaceRoot: root.path)

        do {
            try await client.run(["status"])  // not a repository
            XCTFail("expected a failure outside a repository")
        } catch let GitClientError.failed(command, stderr) {
            XCTAssertEqual(command, "status")
            XCTAssertFalse(stderr.isEmpty)
        } catch {
            XCTFail("expected a structured command failure, got \(error)")
        }
    }

    func testCommitDraftSanitizerStripsReasoningAndFences() {
        let raw = "<think>weighing the diff</think>\n```\nFix the login redirect\n```"
        XCTAssertEqual(CommitMessageDrafter.sanitize(raw), "Fix the login redirect")
        XCTAssertNil(CommitMessageDrafter.sanitize("<think>only thoughts</think>"))
        XCTAssertEqual(CommitMessageDrafter.sanitize("\"Quoted subject\""), "Quoted subject")

        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(CommitMessageDrafter.sanitize(long)?.count, 72, "the subject line is capped")
    }

    func testCommitTemplateSummarizesStagedChanges() {
        XCTAssertEqual(CommitMessageDrafter.template(for: []), "")

        let single = [GitChange(path: "Locus/AppModel.swift", status: .modified, staged: true)]
        XCTAssertEqual(CommitMessageDrafter.template(for: single), "Update AppModel.swift")

        let multiple = [
            GitChange(path: "a.swift", status: .modified, staged: true, additions: 3, deletions: 1),
            GitChange(path: "b.swift", status: .modified, staged: true, additions: 2, deletions: 0),
        ]
        let message = CommitMessageDrafter.template(for: multiple)
        XCTAssertTrue(message.hasPrefix("Update 2 files (+5 −1)"), "got: \(message)")
        XCTAssertTrue(message.contains("- a.swift"))
    }

    // MARK: - Transcript search

    @MainActor
    func testTranscriptSearchMatchesBlocksCaseInsensitivelyAndSkipsTools() {
        let model = AppModel(startImmediately: false)
        let userID = UUID()
        let assistantID = UUID()
        model.blocks = [
            ChatBlock(id: userID, kind: .user, text: "Fix the Login flow"),
            ChatBlock(id: assistantID, kind: .assistant, text: "The login bug is in AuthService."),
            ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "t1", tool: "bash", summary: "$ grep -r login", detail: "",
                status: .done
            )),
        ]
        model.transcriptSearchPresented = true
        model.transcriptSearchQuery = "LOGIN"

        XCTAssertEqual(model.transcriptSearchMatches, [userID, assistantID])
        XCTAssertEqual(model.currentTranscriptMatch, userID)
        XCTAssertEqual(model.transcriptMatchStyle(for: userID), .current)
        XCTAssertEqual(model.transcriptMatchStyle(for: assistantID), .other)
    }

    @MainActor
    func testTranscriptSearchWrapsInBothDirections() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .user, text: "alpha"),
            ChatBlock(kind: .assistant, text: "alpha again"),
        ]
        model.transcriptSearchPresented = true
        model.transcriptSearchQuery = "alpha"

        model.advanceTranscriptSearch(1)
        XCTAssertEqual(model.transcriptSearchSelection, 1)
        model.advanceTranscriptSearch(1)
        XCTAssertEqual(model.transcriptSearchSelection, 0, "forward wraps to the first match")
        model.advanceTranscriptSearch(-1)
        XCTAssertEqual(model.transcriptSearchSelection, 1, "backward wraps to the last match")
    }

    @MainActor
    func testTranscriptSearchSelectionSurvivesShrinkingResults() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .user, text: "match one"),
            ChatBlock(kind: .assistant, text: "match two"),
        ]
        model.transcriptSearchPresented = true
        model.transcriptSearchQuery = "match"
        model.advanceTranscriptSearch(1)

        // The transcript was cleared out from under an active search.
        model.blocks = [ChatBlock(kind: .user, text: "match one")]

        XCTAssertNotNil(model.currentTranscriptMatch, "a stale selection must clamp, not crash")
        model.advanceTranscriptSearch(1)
        XCTAssertEqual(model.transcriptSearchSelection, 0)

        model.closeTranscriptSearch()
        XCTAssertTrue(model.transcriptSearchQuery.isEmpty)
        XCTAssertNil(model.transcriptMatchStyle(for: model.blocks[0].id))
    }

    // MARK: - Thinking visibility

    func testThinkingSegmentsAreFilteredOnlyInHiddenMode() {
        let text = "<think>weighing options</think>The answer is 42."
        let hidden = AssistantSegment.rendered(from: text, mode: .hidden)
        XCTAssertEqual(hidden, [.visible("The answer is 42.")])

        for mode in [ThinkingVisibility.collapsed, .expanded] {
            XCTAssertEqual(
                AssistantSegment.rendered(from: text, mode: mode),
                AssistantSegment.parse(text),
                "only Hidden changes what renders — \(mode.rawValue) is presentation"
            )
        }
    }

    @MainActor
    func testThinkingSlashCommandSetsAndPersistsTheMode() {
        let model = AppModel(startImmediately: false)
        // Not asserted from a fresh model: AppModel(startImmediately: false)
        // still loads the machine's real stored settings, so the initial mode
        // is whatever the developer last used. Pin a baseline instead.
        model.thinkingVisibility = .collapsed
        XCTAssertEqual(model.thinkingVisibility, .collapsed)

        model.send("/thinking expanded")

        XCTAssertEqual(model.thinkingVisibility, .expanded)
        XCTAssertEqual(model.settings.thinkingVisibilityRaw, "expanded")
        XCTAssertTrue(model.blocks.isEmpty, "a local command must not send anything")

        model.send("/thinking sideways")
        XCTAssertEqual(model.thinkingVisibility, .expanded, "an unknown mode changes nothing")

        model.send("/thinking")
        XCTAssertEqual(model.blocks.last?.kind, .note, "no argument lists the modes")
    }

    func testUnknownStoredThinkingVisibilityFallsBackToCollapsed() throws {
        let future = #"{"thinkingVisibilityRaw": "telepathic"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(future.utf8))
        XCTAssertEqual(restored.resolvedThinkingVisibility, .collapsed)
    }

    // MARK: - Tool activity visibility

    func testToolActivityVisibilityDefaultsRoundTripsAndToleratesFutureValues() throws {
        XCTAssertEqual(AppSettings().resolvedToolActivityVisibility, .collapsed)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.resolvedToolActivityVisibility, .collapsed)

        var chosen = AppSettings()
        chosen.toolActivityVisibilityRaw = ToolActivityVisibility.hidden.rawValue
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(chosen)
        )
        XCTAssertEqual(restored.resolvedToolActivityVisibility, .hidden)

        let future = #"{"toolActivityVisibilityRaw":"summary-only"}"#
        let futureRestored = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(future.utf8)
        )
        XCTAssertEqual(futureRestored.resolvedToolActivityVisibility, .collapsed)
    }

    func testOptionalHeaderControlsDefaultOffAndRoundTrip() throws {
        let defaults = AppSettings()
        XCTAssertFalse(defaults.showTeamProgressInHeader)
        XCTAssertFalse(defaults.showContextUsageInHeader)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.showTeamProgressInHeader)
        XCTAssertFalse(legacy.showContextUsageInHeader)

        var enabled = AppSettings()
        enabled.showTeamProgressInHeader = true
        enabled.showContextUsageInHeader = true
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(enabled)
        )
        XCTAssertTrue(restored.showTeamProgressInHeader)
        XCTAssertTrue(restored.showContextUsageInHeader)
    }

    @MainActor
    func testToolActivityVisibilityAccessorUpdatesSettings() {
        let model = AppModel(startImmediately: false)
        model.toolActivityVisibility = .verbose
        XCTAssertEqual(model.toolActivityVisibility, .verbose)
        XCTAssertEqual(model.settings.toolActivityVisibilityRaw, "verbose")

        model.blocks = [ChatBlock(
            kind: .tool,
            tool: ToolPayload(
                toolID: "status-strip", tool: "bash", summary: "Run tests", detail: "swift test",
                status: .running
            )
        )]
        XCTAssertEqual(model.currentWorkPhase, "Using bash")
        model.toolActivityVisibility = .hidden
        XCTAssertEqual(model.currentWorkPhase, "Working…", "hidden mode must not leak tool metadata")
    }

    func testTranscriptProjectsInterleavedActivityAtItsSourcePosition() throws {
        let userID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000701"))
        let reasoningID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000702"))
        let commentaryID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000703"))
        let firstToolID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000704"))
        let secondToolID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000705"))
        let laterCommentaryID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000706"))
        let inlineID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000707"))
        let thirdToolID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000708"))
        let finalID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000709"))
        let completionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000070A"))

        let blocks = [
            ChatBlock(id: userID, kind: .user, text: "Audit this"),
            ChatBlock(
                id: reasoningID,
                kind: .assistant,
                reasoningSections: ["**Planning**", "Checking constraints"]
            ),
            ChatBlock(
                id: commentaryID,
                kind: .assistant,
                text: "I’m checking the workspace.",
                assistantPhase: .commentary
            ),
            ChatBlock(id: firstToolID, kind: .tool, tool: ToolPayload(
                toolID: "read", tool: "read_file", summary: "Read files", detail: "",
                status: .done
            )),
            ChatBlock(id: secondToolID, kind: .tool, tool: ToolPayload(
                toolID: "test", tool: "bash", summary: "Run tests", detail: "swift test",
                status: .awaitingPermission
            )),
            ChatBlock(
                id: laterCommentaryID,
                kind: .assistant,
                text: "The first checks are complete.",
                assistantPhase: .commentary
            ),
            ChatBlock(
                id: inlineID,
                kind: .assistant,
                text: "<think>Compare the results</think>I found one more edge case.",
                assistantPhase: .commentary
            ),
            ChatBlock(id: thirdToolID, kind: .tool, tool: ToolPayload(
                toolID: "browse", tool: "browser", summary: "Open preview", detail: "",
                status: .done
            )),
            ChatBlock(
                id: finalID,
                kind: .assistant,
                text: "Everything is ready.",
                assistantPhase: .finalAnswer
            ),
            ChatBlock(
                id: completionID,
                kind: .note,
                completion: TurnCompletion(
                    outcome: .complete,
                    mode: .work,
                    durationMilliseconds: 1_000
                )
            ),
        ]

        let collapsed = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )
        XCTAssertEqual(collapsed.map(\.id), [
            .block(userID),
            .thinkingGroup(.init(sourceBlockID: reasoningID, ordinal: 0)),
            .assistantSegment(.init(sourceBlockID: commentaryID, ordinal: 0)),
            .toolGroup(firstToolID),
            .assistantSegment(.init(sourceBlockID: laterCommentaryID, ordinal: 0)),
            .thinkingGroup(.init(sourceBlockID: inlineID, ordinal: 0)),
            .assistantSegment(.init(sourceBlockID: inlineID, ordinal: 0)),
            .toolGroup(thirdToolID),
            .assistantSegment(.init(sourceBlockID: finalID, ordinal: 0)),
            .block(completionID),
        ])

        guard case .toolGroup(_, let firstRun) = collapsed[3],
              case .toolGroup(_, let secondRun) = collapsed[7]
        else { return XCTFail("adjacent tool calls should form source-local runs") }
        XCTAssertEqual(firstRun.map(\.toolID), ["read", "test"])
        XCTAssertEqual(secondRun.map(\.toolID), ["browse"])
        XCTAssertEqual(ToolActivityAggregateStatus(tools: firstRun), .awaitingPermission)

        let expanded = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .collapsed,
            thinkingVisibility: .expanded
        )
        XCTAssertEqual(expanded, collapsed, "expanded thinking changes presentation, not order")

        let hidden = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .hidden,
            thinkingVisibility: .hidden
        )
        XCTAssertEqual(hidden.map(\.id), [
            .block(userID),
            .assistantSegment(.init(sourceBlockID: commentaryID, ordinal: 0)),
            .toolGroup(firstToolID),
            .assistantSegment(.init(sourceBlockID: laterCommentaryID, ordinal: 0)),
            .assistantSegment(.init(sourceBlockID: inlineID, ordinal: 0)),
            .toolGroup(thirdToolID),
            .assistantSegment(.init(sourceBlockID: finalID, ordinal: 0)),
            .block(completionID),
        ])

        let verbose = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .verbose,
            thinkingVisibility: .expanded
        )
        XCTAssertEqual(verbose.map(\.id), [
            .block(userID),
            .thinkingGroup(.init(sourceBlockID: reasoningID, ordinal: 0)),
            .assistantSegment(.init(sourceBlockID: commentaryID, ordinal: 0)),
            .block(firstToolID),
            .block(secondToolID),
            .assistantSegment(.init(sourceBlockID: laterCommentaryID, ordinal: 0)),
            .thinkingGroup(.init(sourceBlockID: inlineID, ordinal: 0)),
            .assistantSegment(.init(sourceBlockID: inlineID, ordinal: 0)),
            .block(thirdToolID),
            .assistantSegment(.init(sourceBlockID: finalID, ordinal: 0)),
            .block(completionID),
        ])
    }

    func testThoughtPresentationGroupsNativeAndInlineReasoningAndPreservesAnswers() throws {
        let userID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000721"))
        let nativeOnlyID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000722"))
        let mixedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000723"))
        let finalID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000724"))
        let completionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000725"))
        let nextUserID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000726"))
        let nextReasoningID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000727"))
        let blocks = [
            ChatBlock(id: userID, kind: .user, text: "Audit the workspace"),
            ChatBlock(id: nativeOnlyID, kind: .assistant, reasoningText: "Inspect files"),
            ChatBlock(
                id: mixedID,
                kind: .assistant,
                text: "<think>Compare results</think>Visible progress",
                reasoningText: "Choose the next check"
            ),
            ChatBlock(
                kind: .tool,
                tool: ToolPayload(
                    toolID: "read", tool: "read_file", summary: "Read files", detail: "",
                    status: .done
                )
            ),
            ChatBlock(
                id: finalID,
                kind: .assistant,
                text: "Before<thinking>Prepare response</thinking>After"
            ),
            ChatBlock(
                id: completionID,
                kind: .note,
                completion: TurnCompletion(
                    outcome: .complete,
                    mode: .work,
                    durationMilliseconds: 1_000
                )
            ),
            ChatBlock(id: nextUserID, kind: .user, text: "Continue"),
            ChatBlock(id: nextReasoningID, kind: .assistant, reasoningText: "Second request"),
        ]

        let collapsed = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .verbose,
            thinkingVisibility: .collapsed
        )
        let groups = collapsed.compactMap { item -> (ThinkingPresentationGroupID, [ThinkingPresentationEntry])? in
            guard case .thinkingGroup(let id, let entries) = item else { return nil }
            return (id, entries)
        }
        XCTAssertEqual(groups.map(\.0), [
            .init(sourceBlockID: nativeOnlyID, ordinal: 0),
            .init(sourceBlockID: mixedID, ordinal: 0),
            .init(sourceBlockID: mixedID, ordinal: 1),
            .init(sourceBlockID: finalID, ordinal: 0),
            .init(sourceBlockID: nextReasoningID, ordinal: 0),
        ])
        XCTAssertEqual(groups.map { $0.1.map(\.text) }, [
            ["Inspect files"],
            ["Choose the next check"],
            ["Compare results"],
            ["Prepare response"],
            ["Second request"],
        ])

        let visibleAssistants = collapsed.compactMap { item -> AssistantPresentationSegment? in
            guard case .assistantSegment(let segment) = item else { return nil }
            return segment
        }
        XCTAssertEqual(visibleAssistants.map(\.id), [
            .init(sourceBlockID: mixedID, ordinal: 0),
            .init(sourceBlockID: finalID, ordinal: 0),
            .init(sourceBlockID: finalID, ordinal: 1),
        ])
        XCTAssertEqual(visibleAssistants.map(\.text), ["Visible progress", "Before", "After"])
        XCTAssertTrue(visibleAssistants.allSatisfy { $0.displayBlock.reasoningText == nil })

        let expanded = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .verbose,
            thinkingVisibility: .expanded
        )
        XCTAssertEqual(expanded, collapsed, "expanded mode changes only how the group is rendered")

        let hidden = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .verbose,
            thinkingVisibility: .hidden
        )
        XCTAssertFalse(hidden.contains { item in
            if case .thinkingGroup = item { return true }
            return false
        })
        XCTAssertEqual(hidden.compactMap { item -> AssistantPresentationSegment.ID? in
            guard case .assistantSegment(let segment) = item else { return nil }
            return segment.id
        }, visibleAssistants.map(\.id))
        XCTAssertFalse(hidden.contains { item in
            item.sourceBlockIDs.contains(nativeOnlyID) || item.sourceBlockIDs.contains(nextReasoningID)
        })
    }

    func testToolActivityGroupIdentityAndStatusRemainStableAsCallsUpdate() throws {
        let userID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000711"))
        let firstToolBlockID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000712"))
        let secondToolBlockID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000713"))
        let commentaryID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000714"))
        let thirdToolBlockID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000715"))
        var blocks = [
            ChatBlock(id: userID, kind: .user, text: "Run checks"),
            ChatBlock(id: firstToolBlockID, kind: .tool, tool: ToolPayload(
                toolID: "one", tool: "bash", summary: "First check", detail: "",
                status: .running
            )),
        ]

        let firstProjection = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )
        guard case .toolGroup(let initialID, let initialTools) = firstProjection[1] else {
            return XCTFail("expected the initial tool group")
        }
        XCTAssertEqual(initialID, firstToolBlockID)
        XCTAssertEqual(ToolActivityAggregateStatus(tools: initialTools), .running)

        blocks[1].tool?.status = .error
        blocks.append(ChatBlock(id: secondToolBlockID, kind: .tool, tool: ToolPayload(
            toolID: "two", tool: "read_file", summary: "Fallback check", detail: "",
            status: .done
        )))

        let updatedProjection = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )
        guard case .toolGroup(let updatedID, let updatedTools) = updatedProjection[1] else {
            return XCTFail("expected the updated tool group")
        }
        XCTAssertEqual(updatedID, initialID)
        XCTAssertEqual(updatedTools.map(\.toolID), ["one", "two"])
        XCTAssertEqual(ToolActivityAggregateStatus(tools: updatedTools), .error)

        blocks.append(ChatBlock(
            id: commentaryID,
            kind: .assistant,
            text: "Checking another path",
            assistantPhase: .commentary
        ))
        blocks.append(ChatBlock(id: thirdToolBlockID, kind: .tool, tool: ToolPayload(
            toolID: "three", tool: "browser", summary: "Open preview", detail: "",
            status: .done
        )))
        let separatedProjection = TranscriptPresentation.items(
            from: blocks,
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )
        XCTAssertEqual(separatedProjection.compactMap { item -> UUID? in
            guard case .toolGroup(let id, _) = item else { return nil }
            return id
        }, [firstToolBlockID, thirdToolBlockID], "commentary ends an adjacent tool run")

        func statusTools(_ statuses: [ToolStatus]) -> [ToolPayload] {
            statuses.enumerated().map { index, status in
                ToolPayload(
                    toolID: "status-\(index)", tool: "tool", summary: "", detail: "",
                    status: status
                )
            }
        }
        XCTAssertEqual(ToolActivityAggregateStatus(tools: statusTools([.done])), .done)
        XCTAssertEqual(ToolActivityAggregateStatus(tools: statusTools([.done, .denied])), .denied)
        XCTAssertEqual(
            ToolActivityAggregateStatus(tools: statusTools([.done, .denied, .error])),
            .error
        )
        XCTAssertEqual(
            ToolActivityAggregateStatus(tools: statusTools([.done, .denied, .error, .running])),
            .running
        )
        XCTAssertEqual(
            ToolActivityAggregateStatus(
                tools: statusTools([.done, .denied, .error, .running, .awaitingPermission])
            ),
            .awaitingPermission,
            "attention and active states follow the documented precedence"
        )
    }

    func testCompactToolActivitySummaryUsesFirstSeenFamiliesAndFallbacks() {
        func tool(_ id: String, _ name: String, _ summary: String = "") -> ToolPayload {
            ToolPayload(
                toolID: id,
                tool: name,
                summary: summary,
                detail: "",
                status: .done
            )
        }

        let mixed = CompactToolActivitySummary(tools: [
            tool("read", "read_file"),
            tool("run", "bash"),
            tool("read-again", "list_dir"),
        ])
        XCTAssertEqual(mixed.title, "Read files, ran command")
        XCTAssertEqual(mixed.systemImage, "magnifyingglass")

        XCTAssertEqual(CompactToolActivitySummary(tools: [
            tool("q1", "request_user_input"),
            tool("q2", "request_user_input"),
            tool("q3", "request_user_input"),
        ]).title, "Asked 3 questions")
        XCTAssertEqual(CompactToolActivitySummary(tools: [
            tool("q1", "ask_user_question"),
        ]).title, "Asked a question")
        XCTAssertEqual(CompactToolActivitySummary(tools: [
            tool("e1", "apply_patch"),
            tool("e2", "edit_file"),
        ]).title, "Edited files")
        XCTAssertEqual(
            CompactToolActivitySummary(tools: [tool("custom", "sync_records", "**Synced records**")]).title,
            "Synced records"
        )
        XCTAssertEqual(
            CompactToolActivitySummary(tools: [tool("custom", "sync_records")]).title,
            "Used tools"
        )
    }

    // MARK: - Context window

    @MainActor
    func testContextWindowPrefersBackendContextLimit() {
        let model = AppModel(startImmediately: false)
        model.models = [
            ModelInfo(name: "qwen3:8b", size: 1, parameterSize: "8B", contextLength: 8_192),
        ]

        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        event["context_limit"] = 40_960
        model.handleEventForTesting(event)

        XCTAssertEqual(model.contextWindowTokens, 40_960, "the backend's limit is authoritative")
    }

    @MainActor
    func testContextWindowFallsBackToModelListThenUnknown() {
        let model = AppModel(startImmediately: false)
        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        model.handleEventForTesting(event)

        model.models = [
            ModelInfo(name: "qwen3:8b", size: 1, parameterSize: "8B", contextLength: 8_192),
        ]
        XCTAssertEqual(model.contextWindowTokens, 8_192)

        model.models = []
        XCTAssertNil(model.contextWindowTokens, "no invented 32k window")
        XCTAssertNil(model.contextWindowUsageFraction)
        XCTAssertEqual(
            model.contextBudgetTokens,
            Int(Double(AppModel.assumedContextWindowTokens) * 0.60),
            "the pack budget still needs a cap when the window is unknown"
        )
    }

    @MainActor
    func testContextUsageDoesNotDoubleCountTheContextPack() {
        let model = AppModel(startImmediately: false)
        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        event["approx_tokens"] = 1_000
        event["context_limit"] = 10_000
        model.handleEventForTesting(event)
        model.contextFiles = [
            ContextFile(
                url: URL(fileURLWithPath: "/tmp/pack.swift"),
                content: String(repeating: "x", count: 4_000)
            ),
        ]

        // The pack is embedded into user messages, so the backend's
        // approx_tokens already contains it — adding it again over-reads.
        XCTAssertEqual(model.contextUsedTokens, 1_000)
        XCTAssertEqual(model.contextWindowUsageFraction, 0.1)
    }

    @MainActor
    func testStreamingMovesTheContextMeterAndTurnDoneResetsIt() {
        let model = AppModel(startImmediately: false)
        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        event["approx_tokens"] = 1_000
        event["context_limit"] = 10_000
        model.handleEventForTesting(event)

        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": String(repeating: "y", count: 400)])
        model.handleEventForTesting(["type": "message_end"])

        XCTAssertEqual(model.contextUsedTokens, 1_100, "the streamed reply is estimated at chars/4")

        model.handleEventForTesting(["type": "turn_done"])
        XCTAssertEqual(model.contextUsedTokens, 1_000, "the real count takes over at the boundary")
    }

    @MainActor
    func testSessionInfoWithMissingFieldsStillDecodes() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "session_info", "session_id": "partial"])

        XCTAssertNotNil(model.sessionInfo, "one missing field must not silently disable the app")
        XCTAssertEqual(model.currentSessionID, "partial")
        XCTAssertEqual(model.sessionInfo?.contextLimit, 0)
    }

    func testModelInfoDecodesWithoutOptionalMetadata() throws {
        let data = Data(#"{"name": "hf.co/owner/repo:Q4_K_M"}"#.utf8)
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        XCTAssertEqual(info.name, "hf.co/owner/repo:Q4_K_M")
        XCTAssertEqual(info.contextLength, 0)
        XCTAssertEqual(info.trainedContextLength, 0)
    }

    func testModelPickerDetailComparesModelsByTrainedWindow() throws {
        // The agent reports the window in use (0 for a model that is not
        // loaded) separately from the trained maximum. The picker compares
        // models, so it shows the trained one; an older agent only sends
        // context_length, which fills in.
        let data = Data(#"""
        {"name": "qwen3:8b", "parameter_size": "8B",
         "context_length": 0, "trained_context_length": 262144}
        """#.utf8)
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        XCTAssertEqual(info.detail, "8B · 256k ctx")

        let legacy = ModelInfo(name: "old", size: 1, parameterSize: "3B", contextLength: 32_768)
        XCTAssertEqual(legacy.detail, "3B · 32k ctx")
    }

    func testHistoryMessageToleratesNullContent() throws {
        let data = Data(#"[{"role": "tool", "content": null, "name": "bash"}]"#.utf8)
        let messages = try JSONDecoder().decode([HistoryMessage].self, from: data)
        XCTAssertEqual(messages.first?.content, "")
        XCTAssertEqual(messages.first?.role, "tool")
    }

    // MARK: - Plan approval

    @MainActor
    func testJustChatToggleReturnsToThePreviousAgenticMode() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.selectInspectorTab(.files)
        XCTAssertFalse(model.inspectorCollapsed)

        model.setJustChatEnabled(true)
        XCTAssertTrue(model.justChatEnabled)
        XCTAssertEqual(model.selectedMode, .ask)
        XCTAssertTrue(model.inspectorCollapsed, "Just Chat closes the workspace inspector")

        model.selectInspectorTab(.changes)
        XCTAssertEqual(model.inspectorTab, .files, "inspector shortcuts stay inert in Just Chat")
        XCTAssertTrue(model.inspectorCollapsed)

        model.setJustChatEnabled(false)
        XCTAssertFalse(model.justChatEnabled)
        XCTAssertEqual(model.selectedMode, .plan)
        XCTAssertFalse(model.inspectorCollapsed, "leaving Just Chat restores the previously open inspector")
        XCTAssertEqual(model.inspectorTab, .files)
    }

    @MainActor
    func testJustChatKeepsInspectorClosedWhenItWasAlreadyClosed() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .grill
        model.inspectorCollapsed = true

        model.setJustChatEnabled(true)
        XCTAssertTrue(model.inspectorCollapsed)

        model.setJustChatEnabled(false)
        XCTAssertEqual(model.selectedMode, .grill)
        XCTAssertTrue(model.inspectorCollapsed, "leaving Just Chat preserves a previously closed inspector")
    }

    @MainActor
    func testCompletedWorkTurnAddsTimingMarkerAndFinishesTheActivePlanStep() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .work
        model.todos = [
            TodoItem(content: "Inspect the sidebar", status: .completed),
            TodoItem(content: "Add the completion cue", status: .inProgress),
            TodoItem(content: "Optional follow-up", status: .pending),
        ]

        model.handleEventForTesting([
            "type": "turn_done",
            "reason": "complete",
            "duration_ms": 84_000,
        ])

        XCTAssertEqual(model.todos.map(\.status), [.completed, .completed, .pending])
        let completion = model.blocks.last?.completion
        XCTAssertEqual(completion?.title, "Work finished")
        XCTAssertEqual(completion?.durationText, "1m 24s")
        XCTAssertEqual(completion?.outcome, .complete)
    }

    @MainActor
    func testInterruptedWorkTurnDoesNotClaimTheActivePlanStepFinished() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .work
        model.todos = [TodoItem(content: "Verify the app", status: .inProgress)]

        model.handleEventForTesting([
            "type": "turn_done",
            "reason": "interrupted",
            "duration_ms": 2_400,
        ])

        XCTAssertEqual(model.todos.first?.status, .inProgress)
        XCTAssertEqual(model.blocks.last?.completion?.title, "Stopped")
    }

    @MainActor
    func testCompletedPlanTurnOffersToImplementThePlan() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        XCTAssertTrue(model.planApprovalPending, "a finished plan is a decision point")
        XCTAssertEqual(model.planPanelPresentation.phase, .readyForApproval)
    }

    @MainActor
    func testPlanPanelTracksDraftingStepsAndApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.turnDispatchedMode = .plan
        model.isBusy = true

        XCTAssertEqual(model.planPanelPresentation.phase, .planning)
        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        XCTAssertEqual(model.planPanelPresentation.phase, .planning)

        model.handleEventForTesting([
            "type": "turn_done",
            "reason": "complete",
            "duration_ms": 3_000,
        ])

        XCTAssertEqual(model.planPanelPresentation.phase, .readyForApproval)
        XCTAssertEqual(model.activePlan?.steps, ["Audit the sidebar"])
    }

    @MainActor
    func testPlanPanelPreservesStoppedWorkPlan() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .work
        model.isBusy = true
        model.todos = [TodoItem(content: "Verify the app", status: .inProgress)]

        model.handleEventForTesting([
            "type": "turn_done",
            "reason": "interrupted",
            "duration_ms": 2_400,
        ])

        XCTAssertEqual(model.planPanelPresentation.phase, .stopped)
        XCTAssertEqual(model.planPanelPresentation.stoppedOutcome, .interrupted)
        XCTAssertEqual(model.todos.first?.status, .inProgress)
    }

    @MainActor
    func testStalePlanDoesNotReOfferAfterAChatTurn() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.todos = [TodoItem(content: "Left over from an earlier run", status: .pending)]

        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "only turns that wrote the plan may offer it")
    }

    @MainActor
    func testUnchangedTodoListIsNotAPlanReadyFallback() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.todos = [TodoItem(content: "Existing step", status: .pending)]
        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Existing step", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending)
    }

    @MainActor
    func testWorkTurnDoesNotOfferApprovalEvenAfterAMidRunSwitchToPlan() {
        let model = AppModel(startImmediately: false)
        // What send() latches when a turn is dispatched in Work mode.
        model.selectedMode = .work
        model.turnDispatchedInPlanMode = false

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Implement the header", "status": "in_progress"]],
        ])
        // Flipping the picker to Plan while the Work run streams must not
        // turn its todo bookkeeping into an "implement this plan?" offer.
        model.selectedMode = .plan
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "the offer keys off the dispatch mode, not the picker")
    }

    @MainActor
    func testPlanModeDispatchLatchesTheTurnMode() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online

        model.selectedMode = .plan
        model.send("Sketch the work")
        XCTAssertTrue(model.turnDispatchedInPlanMode)
    }

    @MainActor
    func testForwardedSlashTurnIsNeverAPlanDispatch() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.selectedMode = .plan

        model.send("/init")

        XCTAssertFalse(
            model.turnDispatchedInPlanMode,
            "agent-side slash commands are housekeeping, not plans to offer"
        )
    }

    @MainActor
    func testInterruptedPlanTurnDoesNotOfferApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "interrupted"])

        XCTAssertFalse(model.planApprovalPending, "a stopped run was already a decision")
    }

    @MainActor
    func testMaxIterationsPlanTurnDoesNotOfferApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "max_iterations"])

        XCTAssertFalse(model.planApprovalPending, "an exhausted turn's plan is unfinished")
    }

    @MainActor
    func testTurnDoneWithoutAReasonStillOffersApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertTrue(model.planApprovalPending, "an agent that omits the reason completed normally")
    }

    private static let questionReadyEvent: [String: Any] = [
        "type": "question_ready",
        "question": [
            "id": "q-1",
            "title": "Reddit scope",
            "question": "Site-wide feed or one subreddit?",
            "options": [
                ["label": "Site-wide /new feed", "detail": ""],
                "A subreddit argument",
            ],
            "recommended": "Site-wide /new feed",
        ] as [String: Any],
    ]

    @MainActor
    func testQuestionReadyArmsThePopupWhenTheTurnCompletes() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .grill
        model.isBusy = true

        model.handleEventForTesting(Self.questionReadyEvent)
        XCTAssertNil(model.pendingUserQuestion, "the popup waits for the turn to finish")

        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        let question = model.pendingUserQuestion
        XCTAssertEqual(question?.title, "Reddit scope")
        XCTAssertEqual(
            question?.options.map(\.label),
            ["Site-wide /new feed", "A subreddit argument"]
        )
        XCTAssertEqual(question?.recommendedOptionIndex, 0)
    }

    @MainActor
    func testInterruptedTurnNeverOffersItsQuestion() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .grill
        model.isBusy = true

        model.handleEventForTesting(Self.questionReadyEvent)
        model.handleEventForTesting(["type": "turn_done", "reason": "interrupted"])

        XCTAssertNil(model.pendingUserQuestion, "a stopped run was already a decision")

        // The captured question must not leak into the next turn either.
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])
        XCTAssertNil(model.pendingUserQuestion)
    }

    @MainActor
    func testGrillTurnFallsBackToDetectingTheQuestionBlock() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .grill
        model.isBusy = true
        model.blocks.append(ChatBlock(
            kind: .assistant,
            text: "❓ **Q1** - **Scope**: Site-wide feed or one subreddit?\n\n➡️ Site-wide"
        ))

        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertEqual(model.pendingUserQuestion?.title, "Scope")
        XCTAssertEqual(model.pendingUserQuestion?.recommended, "Site-wide")
    }

    @MainActor
    func testWorkTurnsDoNotSniffQuestionsFromText() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .work
        model.isBusy = true
        model.blocks.append(ChatBlock(
            kind: .assistant,
            text: "❓ **Q1** - **Scope**: Site-wide feed or one subreddit?\n\n➡️ Site-wide"
        ))

        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertNil(model.pendingUserQuestion, "the fallback is Grill's contract, not Work's")
    }

    @MainActor
    func testStructuredQuestionOutranksPlanApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.turnDispatchedMode = .plan
        model.isBusy = true

        model.handleEventForTesting([
            "type": "plan_ready",
            "plan": [
                "id": "p-1", "title": "The plan", "summary": "",
                "steps": ["Inspect", "Fix"], "tests": [],
            ] as [String: Any],
        ])
        model.handleEventForTesting(Self.questionReadyEvent)
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertNotNil(model.pendingUserQuestion)
        XCTAssertFalse(
            model.planApprovalPending,
            "a model still asking is not yet proposing"
        )
    }

    @MainActor
    func testQuestionClearsOnModeSwitchDismissAndError() {
        let arm = { () -> AppModel in
            let model = AppModel(startImmediately: false)
            model.selectedMode = .grill
            model.turnDispatchedMode = .grill
            model.isBusy = true
            model.handleEventForTesting(Self.questionReadyEvent)
            model.handleEventForTesting(["type": "turn_done", "reason": "complete"])
            XCTAssertNotNil(model.pendingUserQuestion)
            return model
        }

        let switched = arm()
        switched.selectedMode = .work
        XCTAssertNil(switched.pendingUserQuestion)

        let dismissed = arm()
        dismissed.dismissUserQuestion()
        XCTAssertNil(dismissed.pendingUserQuestion)

        let errored = arm()
        errored.handleEventForTesting(["type": "error", "message": "boom"])
        XCTAssertNil(errored.pendingUserQuestion)
    }

    func testComposedQuestionAnswerJoinsOptionAndElaboration() {
        XCTAssertEqual(
            AppModel.composedQuestionAnswer(
                option: UserQuestionOption(label: "SQLite"), freeText: ""
            ),
            "SQLite"
        )
        XCTAssertEqual(
            AppModel.composedQuestionAnswer(option: nil, freeText: "  Use Postgres  "),
            "Use Postgres"
        )
        XCTAssertEqual(
            AppModel.composedQuestionAnswer(
                option: UserQuestionOption(label: "SQLite"),
                freeText: "but only if it stays single-writer"
            ),
            "SQLite\n\nbut only if it stays single-writer"
        )
        XCTAssertNil(AppModel.composedQuestionAnswer(option: nil, freeText: "   "))
    }

    @MainActor
    func testPlanEmptiedMidTurnDoesNotOfferApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "todo_update", "todos": [[String: Any]]()])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "there is no zero-step plan to implement")
    }

    @MainActor
    func testEmptyTodoUpdateWithdrawsAPendingOffer() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.handleEventForTesting(["type": "todo_update", "todos": [[String: Any]]()])

        XCTAssertFalse(model.planApprovalPending, "emptying the list withdraws the plan")
    }

    @MainActor
    func testQueuedMessageWaitsBehindPlanApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.queuedMessages = ["and then do the follow-up"]

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertTrue(model.planApprovalPending, "queued work waits until the plan decision is resolved")
        XCTAssertEqual(model.queuedMessages, ["and then do the follow-up"])
    }

    @MainActor
    func testKeepPlanningDismissesThePromptAndStaysInPlanMode() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.resolvePlanApproval(.revise)

        XCTAssertFalse(model.planApprovalPending)
        XCTAssertEqual(model.selectedMode, .plan)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testImplementingThePlanSwitchesToBuildMode() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        armPlanApproval(model)

        model.resolvePlanApproval(.proceed)

        XCTAssertFalse(model.planApprovalPending)
        XCTAssertEqual(model.selectedMode, .work, "implementation happens in Work mode")
    }

    @MainActor
    func testImplementingWhileDisconnectedKeepsThePromptPending() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .unavailable("gone")
        armPlanApproval(model)

        model.resolvePlanApproval(.proceed)

        XCTAssertTrue(model.planApprovalPending, "the decision must survive a reconnect")
        XCTAssertEqual(model.selectedMode, .plan)
    }

    @MainActor
    func testCancellingPlanReturnsToAdaptiveWorkAndKeepsPlan() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.resolvePlanApproval(.cancel)

        XCTAssertFalse(model.planApprovalPending)
        XCTAssertEqual(model.selectedMode, .work)
        XCTAssertNotNil(model.activePlan)
    }

    @MainActor
    func testClarifyingPlanAnswerDoesNotTriggerApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "Which platform should this target?"])
        model.handleEventForTesting(["type": "message_end"])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending)
    }

    @MainActor
    func testClarifyingQuestionSuppressesEvenAnEarlyStructuredPlanSignal() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.handleEventForTesting([
            "type": "plan_ready",
            "plan": [
                "id": "plan-1",
                "title": "Draft plan",
                "summary": "Needs a target",
                "steps": ["Update the target"],
                "tests": [],
            ],
        ])
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "Which target should this use?"])
        model.handleEventForTesting(["type": "message_end"])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending)
    }

    @MainActor
    func testSwitchingModesDismissesThePlanApprovalPrompt() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.selectedMode = .ask

        XCTAssertFalse(model.planApprovalPending, "changing modes is already an answer")
    }

    @MainActor
    func testAgentErrorClearsThePlanApprovalPrompt() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.handleEventForTesting(["type": "error", "message": "agent crashed"])

        XCTAssertFalse(model.planApprovalPending)
    }

    /// Drives the model through the real wire sequence that ends a Plan-mode
    /// turn with a plan on the board: dispatch latch, todo_update, turn_done.
    @MainActor
    private func armPlanApproval(_ model: AppModel) {
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])
    }

    @MainActor
    func testExtensionSnapshotDecodesPluginSkillAndOAuthServer() throws {
        let data = #"""
        {
          "capabilities": {"streamable_http":true,"stdio":false,"oauth":true,"mcp_apps":false,"hooks":false,"sandboxed":true},
          "marketplaces": [{"id":"local","name":"Local","kind":"local","source":"/tmp/market","error":null,"workspace_discovered":false}],
          "plugins": [{
            "id":"local/demo","name":"demo","display_name":"Demo","description":"A demo","version":"1.0.0","author":"Locus",
            "digest":"abc","enabled_global":true,"enabled_workspaces":[],"disabled_workspaces":[],"previous_versions":[],
            "skills":[],"mcp_servers":[],"scripts":[],"unsupported":[],"error":null
          }],
          "skills": [{
            "id":"demo:review","name":"review","display_name":"Review","description":"Review changes","source":"plugin",
            "plugin_id":"local/demo","allow_implicit_invocation":true,"enabled":true,"error":null
          }],
          "mcp_servers": [{
            "id":"plugin:demo:remote","name":"remote","transport":"streamable_http","url":"https://example.com/mcp","command":"",
            "origin":"plugin","plugin_id":"local/demo","active":true,"enabled":true,"enabled_global":true,"enabled_workspaces":[],
            "disabled_workspaces":[],"state":"connected","error":null,"tool_count":2,"has_credentials":true,"approval_mode":"annotations",
            "auth":"oauth","oauth":{"authorization_endpoint":"https://example.com/authorize","token_endpoint":"https://example.com/token","client_id":"client","scopes":["tools"],"redirect_uri":"locus://mcp/oauth"}
          }],
          "mcp_presets": [],
          "errors":[],"pending_updates":0
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(ExtensionsResponse.self, from: data)

        XCTAssertEqual(response.plugins.first?.displayName, "Demo")
        XCTAssertEqual(response.skills.first?.id, "demo:review")
        XCTAssertEqual(response.mcpServers.first?.oauth?.clientID, "client")
        XCTAssertFalse(response.capabilities.stdio)
    }

    func testIssuerBoundMCPCredentialsAreNotReplayedToAnEditedServer() throws {
        let server = try JSONDecoder().decode(
            ExtensionMCPServer.self,
            from: Data(#"""
            {"id":"remote","name":"Remote","transport":"streamable_http",
             "url":"https://mcp.example/mcp","auth":"oauth",
             "oauth":{"issuer":"https://auth.example",
                      "authorization_endpoint":"https://auth.example/authorize",
                      "token_endpoint":"https://auth.example/token",
                      "client_id":"client","scopes":[],
                      "redirect_uri":"locus://mcp/oauth"}}
            """#.utf8)
        )

        XCTAssertTrue(ExtensionsModel.mcpCredentials([
            "access_token": "token",
            "resource": "https://mcp.example/mcp",
            "issuer": "https://auth.example",
        ], areBoundTo: server))
        XCTAssertFalse(ExtensionsModel.mcpCredentials([
            "access_token": "token",
            "resource": "https://other.example/mcp",
            "issuer": "https://auth.example",
        ], areBoundTo: server))
        XCTAssertFalse(ExtensionsModel.mcpCredentials([
            "access_token": "token",
            "resource": "https://mcp.example/mcp",
            "issuer": "https://other-auth.example",
        ], areBoundTo: server))
        XCTAssertTrue(
            ExtensionsModel.mcpCredentials(["access_token": "legacy-token"], areBoundTo: server),
            "version-1 credentials without binding metadata must remain migratable"
        )
    }

    @MainActor
    func testDispatchPlanAllowsOrderedCodingJobsAndRejectsUnorderedWriters() {
        let model = AppModel(startImmediately: false)
        let dispatcher = AgentProfile(
            name: "Dispatcher", model: "qwen", role: .dispatcher
        )
        let backend = AgentProfile(
            name: "Backend", model: "kimi", role: .implementer,
            accessCeiling: .workspaceWrite
        )
        let ui = AgentProfile(
            name: "UI", model: "claude", role: .implementer,
            accessCeiling: .computerControl
        )
        [dispatcher, backend, ui].forEach(model.agentTeamsModel.saveAgentProfile)
        let team = AgentTeam(
            name: "Two Writers",
            dispatcherID: dispatcher.id,
            fallbackDispatcherID: nil,
            memberIDs: [dispatcher.id, backend.id, ui.id],
            defaultWriterID: backend.id
        )
        model.agentTeamsModel.saveAgentTeam(team)
        model.agentTeamsModel.selectAgentTeam(team.id)
        let ordered = DispatchPlan(
            summary: "Backend then UI",
            jobs: [
                DispatchJob(
                    id: "backend", agentID: backend.id.uuidString,
                    goal: "Build API", dependencies: [], kind: "writer",
                    requiredRole: nil, capabilityTags: nil, preferredAgentID: nil
                ),
                DispatchJob(
                    id: "ui", agentID: ui.id.uuidString,
                    goal: "Build UI", dependencies: ["backend"], kind: "writer",
                    requiredRole: nil, capabilityTags: nil, preferredAgentID: nil
                ),
            ]
        )
        XCTAssertTrue(model.dispatchPlanErrors(ordered).isEmpty)

        var unordered = ordered
        unordered.jobs[1].dependencies = []
        XCTAssertTrue(
            model.dispatchPlanErrors(unordered).contains(where: {
                $0.contains("Every pair of coding jobs")
            })
        )
    }

    @MainActor
    func testApplicationSnapshotPromptIsRedactedContextWithoutAPath() {
        let model = AppModel(startImmediately: false)
        let context = ApplicationSnapshotContext(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            applicationName: "Editor",
            windowTitle: "Draft",
            windowIdentifier: 7,
            accessibilityText: "AXTextField · Password · ••••••",
            iconData: nil
        )
        let attachment = ChatAttachment(
            url: URL(fileURLWithPath: "/dev/null/appshot.png"),
            kind: .applicationSnapshot,
            imageData: Data([0x89, 0x50, 0x4e, 0x47]),
            mimeType: "image/png",
            overrideName: "Editor — Draft",
            applicationContext: context
        )

        let prompt = model.decoratedPrompt(
            "Review this", mode: .ask, chatAttachments: [attachment]
        )
        XCTAssertTrue(prompt.contains("Applications mentioned by the user"))
        XCTAssertTrue(prompt.contains("Editor: Draft"))
        XCTAssertTrue(prompt.contains("secure-field-redacted"))
        XCTAssertTrue(prompt.contains("••••••"))
        XCTAssertFalse(prompt.contains("/dev/null"))
        let sources = AppModel.providedSourceItems(
            attachments: [attachment], contextFiles: [], mode: .ask
        )
        XCTAssertEqual(sources.first?.kind, .application)
        XCTAssertNil(sources.first?.path)
    }

    @MainActor
    func testApplicationSnapshotClearsOnlyAfterSuccessfulDelivery() {
        let snapshot = ChatAttachment(
            url: URL(fileURLWithPath: "/dev/null/appshot.png"),
            kind: .applicationSnapshot,
            imageData: Data([0x89]),
            mimeType: "image/png",
            overrideName: "Editor — Draft"
        )
        let image = ChatAttachment(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            kind: .image,
            imageData: Data([0x89]),
            mimeType: "image/png"
        )
        XCTAssertEqual(
            AppModel.attachmentIDsToClear([snapshot, image], deliverySucceeded: false),
            [image.id]
        )
        XCTAssertEqual(
            AppModel.attachmentIDsToClear([snapshot, image], deliverySucceeded: true),
            [snapshot.id, image.id]
        )
    }

    @MainActor
    func testSimulatorDiscoverySortsBootedIPadFirstAndFiltersOtherFamilies() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "devices": [
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    [
                        "name": "iPhone 17", "udid": "PHONE", "state": "Booted",
                        "isAvailable": true, "deviceTypeIdentifier": "phone",
                    ],
                    [
                        "name": "iPad Pro 13-inch", "udid": "IPAD", "state": "Booted",
                        "isAvailable": true, "deviceTypeIdentifier": "ipad",
                    ],
                    [
                        "name": "Apple Watch", "udid": "WATCH", "state": "Booted",
                        "isAvailable": true, "deviceTypeIdentifier": "watch",
                    ],
                ],
            ],
        ])

        let devices = try SimulatorControlService.parseDevices(data)
        XCTAssertEqual(devices.map(\.udid), ["IPAD", "PHONE"])
        XCTAssertTrue(devices[0].isIPad)
    }

    @MainActor
    func testLiveApplicationScopeRequiresExactBundleAndPID() {
        let target = ApplicationTarget(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            name: "Editor",
            windowTitle: "Draft",
            windowIdentifier: 7,
            iconData: nil
        )
        XCTAssertTrue(
            ComputerControlService.scopeAllows(
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 42,
                scope: target
            )
        )
        XCTAssertFalse(
            ComputerControlService.scopeAllows(
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 43,
                scope: target
            )
        )
        XCTAssertTrue(
            AppModel.effectiveComputerControlEnabled(
                globalEnabled: false,
                hasLiveApplication: true,
                liveApplicationConnected: true
            )
        )
        XCTAssertFalse(
            AppModel.effectiveComputerControlEnabled(
                globalEnabled: true,
                hasLiveApplication: true,
                liveApplicationConnected: false
            ),
            "A disconnected exact scope must override broader global control."
        )
        XCTAssertFalse(
            ComputerControlService.scopeAllows(
                bundleIdentifier: "com.example.Other",
                processIdentifier: 42,
                scope: target
            )
        )
    }

    func testSimulatorAccessibilityCoordinatesFollowLandscapeRotation() {
        let mapped = SimulatorControlService.mapAccessibilityPoint(
            CGPoint(x: 549.5, y: 762),
            displaySize: CGSize(width: 1_376, height: 1_032),
            clockwiseQuarterTurns: 1
        )
        XCTAssertEqual(mapped.x, 614, accuracy: 0.01)
        XCTAssertEqual(mapped.y, 549.5, accuracy: 0.01)
    }

    private func sessionInfo(id: String) -> [String: Any] {
        [
            "model": "qwen3:8b",
            "host": "http://localhost:11434",
            "cwd": "/tmp",
            "session": "/tmp/\(id).jsonl",
            "session_id": id,
            "messages": 1,
            "approx_tokens": 0,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "max_iterations": 40,
            "has_project_context": false,
            "permissions": ["skip_all": false, "allowed": []],
        ]
    }
}
