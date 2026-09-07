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
    private var openedConversations: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        workspace = "/tmp/capsule-tests"
        planningRequests = []
        executionRequests = []
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
