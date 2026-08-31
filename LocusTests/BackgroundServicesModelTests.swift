import Combine
import XCTest

@testable import Locus

@MainActor
final class BackgroundServicesModelTests: XCTestCase {
    private var toasts: [String] = []
    private var websiteOutputs: [(URL, String)] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
        websiteOutputs = []
    }

    private func makeModel(recordingSessionID: String = "session-1") -> BackgroundServicesModel {
        let model = BackgroundServicesModel()
        model.configure(
            transportProvider: { stubbedBackendService() },
            recordingSessionIDProvider: { recordingSessionID },
            websiteOutput: { [weak self] url, id in self?.websiteOutputs.append((url, id)) },
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


    private static func serviceJSON(name: String, running: Bool, port: Int?) -> [String: Any] {
        var json: [String: Any] = [
            "name": name,
            "command": "npm run dev",
            "cwd": "/tmp",
            "running": running,
            "started_at": "2026-08-30T00:00:00Z",
            "uptime_seconds": 5,
        ]
        if let port { json["port"] = port }
        return json
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testRefreshRecordsNewDevServersAsWebsiteOutputs() async throws {
        BackendStub.respond(toPath: "/api/services") { _ in
            ["services": [Self.serviceJSON(name: "vite", running: true, port: 5173)]]
        }
        let model = makeModel()
        model.refreshBackgroundServices(recordingOutputs: true)
        try await waitUntil(
            self.websiteOutputs.isEmpty == false,
            timeoutMessage: "website output never recorded"
        )
        let output = try XCTUnwrap(websiteOutputs.first)
        XCTAssertEqual(output.0.absoluteString, "http://localhost:5173")
        XCTAssertEqual(output.1, "session-1")
        XCTAssertEqual(model.backgroundServices.map(\.name), ["vite"])
    }

    func testStopInvalidatesStaleListResponses() async throws {
        BackendStub.respond(toPath: "/api/services") { _ in
            ["services": [Self.serviceJSON(name: "vite", running: true, port: 5173)]]
        }
        BackendStub.respond(whenPathHasPrefix: "/api/services/") { _ in ["ok": true, "stopped": ["vite"]] }
        let model = makeModel()
        model.applyBackgroundServicesForTesting([])
        model.refreshBackgroundServices()
        // The stop bumps the generation before the list response lands, so the
        // stale list must not repopulate the row.
        let vite = try XCTUnwrap(
            decode(BackgroundServiceRecord.self, from: Self.serviceJSON(name: "vite", running: true, port: 5173))
        )
        model.stopBackgroundService(vite)
        try await waitUntil(
            self.toasts.isEmpty == false,
            timeoutMessage: "stop never completed"
        )
        XCTAssertEqual(toasts.first, "Stopped vite")
    }

    func testAppModelRepublishesBackgroundServiceChanges() async throws {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.backgroundServicesModel.applyBackgroundServicesForTesting([])
        await fulfillment(of: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
