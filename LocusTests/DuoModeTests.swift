import XCTest
import SwiftUI
@testable import Locus

@MainActor
final class DuoModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "DuoModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func task() -> DuoTask {
        let planner = AgentProfile(name: "Planner", route: .providerAccount(UUID()), model: "strong", role: .planner)
        let executor = AgentProfile(name: "Builder", model: "small", role: .implementer, accessCeiling: .workspaceWrite)
        var recipe = TaskCapsuleRecipe()
        recipe.plannerProfileID = planner.id.uuidString
        recipe.executorProfileID = executor.id.uuidString
        let request = TaskCapsulePlanningRequest(title: "Change", request: "Make the change", workspaceRoot: "/tmp",
            recipe: recipe, originRunID: "plan-run", originSessionID: "task-one")
        return DuoTask(sessionID: "task-one", workspaceRoot: TaskCapsuleWorkspace.canonicalPath("/tmp"),
            planner: planner, executor: executor, request: request)
    }

    private func capsule(_ task: DuoTask) -> TaskCapsule {
        TaskCapsule(title: "Change", request: task.request.request, workspaceRoot: task.workspaceRoot,
                    plan: PlanDocument(title: "Change", steps: ["Implement", "Verify"]), recipe: task.request.recipe)
    }

    func testReadyPlanAndExactPairSurviveRestartAndDefaultChanges() throws {
        let model = DuoModel(defaults: defaults)
        let original = task()
        model.put(original)
        model.planSaved(capsule(original), request: original.request)
        let handoff = try XCTUnwrap(model.saved.tasks[original.sessionID]?.handoffID)
        model.setChoice(AgentProfile(name: "Other", model: "other"), planner: false)
        let restored = DuoModel(defaults: defaults)
        let value = try XCTUnwrap(restored.task(sessionID: original.sessionID, workspace: "/tmp"))
        XCTAssertEqual(value.phase, .ready)
        XCTAssertEqual(value.executor, original.executor)
        XCTAssertEqual(value.planner, original.planner)
        XCTAssertEqual(value.handoffID, handoff)
        XCTAssertNil(restored.task(sessionID: original.sessionID, workspace: "/different"))
        XCTAssertEqual(restored.saved.profiles.count, 3)
    }

    func testInterruptedBuildRestoresPausedWithoutChangingAcceptedHandoff() throws {
        let model = DuoModel(defaults: defaults)
        var original = task()
        original.capsule = capsule(original)
        original.phase = .executing
        model.put(original)
        let restored = try XCTUnwrap(DuoModel(defaults: defaults).saved.tasks[original.sessionID])
        XCTAssertEqual(restored.phase, .paused)
        XCTAssertEqual(restored.handoffID, original.handoffID)
    }

    func testOnlySuccessfulPlanTurnBecomesSaveableAndStaleRunCannotOverwriteIt() throws {
        let model = DuoModel(defaults: defaults)
        var original = task()
        original.activeRunID = "plan-run"
        model.put(original)
        let plan: [String: Any] = ["id": "p", "title": "Plan", "steps": ["Implement"]]
        model.handleEvent(["type": "plan_ready", "run_id": "old-run", "plan": plan], sessionID: original.sessionID)
        XCTAssertNil(model.saved.tasks[original.sessionID]?.submittedPlan)
        model.handleEvent(["type": "plan_ready", "run_id": "plan-run", "plan": plan], sessionID: original.sessionID)
        model.handleEvent(["type": "turn_done", "run_id": "plan-run", "reason": "interrupted"], sessionID: original.sessionID)
        XCTAssertEqual(model.saved.tasks[original.sessionID]?.phase, .planning)
        model.handleEvent(["type": "turn_done", "run_id": "plan-run", "reason": "complete"], sessionID: original.sessionID)
        XCTAssertEqual(model.saved.tasks[original.sessionID]?.phase, .saving)
        let restored = DuoModel(defaults: defaults)
        XCTAssertEqual(restored.saved.tasks[original.sessionID]?.submittedPlan?.title, "Plan")
    }

    func testLateSaveCannotReplaceAnotherPlanningRun() {
        let model = DuoModel(defaults: defaults)
        let original = task()
        var newer = original
        newer.request.originRunID = "new-run"
        model.put(newer)
        model.planSaved(capsule(original), request: original.request)
        XCTAssertNil(model.saved.tasks[original.sessionID]?.capsule)
        XCTAssertEqual(model.saved.tasks[original.sessionID]?.phase, .planning)
    }

    func testDuoIsInteractiveAndReadOnlyUntilItsExplicitStageDispatch() throws {
        XCTAssertTrue(WorkMode.allCases.contains(.duo))
        XCTAssertFalse(WorkMode.automationCases.contains(.duo))
        XCTAssertTrue(WorkMode.duo.instruction.contains("do not modify"))
        XCTAssertEqual(try JSONDecoder().decode(WorkMode.self, from: Data("\"duo\"".utf8)), .duo)
    }

    func testComposerSubmissionDispatchesPlannerAndKeepsDuoSelected() {
        let state = DuoModel(defaults: defaults)
        state.setChoice(AgentProfile(name: "Planner", model: "strong", role: .planner), planner: true)
        state.setChoice(AgentProfile(name: "Builder", model: "small", role: .implementer, accessCeiling: .workspaceWrite), planner: false)
        let app = AppModel(startImmediately: false, duoOverride: state)
        app.installTranscriptSession("task-one", blocks: [])
        app.agentRuntimePhase = .online
        app.selectedMode = .duo
        let ordinaryModel = app.selectedModel
        app.send("Implement the feature")
        XCTAssertEqual(app.selectedMode, .duo)
        XCTAssertEqual(app.turnDispatchedMode, .plan)
        XCTAssertTrue(app.turnDispatchedInPlanMode)
        XCTAssertEqual(app.duoTask?.planner.model, "strong")
        XCTAssertEqual(app.duoTask?.executor.model, "small")
        XCTAssertEqual(app.selectedModel, ordinaryModel)
        XCTAssertNotNil(app.taskCapsules.pendingPlanningRequest(for: "task-one"))
    }

    func testAcceptDispatchesBuilderOnceAndReviseWaitsForFeedback() throws {
        let state = DuoModel(defaults: defaults)
        let app = AppModel(startImmediately: false, duoOverride: state)
        app.installTranscriptSession("task-one", blocks: [])
        app.agentRuntimePhase = .online
        app.selectedMode = .duo
        var original = task()
        original.planner.route = .localOllama
        original.workspaceRoot = TaskCapsuleWorkspace.canonicalPath(app.workspacePath)
        original.request.workspaceRoot = original.workspaceRoot
        state.put(original)
        state.planSaved(capsule(original), request: original.request)
        app.reviseDuo()
        XCTAssertEqual(app.duoTask?.phase, .planning)
        XCTAssertFalse(app.isBusy, "Revise opens the conversation without spending a planner call")
        XCTAssertNil(app.taskCapsules.pendingPlanningRequest(for: "task-one"))
        let revisionDispatch = try XCTUnwrap(app.duoTask.flatMap { app.capsulePlanningDispatch($0.request) })
        XCTAssertEqual(revisionDispatch.context["stage"] as? String, "plan")
        XCTAssertNil(revisionDispatch.context["continuation_of_run_id"])
        original.request.originRunID = nil
        state.put(original)
        state.planSaved(capsule(original), request: original.request)
        let handoff = try XCTUnwrap(app.duoTask?.handoffID)
        app.acceptDuo()
        XCTAssertEqual(app.duoTask?.phase, .executing)
        XCTAssertEqual(app.turnDispatchedMode, .work)
        XCTAssertEqual(app.selectedMode, .duo)
        app.acceptDuo()
        XCTAssertEqual(app.duoTask?.handoffID, handoff)
        XCTAssertTrue(app.queuedMessages.isEmpty)
    }

    func testDuoPanelRendersReadyAndPausedAtNarrowWidth() async throws {
        let state = DuoModel(defaults: defaults)
        let app = AppModel(startImmediately: false, duoOverride: state)
        app.installTranscriptSession("task-one", blocks: [])
        var value = task()
        value.workspaceRoot = TaskCapsuleWorkspace.canonicalPath(app.workspacePath)
        value.request.workspaceRoot = value.workspaceRoot
        value.capsule = capsule(value)
        value.capsule?.plan.summary = "Use the existing settings controls and preserve the selected account."
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("locus-duo-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for phase in [DuoPhase.ready, .paused] {
            value.phase = phase
            state.put(value)
            let view = DuoComposerView(duo: state, capsules: app.taskCapsules)
                .environmentObject(app).padding(12).frame(width: 420, height: 300, alignment: .topLeading)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            let size = NSSize(width: 420, height: 300)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.center()
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            host.display()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(phase.rawValue).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Duo \(phase.rawValue) at 420px"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(host.bounds.size, size)
            XCTAssertGreaterThan(png.count, 2000)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        print("Duo renders: \(output.path)")
    }

    func testWaitingDuoDecisionPreservesQueuedMessages() {
        let state = DuoModel(defaults: defaults)
        let app = AppModel(startImmediately: false, duoOverride: state)
        app.installTranscriptSession("task-one", blocks: [])
        app.agentRuntimePhase = .online
        app.selectedMode = .duo
        var value = task()
        value.workspaceRoot = TaskCapsuleWorkspace.canonicalPath(app.workspacePath)
        for phase in [DuoPhase.saving, .ready, .paused] {
            value.phase = phase
            state.put(value)
            app.queuedMessages = ["Preserve this follow-up"]
            app.drainQueuedMessages()
            XCTAssertEqual(app.queuedMessages, ["Preserve this follow-up"])
            XCTAssertFalse(app.isBusy)
        }
    }
}
