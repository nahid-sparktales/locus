import Combine
import XCTest

@testable import Locus

@MainActor
final class EvaluationsModelTests: XCTestCase {
    private var toasts: [String] = []
    private var manifestRequests: [(prompt: String, teamID: UUID)] = []
    private var manifest: [String: Any]?

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
        manifestRequests = []
        manifest = nil
    }

    private func makeModel(selectedTeamID: UUID? = nil) -> EvaluationsModel {
        let model = EvaluationsModel()
        model.configure(
            backend: stubbedBackendService(),
            workspacePathProvider: { "/tmp/eval-tests" },
            selectedTeamIDProvider: { selectedTeamID },
            manifestProvider: { [weak self] prompt, teamID in
                self?.manifestRequests.append((prompt, teamID))
                return self?.manifest
            },
            toastHandler: { [weak self] in self?.toasts.append($0) }
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

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testIngestTracksTheEvaluationLifecycle() async throws {
        BackendStub.respond(toPath: "/api/evaluations") { _ in ["suites": []] }
        let model = makeModel()

        model.ingest("evaluation_started", ["evaluation_id": "eval-1"])
        XCTAssertEqual(model.activeEvaluationID, "eval-1")
        XCTAssertEqual(model.evaluationStatus, "Starting evaluation")

        model.ingest("evaluation_case_started", ["case_index": 1, "case_count": 3])
        XCTAssertEqual(model.evaluationStatus, "Running case 2 of 3")

        model.ingest("evaluation_case_completed", [:])
        XCTAssertEqual(model.evaluationStatus, "Grading results")

        model.ingest("evaluation_completed", ["state": "interrupted"])
        XCTAssertNil(model.activeEvaluationID)
        XCTAssertEqual(model.evaluationStatus, "Evaluation interrupted")
        try await waitUntil(
            BackendStub.requestPaths.contains("/api/evaluations"),
            timeoutMessage: "completion never refreshed the suites"
        )
    }

    func testRunBlocksWhenATeamCaseHasNoManifest() {
        let teamID = UUID()
        var suite = EvaluationSuite(
            name: "Suite",
            workspaceRoot: "/tmp/eval-tests",
            cases: [EvaluationCase(name: "case", prompt: "do the thing")]
        )
        suite.cases[0].teamID = teamID.uuidString
        let model = makeModel()
        model.runEvaluationSuite(suite)
        XCTAssertEqual(toasts, ["Select or repair every team used by this suite"])
        XCTAssertEqual(manifestRequests.count, 1)
        XCTAssertNoBackendTraffic()
    }

    func testRunPostsManifestsForTeamCases() async throws {
        let teamID = UUID()
        manifest = ["team": "manifest"]
        BackendStub.respond(whenPathHasPrefix: "/api/evaluations/") { _ in
            ["ok": true, "evaluation_id": "eval-9", "state": "queued"]
        }
        var suite = EvaluationSuite(
            name: "Suite",
            workspaceRoot: "/tmp/eval-tests",
            cases: [EvaluationCase(name: "case", prompt: "do the thing")]
        )
        suite.cases[0].teamID = teamID.uuidString
        let model = makeModel(selectedTeamID: teamID)
        model.runEvaluationSuite(suite)
        try await waitUntil(
            model.activeEvaluationID == "eval-9",
            timeoutMessage: "run response never landed"
        )
        XCTAssertEqual(model.evaluationStatus, "Queued")
        XCTAssertEqual(BackendStub.requests[0].url?.path, "/api/evaluations/\(suite.id)/run")
        XCTAssertEqual(toasts, [])
    }

    func testAppModelRepublishesEvaluationChanges() async throws {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.evaluations.objectWillChange.send()
        await fulfillment(of: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
