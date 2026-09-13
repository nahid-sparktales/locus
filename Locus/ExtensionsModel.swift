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
    @Published private(set) var mcpOperations: [String: String] = [:]
    @Published private(set) var mcpProbeStatuses: [String: MCPStatusResponse] = [:]
    @Published private(set) var mcpProbeErrors: [String: String] = [:]
    @Published private(set) var mcpCatalogs: [String: MCPServerCatalog] = [:]

    private let mcpAuthCoordinator: MCPAuthCoordinator
    private let credentialStore: any MCPCredentialStoring
    private var extensionRefreshTask: Task<Void, Never>?
    private var mcpConfigurationEdits: Set<String> = []

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
            mcpProbeStatuses = [:]
            let serverIDs = Set(response.mcpServers.map(\.id))
            mcpProbeErrors = mcpProbeErrors.filter { serverIDs.contains($0.key) }
            for server in response.mcpServers where server.state == "connected" || server.state == "connecting" {
                mcpProbeErrors.removeValue(forKey: server.id)
            }
            mcpCatalogs = mcpCatalogs.filter { serverIDs.contains($0.key) }
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

    @discardableResult
    func saveMCPServer(_ body: [String: Any]) async -> Bool {
        guard let backend else { return false }
        let id = body["id"] as? String ?? ""
        let previous = extensions.mcpServers.first { $0.id == id }
        mcpConfigurationEdits.insert(id)
        defer { mcpConfigurationEdits.remove(id) }
        do {
            let saved = try await backend.post(
                "/api/extensions/mcp",
                body: body,
                as: ExtensionMCPServer.self
            )
            if let previous, previous.credentialBinding != saved.credentialBinding {
                // The runtime has invalidated its handoff too. Remove native
                // credentials before a refresh can replay a legacy record.
                credentialStore.remove(serverID: id)
            }
            await refreshExtensions()
            return true
        } catch {
            extensionErrorMessage = error.localizedDescription
            return false
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
        await probeMCPServer(id, reconnect: false)
    }

    func reconnectMCPServer(_ id: String) async {
        _ = await probeMCPServer(id, reconnect: true)
    }

    private func probeMCPServer(_ id: String, reconnect: Bool) async -> Bool {
        guard let backend, mcpOperations[id] == nil else { return false }
        mcpOperations[id] = reconnect ? "Reconnecting…" : "Testing…"
        mcpProbeStatuses.removeValue(forKey: id)
        mcpProbeErrors.removeValue(forKey: id)
        extensionErrorMessage = nil
        defer { mcpOperations.removeValue(forKey: id) }
        do {
            let response = try await backend.post(
                reconnect ? "/api/extensions/mcp/reconnect" : "/api/extensions/mcp/test",
                body: ["id": id],
                timeout: 135,
                as: MCPTestResponse.self
            )
            await refreshExtensions()
            if let status = response.status { mcpProbeStatuses[id] = status }
            if response.status?.state == "connected" {
                toastHandler(reconnect ? "MCP server reconnected" : "MCP server connected")
                return true
            }
            let message = response.status?.error ?? "The MCP server did not connect. Open Connection details for more information."
            mcpProbeErrors[id] = message
            extensionErrorMessage = message
            toastHandler("MCP connection failed")
            return false
        } catch {
            let message = (error as NSError).code == NSURLErrorTimedOut
                ? "Locus did not receive the connection test result in time. Check the server's latest connection details."
                : mcpConnectionError(error, serverID: id)
            await refreshExtensions()
            mcpProbeErrors[id] = message
            extensionErrorMessage = message
            toastHandler("MCP connection failed")
            return false
        }
    }

    func mcpError(for server: ExtensionMCPServer) -> String? {
        mcpProbeErrors[server.id] ?? mcpProbeStatuses[server.id]?.error ?? server.error
    }

    func mcpDiagnostics(for server: ExtensionMCPServer) -> MCPConnectionDiagnostics? {
        mcpProbeStatuses[server.id]?.diagnostics ?? server.diagnostics
    }

    @discardableResult
    func loadMCPCatalog(_ serverID: String) async throws -> MCPServerCatalog {
        guard let backend else { throw URLError(.notConnectedToInternet) }
        // Server IDs are generated identifiers; plugin IDs contain slashes,
        // which this route accepts with a path capture. BackendService owns
        // URL encoding, so pre-encoding here would encode '%' a second time.
        let result = try await backend.get("/api/extensions/mcp/\(serverID)/catalog", timeout: 135, as: MCPServerCatalog.self)
        mcpCatalogs[serverID] = result
        return result
    }

    func updateMCPCatalogPolicy(serverID: String, resourceAccess: String, resources: [String], prompts: [String]) async throws {
        guard let backend else { throw URLError(.notConnectedToInternet) }
        _ = try await backend.post("/api/extensions/mcp/policy", body: [
            "id": serverID, "resource_access": resourceAccess,
            "enabled_resources": resources, "enabled_prompts": prompts,
        ], as: ExtensionMCPServer.self)
        await refreshExtensions()
        try await loadMCPCatalog(serverID)
    }

    func previewMCPItem(serverID: String, kind: String, name: String, arguments: [String: String]) async throws -> MCPPreviewResponse {
        guard let backend else { throw URLError(.notConnectedToInternet) }
        return try await backend.post("/api/extensions/mcp/\(kind)", body: [
            "id": serverID, kind == "prompt" ? "prompt" : "uri": name, "arguments": arguments,
        ], timeout: 135, as: MCPPreviewResponse.self)
    }

    func completeMCPArgument(serverID: String, kind: String, name: String, argument: String, value: String, context: [String: String]) async throws -> [String] {
        guard let backend else { throw URLError(.notConnectedToInternet) }
        let result = try await backend.post("/api/extensions/mcp/complete", body: [
            "id": serverID, "kind": kind, "name": name, "argument": argument,
            "value": value, "context_arguments": context,
        ], timeout: 135, as: MCPCompletionResponse.self)
        return result.values
    }

    func loadMCPPreviewImages(_ preview: MCPPreviewResponse) async throws -> [String: Data] {
        guard let backend, let sessionID = preview.sessionID else { return [:] }
        var images: [String: Data] = [:]
        for attachment in (preview.attachments ?? []).prefix(10) {
            let data = try await backend.chatImage(sessionID: sessionID, mediaID: attachment.id)
            guard data.count <= 15_000_000, NSImage(data: data) != nil else { continue }
            images[attachment.id] = data
        }
        return images
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
            if mcpCatalogs[serverID] != nil { try await loadMCPCatalog(serverID) }
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
        guard let backend, !mcpConfigurationEdits.contains(serverID) else { return false }
        var values = values
        if let server = extensions.mcpServers.first(where: { $0.id == serverID }) {
            values["mcp_server_binding"] = server.credentialBinding
        }
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

    func mcpCredentialNames(serverID: String, kind: String) -> [String] {
        ((credentialStore.get(serverID: serverID)?[kind] as? [String: String]) ?? [:]).keys.sorted()
    }

    /// Empty editor values mean “keep the saved value”; deleting a row is the
    /// explicit removal operation. Supplemental edits preserve OAuth data;
    /// an explicit bearer replacement disables refresh of the old account token.
    nonisolated static func mergingMCPCredentials(
        _ current: [String: Any], accessToken: String? = nil,
        headers: [String: String] = [:], env: [String: String] = [:],
        removedHeaders: Set<String> = [], removedEnv: Set<String> = []
    ) -> [String: Any] {
        var result = current
        if let accessToken, !accessToken.isEmpty {
            result["access_token"] = accessToken
            result.removeValue(forKey: "refresh_token")
            result.removeValue(forKey: "expires_at")
        }
        for (kind, updates, removed) in [("headers", headers, removedHeaders), ("env", env, removedEnv)] {
            var values = (current[kind] as? [String: String]) ?? [:]
            for key in removed { values.removeValue(forKey: key) }
            for (key, value) in updates where !value.isEmpty { values[key] = value }
            if !values.isEmpty || current[kind] != nil { result[kind] = values }
        }
        return result
    }

    func updateMCPTransportCredentials(
        serverID: String, accessToken: String?, headers: [String: String], env: [String: String],
        removedHeaders: Set<String>, removedEnv: Set<String>
    ) async -> Bool {
        let server = extensions.mcpServers.first { $0.id == serverID }
        let stored = credentialStore.get(serverID: serverID) ?? [:]
        let current = server.map { Self.mcpCredentials(stored, areBoundTo: $0) } == false ? [:] : stored
        let values = Self.mergingMCPCredentials(
            current, accessToken: accessToken, headers: headers, env: env,
            removedHeaders: removedHeaders, removedEnv: removedEnv
        )
        let hasAuthorization = (values["headers"] as? [String: String] ?? [:]).keys.contains { $0.lowercased() == "authorization" }
        let suppliesBearer = !(values["access_token"] as? String ?? "").isEmpty
            || !(server?.bearerTokenEnvVar ?? "").isEmpty || ["auto", "oauth"].contains(server?.auth ?? "")
        guard !hasAuthorization || !suppliesBearer else {
            extensionErrorMessage = "Authorization is already supplied by a bearer token or OAuth account. Remove the Authorization header, or switch to custom headers and clear the saved token/account and bearer environment mapping first. Other headers can be used alongside OAuth."
            return false
        }
        return await setMCPCredentials(serverID: serverID, values: values)
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
                    guard !self.mcpConfigurationEdits.contains(server.id),
                          let current = self.extensions.mcpServers.first(where: { $0.id == server.id }),
                          Self.mcpCredentials(values, areBoundTo: current),
                          current.credentialBinding == server.credentialBinding
                    else {
                        self.extensionErrorMessage = "The MCP server settings changed during sign-in. Connect again using the current settings."
                        completion?(false)
                        return
                    }
                    var merged = values
                    let previous = self.credentialStore.get(serverID: server.id) ?? [:]
                    if Self.mcpCredentials(previous, areBoundTo: current) {
                        for key in ["headers", "env"] { merged[key] = previous[key] }
                    }
                    let saved = await self.setMCPCredentials(serverID: server.id, values: merged)
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
            guard !mcpConfigurationEdits.contains(server.id),
                  var storedValues = credentialStore.get(serverID: server.id) else { continue }
            guard Self.mcpCredentials(storedValues, areBoundTo: server) else {
                extensionErrorMessage = "Saved credentials no longer match \(server.name). Reconnect its account or update its credentials before enabling the server."
                continue
            }
            if storedValues["mcp_server_binding"] == nil {
                // Upgrade unchanged legacy records before any async handoff.
                storedValues["mcp_server_binding"] = server.credentialBinding
                guard credentialStore.set(storedValues, serverID: server.id) else { continue }
            }
            let values = (try? await mcpAuthCoordinator.refreshedCredentialsIfNeeded(storedValues, server: server))
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
        if let binding = values["mcp_server_binding"] as? String, binding != server.credentialBinding { return false }
        if let origin = values["loopback_oauth_origin"] as? String {
            guard server.oauth?.allowLoopbackHTTP == true,
                  origin == MCPOAuthTransportPolicy.loopbackHTTPOrigin(server.url ?? "")
            else { return false }
        } else if (values["token_endpoint"] as? String)?.lowercased().hasPrefix("http:") == true {
            return false
        }
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
