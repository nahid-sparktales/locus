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

    private func mcpServer(_ overrides: [String: Any] = [:]) throws -> ExtensionMCPServer {
        var value: [String: Any] = ["id": "local", "name": "Macuse", "transport": "streamable_http",
            "url": "http://127.0.0.1:35792/mcp", "auth": "auto",
            "oauth": ["issuer": "http://127.0.0.1:35792/oauth", "authorization_endpoint": "",
                "token_endpoint": "", "client_id": "", "scopes": [], "allow_loopback_http": true]]
        value.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(ExtensionMCPServer.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testMCPDiagnosticsAreOptionalAndCopyContainsRuntimeEvidence() throws {
        let legacy = try mcpServer()
        XCTAssertNil(legacy.diagnostics)
        let server = try mcpServer(["diagnostics": [
            "transport": "stdio", "stage": "initialize", "target": "/Applications/Macuse",
            "elapsed_ms": 125, "auth_present": false, "causes": ["Connection closed"],
            "stderr_tail": "Missing MACUSE_TOKEN", "hints": ["Add the missing environment variable."],
        ]])
        let report = try XCTUnwrap(server.diagnostics).report
        XCTAssertTrue(report.contains("Stage: initialize"))
        XCTAssertTrue(report.contains("Missing MACUSE_TOKEN"))
        XCTAssertTrue(report.contains("Credentials: not provided"))
        XCTAssertTrue(report.contains("Add the missing environment variable."))
    }

    func testMCPFailedStatusIsTruthfulAndSurvivesSnapshotRefresh() async throws {
        let empty = try JSONEncoder().encode(ExtensionsResponse.empty)
        BackendStub.respond(toPath: "/api/extensions") { _ in empty }
        BackendStub.respond(toPath: "/api/extensions/mcp/test") { _ in ["status": [
            "id": "local", "name": "Macuse", "state": "error", "error": "Macuse refused the connection.",
            "diagnostics": ["stage": "connect", "http_status": 401],
        ]] }
        let model = makeModel()
        let connected = await model.testMCPServer("local")
        XCTAssertFalse(connected)
        XCTAssertEqual(model.extensionErrorMessage, "Macuse refused the connection.")
        XCTAssertEqual(model.mcpProbeStatuses["local"]?.diagnostics?.httpStatus, 401)
        XCTAssertEqual(toasts, ["MCP connection failed"])
        XCTAssertTrue(model.mcpOperations.isEmpty)
    }

    func testMCPHTTPFailureRefreshesAndKeepsErrorAndRetryClearsIt() async throws {
        let empty = try JSONEncoder().encode(ExtensionsResponse.empty)
        BackendStub.respond(toPath: "/api/extensions") { _ in empty }
        BackendStub.respond(toPath: "/api/extensions/mcp/test", status: 422) { _ in ["detail": "The command was not found."] }
        let model = makeModel()
        _ = await model.testMCPServer("local")
        XCTAssertEqual(model.extensionErrorMessage, "The command was not found.")
        XCTAssertTrue(BackendStub.requestPaths.contains("/api/extensions"))
        BackendStub.reset()
        BackendStub.respond(toPath: "/api/extensions") { _ in empty }
        BackendStub.respond(toPath: "/api/extensions/mcp/test") { _ in ["status": [
            "id": "local", "name": "Macuse", "state": "connected", "tool_count": 0,
        ]] }
        let connected = await model.testMCPServer("local")
        XCTAssertTrue(connected, "a server can connect successfully without tools")
        XCTAssertNil(model.extensionErrorMessage)
        XCTAssertNil(model.mcpProbeErrors["local"])
        XCTAssertEqual(toasts.last, "MCP server connected")
    }

    func testCredentialEditingPreservesOAuthAndOtherValuesWithExplicitRemoval() {
        let merged = ExtensionsModel.mergingMCPCredentials([
            "access_token": "oauth-access", "refresh_token": "native-refresh", "issuer": "https://issuer.test",
            "headers": ["First": "old", "Second": "kept", "Delete": "gone"], "env": ["TOKEN": "secret"],
        ], headers: ["First": "new", "Second": "", "Third": "added"], removedHeaders: ["Delete"])
        XCTAssertEqual(merged["refresh_token"] as? String, "native-refresh")
        XCTAssertEqual(merged["access_token"] as? String, "oauth-access")
        XCTAssertEqual(merged["headers"] as? [String: String], ["First": "new", "Second": "kept", "Third": "added"])
        XCTAssertEqual(merged["env"] as? [String: String], ["TOKEN": "secret"])
    }

    func testExplicitBearerReplacementCannotRefreshThePreviousOAuthAccount() async throws {
        let previous: [String: Any] = ["access_token": "old", "refresh_token": "old-refresh", "expires_at": 0,
            "issuer": "https://auth.test", "token_endpoint": "https://auth.test/token", "client_id": "registered",
            "headers": ["X-Account": "kept"], "env": ["TOKEN": "kept"]]
        let supplemental = ExtensionsModel.mergingMCPCredentials(previous, headers: ["X-Extra": "new"])
        XCTAssertEqual(supplemental["refresh_token"] as? String, "old-refresh")
        XCTAssertEqual(supplemental["expires_at"] as? Int, 0)
        let replaced = ExtensionsModel.mergingMCPCredentials(previous, accessToken: "explicit-fallback")
        XCTAssertNil(replaced["refresh_token"])
        XCTAssertNil(replaced["expires_at"])
        XCTAssertEqual(replaced["client_id"] as? String, "registered")
        XCTAssertEqual(replaced["headers"] as? [String: String], ["X-Account": "kept"])
        XCTAssertEqual(replaced["env"] as? [String: String], ["TOKEN": "kept"])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendStub.self]
        let coordinator = MCPAuthCoordinator(configurationForTesting: config, credentialStore: InMemoryMCPCredentialStore())
        let unchanged = try await coordinator.refreshedCredentialsIfNeeded(replaced)
        XCTAssertEqual(unchanged["access_token"] as? String, "explicit-fallback")
        XCTAssertNoBackendTraffic()
    }

    func testAdvancedConfigurationRoundTripsWithoutDiagnosticsOrLosingScope() throws {
        let server = try mcpServer(["protocol_mode": "legacy", "share_workspace_root": true,
            "cwd": "/tmp/work", "startup_timeout_sec": 42, "tool_timeout_sec": 200,
            "enabled_global": false, "enabled_workspaces": ["/tmp/work"], "disabled_workspaces": ["/tmp/other"],
            "env_vars": ["PATH"], "env_http_headers": ["X-Token": "TOKEN"], "preset_id": "fixture",
            "enabled_resources": ["data://one"], "enabled_prompts": ["review"], "resource_access": "selected",
            "diagnostics": ["stage": "connect"], "tool_policies": ["write": ["mode": "ask"]]])
        let payload = server.editableConfiguration
        XCTAssertEqual(payload["protocol_mode"] as? String, "legacy")
        XCTAssertEqual(payload["enabled_global"] as? Bool, false)
        XCTAssertEqual(payload["enabled_workspaces"] as? [String], ["/tmp/work"])
        XCTAssertEqual(payload["share_workspace_root"] as? Bool, true)
        XCTAssertEqual(payload["env_http_headers"] as? [String: String], ["X-Token": "TOKEN"])
        XCTAssertEqual(payload["preset_id"] as? String, "fixture")
        XCTAssertNotNil(payload["tools"])
        XCTAssertNil(payload["diagnostics"])
    }

    func testLoopbackOAuthPolicyIsBoundToTheConfiguredOriginAndOptIn() throws {
        let server = try mcpServer()
        let allowed = try MCPOAuthTransportPolicy(server: server)
        XCTAssertNoThrow(try allowed.url("http://127.0.0.1:35792/token", label: "token"))
        for value in ["http://127.0.0.1:35793/token", "http://localhost:35792/token", "http://[::1]:35792/token",
            "http://127.0.0.1.evil.test:35792/token", "http://192.168.1.1/token", "http://user:secret@127.0.0.1:35792/token",
            "http://127.0.0.1:35792/token#fragment", "https://auth.test/token", "https://127.0.0.1:35792/token"] {
            XCTAssertThrowsError(try allowed.url(value, label: "token"), value)
        }
        XCTAssertThrowsError(try allowed.url("https://auth.test/metadata", label: "metadata", resource: true))
        let disabled = try mcpServer(["oauth": ["issuer": "", "authorization_endpoint": "", "token_endpoint": "",
            "client_id": "", "scopes": []]])
        let policy = try MCPOAuthTransportPolicy(server: disabled)
        XCTAssertThrowsError(try policy.url("http://127.0.0.1:35792/token", label: "token"))
        XCTAssertNoThrow(try policy.url("https://auth.test/token", label: "token"))
        XCTAssertNoThrow(try policy.url("http://127.0.0.1:35792/mcp", label: "resource", resource: true))
    }

    func testLoopbackOAuthDiscoveryAndRefreshCarryOriginBinding() async throws {
        let server = try mcpServer()
        let store = InMemoryMCPCredentialStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendStub.self]
        BackendStub.respond(toPath: "/.well-known/oauth-protected-resource/mcp") { _ in [
            "resource": "http://127.0.0.1:35792/mcp", "authorization_servers": ["http://127.0.0.1:35792/oauth"],
        ] }
        BackendStub.respond(toPath: "/.well-known/oauth-authorization-server/oauth") { _ in [
            "issuer": "http://127.0.0.1:35792/oauth", "authorization_endpoint": "http://127.0.0.1:35792/authorize",
            "token_endpoint": "http://127.0.0.1:35792/token", "registration_endpoint": "http://127.0.0.1:35792/register",
            "code_challenge_methods_supported": ["S256"],
        ] }
        BackendStub.respond(toPath: "/register") { _ in ["client_id": "local-client"] }
        BackendStub.respond(toPath: "/token") { _ in ["access_token": "rotated", "refresh_token": "next", "expires_in": 3600] }
        let coordinator = MCPAuthCoordinator(configurationForTesting: config, credentialStore: store)
        let resolved = try await coordinator.resolvedConfigurationForTesting(server: server)
        XCTAssertEqual(resolved["issuer"] as? String, "http://127.0.0.1:35792/oauth")
        var credentials = try XCTUnwrap(store.get(serverID: server.id))
        XCTAssertEqual(credentials["loopback_oauth_origin"] as? String, "http://127.0.0.1:35792")
        credentials["refresh_token"] = "native-only"; credentials["expires_at"] = 0
        let refreshed = try await coordinator.refreshedCredentialsIfNeeded(credentials, server: server)
        XCTAssertEqual(refreshed["access_token"] as? String, "rotated")
        XCTAssertEqual(refreshed["refresh_token"] as? String, "next")
        let changed = try mcpServer(["url": "http://127.0.0.1:35793/mcp"])
        XCTAssertFalse(ExtensionsModel.mcpCredentials(refreshed, areBoundTo: changed))
        do { _ = try await coordinator.refreshedCredentialsIfNeeded(credentials, server: changed); XCTFail("changed origin refreshed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertFalse(ExtensionsModel.runtimeMCPCredentials(refreshed).keys.contains("loopback_oauth_origin"))
    }

    func testLoopbackRefreshRequiresBindingEvenWhenCompatibilityIsEnabled() async throws {
        let server = try mcpServer()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendStub.self]
        let coordinator = MCPAuthCoordinator(configurationForTesting: config, credentialStore: InMemoryMCPCredentialStore())
        do {
            _ = try await coordinator.refreshedCredentialsIfNeeded([
                "refresh_token": "unbound", "token_endpoint": "http://127.0.0.1:35792/token",
                "resource": "http://127.0.0.1:35792/mcp", "issuer": "http://127.0.0.1:35792/oauth",
                "client_id": "client", "expires_at": 0,
            ], server: server)
            XCTFail("unbound local credentials refreshed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("do not match")) }
        XCTAssertNoBackendTraffic()
    }

    func testManualOAuthWithoutIssuerUsesAuthorizationOrigin() async throws {
        let server = try mcpServer(["url": "https://mcp.test/mcp", "auth": "oauth", "oauth": [
            "issuer": "", "authorization_endpoint": "https://auth.test/authorize",
            "token_endpoint": "https://auth.test/token", "client_id": "client", "scopes": [],
        ]])
        let coordinator = MCPAuthCoordinator(credentialStore: InMemoryMCPCredentialStore())
        let resolved = try await coordinator.resolvedConfigurationForTesting(server: server)
        XCTAssertEqual(resolved["issuer"] as? String, "https://auth.test")
        XCTAssertNoBackendTraffic()
    }

    func testCatalogPluginIdentifierRetainsSlashesAndReadDoesNotChangePolicy() async throws {
        BackendStub.respond(toPath: "/api/extensions/mcp/plugin:demo/server/catalog") { _ in
            ["resources": [], "templates": [], "prompts": []]
        }
        let model = makeModel()
        try await model.loadMCPCatalog("plugin:demo/server")
        XCTAssertEqual(BackendStub.requestPaths, ["/api/extensions/mcp/plugin:demo/server/catalog"])
        XCTAssertNotNil(model.mcpCatalogs["plugin:demo/server"])
    }

    func testResourceTemplateParametersPreserveOrderAndRemoveModifiers() throws {
        let resource = try JSONDecoder().decode(MCPResourceEntry.self, from: Data(#"{"uri":"repo://{owner}/{repo}{?query,limit:3}{/path*}","name":"repo","template":true}"#.utf8))
        XCTAssertEqual(resource.parameterNames, ["owner", "repo", "query", "limit", "path"])
    }

    private func snapshot(_ server: ExtensionMCPServer) -> ExtensionsResponse {
        ExtensionsResponse(capabilities: ExtensionCapabilities(), marketplaces: [], plugins: [], skills: [],
            mcpServers: [server], mcpPresets: [], errors: [], pendingUpdates: 0)
    }

    func testCredentialBindingRejectsIdentityChangesAndPreservesDisplayPolicyEdits() throws {
        let server = try mcpServer()
        let values: [String: Any] = ["access_token": "bound", "mcp_server_binding": server.credentialBinding]
        let renamed = try mcpServer(["name": "Renamed", "enabled_global": false,
            "startup_timeout_sec": 60, "resource_access": "none"])
        XCTAssertTrue(ExtensionsModel.mcpCredentials(values, areBoundTo: renamed))
        for changed in [try mcpServer(["auth": "none"]), try mcpServer(["transport": "sse"]),
            try mcpServer(["url": "http://127.0.0.1:35792/other"]), try mcpServer(["oauth": [
                "issuer": "http://127.0.0.1:35792/oauth", "authorization_endpoint": "",
                "token_endpoint": "http://127.0.0.1:35792/new-token", "client_id": "", "scopes": [],
                "allow_loopback_http": true]])] {
            XCTAssertFalse(ExtensionsModel.mcpCredentials(values, areBoundTo: changed))
        }
        XCTAssertNil(ExtensionsModel.runtimeMCPCredentials(values)["mcp_server_binding"])
    }

    func testSavingChangedServerClearsLegacyCredentialsBeforeSnapshotRestore() async throws {
        let original = try mcpServer()
        let changed = try mcpServer(["auth": "none"])
        let store = InMemoryMCPCredentialStore()
        XCTAssertTrue(store.set(["access_token": "old-token", "headers": ["X-Account": "old-secret"]], serverID: original.id))
        let model = makeModel(credentialStore: store)
        model.extensions = snapshot(original)
        let savedData = try JSONEncoder().encode(changed)
        let snapshotData = try JSONEncoder().encode(snapshot(changed))
        BackendStub.respond(toPath: "/api/extensions/mcp") { _ in savedData }
        BackendStub.respond(toPath: "/api/extensions") { _ in snapshotData }
        let saved = await model.saveMCPServer(["id": original.id, "auth": "none"])
        XCTAssertTrue(saved)
        XCTAssertNil(store.get(serverID: original.id))
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/extensions/mcp/credentials"))
    }

    func testUnchangedLegacyCredentialsMigrateAndChangedContextDoesNotReplay() async throws {
        let server = try mcpServer(["auth": "bearer", "oauth": NSNull()])
        let store = InMemoryMCPCredentialStore()
        XCTAssertTrue(store.set(["access_token": "legacy-valid", "headers": ["X-Account": "kept"]], serverID: server.id))
        let originalData = try JSONEncoder().encode(snapshot(server))
        BackendStub.respond(toPath: "/api/extensions") { _ in originalData }
        let model = makeModel(credentialStore: store)
        await model.refreshExtensions()
        XCTAssertEqual(store.get(serverID: server.id)?["mcp_server_binding"] as? String, server.credentialBinding)
        XCTAssertEqual(store.get(serverID: server.id)?["headers"] as? [String: String], ["X-Account": "kept"])
        BackendStub.reset()
        let changed = try mcpServer(["auth": "none", "oauth": NSNull()])
        let changedData = try JSONEncoder().encode(snapshot(changed))
        BackendStub.respond(toPath: "/api/extensions") { _ in changedData }
        await model.refreshExtensions()
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/extensions/mcp/credentials"))
        XCTAssertTrue(model.extensionErrorMessage?.contains("no longer match") == true)
    }

    func testAuthorizationHeaderConflictDoesNotOverwriteSavedOAuth() async throws {
        let server = try mcpServer()
        let store = InMemoryMCPCredentialStore()
        XCTAssertTrue(store.set(["access_token": "oauth-access", "refresh_token": "native-only",
            "mcp_server_binding": server.credentialBinding], serverID: server.id))
        let model = makeModel(credentialStore: store)
        model.extensions = snapshot(server)
        let saved = await model.updateMCPTransportCredentials(serverID: server.id, accessToken: nil,
            headers: ["authorization": "custom"], env: [:], removedHeaders: [], removedEnv: [])
        XCTAssertFalse(saved)
        XCTAssertTrue(model.extensionErrorMessage?.contains("Authorization is already supplied") == true)
        XCTAssertEqual(store.get(serverID: server.id)?["refresh_token"] as? String, "native-only")
        XCTAssertNoBackendTraffic()
    }

    func testCatalogDecodesDisabledToolsWithoutRequiringAgentExposureFields() throws {
        let catalog = try JSONDecoder().decode(MCPServerCatalog.self, from: Data(#"{"tools":[{"name":"write","description":"Write a file","approval_mode":"disabled","enabled":false}],"resources":[],"templates":[],"prompts":[]}"#.utf8))
        let tool = try XCTUnwrap(catalog.tools?.first?.permissionMetadata)
        XCTAssertEqual(tool.name, "write")
        XCTAssertEqual(tool.approvalMode, "disabled")
        XCTAssertFalse(tool.active)
    }

}
