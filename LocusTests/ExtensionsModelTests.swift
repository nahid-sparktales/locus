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

    private func makeModel(credentialStore: (any MCPCredentialStoring)? = nil) -> ExtensionsModel {
        let model = ExtensionsModel(credentialStore: credentialStore ?? InMemoryMCPCredentialStore())
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

    func testMCPMemoryStoresValidateJSONAndNeverShareRegistrations() {
        let first = InMemoryMCPCredentialStore()
        let second = InMemoryMCPCredentialStore()
        XCTAssertTrue(first.set(["refresh_token": "fixture-only"], serverID: "same-fixture"))
        XCTAssertEqual(first.get(serverID: "same-fixture")?["refresh_token"] as? String, "fixture-only")
        XCTAssertNil(second.get(serverID: "same-fixture"))
        XCTAssertFalse(first.set(["invalid": Date()], serverID: "same-fixture"))
        XCTAssertEqual(first.get(serverID: "same-fixture")?["refresh_token"] as? String, "fixture-only")
        second.removeOrphaned(keeping: [])
        XCTAssertNotNil(first.get(serverID: "same-fixture"))
        first.removeOrphaned(keeping: [])
        XCTAssertNil(first.get(serverID: "same-fixture"))
    }

    func testFailedMCPRuntimeHandoffRestoresOnlyInjectedCredentials() async {
        let store = InMemoryMCPCredentialStore()
        XCTAssertTrue(store.set(["access_token": "previous"], serverID: "fixture"))
        let model = makeModel(credentialStore: store)
        let saved = await model.setMCPCredentials(
            serverID: "fixture", values: ["access_token": "replacement", "refresh_token": "native-only"]
        )
        XCTAssertFalse(saved, "the unstubbed runtime handoff must fail")
        XCTAssertEqual(store.get(serverID: "fixture")?["access_token"] as? String, "previous")
        XCTAssertNil(store.get(serverID: "fixture")?["refresh_token"])

        let newSaved = await model.setMCPCredentials(serverID: "new-fixture", values: ["access_token": "new"])
        XCTAssertFalse(newSaved)
        XCTAssertNil(store.get(serverID: "new-fixture"))
    }

    func testCompleteMCPRefreshSweepsOnlyTheInjectedStore() async throws {
        let store = InMemoryMCPCredentialStore()
        let independent = InMemoryMCPCredentialStore()
        XCTAssertTrue(store.set(["access_token": "orphan"], serverID: "fixture"))
        XCTAssertTrue(independent.set(["access_token": "survivor"], serverID: "fixture"))
        let empty = try JSONEncoder().encode(ExtensionsResponse.empty)
        BackendStub.respond(toPath: "/api/extensions") { _ in empty }
        let model = makeModel(credentialStore: store)
        await model.refreshExtensions()
        XCTAssertNil(model.extensionErrorMessage)
        XCTAssertNil(store.get(serverID: "fixture"))
        XCTAssertEqual(independent.get(serverID: "fixture")?["access_token"] as? String, "survivor")
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
