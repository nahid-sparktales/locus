import Foundation

/// Forwarders kept while consumers still reach extensions and MCP through
/// AppModel; each is deleted once its last caller observes
/// `model.extensionsModel` directly.
extension AppModel {
    var extensions: ExtensionsResponse {
        get { extensionsModel.extensions }
        set { extensionsModel.extensions = newValue }
    }

    var extensionCatalog: [ExtensionCatalogEntry] { extensionsModel.extensionCatalog }
    var extensionTools: [ExtensionToolMetadata] { extensionsModel.extensionTools }
    var isLoadingExtensions: Bool { extensionsModel.isLoadingExtensions }

    var extensionErrorMessage: String? {
        get { extensionsModel.extensionErrorMessage }
        set { extensionsModel.extensionErrorMessage = newValue }
    }

    var mcpInputRequest: MCPInputRequest? {
        get { extensionsModel.mcpInputRequest }
        set { extensionsModel.mcpInputRequest = newValue }
    }

    var mcpDeviceAuthorization: MCPDeviceAuthorizationPrompt? {
        get { extensionsModel.mcpDeviceAuthorization }
        set { extensionsModel.mcpDeviceAuthorization = newValue }
    }

    func refreshExtensions() async { await extensionsModel.refreshExtensions() }

    func refreshExtensionCatalog(query: String = "", marketplaceID: String = "") async {
        await extensionsModel.refreshExtensionCatalog(query: query, marketplaceID: marketplaceID)
    }

    func addMarketplace(source: String, name: String = "") async {
        await extensionsModel.addMarketplace(source: source, name: name)
    }

    func refreshMarketplace(_ id: String) async { await extensionsModel.refreshMarketplace(id) }
    func removeMarketplace(_ id: String) async { await extensionsModel.removeMarketplace(id) }

    func inspectPlugin(_ entry: ExtensionCatalogEntry) async -> PluginTrustResponse? {
        await extensionsModel.inspectPlugin(entry)
    }

    func inspectUpdate(
        for plugin: ExtensionPlugin
    ) async -> (ExtensionCatalogEntry, PluginTrustResponse)? {
        await extensionsModel.inspectUpdate(for: plugin)
    }

    func installPlugin(
        _ entry: ExtensionCatalogEntry,
        trust: PluginTrustResponse,
        scope: String = "global"
    ) async {
        await extensionsModel.installPlugin(entry, trust: trust, scope: scope)
    }

    func setPlugin(_ id: String, enabled: Bool, scope: String) async {
        await extensionsModel.setPlugin(id, enabled: enabled, scope: scope)
    }

    func rollbackPlugin(_ id: String) async { await extensionsModel.rollbackPlugin(id) }
    func uninstallPlugin(_ id: String) async { await extensionsModel.uninstallPlugin(id) }

    func importSkill(from source: String, scope: String = "global") async {
        await extensionsModel.importSkill(from: source, scope: scope)
    }

    func setSkill(_ id: String, enabled: Bool, scope: String) async {
        await extensionsModel.setSkill(id, enabled: enabled, scope: scope)
    }

    func removeSkill(_ id: String) async { await extensionsModel.removeSkill(id) }
    func saveMCPServer(_ body: [String: Any]) async { await extensionsModel.saveMCPServer(body) }

    func materializeMCPPreset(
        _ preset: ExtensionMCPPreset,
        projectRef: String = ""
    ) async -> ExtensionMCPServer? {
        await extensionsModel.materializeMCPPreset(preset, projectRef: projectRef)
    }

    func setMCPServer(_ id: String, enabled: Bool, scope: String) async {
        await extensionsModel.setMCPServer(id, enabled: enabled, scope: scope)
    }

    @discardableResult
    func testMCPServer(_ id: String) async -> Bool { await extensionsModel.testMCPServer(id) }
    func reconnectMCPServer(_ id: String) async { await extensionsModel.reconnectMCPServer(id) }

    func setMCPPolicy(serverID: String, tool: String? = nil, mode: String) async {
        await extensionsModel.setMCPPolicy(serverID: serverID, tool: tool, mode: mode)
    }

    func removeMCPServer(_ id: String) async { await extensionsModel.removeMCPServer(id) }

    @discardableResult
    func setMCPCredentials(serverID: String, values: [String: Any]) async -> Bool {
        await extensionsModel.setMCPCredentials(serverID: serverID, values: values)
    }

    func clearMCPCredentials(serverID: String) async {
        await extensionsModel.clearMCPCredentials(serverID: serverID)
    }

    func authenticateMCPServer(
        _ server: ExtensionMCPServer,
        completion: ((Bool) -> Void)? = nil
    ) {
        extensionsModel.authenticateMCPServer(server, completion: completion)
    }

    func githubConnectionCapability(
        configuredClientID: String? = nil,
        hasCredentials: Bool = false,
        authorizationError: String? = nil
    ) -> GitHubConnectionCapability {
        extensionsModel.githubConnectionCapability(
            configuredClientID: configuredClientID,
            hasCredentials: hasCredentials,
            authorizationError: authorizationError
        )
    }

    func githubConnectionCapability(for server: ExtensionMCPServer) -> GitHubConnectionCapability {
        extensionsModel.githubConnectionCapability(for: server)
    }

    func cancelMCPDeviceAuthorization() { extensionsModel.cancelMCPDeviceAuthorization() }

    func answerMCPInput(action: String, content: [String: Any] = [:]) {
        extensionsModel.answerMCPInput(action: action, content: content)
    }
}
