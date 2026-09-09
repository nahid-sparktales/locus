import AppKit
import ApplicationServices
import SwiftUI
import XCTest

@testable import Locus

@MainActor
final class TaskCapsuleModelTests: XCTestCase {
    private var workspace = "/tmp/capsule-tests"
    private var planner = AgentProfile(name: "ChatGPT planner", model: "planner")
    private var executor = AgentProfile(name: "Kimi implementer", model: "worker", accessCeiling: .workspaceWrite)
    private var planningRequests: [TaskCapsulePlanningRequest] = []
    private var executionRequests: [TaskCapsule] = []
    private var resumeRequests: [(String, Bool)] = []
    private var openedConversations: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        workspace = "/tmp/capsule-tests"
        planningRequests = []
        executionRequests = []
        resumeRequests = []
        openedConversations = []
    }

    private var recipe: TaskCapsuleRecipe {
        var value = TaskCapsuleRecipe()
        value.plannerProfileID = planner.id.uuidString
        value.executorProfileID = executor.id.uuidString
        return value
    }

    private var request: TaskCapsulePlanningRequest {
        TaskCapsulePlanningRequest(title: "Story edits", request: "Make the requested edits",
                                   workspaceRoot: workspace, recipe: recipe)
    }

    private var plan: PlanDocument {
        PlanDocument(id: "plan-story-edits", title: "Story edits", summary: "Preserve the approved reference",
                     steps: ["Edit the coat"], tests: ["Compare the reference"],
                     stepDetails: [CapsulePlanStep(id: "edit-coat", title: "Edit the coat",
                                                  instructions: "Use the localized edit operation",
                                                  files: ["page8.png"], checks: ["Face stays unchanged"])])
    }

    private var capsule: TaskCapsule {
        TaskCapsule(id: "capsule-1", title: "Story edits", request: request.request,
                    workspaceRoot: workspace, plan: plan, recipe: recipe,
                    createdAt: "2026-09-06T15:00:00Z", updatedAt: "2026-09-06T15:00:00Z")
    }

    private func makeModel(profiles: [AgentProfile]? = nil) -> TaskCapsuleModel {
        let model = TaskCapsuleModel()
        model.configure(
            backend: stubbedBackendService(), workspacePathProvider: { self.workspace },
            profilesProvider: { profiles ?? [self.planner, self.executor] },
            activePlanProvider: { nil }, isBusyProvider: { false },
            startPlanning: { self.planningRequests.append($0) },
            startExecution: { self.executionRequests.append($0) },
            startReview: { _ in }, askPlanner: { _, _ in },
            resumeExecution: { _, id, checks in self.resumeRequests.append((id, checks)) },
            openConversation: { self.openedConversations.append($0) }
        )
        return model
    }

    private func registerBackend(capsules: [TaskCapsule] = []) throws {
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(capsule))
        let records = try JSONSerialization.jsonObject(with: JSONEncoder().encode(capsules))
        BackendStub.respond(toPath: "/api/capsules") { _ in ["capsule": record, "capsules": records] }
    }

    func testConstructionAndConfigurationAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testTaskCapsuleRendersDraftSavedPlanAndSetupAtCompactSizes() async throws {
        // SwiftUI exposes its virtual nodes after a public accessibility
        // client reads this test process; native getters alone leave it dormant.
        let accessibilityReady = expectation(description: "Capsule accessibility tree is ready")
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(getpid())
            XCTAssertEqual(AXUIElementSetMessagingTimeout(application, 0.2), .success)
            var windows: CFTypeRef?
            XCTAssertEqual(AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows), .success)
            accessibilityReady.fulfill()
        }
        await fulfillment(of: [accessibilityReady], timeout: 1)
        var saved = capsule
        saved.plan.constraints = ["Keep the character’s face and pose unchanged."]
        saved.plan.decisions = ["Use a localized edit so the approved background stays intact."]
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        BackendStub.respond(toPath: "/api/capsules") { _ in ["capsules": [record]] }
        BackendStub.respond(toPath: "/api/capsules/\(saved.id)") { _ in ["capsule": record] }
        let model = makeModel()
        await model.refresh()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-capsule-renders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for size in [NSSize(width: 940, height: 760), NSSize(width: 680, height: 620)] {
            let suffix = "\(Int(size.width))x\(Int(size.height))"
            model.newCapsule()
            try await renderCapsule(model, size: size, name: "Draft-\(suffix)",
                                    primaryAction: "capsules.generate", output: output)
            model.selectedID = saved.id
            try await renderCapsule(model, size: size, name: "Saved-plan-\(suffix)",
                                    primaryAction: "capsules.run", output: output)
            XCTAssertEqual(model.selectedCapsule?.plan.stepDetails.first?.checks, ["Face stays unchanged"])
            XCTAssertEqual(model.selectedCapsule?.plan.constraints, saved.plan.constraints)
            try await renderCapsule(model, size: size, name: "Edit-choices-\(suffix)",
                                    primaryAction: "capsules.saveRecipe", output: output,
                                    transition: { model.beginEditingRecipe() })
            model.cancelRecipeEditing()
        }

        let setup = makeModel(profiles: [])
        await setup.refresh()
        try await renderCapsule(setup, size: NSSize(width: 680, height: 620), name: "Setup-680x620",
                                primaryAction: "capsules.setupModels", output: output)
        XCTAssertFalse(setup.canGenerate)
        XCTAssertNotNil(setup.planningUnavailableReason)
        XCTAssertTrue(planningRequests.isEmpty, "Rendering setup must not start model work")
        XCTAssertTrue(executionRequests.isEmpty, "Reviewing a saved plan must not execute it")
        XCTAssertTrue(BackendStub.requests.allSatisfy { $0.httpMethod == "GET" })
        let artifactLocation = XCTAttachment(string: output.path)
        artifactLocation.name = "Capsule render artifact directory"
        artifactLocation.lifetime = .keepAlways
        add(artifactLocation)
        print("Capsule render artifacts: \(output.path)")
    }

    private func renderCapsule(
        _ model: TaskCapsuleModel, size: NSSize, name: String, primaryAction: String,
        output: URL, transition: (() -> Void)? = nil
    ) async throws {
        let host = NSHostingView(rootView: TaskCapsuleView(model: model).preferredColorScheme(.dark))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        if let transition {
            transition()
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("\(name).png"))
        let snapshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        snapshot.name = name
        snapshot.lifetime = .keepAlways
        add(snapshot)

        XCTAssertEqual(host.bounds.size, size, "\(name) must fit the requested window")
        XCTAssertEqual(window.contentView?.frame.size, size)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide), size.width * window.backingScaleFactor, accuracy: 1)
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh), size.height * window.backingScaleFactor, accuracy: 1)
        XCTAssertGreaterThan(png.count, 2_000, "\(name) must render visible content")

        var pending: [Any] = [host]
        var visited = Set<ObjectIdentifier>()
        var identifiers = Set<String>()
        var primaryFrame: NSRect?
        var accessibility: [String] = []
        while let value = pending.popLast(), visited.count < 800 {
            guard let node = TranscriptAccessibilityNode(value),
                  visited.insert(ObjectIdentifier(node.object)).inserted else { continue }
            if let identifier = node.identifier, !identifier.isEmpty {
                identifiers.insert(identifier)
                accessibility.append("\(node.role?.rawValue ?? "unknown") \(identifier) \(NSStringFromRect(node.frame))")
                if identifier == primaryAction { primaryFrame = node.frame }
            }
            pending.append(contentsOf: node.children)
            if let view = node.object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        let metadata = XCTAttachment(string: accessibility.joined(separator: "\n"))
        metadata.name = "\(name) accessibility"
        metadata.lifetime = .keepAlways
        add(metadata)
        XCTAssertLessThan(visited.count, 800, "Accessibility traversal must finish within its bound")
        XCTAssertTrue(identifiers.contains(primaryAction), "\(name) must expose the primary action’s own identifier")
        if let primaryFrame {
            XCTAssertFalse(primaryFrame.isEmpty)
            XCTAssertTrue(window.convertToScreen(host.bounds).contains(primaryFrame),
                          "\(name) must keep its primary action visible inside the window")
        }
    }

    func testComposerPrefillPreservesUnfinishedCapsulesAndResetsAcrossWorkspaces() async throws {
        try registerBackend(capsules: [capsule])
        let model = makeModel()
        model.open(prefillingRequest: "  Current chat draft  ")
        await model.refresh()
        XCTAssertEqual(model.draftRequest, "Current chat draft")
        model.draftRequest = "Unfinished capsule"
        model.open(prefillingRequest: "Another chat draft")
        XCTAssertEqual(model.draftRequest, "Unfinished capsule")
        model.draftRequest = ""
        model.selectedID = capsule.id
        model.open(prefillingRequest: "Do not replace this plan")
        XCTAssertEqual(model.selectedID, capsule.id)
        XCTAssertEqual(model.draftRequest, "")
        workspace = "/tmp/another-capsule-workspace"
        model.open(prefillingRequest: "New workspace request")
        await model.refresh()
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.draftRequest, "New workspace request")
        XCTAssertTrue(planningRequests.isEmpty)
        XCTAssertTrue(executionRequests.isEmpty)
    }

    func testReadOnlyProfileCannotBecomeImplementationDefault() async throws {
        try registerBackend()
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.draftRecipe.plannerProfileID, planner.id.uuidString)
        XCTAssertEqual(model.draftRecipe.executorProfileID, executor.id.uuidString)
        var invalid = recipe
        invalid.executorProfileID = planner.id.uuidString
        XCTAssertNotNil(model.recipeError(invalid))
        XCTAssertNil(model.recipeError(recipe))
        XCTAssertNil(recipe.maximumEstimatedCost, "Subscription use must not default to a dollar budget")
    }

    func testPlanningAvailabilityExplainsTheNextRequiredStep() async throws {
        try registerBackend()
        let model = makeModel()
        XCTAssertFalse(model.canGenerate)
        XCTAssertTrue(model.planningUnavailableReason?.contains("workspace") == true)
        await model.refresh()
        XCTAssertFalse(model.canGenerate)
        XCTAssertTrue(model.planningUnavailableReason?.contains("Describe your task") == true)
        model.draftRequest = "Make the requested edits"
        XCTAssertTrue(model.canGenerate)
        XCTAssertNil(model.planningUnavailableReason)
        model.draftRecipe.executorProfileID = planner.id.uuidString
        XCTAssertFalse(model.canGenerate)
        XCTAssertEqual(model.planningUnavailableReason, model.recipeError(model.draftRecipe))
        XCTAssertTrue(planningRequests.isEmpty, "Explaining setup must not start model work")
    }

    func testContinuePlanningOpensConversationAndPreservesItsPendingRequest() async {
        let model = makeModel()
        model.planningStarted(request, sessionID: "planning-session")
        await model.planningFinished(sessionID: "planning-session", succeeded: true)
        model.isPresented = true
        model.openConversation(sessionID: "planning-session")
        XCTAssertEqual(openedConversations, ["planning-session"])
        XCTAssertFalse(model.isPresented)
        XCTAssertNotNil(model.pendingPlanningRequest(for: "planning-session"))
        XCTAssertTrue(planningRequests.isEmpty)
        XCTAssertTrue(executionRequests.isEmpty)
        XCTAssertNoBackendTraffic()
    }

    func testInterruptedPlanningNeverSavesSubmittedPlan() async throws {
        let model = makeModel()
        model.planningStarted(request, sessionID: "planning-session")
        model.handlePlan(plan, sessionID: "planning-session")
        await model.planningFinished(sessionID: "planning-session", succeeded: false)
        XCTAssertNoBackendTraffic()
        XCTAssertNil(model.pendingPlanningRequest(for: "planning-session"))
        XCTAssertTrue(model.activeStageSessions.isEmpty)
    }

    func testOtherConversationCannotSupplyThePlan() async {
        let model = makeModel()
        model.planningStarted(request, sessionID: "planning-session")
        model.handlePlan(plan, sessionID: "unrelated-session")
        await model.planningFinished(sessionID: "planning-session", succeeded: true)
        XCTAssertNoBackendTraffic()
        XCTAssertNotNil(model.pendingPlanningRequest(for: "planning-session"))
    }

    func testPlanningUsageKeepsOriginTaskAndRunIdentity() {
        let model = makeModel()
        model.planningStarted(request, sessionID: "planning-session")
        XCTAssertTrue(model.handleEvent(["type": "run_started", "run_id": "run-1"], sessionID: "planning-session"))
        XCTAssertFalse(model.handleEvent(["type": "run_started", "run_id": "other-run"], sessionID: "unrelated-session"))
        XCTAssertEqual(model.pendingPlanningRequest(for: "planning-session")?.originRunID, "run-1")
        XCTAssertEqual(model.pendingPlanningRequest(for: "planning-session")?.originSessionID, "planning-session")
        XCTAssertNoBackendTraffic()
    }

    func testClarificationKeepsTheOriginalRecipeUntilPlanCompletes() async throws {
        try registerBackend()
        let model = makeModel()
        await model.refresh()
        model.planningStarted(request, sessionID: "planning-session")
        await model.planningFinished(sessionID: "planning-session", succeeded: true)
        XCTAssertEqual(model.pendingPlanningRequest(for: "planning-session")?.recipe, recipe)
        XCTAssertEqual(BackendStub.requests.filter { $0.httpMethod == "POST" }.count, 0)

        model.handlePlan(plan, sessionID: "planning-session")
        await model.planningFinished(sessionID: "planning-session", succeeded: true)
        XCTAssertEqual(BackendStub.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(model.selectedCapsule?.plan.stepDetails.first?.files, ["page8.png"])
        XCTAssertNil(model.pendingPlanningRequest(for: "planning-session"))
        XCTAssertTrue(executionRequests.isEmpty, "Saving a plan must never start execution")
    }

    func testWaitingPlannerCanBeCancelledWithoutStoppingAnActiveTurn() async {
        let model = makeModel()
        model.planningStarted(request, sessionID: "planning-session")
        model.cancelPlanning(sessionID: "planning-session")
        XCTAssertNotNil(model.pendingPlanningRequest(for: "planning-session"), "Active work must use the conversation's Stop control")
        await model.planningFinished(sessionID: "planning-session", succeeded: true)
        XCTAssertEqual(model.waitingPlans.map(\.id), ["planning-session"])
        model.cancelPlanning(sessionID: "planning-session")
        XCTAssertNil(model.pendingPlanningRequest(for: "planning-session"))
        XCTAssertTrue(model.waitingPlans.isEmpty)
        XCTAssertNoBackendTraffic()
    }

    func testExplicitImplementationCannotFinishAnOlderWaitingPlan() async {
        let model = makeModel()
        model.planningStarted(request, sessionID: "planning-session")
        await model.planningFinished(sessionID: "planning-session", succeeded: true)
        model.stageStarted(capsule: capsule, stage: "execute", sessionID: "planning-session")
        XCTAssertNil(model.pendingPlanningRequest(for: "planning-session"))
        XCTAssertFalse(model.handleEvent(["type": "run_started", "run_id": "implementation-run"], sessionID: "planning-session"))
        XCTAssertEqual(model.activeStageSessions["planning-session"], "execute")
        XCTAssertNoBackendTraffic()
    }

    func testSavedExecutionUsesStoredRecipeWithoutReplanning() async throws {
        try registerBackend(capsules: [capsule])
        let model = makeModel()
        await model.refresh()
        model.selectedID = capsule.id
        model.draftRecipe.plannerProfileID = executor.id.uuidString
        model.runSelected()
        XCTAssertEqual(executionRequests.first?.recipe, recipe)
        XCTAssertTrue(planningRequests.isEmpty)
        XCTAssertEqual(BackendStub.requests.count, 1)
    }

    func testEditingRecipePatchesOnlyChoicesAndKeepsTheSavedPlan() async throws {
        try registerBackend(capsules: [capsule])
        var updated = capsule
        updated.revision = 2
        updated.recipe.executionCallLimit = 40
        updated.recipe.maxPlannerEscalations = 3
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated))
        BackendStub.respond(toPath: "/api/capsules/capsule-1") { _ in ["capsule": record] }
        let model = makeModel()
        await model.refresh()
        model.selectedID = capsule.id
        model.beginEditingRecipe()
        model.draftRecipe.executionCallLimit = 40
        model.draftRecipe.maxPlannerEscalations = 3
        await model.saveRecipeChanges()

        XCTAssertEqual(model.selectedCapsule?.revision, 2)
        XCTAssertEqual(model.selectedCapsule?.plan, plan)
        XCTAssertEqual(model.selectedCapsule?.recipe.executionCallLimit, 40)
        XCTAssertFalse(model.isEditingRecipe)
        let sent = try XCTUnwrap(BackendStub.requests.first { $0.httpMethod == "PATCH" })
        let body = try requestBody(sent)
        XCTAssertEqual(Set(body.keys), Set(["workspace_root", "expected_revision", "recipe"]))
        XCTAssertEqual(body["expected_revision"] as? Int, 1)
        XCTAssertNil(body["plan"], "Changing profiles must not recapture source fingerprints")
        XCTAssertTrue(executionRequests.isEmpty)
        XCTAssertTrue(planningRequests.isEmpty)
    }

    func testRecipeConflictKeepsDraftForReviewWithoutOverwritingSavedRevision() async throws {
        try registerBackend(capsules: [capsule])
        BackendStub.respond(toPath: "/api/capsules/capsule-1", status: 409) { _ in ["detail": "capsule changed; reload before saving"] }
        let model = makeModel()
        await model.refresh()
        model.selectedID = capsule.id
        model.beginEditingRecipe()
        model.draftRecipe.executionCallLimit = 40
        await model.saveRecipeChanges()
        XCTAssertEqual(model.selectedCapsule?.revision, 1)
        XCTAssertEqual(model.draftRecipe.executionCallLimit, 40)
        XCTAssertTrue(model.isEditingRecipe)
        XCTAssertNotNil(model.error)
        model.cancelRecipeEditing()
        XCTAssertEqual(model.draftRecipe.executionCallLimit, recipe.executionCallLimit)
    }

    func testWorkspaceSwitchCannotExecuteOrDisplayAnotherWorkspaceCapsule() async throws {
        try registerBackend(capsules: [capsule])
        let model = makeModel()
        await model.refresh()
        model.selectedID = capsule.id
        workspace = "/tmp/other-project"
        model.runSelected()
        XCTAssertTrue(executionRequests.isEmpty)
        XCTAssertNotNil(model.error)
        await model.refresh()
        XCTAssertTrue(model.capsules.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    func testSymlinkWorkspaceLoadsAndExecutesCanonicalSavedCapsule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capsule-path-\(UUID().uuidString)")
        let target = directory.appendingPathComponent("workspace")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        workspace = alias.path + "/."
        try registerBackend(capsules: [capsule])
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.workspaceRoot, target.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.capsules.count, 1)
        model.selectedID = capsule.id
        model.runSelected()
        XCTAssertEqual(executionRequests.count, 1)
        XCTAssertNil(model.error)
    }

    func testRichPlanRoundTripKeepsChecksAndBackwardCompatibleStepDefaults() throws {
        let encoded = try JSONEncoder().encode(capsule)
        let decoded = try JSONDecoder().decode(TaskCapsule.self, from: encoded)
        XCTAssertEqual(decoded.plan.stepDetails, plan.stepDetails)
        XCTAssertEqual(decoded.createdAt, "2026-09-06T15:00:00Z")
        let legacy = try JSONDecoder().decode(CapsulePlanStep.self, from: Data(#"{"id":"one","title":"Step"}"#.utf8))
        XCTAssertEqual(legacy.dependencies, [])
        XCTAssertEqual(legacy.checks, [])
    }

    func testNestedRunUsageDecodesProviderReportedTokensWithoutInventingCost() throws {
        let raw = #"{"run_id":"run-1","stage":"execute","state":"completed","usage":{"model_calls":4,"prompt_tokens":1000,"completion_tokens":300}}"#
        let run = try JSONDecoder().decode(TaskCapsuleRun.self, from: Data(raw.utf8))
        XCTAssertEqual(run.modelCalls, 4)
        XCTAssertEqual(run.totalTokens, 1300)
        XCTAssertEqual(run.status, "completed")
        XCTAssertNil(run.estimatedCost)
    }

    func testPlannerClarificationDoesNotConsumeAnotherHelpAllowance() throws {
        let raw = #"[{"run_id":"first","stage":"escalate","state":"completed"},{"run_id":"answer","stage":"escalate","state":"completed","continuation_of_run_id":"first"}]"#
        var value = capsule
        value.runs = try JSONDecoder().decode([TaskCapsuleRun].self, from: Data(raw.utf8))
        XCTAssertEqual(value.plannerHelpRequestsUsed, 1)
        XCTAssertEqual(value.plannerHelpRequestsRemaining, 0)
        value.recipe.maxPlannerEscalations = 2
        XCTAssertEqual(value.plannerHelpRequestsRemaining, 1)
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


extension TaskCapsuleModelTests {
    func testRecoveryActionsPreserveAttemptAndNeverStartAnotherExecution() async throws {
        var saved = capsule
        saved.attempts = [CapsuleAttempt(id: "original-attempt", state: "paused",
                                        steps: ["edit-coat": CapsuleStepProgress(state: "verified")])]
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        BackendStub.respond(toPath: "/api/capsules") { _ in ["capsules": [raw]] }
        let model = makeModel()
        await model.refresh()
        model.selectedID = saved.id
        model.resumeSelected()
        model.resumeSelected(checksOnly: true)
        XCTAssertEqual(resumeRequests.map { $0.0 }, ["original-attempt", "original-attempt"])
        XCTAssertEqual(resumeRequests.map { $0.1 }, [false, true])
        XCTAssertTrue(executionRequests.isEmpty)
        XCTAssertEqual(model.selectedCapsule?.recipe, saved.recipe)
    }

    func testLiveCheckingAndUncertainActionRecovery() async throws {
        try registerBackend(capsules: [capsule])
        let model = makeModel()
        await model.refresh()
        model.selectedID = capsule.id
        model.handleEvent(["type": "capsule_progress", "capsule_id": capsule.id,
                           "attempt": ["id": "attempt", "state": "running", "steps": [:],
                                       "verification_status": "checking"]], sessionID: "session")
        XCTAssertEqual(model.selectedCapsule?.attempts.first?.title, "Checking")
        XCTAssertNil(model.selectedCapsule?.resumableAttempt)
        model.handleEvent(["type": "capsule_progress", "capsule_id": capsule.id,
                           "attempt": ["id": "attempt", "state": "paused", "steps": [:],
                                       "uncertain_action": ["id": "action", "tool": "bash"]]], sessionID: "session")
        XCTAssertFalse(try XCTUnwrap(model.selectedCapsule?.resumableAttempt).canResume)
        model.resumeSelected()
        XCTAssertTrue(resumeRequests.isEmpty)
    }

    func testAcceptanceChecksAndLegacyCapsulesDecodeWithoutInventedEvidence() throws {
        let legacy = try JSONDecoder().decode(TaskCapsule.self, from: JSONEncoder().encode(capsule))
        XCTAssertTrue(legacy.attempts.isEmpty)
        XCTAssertTrue(legacy.plan.acceptanceChecks.isEmpty)
        var updated = capsule
        updated.plan.acceptanceChecks = [["id": .string("file"), "requirement": .string("Result exists"),
                                          "kind": .string("file_exists"), "path": .string("result.txt")]]
        let decoded = try JSONDecoder().decode(TaskCapsule.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.plan.acceptanceChecks, updated.plan.acceptanceChecks)
    }

    func testSeededRecoveryStatesRenderAtCompactSize() async throws {
        let ready = expectation(description: "Accessibility ready")
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(getpid())
            _ = AXUIElementSetMessagingTimeout(application, 0.2)
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 1)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("locus-recovery-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for state in ["paused", "needs_review"] {
            BackendStub.reset()
            var saved = capsule
            saved.attempts = [CapsuleAttempt(id: "attempt", state: state,
                steps: ["edit-coat": CapsuleStepProgress(state: "verified")],
                verificationStatus: state == "needs_review" ? "needs_review" : "pending",
                reason: state == "needs_review" ? "Compare the character's face with the approved reference." : "Stopped after one verified step.")]
            let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
            BackendStub.respond(toPath: "/api/capsules") { _ in ["capsules": [raw]] }
            BackendStub.respond(toPath: "/api/capsules/\(saved.id)") { _ in ["capsule": raw] }
            let model = makeModel()
            await model.refresh()
            model.selectedID = saved.id
            try await renderCapsule(model, size: NSSize(width: 680, height: 620), name: "Recovery-\(state)",
                                    primaryAction: state == "needs_review" ? "capsules.accept" : "capsules.resume", output: output)
        }
    }
    func testTaskDetailDecodesUnknownUsageAndExactPlanApproval() throws {
        let data = Data(#"{"id":"task","request":"Make a result","state":"paused","revision":4,"blocker":"Review pending","plan":{"id":"plan","title":"Saved","approval_reference":{"id":"plan","revision":2,"content_hash":"hash","execution_path":"/tmp"}},"usage":{"known_subtotal":0.25,"coverage":"partial","unknown_entries":1,"pending_entries":1,"subscription_entries":2,"local_entries":0,"entries":[],"spans":[]},"files":[],"progress":[],"links":[],"restorations":[],"reviews":[]}"#.utf8)
        let task = try JSONDecoder().decode(TaskDetailSnapshot.self, from: data)
        XCTAssertEqual(task.usage.coverage, "partial")
        XCTAssertTrue(task.usage.label.contains("partial"))
        XCTAssertFalse(task.allows("restore"), "Older projections do not authorize new mutations")
        XCTAssertFalse(task.allows("run_again"))
        XCTAssertEqual(task.verificationState, "unverified")
        XCTAssertEqual(task.plan?.approvalReference?["content_hash"]?.string, "hash")
        let saved = try JSONEncoder().encode(task.plan)
        let restored = try JSONDecoder().decode(PlanDocument.self, from: saved)
        XCTAssertEqual(restored.approvalReference, task.plan?.approvalReference)
    }

    func testOpeningTaskDetailOnlyReadsAndRendersAtCompactWidth() async throws {
        let record: [String: Any] = ["id": "task", "request": "Repair and verify the saved result", "state": "paused", "revision": 2,
            "blocker": "The final review is unresolved", "usage": ["known_subtotal": 0.25, "coverage": "partial", "unknown_entries": 1,
            "pending_entries": 1, "subscription_entries": 2, "local_entries": 0, "entries": [], "spans": []],
            "files": [["id": "edit", "path": "result.txt", "state": "captured"]],
            "progress": [["kind": "check_passed"]], "links": [], "restorations": [], "reviews": []]
        BackendStub.respond(toPath: "/api/sessions/fixture/task") { _ in record }
        let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let host = NSHostingView(rootView: TaskDetailView(sessionID: "fixture", compact: true).environmentObject(app))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(BackendStub.requests.contains { $0.url?.path == "/api/sessions/fixture/task" })
        XCTAssertTrue(BackendStub.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(host.bounds.width, 340)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Unified task detail at compact width"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTaskDetailUsesPersistedActionsAndAcceptsAdditiveFields() throws {
        let data = Data(#"{"id":"task","request":"Saved result","state":"paused","revision":8,"blocker":"","usage":{"known_subtotal":0,"coverage":"unknown","unknown_entries":0,"pending_entries":0,"subscription_entries":0,"local_entries":0,"entries":[],"spans":[]},"files":[],"progress":[],"links":[],"restorations":[],"reviews":[],"owner_kind":"work","run_id":"saved-run","actions":["restore","retry_checks"],"interface_version":1,"future_field":{"version":2},"outputs":[{"path":"result.txt","state":"present"}],"recovery_history":[{"state":"interrupted","reason":"Check interrupted"}]}"#.utf8)
        let task = try JSONDecoder().decode(TaskDetailSnapshot.self, from: data)
        XCTAssertTrue(task.allows("restore"))
        XCTAssertTrue(task.allows("retry_checks"))
        XCTAssertFalse(task.allows("resume"), "A paused label alone must not enable execution")
        XCTAssertFalse(task.allows("accept"))
        XCTAssertEqual(task.run_id, "saved-run")
        XCTAssertEqual(task.outputs?.first?.path, "result.txt")
        XCTAssertEqual(task.recovery_history?.first?["reason"]?.string, "Check interrupted")
    }

    func testCapsuleAndTaskDetailSheetsWaitForEachOtherToDismiss() {
        let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        app.taskCapsules.isPresented = true
        app.showTaskDetail(sessionID: "saved-session")
        XCTAssertFalse(app.taskCapsules.isPresented)
        XCTAssertFalse(app.taskDetailPresented)
        XCTAssertTrue(app.taskDetailAfterCapsuleDismissal)
        app.completeCapsuleTaskDismissal()
        XCTAssertTrue(app.taskDetailPresented)
        XCTAssertEqual(app.taskDetailSessionID, "saved-session")
        app.showTaskRecipe("saved-capsule")
        XCTAssertFalse(app.taskDetailPresented)
        XCTAssertFalse(app.taskCapsules.isPresented)
        app.completeTaskDetailDismissal()
        XCTAssertTrue(app.taskCapsules.isPresented)
        XCTAssertNil(app.taskRecipeAfterDetailDismissal)
        XCTAssertTrue(BackendStub.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testTaskDetailsDoNotRestartATeamWhenResumeNeedsRepair() async throws {
        let reset = expectation(description: "A repairable team must retain its checkpoint and allowance")
        reset.isInverted = true
        BackendStub.respond(toPath: "/api/runs/saved-team/retry") { _ in reset.fulfill(); return [:] }
        let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let run = try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(withJSONObject: [
            "id": "saved-team", "team_id": UUID().uuidString, "run_kind": "team", "workspace_root": "/tmp",
            "state": "paused", "request": "Preserve the saved plan", "created_at": 1,
            "updated_at": 2, "last_seq": 0, "pinned": false, "legacy": false, "recoverable": true]))
        app.resumeTaskRun(run)
        await fulfillment(of: [reset], timeout: 0.2)
        XCTAssertFalse(app.isBusy)
    }

}
