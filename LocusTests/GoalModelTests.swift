import XCTest

@testable import Locus

@MainActor
final class GoalModelTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    private func goal(_ status: GoalStatus = .active, revision: Int = 1, sessionID: String = "session-1") -> PersistentGoal {
        PersistentGoal(id: "goal-\(sessionID)", sessionID: sessionID, objective: "Implement and verify the feature",
                       revision: revision, status: status,
                       execution: ["provider": .string("ollama"), "model": .string("fixture")])
    }

    private func object(_ goal: PersistentGoal) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(goal)) as? [String: Any])
    }

    private func snapshot(_ goal: PersistentGoal, model: GoalModel) throws {
        _ = model.handleEvent(["type": "goal_snapshot", "goal": try object(goal)], sessionID: goal.sessionID)
    }

    private func makeModel(canContinue: @escaping (PersistentGoal) -> Bool = { _ in false },
                           dispatch: @escaping (PersistentGoal, OrchestrationRun) async -> Bool = { _, _ in false },
                           stop: @escaping (String) -> Void = { _ in },
                           prepare: @escaping (String) -> Void = { _ in },
                           notify: @escaping (PersistentGoal) -> Void = { _ in }) -> GoalModel {
        let model = GoalModel()
        model.configure(backend: stubbedBackendService(), canContinue: canContinue, dispatch: dispatch,
                        stopTurn: stop, prepareResume: prepare, notify: notify)
        return model
    }

    private func fixtureRun(_ id: String = "run-1", sessionID: String = "session-1") -> [String: Any] {
        ["id": id, "session_id": sessionID, "state": "queued", "request": "Continue the goal",
         "created_at": 1.0, "updated_at": 1.0, "last_seq": 0, "pinned": false,
         "legacy": false, "recoverable": false]
    }

    func testConstructionAndConfigurationDoNotReadOrStartGoals() {
        let model = makeModel()
        XCTAssertTrue(model.goals.isEmpty)
        XCTAssertNoBackendTraffic()
    }

    func testGoalRecordDecodesMinimalStateAndKeepsExecutionSnapshot() throws {
        let decoded = try JSONDecoder().decode(PersistentGoal.self, from: JSONSerialization.data(withJSONObject: [
            "id": "goal-1", "session_id": "chat-1", "objective": "Finish the job", "status": "paused",
            "execution": ["provider_account_id": "exact-account", "agent_config": ["custom": true]],
            "token_usage_available": false, "model_call_usage_available": false,
        ]))
        XCTAssertEqual(decoded.modelCalls, 0)
        XCTAssertNil(decoded.tokenBudget)
        XCTAssertEqual(decoded.evidence, [])
        XCTAssertFalse(decoded.tokenUsageAvailable)
        XCTAssertFalse(decoded.modelCallUsageAvailable)
        XCTAssertEqual(decoded.execution["provider_account_id"], .string("exact-account"))
        XCTAssertEqual(try JSONDecoder().decode(PersistentGoal.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testStartupRestoresEverySessionButWaitsForAdmission() async throws {
        let records = try [goal(), goal(.paused, sessionID: "session-2"), goal(sessionID: "session-3")].map(object)
        BackendStub.respond(toPath: "/api/goals") { _ in ["goals": records] }
        var restored: [String] = []
        let model = makeModel(prepare: { restored.append($0) })
        defer { model.shutdown() }
        await model.refresh()
        XCTAssertEqual(Set(model.goals.keys), Set(["session-1", "session-2", "session-3"]))
        XCTAssertEqual(Set(restored), Set(["session-1", "session-3"]))
        XCTAssertEqual(BackendStub.requestPaths, ["/api/goals"])
    }

    func testMissingCapabilityDoesNotRunAContinuation() async {
        let model = makeModel(canContinue: { _ in true })
        defer { model.shutdown() }
        await model.refresh()
        XCTAssertFalse(model.supportsGoals)
        XCTAssertNil(model.error)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/goals"])
    }

    func testHistoricalGoalUsageCannotReplaceTheNewerSessionGoal() async throws {
        var older = goal(.completed)
        older.createdAt = .number(1)
        older.updatedAt = .number(100)
        var current = goal()
        current.id = "new-goal"
        current.createdAt = .number(2)
        current.updatedAt = .number(3)
        let records = try [current, older].map(object)
        BackendStub.respond(toPath: "/api/goals") { _ in ["goals": records] }
        var prepared: [String] = []
        let model = makeModel(prepare: { prepared.append($0) })
        defer { model.shutdown() }
        await model.refresh()
        XCTAssertEqual(model.goal(for: "session-1")?.id, current.id)
        XCTAssertEqual(prepared, ["session-1"])
        older.status = .active
        older.revision = 20
        try snapshot(older, model: model)
        XCTAssertEqual(model.goal(for: "session-1")?.id, current.id)
        current.status = .completed
        try snapshot(current, model: model)
        try snapshot(older, model: model)
        XCTAssertEqual(model.goal(for: "session-1")?.id, current.id)
        XCTAssertEqual(model.goal(for: "session-1")?.status, .completed)
    }

    func testRestoreOnlyPreparesTheLatestGoalAfterReadingHistory() async throws {
        var older = goal()
        older.createdAt = .number(1)
        var current = goal(.completed)
        current.id = "new-goal"
        current.createdAt = .number(2)
        let records = try [older, current].map(object)
        BackendStub.respond(toPath: "/api/goals") { _ in ["goals": records] }
        var prepared: [String] = []
        let model = makeModel(prepare: { prepared.append($0) })
        defer { model.shutdown() }
        await model.refresh()
        XCTAssertEqual(model.goal(for: "session-1")?.id, current.id)
        XCTAssertTrue(prepared.isEmpty, "Historical active snapshots cannot change the current chat mode")
        older.createdAt = nil
        try snapshot(older, model: model)
        XCTAssertEqual(model.goal(for: "session-1")?.id, current.id)
    }

    func testDuplicateWakeupsDispatchClaimedRunOnlyOnce() async throws {
        let record = try object(goal())
        let runBody = fixtureRun()
        BackendStub.respond(toPath: "/api/goals/goal-session-1/claim") { _ in ["goal": record, "run": runBody] }
        let delivered = expectation(description: "Claimed run dispatched")
        delivered.assertForOverFulfill = true
        let model = makeModel(canContinue: { _ in true }, dispatch: { goal, run in
            XCTAssertEqual(goal.sessionID, "session-1")
            XCTAssertEqual(run.id, "run-1")
            delivered.fulfill()
            return true
        })
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        for _ in 0..<10 { model.wake() }
        await fulfillment(of: [delivered], timeout: 2)
        model.wake()
        await Task.yield()
        XCTAssertEqual(BackendStub.requests.filter { $0.url?.path.hasSuffix("/claim") == true }.count, 1)
    }

    func testAdmissionIsRecheckedAfterClaim() async throws {
        let record = try object(goal())
        let claimed = expectation(description: "Continuation claimed")
        let runBody = fixtureRun()
        BackendStub.respond(toPath: "/api/goals/goal-session-1/claim") { _ in
            claimed.fulfill()
            return ["goal": record, "run": runBody]
        }
        var checks = 0
        var dispatches = 0
        let model = makeModel(canContinue: { _ in checks += 1; return checks == 1 },
                              dispatch: { _, _ in dispatches += 1; return true })
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        await fulfillment(of: [claimed], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(dispatches, 0, "A user action or permission can take priority while the claim is in flight")
    }

    func testTurnCompletionDuringDispatchSchedulesTheNextContinuation() async throws {
        let record = try object(goal())
        let runBody = fixtureRun()
        BackendStub.respond(toPath: "/api/goals/goal-session-1/claim") { _ in
            ["goal": record, "run": runBody]
        }
        BackendStub.respond(toPath: "/api/sessions/session-1/goal") { _ in ["goal": record] }
        let delivered = expectation(description: "Both continuations dispatch")
        delivered.expectedFulfillmentCount = 2
        var count = 0
        var model: GoalModel!
        model = makeModel(canContinue: { _ in true }, dispatch: { _, _ in
            count += 1
            if count == 1 {
                _ = model.handleEvent(["type": "turn_done", "goal": record], sessionID: "session-1")
                model.wake()
            } else {
                model.suspend(sessionID: "session-1")
            }
            delivered.fulfill()
            return true
        })
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(count, 2, "A fast terminal event must not lose its wakeup behind the prior dispatch")
    }

    func testAWaitingWorkspaceDoesNotPreventAnotherGoalFromDispatching() async throws {
        let first = goal(sessionID: "a-waiting")
        let second = goal(sessionID: "b-ready")
        let firstRecord = try object(first)
        let secondRecord = try object(second)
        let firstRun = fixtureRun("run-waiting", sessionID: first.sessionID)
        let secondRun = fixtureRun("run-ready", sessionID: second.sessionID)
        BackendStub.respond(toPath: "/api/goals/\(first.id)/claim") { _ in ["goal": firstRecord, "run": firstRun] }
        BackendStub.respond(toPath: "/api/goals/\(second.id)/claim") { _ in ["goal": secondRecord, "run": secondRun] }
        let waiting = expectation(description: "First goal waits for its workspace")
        let ready = expectation(description: "Second goal dispatches independently")
        let model = makeModel(canContinue: { _ in true }, dispatch: { goal, _ in
            if goal.sessionID == "a-waiting" {
                waiting.fulfill()
                do { try await Task.sleep(for: .seconds(10)) } catch { return false }
            } else { ready.fulfill() }
            return true
        })
        defer { model.shutdown() }
        try snapshot(first, model: model)
        try snapshot(second, model: model)
        await fulfillment(of: [waiting, ready], timeout: 2)
    }

    func testPauseBlocksClaimBeforeTheBackendResponds() async throws {
        let paused = try object(goal(.paused, revision: 2))
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in paused }
        let model = makeModel(canContinue: { _ in true })
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        model.suspend(sessionID: "session-1")
        let succeeded = await model.pause(sessionID: "session-1")
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.goal(for: "session-1")?.status, .paused)
        XCTAssertFalse(BackendStub.requestPaths.contains { $0.hasSuffix("/claim") })
    }

    func testSavingAnEditPausesAndUsesThePausedRevision() async throws {
        let paused = try object(goal(.paused, revision: 2))
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in paused }
        var stopped: [String] = []
        let model = makeModel(stop: { stopped.append($0) })
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        model.open(sessionID: "session-1", execution: ["provider": "ollama", "model": "new-model"])
        model.draftObjective = "A revised objective"
        model.draftTokenBudget = "5000"
        await model.saveDraft()
        let bodies = try BackendStub.requests.map(requestBody)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first?["action"] as? String, "pause")
        XCTAssertEqual(bodies.first?["expected_revision"] as? Int, 1)
        XCTAssertEqual(bodies.last?["action"] as? String, "edit")
        XCTAssertEqual(bodies.last?["expected_revision"] as? Int, 2)
        XCTAssertEqual(bodies.last?["objective"] as? String, "A revised objective")
        XCTAssertEqual((bodies.last?["execution"] as? [String: Any])?["model"] as? String, "new-model")
        XCTAssertEqual(stopped, ["session-1"])
        XCTAssertEqual(model.goal(for: "session-1")?.status, .paused)
    }

    func testFailedEditPreservesItsDraftAndReportsConflict() async throws {
        BackendStub.respond(toPath: "/api/goals/goal-session-1", status: 409) { _ in ["detail": "The goal changed. Reload it before editing."] }
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        model.open(sessionID: "session-1")
        model.draftObjective = "Keep this unsaved objective"
        await model.saveDraft()
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.draftObjective, "Keep this unsaved objective")
        XCTAssertNotNil(model.error)
        XCTAssertEqual(BackendStub.requests.count, 1)
    }

    func testEachQueuedUserMessageGetsItsOwnDurableFence() async throws {
        var fenced = goal(revision: 2)
        fenced.pendingUserInput = true
        let record = try object(fenced)
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in record }
        let model = makeModel(canContinue: { _ in true })
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        model.noteUserInput(sessionID: "session-1")
        model.noteUserInput(sessionID: "session-1")
        let result = await model.flushUserInput(sessionID: "session-1")
        let requests = try BackendStub.requests.map(requestBody)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0["action"] as? String == "steer" })
        XCTAssertEqual(Set(requests.compactMap { $0["input_id"] as? String }).count, 2)
        XCTAssertEqual(result?.pendingUserInput, true)
        XCTAssertFalse(BackendStub.requestPaths.contains { $0.hasSuffix("/claim") })
    }

    func testInputAddedAfterEarlierFenceSettlesIsFlushedBeforeDispatch() async throws {
        var fenced = goal(revision: 2)
        fenced.pendingUserInput = true
        let record = try object(fenced)
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in record }
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        model.noteUserInput(sessionID: "session-1", text: "First direction")
        for _ in 0..<100 where model.goal(for: "session-1")?.pendingUserInput != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.goal(for: "session-1")?.pendingUserInput, true)
        model.noteUserInput(sessionID: "session-1", text: "Later direction")
        _ = await model.flushUserInput(sessionID: "session-1")
        XCTAssertEqual(BackendStub.requests.count, 2, "A finished earlier fence task must not hide newly queued input")
    }

    func testFenceFailureReturnsNoGoalAndRetryKeepsTheInputIdentity() async throws {
        BackendStub.respond(toPath: "/api/goals/goal-session-1", status: 503) { _ in ["detail": "Agent unavailable"] }
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        model.noteUserInput(sessionID: "session-1")
        let first = await model.flushUserInput(sessionID: "session-1")
        let second = await model.flushUserInput(sessionID: "session-1")
        XCTAssertNil(first)
        XCTAssertNil(second)
        let requests = try BackendStub.requests.map(requestBody)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?["input_id"] as? String, requests.last?["input_id"] as? String)
    }

    func testDuplicateQueuedTextKeepsSeparateIdentitiesAcrossRetry() throws {
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        let first = try XCTUnwrap(model.noteUserInput(sessionID: "session-1", text: "Same direction"))
        let second = try XCTUnwrap(model.noteUserInput(sessionID: "session-1", text: "Same direction"))
        XCTAssertEqual(model.takeUserInput(sessionID: "session-1", text: " Same direction "), first)
        model.restoreUserInput(sessionID: "session-1", text: "Same direction", inputID: first)
        XCTAssertEqual(model.takeUserInput(sessionID: "session-1", text: "Same direction"), first)
        XCTAssertEqual(model.takeUserInput(sessionID: "session-1", text: "Same direction"), second)
        XCTAssertNil(model.takeUserInput(sessionID: "session-1", text: "Same direction"))
    }

    func testRemovingQueuedInputReleasesOnlyItsDurableFence() async throws {
        let record = try object(goal(revision: 2))
        let mutations = expectation(description: "Steer and discard both persisted")
        mutations.expectedFulfillmentCount = 2
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in
            mutations.fulfill()
            return record
        }
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        let inputID = model.noteUserInput(sessionID: "session-1", text: "Remove this direction")
        let removed = await model.discardUserInput(sessionID: "session-1", text: "Remove this direction")
        XCTAssertTrue(removed)
        await fulfillment(of: [mutations], timeout: 2)
        let bodies = try BackendStub.requests.map(requestBody)
        XCTAssertEqual(bodies.map { $0["action"] as? String }, ["steer", "discard_input"])
        XCTAssertTrue(bodies.allSatisfy { $0["input_id"] as? String == inputID })
        XCTAssertNil(model.takeUserInput(sessionID: "session-1", text: "Remove this direction"))
    }

    func testFailedRemovalRetainsTheInputIdentityUntilRetrySucceeds() async throws {
        var pending = goal(revision: 2)
        pending.pendingUserInput = true
        let pendingRecord = try object(pending)
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in pendingRecord }
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        let inputID = model.noteUserInput(sessionID: "session-1", text: "Keep until removed")
        _ = await model.flushUserInput(sessionID: "session-1")
        var requests = BackendStub.requests
        BackendStub.reset()
        BackendStub.respond(toPath: "/api/goals/goal-session-1", status: 503) { _ in ["detail": "Unavailable"] }
        let failed = await model.discardUserInput(sessionID: "session-1", text: "Keep until removed")
        XCTAssertFalse(failed)
        XCTAssertNotNil(model.error)
        requests += BackendStub.requests
        BackendStub.reset()
        let cleared = try object(goal(revision: 3))
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in cleared }
        let removed = await model.discardUserInput(sessionID: "session-1", text: "Keep until removed")
        XCTAssertTrue(removed)
        requests += BackendStub.requests
        let bodies = try requests.map(requestBody)
        XCTAssertEqual(bodies.map { $0["action"] as? String }, ["steer", "discard_input", "discard_input"])
        XCTAssertTrue(bodies.allSatisfy { $0["input_id"] as? String == inputID })
        XCTAssertNil(model.takeUserInput(sessionID: "session-1", text: "Keep until removed"))
    }

    func testNewGoalCannotReuseTheCancelledGoalsInputIdentity() throws {
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(), model: model)
        let previousID = model.noteUserInput(sessionID: "session-1", text: "Same direction")
        try snapshot(goal(.cancelled), model: model)
        var replacement = goal()
        replacement.id = "replacement"
        try snapshot(replacement, model: model)
        let currentID = model.noteUserInput(sessionID: "session-1", text: "Same direction")
        XCTAssertNotEqual(previousID, currentID)
        XCTAssertEqual(model.takeUserInput(sessionID: "session-1", text: "Same direction"), currentID)
        XCTAssertNil(model.takeUserInput(sessionID: "session-1", text: "Same direction"))
    }

    func testAttachingUserInputCannotReleaseAnExplicitPauseFence() async throws {
        var pending = goal()
        pending.pendingUserInput = true
        let model = makeModel(canContinue: { _ in true })
        defer { model.shutdown() }
        try snapshot(pending, model: model)
        model.suspend(sessionID: "session-1")
        try snapshot(goal(), model: model)
        model.wake()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNoBackendTraffic()
    }

    func testComposerQueueAndRemovalPersistAndReleaseTheSameGoalInput() async throws {
        let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        defer { app.goals.shutdown(); app.toastCenter.cancelPendingDismissal() }
        app.sessionInfo = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp",
            session: "session-1", sessionID: "session-1", messages: 0, approxTokens: 0,
            promptTokens: 0, completionTokens: 0, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: []))
        app.installTranscriptSession("session-1", blocks: [])
        app.agentRuntimePhase = .online
        app.goals.configure(backend: stubbedBackendService(), canContinue: { _ in false }, dispatch: { _, _ in false })
        let record = try object(goal(revision: 2))
        let mutations = expectation(description: "Composer persisted then removed its fence")
        mutations.expectedFulfillmentCount = 2
        BackendStub.respond(toPath: "/api/goals/goal-session-1") { _ in mutations.fulfill(); return record }
        try snapshot(goal(), model: app.goals)
        app.isBusy = true
        app.draftText = "Queued direction"
        app.submitDraft()
        XCTAssertEqual(app.queuedMessages, ["Queued direction"])
        XCTAssertEqual(app.draftText, "")
        app.removeQueuedMessage(at: 0)
        await fulfillment(of: [mutations], timeout: 2)
        for _ in 0..<100 where !app.queuedMessages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(app.queuedMessages.isEmpty)
        let bodies = try BackendStub.requests.map(requestBody)
        XCTAssertEqual(bodies.map { $0["action"] as? String }, ["steer", "discard_input"])
        XCTAssertEqual(bodies.first?["input_id"] as? String, bodies.last?["input_id"] as? String)
    }

    func testPausedManualMessagesNeverCreateGoalInputFences() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        try snapshot(goal(.paused), model: model)
        model.noteUserInput(sessionID: "session-1")
        _ = await model.flushUserInput(sessionID: "session-1")
        XCTAssertNoBackendTraffic()
    }

    func testBackgroundSnapshotsAreSessionScopedAndNotificationsAreDeduplicated() throws {
        var notifications: [String] = []
        let model = makeModel(notify: { notifications.append($0.sessionID) })
        defer { model.shutdown() }
        try snapshot(goal(sessionID: "background"), model: model)
        let completed = goal(.completed, sessionID: "background")
        try snapshot(completed, model: model)
        try snapshot(completed, model: model)
        try snapshot(goal(sessionID: "background"), model: model)
        XCTAssertEqual(model.goal(for: "background")?.status, .completed)
        XCTAssertEqual(notifications, ["background"])
        XCTAssertNil(model.goal(for: "session-1"))
        XCTAssertTrue(model.handleEvent(["type": "goal_snapshot", "goal": try object(goal())], sessionID: "other"))
        XCTAssertNil(model.goal(for: "session-1"), "A socket cannot update another session's goal")
    }

    func testShutdownCannotBeRestartedByLateEventsOrReadinessWakeups() async throws {
        let model = makeModel(canContinue: { _ in true })
        model.shutdown()
        try snapshot(goal(), model: model)
        model.wake()
        await model.refresh()
        model.noteUserInput(sessionID: "session-1")
        _ = await model.flushUserInput(sessionID: "session-1")
        XCTAssertTrue(model.goals.isEmpty)
        XCTAssertNoBackendTraffic()
    }

    func testBudgetEditorRejectsInvalidLimitsAndDoesNotInventDefaults() {
        let model = makeModel()
        defer { model.shutdown() }
        model.open(sessionID: "session-1", objective: "Complete it")
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.draftModelCallBudget, "")
        XCTAssertEqual(model.draftTokenBudget, "")
        for value in ["-1", "0", "1.5", "many"] {
            model.draftModelCallBudget = value
            XCTAssertFalse(model.canSave)
        }
        model.draftModelCallBudget = " 100 "
        XCTAssertTrue(model.canSave)
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
