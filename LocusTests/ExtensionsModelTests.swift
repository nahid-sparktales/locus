import Combine
import XCTest

@testable import Locus

@MainActor
final class ExtensionsModelTests: XCTestCase {
    private var toasts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
    }

    private func makeModel() -> ExtensionsModel {
        let model = ExtensionsModel()
        model.configure(
            backend: stubbedBackendService(),
            isUITesting: false,
            workspacePathProvider: { "/tmp/ext-tests" },
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

    func testExtensionsChangedDebouncesIntoARefresh() async throws {
        let model = makeModel()
        model.ingest("extensions_changed", [:])
        model.ingest("mcp_status", [:])
        // Wait for the end of the refresh, not its start. The stub records a
        // request when it begins loading, so waiting on the path alone can
        // observe the request before its response has been handled — which is
        // what made this test fail on a loaded runner and pass locally.
        try await waitUntil(
            model.extensionErrorMessage != nil,
            timeoutMessage: "refresh never fired"
        )
        // Two rapid events coalesce into one debounced refresh.
        XCTAssertEqual(BackendStub.requestPaths.filter { $0 == "/api/extensions" }.count, 1)
    }

    func testMCPAuthRequiredSurfacesErrorAndToast() {
        let model = makeModel()
        model.ingest("mcp_auth_required", ["server_name": "GitHub"])
        XCTAssertEqual(model.extensionErrorMessage, "GitHub needs authentication in Settings → Extensions.")
        XCTAssertEqual(toasts, ["MCP authentication needed"])
    }

    func testAnswerMCPInputKeepsTheRequestWhenTheSocketIsDown() {
        let model = makeModel()
        model.mcpInputRequest = MCPInputRequest(
            id: "req-1",
            serverID: "server",
            mode: "form",
            message: "Provide input",
            url: nil,
            elicitationID: nil,
            schema: nil
        )
        model.answerMCPInput(action: "submit")
        XCTAssertNotNil(model.mcpInputRequest, "an undeliverable response must not drop the request")
        XCTAssertEqual(toasts, ["The MCP input response could not be delivered"])
    }

    func testRuntimeCredentialsFilterKeepsOnlyTransportMaterial() {
        let runtime = ExtensionsModel.runtimeMCPCredentials([
            "access_token": "tok",
            "refresh_token": "secret",
            "client_registration": "native-only",
            "headers": ["X": "y"],
        ])
        XCTAssertEqual(Set(runtime.keys), ["access_token", "headers"])
    }

}
