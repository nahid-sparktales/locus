import AppKit
import Foundation

/// Owns the extension surface: installed plugins/skills/marketplaces, the
/// catalog, MCP servers with their credentials and device-flow auth, and the
/// MCP input/authorization prompts fed by backend events. AppModel wires it
/// via configure(...) and bridges its publication; it never retains AppModel.
@MainActor
final class ExtensionsModel: ObservableObject {
    @Published var extensions = ExtensionsResponse.empty
    @Published private(set) var extensionCatalog: [ExtensionCatalogEntry] = []
    @Published private(set) var extensionTools: [ExtensionToolMetadata] = []
    @Published var extensionErrorMessage: String?
    @Published private(set) var isLoadingExtensions = false
    @Published var mcpInputRequest: MCPInputRequest?
    @Published var mcpDeviceAuthorization: MCPDeviceAuthorizationPrompt?

    private let mcpAuthCoordinator: MCPAuthCoordinator
    private let credentialStore: any MCPCredentialStoring
    private var extensionRefreshTask: Task<Void, Never>?

    private var backend: BackendService?
    private var isUITesting = false
    private var workspacePathProvider: () -> String = { "" }
    private var toastHandler: (String) -> Void = { _ in }

    init(credentialStore: (any MCPCredentialStoring)? = nil) {
        let credentialStore = credentialStore ?? KeychainMCPCredentialStore()
        self.credentialStore = credentialStore
        mcpAuthCoordinator = MCPAuthCoordinator(credentialStore: credentialStore)
    }

    func configure(
        backend: BackendService,
        isUITesting: Bool,
        workspacePathProvider: @escaping () -> String,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.isUITesting = isUITesting
        self.workspacePathProvider = workspacePathProvider
        self.toastHandler = toastHandler
    }

    /// Backend extension and MCP events, routed here by AppModel's dispatcher.
    func ingest(_ type: String, _ event: [String: Any]) {
        switch type {
        case "extensions_changed", "mcp_status", "mcp_credential_refresh":
            extensionRefreshTask?.cancel()
            extensionRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                await self?.refreshExtensions()
            }

        case "mcp_auth_required":
            let name = event["server_name"] as? String ?? "MCP server"
            extensionErrorMessage = "\(name) needs authentication in Settings → Extensions."
            toastHandler("MCP authentication needed")

        case "mcp_input_required":
            mcpInputRequest = decode(MCPInputRequest.self, from: event)

        case "mcp_input_rejected":
            let message = event["message"] as? String
                ?? "Sensitive MCP input must use a verified browser flow."
            toastHandler(message)

        default:
            break
        }
    }

    func refreshExtensions() async {
        guard !isUITesting, let backend else { return }
        isLoadingExtensions = true
        defer { isLoadingExtensions = false }
        do {
            let response = try await backend.get("/api/extensions", as: ExtensionsResponse.self)
            extensions = response
            extensionErrorMessage = response.errors.first
            // Reclaim OAuth tokens whose server is gone — but only from a
            // clean read. An empty `errors` is the agent's promise that this
            // list is complete (ExtensionManager._load_state reports a
            // degraded read through it); without that promise a truncated or
            // unreadable state file would present as "no servers" and this
            // would delete live third-party refresh tokens rather than orphans.
            if response.errors.isEmpty {
                credentialStore.removeOrphaned(
                    keeping: Set(response.mcpServers.map(\.id))
                )
            }
            await restoreExtensionCredentials(for: response.mcpServers)
            if let response = try? await backend.get("/api/tools", as: ExtensionToolsResponse.self) {
                extensionTools = response.tools
            }
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func refreshExtensionCatalog(query: String = "", marketplaceID: String = "") async {
        guard let backend else { return }
        do {
            let response = try await backend.get(
                "/api/extensions/catalog",
                query: [
                    URLQueryItem(name: "query", value: query),
                    URLQueryItem(name: "marketplace_id", value: marketplaceID),
                ],
                as: ExtensionCatalogResponse.self
            )
            extensionCatalog = response.entries
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func addMarketplace(source: String, name: String = "") async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/marketplaces",
                body: ["source": source, "name": name],
                timeout: 190,
                as: ExtensionMarketplace.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func refreshMarketplace(_ id: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/marketplaces/\(id)/refresh",
                body: [:],
                timeout: 190,
                as: ExtensionMarketplace.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func removeMarketplace(_ id: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.delete(
                "/api/extensions/marketplaces/\(id)",
                as: ExtensionOperationResponse.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func inspectPlugin(_ entry: ExtensionCatalogEntry) async -> PluginTrustResponse? {
        guard let backend else { return nil }
        do {
            return try await backend.get(
                "/api/extensions/catalog/trust",
                query: [
                    URLQueryItem(name: "marketplace_id", value: entry.marketplaceID),
                    URLQueryItem(name: "plugin", value: entry.name),
                ],
                as: PluginTrustResponse.self
            )
        } catch {
            extensionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func inspectUpdate(
        for plugin: ExtensionPlugin
    ) async -> (ExtensionCatalogEntry, PluginTrustResponse)? {
        await refreshExtensionCatalog()
        guard let entry = extensionCatalog.first(where: { $0.id == plugin.id }) else {
            extensionErrorMessage = "The plugin is no longer available from its marketplace."
            return nil
        }
        guard let trust = await inspectPlugin(entry) else { return nil }
        return (entry, trust)
    }

    func installPlugin(
        _ entry: ExtensionCatalogEntry,
        trust: PluginTrustResponse,
        scope: String = "global"
    ) async {
        guard let backend else { return }
        do {
            let path = entry.installed
                ? "/api/extensions/plugins/update"
                : "/api/extensions/plugins/install"
            let body: [String: Any] = entry.installed
                ? ["id": entry.id, "expected_digest": trust.digest]
                : [
                    "marketplace_id": entry.marketplaceID,
                    "plugin": entry.name,
                    "expected_digest": trust.digest,
                    "scope": scope,
                    "workspace": workspacePathProvider(),
                ]
            _ = try await backend.post(
                path,
                body: body,
                timeout: 190,
                as: ExtensionPlugin.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
            toastHandler(entry.installed ? "Plugin updated" : "Plugin installed")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setPlugin(_ id: String, enabled: Bool, scope: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/plugins/enable",
                body: [
                    "id": id, "enabled": enabled, "scope": scope,
                    "workspace": workspacePathProvider(),
                ],
                as: ExtensionPlugin.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func rollbackPlugin(_ id: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/plugins/rollback",
                body: ["id": id],
                as: ExtensionPlugin.self
            )
            await refreshExtensions()
            toastHandler("Plugin rolled back")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func uninstallPlugin(_ id: String) async {
        guard let backend else { return }
        let credentialServerIDs = extensions.mcpServers
            .filter { $0.pluginID == id }
            .map(\.id)
        do {
            _ = try await backend.delete(
                "/api/extensions/plugins/\(id)",
                as: ExtensionOperationResponse.self
            )
            for serverID in credentialServerIDs {
                credentialStore.remove(serverID: serverID)
            }
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func importSkill(from source: String, scope: String = "global") async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/skills/import",
                body: ["source": source, "scope": scope, "workspace": workspacePathProvider()],
                as: ExtensionSkill.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setSkill(_ id: String, enabled: Bool, scope: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/skills/enable",
                body: [
                    "id": id, "enabled": enabled, "scope": scope,
                    "workspace": workspacePathProvider(),
                ],
                as: ExtensionSkill.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func removeSkill(_ id: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.delete(
                "/api/extensions/skills/\(id)",
                as: ExtensionOperationResponse.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func saveMCPServer(_ body: [String: Any]) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/mcp",
                body: body,
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func materializeMCPPreset(
        _ preset: ExtensionMCPPreset,
        projectRef: String = ""
    ) async -> ExtensionMCPServer? {
        guard let backend else { return nil }
        do {
            let server = try await backend.post(
                "/api/extensions/mcp/presets/materialize",
                body: ["id": preset.id, "project_ref": projectRef],
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
            return server
        } catch {
            extensionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func setMCPServer(_ id: String, enabled: Bool, scope: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/enable",
                body: [
                    "id": id, "enabled": enabled, "scope": scope,
                    "workspace": workspacePathProvider(),
                ],
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func testMCPServer(_ id: String) async -> Bool {
        guard let backend else { return false }
        do {
            let response = try await backend.post(
                "/api/extensions/mcp/test",
                body: ["id": id],
                timeout: 135,
                as: MCPTestResponse.self
            )
            await refreshExtensions()
            toastHandler(response.status?.state == "connected" ? "MCP server connected" : "MCP test finished")
            return response.status?.state == "connected"
        } catch {
            extensionErrorMessage = mcpConnectionError(error, serverID: id)
            return false
        }
    }

    func reconnectMCPServer(_ id: String) async {
        guard let backend else { return }
        do {
            let response = try await backend.post(
                "/api/extensions/mcp/reconnect",
                body: ["id": id],
                timeout: 135,
                as: MCPTestResponse.self
            )
            await refreshExtensions()
            toastHandler(response.status?.state == "connected" ? "MCP server reconnected" : "MCP reconnect finished")
        } catch {
            extensionErrorMessage = mcpConnectionError(error, serverID: id)
        }
    }

    private func mcpConnectionError(_ error: Error, serverID: String) -> String {
        let original = error.localizedDescription
        guard extensions.mcpServers.first(where: { $0.id == serverID })?.presetID == "github"
        else { return original }
        let lower = original.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("expired") {
            return "GitHub credentials expired or were revoked. Choose Reconnect account, or update the personal token fallback."
        }
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("organization") {
            return "GitHub or an organization blocked this connection. Ask an organization owner to install or approve the Locus GitHub App for the needed repositories, or use an allowed personal token."
        }
        if lower.contains("permission") || lower.contains("scope") {
            return "The GitHub connection lacks permission for that repository or action. Update the app installation's repository selection, or use a personal token with the required access."
        }
        return original
    }

    func setMCPPolicy(serverID: String, tool: String? = nil, mode: String) async {
        guard let backend else { return }
        do {
            var body: [String: Any] = ["id": serverID, "mode": mode]
            if let tool { body["tool"] = tool }
            _ = try await backend.post(
                "/api/extensions/mcp/policy",
                body: body,
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func removeMCPServer(_ id: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.delete(
                "/api/extensions/mcp/\(id)",
                as: ExtensionOperationResponse.self
            )
            credentialStore.remove(serverID: id)
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setMCPCredentials(serverID: String, values: [String: Any]) async -> Bool {
        guard let backend else { return false }
        guard JSONSerialization.isValidJSONObject(values) else {
            extensionErrorMessage = "The MCP credentials could not be saved."
            return false
        }
        let previous = credentialStore.get(serverID: serverID)
        guard credentialStore.set(values, serverID: serverID) else {
            extensionErrorMessage = "The MCP credentials could not be saved."
            return false
        }
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": serverID, "credentials": Self.runtimeMCPCredentials(values)],
                as: MCPStatusCredentialResponse.self
            )
            await refreshExtensions()
            return true
        } catch {
            if let previous {
                credentialStore.set(previous, serverID: serverID)
            } else {
                credentialStore.remove(serverID: serverID)
            }
            extensionErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearMCPCredentials(serverID: String) async {
        guard let backend else { return }
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": serverID, "credentials": [String: Any]()],
                as: MCPStatusCredentialResponse.self
            )
            credentialStore.remove(serverID: serverID)
            await refreshExtensions()
            toastHandler("MCP credentials removed")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func authenticateMCPServer(
        _ server: ExtensionMCPServer,
        completion: ((Bool) -> Void)? = nil
    ) {
        mcpAuthCoordinator.authorize(
            server: server,
            onDeviceCode: { [weak self] prompt in
                guard let self else { return }
                mcpDeviceAuthorization = prompt
                NSWorkspace.shared.open(prompt.verificationURL)
            }
        ) { [weak self] result in
            guard let self else { return }
            mcpDeviceAuthorization = nil
            switch result {
            case .success(let values):
                Task {
                    let saved = await self.setMCPCredentials(serverID: server.id, values: values)
                    completion?(saved)
                }
            case .failure(let error):
                self.extensionErrorMessage = error.localizedDescription
                completion?(false)
            }
        }
    }

    func githubConnectionCapability(
        configuredClientID: String? = nil,
        hasCredentials: Bool = false,
        authorizationError: String? = nil
    ) -> GitHubConnectionCapability {
        GitHubConnectionConfiguration.capability(
            configured: configuredClientID,
            hasCredentials: hasCredentials,
            authorizationError: authorizationError
        )
    }

    func githubConnectionCapability(for server: ExtensionMCPServer) -> GitHubConnectionCapability {
        guard server.presetID == "github" || server.oauthStrategy == "github_device" else {
            return server.hasCredentials == true ? .connected : .deviceFlowAvailable
        }
        return githubConnectionCapability(
            configuredClientID: server.oauth?.clientID,
            hasCredentials: server.hasCredentials == true,
            authorizationError: server.error
        )
    }

    func cancelMCPDeviceAuthorization() {
        mcpAuthCoordinator.cancel()
        mcpDeviceAuthorization = nil
    }

    private func restoreExtensionCredentials(for servers: [ExtensionMCPServer]) async {
        guard let backend else { return }
        for server in servers {
            guard let storedValues = credentialStore.get(serverID: server.id) else { continue }
            guard Self.mcpCredentials(storedValues, areBoundTo: server) else {
                extensionErrorMessage = "Saved OAuth credentials no longer match \(server.name). Reconnect it before enabling the server."
                continue
            }
            let values = (try? await mcpAuthCoordinator.refreshedCredentialsIfNeeded(storedValues))
                ?? storedValues
            let oldData = try? JSONSerialization.data(withJSONObject: storedValues, options: [.sortedKeys])
            let refreshedData = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let refreshedToken = oldData != refreshedData
            if refreshedToken { credentialStore.set(values, serverID: server.id) }
            guard server.hasCredentials != true || refreshedToken else { continue }
            _ = try? await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": server.id, "credentials": Self.runtimeMCPCredentials(values)],
                as: MCPStatusCredentialResponse.self
            )
        }
    }

    /// Never replay an issuer-bound access token after its user-editable MCP
    /// server has been pointed at a different resource or explicit issuer.
    /// Credentials written before issuer binding have neither field and remain
    /// available for the promised version-1 migration path.
    nonisolated static func mcpCredentials(
        _ values: [String: Any],
        areBoundTo server: ExtensionMCPServer
    ) -> Bool {
        if let resource = values["resource"] as? String {
            guard let rawURL = server.url,
                  var components = URLComponents(string: rawURL)
            else { return false }
            components.fragment = nil
            guard components.url?.absoluteString == resource else { return false }
        }
        if let issuer = values["issuer"] as? String,
           let configuredIssuer = server.oauth?.issuer,
           !configuredIssuer.isEmpty,
           issuer != configuredIssuer {
            return false
        }
        return true
    }

    /// Keep native-only registration and refresh material out of the Python
    /// runtime. It receives only what the active transport needs right now.
    nonisolated static func runtimeMCPCredentials(_ values: [String: Any]) -> [String: Any] {
        var runtime: [String: Any] = [:]
        for key in ["access_token", "headers", "env"] {
            if let value = values[key] { runtime[key] = value }
        }
        return runtime
    }

    func answerMCPInput(action: String, content: [String: Any] = [:]) {
        guard let backend, let request = mcpInputRequest else { return }
        let sent = backend.send([
            "type": "mcp_input_response",
            "request_id": request.id,
            "action": action,
            "content": content,
        ])
        if sent { mcpInputRequest = nil }
        else { toastHandler("The MCP input response could not be delivered") }
    }
}
