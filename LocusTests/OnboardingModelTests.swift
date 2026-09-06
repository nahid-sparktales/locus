import XCTest
@testable import Locus

final class OnboardingModelTests: XCTestCase {
    private let ready = OnboardingReadiness(agentReady: true, modelReady: true, modelName: "fixture", detail: "Ready")

    func testOlderProgressRunDecodesWithoutDurableID() throws {
        let raw = #"{"sessionID":"old-chat","workspace":"/tmp/example","outputPath":"Locus Summary.md","startedAt":1,"requestStartedAt":123}"#
        let run = try JSONDecoder().decode(OnboardingRun.self, from: Data(raw.utf8))
        XCTAssertNil(run.runID)
        XCTAssertEqual(run.sessionID, "old-chat")
    }

    func testDurableReceiptNeedsExactIdentityCompletedOutcomeAndSavedOutput() throws {
        let run = OnboardingRun(sessionID: "first-chat", workspace: "/tmp/example", outputPath: "Locus Summary.md",
                                startedAt: Date(timeIntervalSince1970: 100), requestStartedAt: 100_000, runID: "first-run")
        let raw = #"{"id":"first-run","session_id":"first-chat","workspace_root":"/tmp/example","state":"completed","created_at":100,"updated_at":105,"completed_at":105,"usage":{"completion_tokens":50}}"#
        let receipt = try JSONDecoder().decode(OnboardingRunReceipt.self, from: Data(raw.utf8))
        XCTAssertEqual(receipt.observation(for: run, savedOutput: true),
                       .completed(durationMilliseconds: 5000, outputTokensPerSecond: 10))
        XCTAssertEqual(receipt.observation(for: run, savedOutput: false, now: Date(timeIntervalSince1970: 110)),
                       .awaitingOutput(durationMilliseconds: 5000))
        guard case .failed = receipt.observation(for: run, savedOutput: false, now: Date(timeIntervalSince1970: 136)) else {
            return XCTFail("Missing output must fail after its bounded grace period")
        }
        var another = run
        another.runID = "later-run"
        guard case .failed = receipt.observation(for: another, savedOutput: true) else {
            return XCTFail("A later task must never complete the first task")
        }
        let active = OnboardingRunReceipt(id: "first-run", sessionID: run.sessionID, workspaceRoot: run.workspace,
            state: "running", createdAt: 100, updatedAt: 105, completedAt: nil)
        XCTAssertEqual(active.observation(for: run, savedOutput: true), .running)
        let cancelled = OnboardingRunReceipt(id: "first-run", sessionID: run.sessionID, workspaceRoot: run.workspace,
            state: "cancelled", createdAt: 100, updatedAt: 105, completedAt: 105)
        guard case .failed = cancelled.observation(for: run, savedOutput: true) else {
            return XCTFail("A saved draft must not count as a completed task")
        }
    }

    @MainActor
    func testSavedOutputRequiresRunAndSessionOnTheSameOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locus-onboarding-output-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OutputsLibraryStore(directory: root.appendingPathComponent("library"))
        let library = OutputsLibraryModel(store: store)
        try Data("A saved summary".utf8).write(to: workspace.appendingPathComponent("Locus Summary.md"))
        let original = try await store.capture(OutputCapture(workspace: workspace.path, path: "Locus Summary.md", sessionID: "old-chat", runID: "old-run"))
        let since = Date()
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "Locus Summary.md", sessionID: "first-chat", runID: "later-run"))
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "Locus Summary.md", sessionID: "other-chat", runID: "first-run"))
        let mixedOrigin = await library.hasSavedVersion(workspace: workspace.path, relativePath: "Locus Summary.md",
                                                       sessionID: "first-chat", since: since, runID: "first-run")
        XCTAssertFalse(mixedOrigin)
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "Locus Summary.md", sessionID: "first-chat", runID: "first-run"))
        let exactOrigin = await library.hasSavedVersion(workspace: workspace.path, relativePath: "Locus Summary.md",
                                                       sessionID: "first-chat", since: since, runID: "first-run")
        XCTAssertTrue(exactOrigin)
        let retained = try await store.list(workspace: workspace.path)
        XCTAssertEqual(retained.first?.versions.count, 1)
        XCTAssertEqual(retained.first?.versions.first?.capturedAt, original?.versions.first?.capturedAt)
        XCTAssertLessThan(try XCTUnwrap(retained.first?.versions.first?.capturedAt), since)
    }

    @MainActor
    func testNewInstallOffersSetupButExistingInstallDoesNot() {
        for existing in [false, true] {
            let model = OnboardingModel()
            XCTAssertFalse(model.isPresented)
            model.configure(isExistingInstallation: existing, autoPresent: true, readiness: { self.ready }, refresh: {},
                            start: { _, _ in throw CocoaError(.userCancelled) }, observe: { _ in .running })
            XCTAssertEqual(model.isPresented, !existing)
            model.present()
            XCTAssertTrue(model.isPresented)
        }
    }

    @MainActor
    func testSkipPersistsProgressWithoutCompletingFirstTask() throws {
        let name = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = OnboardingModel()
        model.configure(defaults: defaults, isExistingInstallation: false, autoPresent: true, readiness: { self.ready }, refresh: {},
                        start: { _, _ in throw CocoaError(.userCancelled) }, observe: { _ in .running })
        model.select(.coding)
        model.next()
        model.selectWorkspace("/tmp/example", sample: false)
        model.dismiss()
        let restored = OnboardingModel()
        restored.configure(defaults: defaults, isExistingInstallation: true, autoPresent: true, readiness: { self.ready }, refresh: {},
                           start: { _, _ in throw CocoaError(.userCancelled) }, observe: { _ in .running })
        XCTAssertFalse(restored.isPresented)
        XCTAssertFalse(restored.progress.firstTaskCompleted)
        XCTAssertEqual(restored.progress.step, .model)
        XCTAssertEqual(restored.progress.startingPoint, .coding)
        XCTAssertEqual(restored.progress.workspace, "/tmp/example")
    }

    @MainActor
    func testOnlySavedOutputCompletesTaskAndDuplicateStartIsSuppressed() async throws {
        var starts = 0
        var result = OnboardingRunObservation.awaitingOutput(durationMilliseconds: 1200)
        let model = OnboardingModel()
        model.configure(isExistingInstallation: false, autoPresent: false, readiness: { self.ready }, refresh: {}, start: { _, workspace in
            starts += 1
            return OnboardingRun(sessionID: "own-session", workspace: workspace, outputPath: "Locus Summary.md", startedAt: Date(), requestStartedAt: 123)
        }, observe: { _ in result })
        model.selectWorkspace("/tmp/own-workspace", sample: true)
        model.runFirstTask()
        model.runFirstTask()
        for _ in 0..<40 where model.progress.run == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.stopMonitoring()
        await model.refreshRun()
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(model.isWaitingForOutput)
        XCTAssertFalse(model.progress.firstTaskCompleted)
        model.requestOutputs()
        XCTAssertNil(model.takeOutputRequest())
        result = .completed(durationMilliseconds: 1200)
        await model.refreshRun()
        XCTAssertTrue(model.progress.firstTaskCompleted)
        XCTAssertEqual(model.progress.durationMilliseconds, 1200)
        model.present()
        model.requestOutputs()
        XCTAssertFalse(model.isPresented)
        let outputRequest = try XCTUnwrap(model.takeOutputRequest())
        XCTAssertEqual(outputRequest.workspace, "/tmp/own-workspace")
        XCTAssertEqual(outputRequest.sessionID, "own-session")
        XCTAssertNil(model.takeOutputRequest())
    }

    @MainActor
    func testDismissedRunningTaskResumesMonitoringAfterRestart() async throws {
        let name = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let run = OnboardingRun(sessionID: "background-session", workspace: "/tmp/first-workspace",
                                outputPath: "Locus Summary.md", startedAt: Date(), requestStartedAt: 123)
        let original = OnboardingModel()
        original.configure(defaults: defaults, isExistingInstallation: false, autoPresent: true,
                           readiness: { self.ready }, refresh: {}, start: { _, _ in run }, observe: { _ in .running })
        original.selectWorkspace(run.workspace, sample: false)
        original.runFirstTask()
        for _ in 0..<40 where original.progress.run == nil { try await Task.sleep(for: .milliseconds(10)) }
        original.dismiss()
        original.stopMonitoring()

        var observedRun: OnboardingRun?
        let restored = OnboardingModel()
        restored.configure(defaults: defaults, isExistingInstallation: true, autoPresent: true,
                           readiness: { .unknown }, refresh: {},
                           start: { _, _ in XCTFail("A restored task must not be started again"); return run },
                           observe: { value in
                               observedRun = value
                               return .completed(durationMilliseconds: 1500)
                           })
        for _ in 0..<40 where !restored.progress.firstTaskCompleted { try await Task.sleep(for: .milliseconds(10)) }
        restored.stopMonitoring()
        XCTAssertEqual(observedRun, run)
        XCTAssertFalse(restored.isPresented)
        XCTAssertTrue(restored.progress.firstTaskCompleted)
        XCTAssertEqual(restored.progress.durationMilliseconds, 1500)
        XCTAssertEqual(restored.progress.run?.workspace, run.workspace)
    }

    @MainActor
    func testUnrelatedBusyChatDoesNotHideInterruptedFirstTask() async {
        let app = AppModel(startImmediately: false)
        let run = OnboardingRun(sessionID: "interrupted-example", workspace: "/tmp/first-workspace",
                                outputPath: "Locus Summary.md", startedAt: Date().addingTimeInterval(-60), requestStartedAt: 123)
        app.sessionOverview.activate(sessionID: run.sessionID, initial: .empty(workspacePath: run.workspace))
        app.currentSessionID = "unrelated-running-chat"
        app.isBusy = true
        let observation = await app.observeOnboardingTask(run)
        guard case .failed = observation else {
            return XCTFail("An unrelated chat must not keep an interrupted example running")
        }
    }

    @MainActor
    func testFailedTaskCanRetryWithoutClaimingSuccess() async throws {
        var starts = 0
        let model = OnboardingModel()
        model.configure(isExistingInstallation: false, autoPresent: false, readiness: { self.ready }, refresh: {}, start: { _, workspace in
            starts += 1
            return OnboardingRun(sessionID: "attempt-\(starts)", workspace: workspace, outputPath: "Locus Summary.md", startedAt: Date(), requestStartedAt: starts)
        }, observe: { _ in .failed("Interrupted") })
        model.selectWorkspace("/tmp/test", sample: true)
        model.runFirstTask()
        for _ in 0..<40 where model.progress.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.progress.firstTaskCompleted)
        XCTAssertEqual(model.progress.failure, "Interrupted")
        model.runFirstTask()
        for _ in 0..<40 where starts < 2 { try await Task.sleep(for: .milliseconds(10)) }
        model.stopMonitoring()
        XCTAssertEqual(starts, 2)
    }

    @MainActor
    func testUnavailableModelDoesNotStartTask() {
        var starts = 0
        let model = OnboardingModel()
        model.configure(isExistingInstallation: false, autoPresent: false, readiness: { .unknown }, refresh: {}, start: { _, _ in
            starts += 1
            throw CocoaError(.userCancelled)
        }, observe: { _ in .running })
        model.selectWorkspace("/tmp/test", sample: true)
        model.runFirstTask()
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testChangingPathReplacesOnlySampleSelection() {
        let model = OnboardingModel()
        model.selectWorkspace("/tmp/document-sample", sample: true)
        model.select(.coding)
        XCTAssertNil(model.progress.workspace)
        model.selectWorkspace("/tmp/my-project", sample: false)
        model.select(.documents)
        XCTAssertEqual(model.progress.workspace, "/tmp/my-project")
    }

    func testSampleWorkspacesContainRealReadableInputsWithoutOverwritingUserFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("documents")
        let coding = base.appendingPathComponent("coding")
        try OnboardingSamples.create(at: documents, startingPoint: .documents)
        try OnboardingSamples.create(at: coding, startingPoint: .coding)
        let pdf = try Data(contentsOf: documents.appendingPathComponent("Locus Documents/Project Brief.pdf"))
        XCTAssertTrue(String(decoding: pdf.prefix(4), as: UTF8.self).hasPrefix("%PDF"))
        let code = try String(contentsOf: coding.appendingPathComponent("Checklist.swift"), encoding: .utf8)
        XCTAssertTrue(code.contains("items.filter(\\.isComplete)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Locus Summary.md").path))
    }
}
