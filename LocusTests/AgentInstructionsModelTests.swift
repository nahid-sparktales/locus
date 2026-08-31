import Combine
import XCTest

@testable import Locus

@MainActor
final class AgentInstructionsModelTests: XCTestCase {
    private var workspace: URL!
    private var toasts: [String] = []
    private var refreshedWorkspaceFiles = 0

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
        refreshedWorkspaceFiles = 0
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "agents-md-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace)
        try await super.tearDown()
    }

    private func makeModel(
        runIsActive: Bool = false,
        isUITesting: Bool = false
    ) -> AgentInstructionsModel {
        let model = AgentInstructionsModel()
        model.configure(
            backend: stubbedBackendService(),
            isUITesting: isUITesting,
            workspacePathProvider: { [workspace] in workspace!.path },
            runIsActive: { runIsActive },
            toastHandler: { [weak self] in self?.toasts.append($0) },
            workspaceFilesChanged: { [weak self] in self?.refreshedWorkspaceFiles += 1 }
        )
        return model
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeoutMessage: String
    ) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), timeoutMessage)
    }

    func testDirtyTrackingFollowsDraftEdits() {
        let model = makeModel()
        XCTAssertFalse(model.agentInstructionsHasUnsavedChanges)
        model.agentInstructionsDraft = "# edited"
        XCTAssertTrue(model.agentInstructionsHasUnsavedChanges)
    }

    func testSaveIsBlockedWhileARunIsActive() {
        let model = makeModel(runIsActive: true)
        model.agentInstructionsDraft = "# edited"
        model.saveAgentInstructions()
        XCTAssertEqual(toasts, ["Wait for the current run to finish before saving AGENTS.md"])
        XCTAssertFalse(model.isSavingAgentInstructions)
        XCTAssertNoBackendTraffic()
    }

    func testSaveWritesTheFileAndReloadsBackendContext() async throws {
        BackendStub.respond(toPath: "/api/context/reload") { _ in ["ok": true] }
        let model = makeModel()
        model.agentInstructionsDraft = "# Workspace instructions\n"
        model.saveAgentInstructions()
        try await waitUntil(
            self.toasts.isEmpty == false,
            timeoutMessage: "save never completed"
        )
        XCTAssertEqual(toasts, ["Saved AGENTS.md — instructions reloaded"])
        XCTAssertTrue(model.agentInstructionsExists)
        XCTAssertEqual(model.savedAgentInstructions, "# Workspace instructions\n")
        XCTAssertEqual(refreshedWorkspaceFiles, 1)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/context/reload"])
        let onDisk = try String(contentsOf: AgentInstructionsFile.url(for: workspace.path), encoding: .utf8)
        XCTAssertEqual(onDisk, "# Workspace instructions\n")
    }

    func testRefreshLoadsFromDiskAndProtectsDirtyDraft() async throws {
        try "# saved contents\n".write(
            to: AgentInstructionsFile.url(for: workspace.path),
            atomically: true,
            encoding: .utf8
        )
        let model = makeModel()
        model.refreshAgentInstructions()
        try await waitUntil(
            model.savedAgentInstructions.isEmpty == false,
            timeoutMessage: "refresh never completed"
        )
        XCTAssertEqual(model.agentInstructionsDraft, "# saved contents\n")
        XCTAssertTrue(model.agentInstructionsExists)

        model.agentInstructionsDraft = "# dirty"
        model.refreshAgentInstructions()
        XCTAssertEqual(toasts, ["Save or revert the AGENTS.md edits first"])
        XCTAssertEqual(model.agentInstructionsDraft, "# dirty")

        model.revertAgentInstructions()
        try await waitUntil(
            model.agentInstructionsDraft == "# saved contents\n",
            timeoutMessage: "revert never reloaded"
        )
        XCTAssertNoBackendTraffic()
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testAppModelRepublishesAgentInstructionsChanges() {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.agentInstructions.agentInstructionsDraft = "# bridge check"
        wait(for: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
