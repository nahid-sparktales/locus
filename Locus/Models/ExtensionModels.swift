import Combine
import Foundation

struct ExtensionCapabilities: Codable, Hashable {
    var streamableHTTP = true
    var stdio = false
    var oauth = true
    var mcpApps = false
    var hooks = false
    var sandboxed = false
    var pluginScreens: Bool? = nil
    var sse: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case stdio, oauth, hooks, sandboxed, sse
        case streamableHTTP = "streamable_http"
        case mcpApps = "mcp_apps"
        case pluginScreens = "plugin_screens"
    }
}

struct ExtensionMarketplace: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let source: String
    let error: String?
    let workspaceDiscovered: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, source, error
        case workspaceDiscovered = "workspace_discovered"
    }
}

struct ExtensionMCPComponent: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]?
    let cwd: String?
}

struct ExtensionSkill: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let description: String
    let source: String
    let pluginID: String?
    let allowImplicitInvocation: Bool?
    let activation: String?
    let enabled: Bool
    let enabledGlobal: Bool?
    let enabledWorkspaces: [String]?
    let disabledWorkspaces: [String]?
    let error: String?
    let builtin: Bool?
    let shadowed: Bool?
    let provenance: ExtensionSkillProvenance?

    enum CodingKeys: String, CodingKey {
        case id, name, description, source, enabled, error, builtin, shadowed, provenance, activation
        case displayName = "display_name"
        case pluginID = "plugin_id"
        case allowImplicitInvocation = "allow_implicit_invocation"
        case enabledGlobal = "enabled_global"
        case enabledWorkspaces = "enabled_workspaces"
        case disabledWorkspaces = "disabled_workspaces"
    }
}

struct ExtensionSkillProvenance: Codable, Hashable {
    let provider: String?
    let repository: String?
    let commit: String?
    let upstreamPath: String?
    let license: String?

    enum CodingKeys: String, CodingKey {
        case provider, repository, commit, license
        case upstreamPath = "upstream_path"
    }
}

struct ExtensionPluginScreen: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let entrypoint: String
    let version: Int
    let capabilities: [String]

    /// Version-1 native workspace, deliberately distinct from a web screen.
    var isSocialStudio: Bool { id == "social-studio" && capabilities.contains("social.workspace") }

    var capabilityDescription: String {
        capabilities.map { capability in
            switch capability {
            case "agents.read": "Can read agent names, roles and activity."
            case "agents.interact": "Can select an agent in the native conversation panel."
            case "world.preferences": "Can save the selected world theme and resident appearance."
            case "social.workspace": "Can open the native social studio, save project drafts, prepare assistant requests, and connect to OpenPost through native controls."
            default: capability
            }
        }.joined(separator: " ")
    }

    var isSupported: Bool {
        version == 1 && !id.isEmpty && !title.isEmpty
            && Set(capabilities).isSubset(of: ["agents.read", "agents.interact", "world.preferences", "social.workspace"])
            && (!capabilities.contains("social.workspace") || (id == "social-studio" && capabilities == ["social.workspace"]))
            && PluginScreenFiles.isSafeRelativePath(entrypoint)
            && ["html", "htm"].contains(URL(fileURLWithPath: entrypoint).pathExtension.lowercased())
    }
}

struct ExtensionPlugin: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let description: String?
    let version: String?
    let author: String?
    let digest: String?
    let enabledGlobal: Bool
    let enabledWorkspaces: [String]
    let disabledWorkspaces: [String]
    let previousVersions: [String]?
    let skills: [ExtensionSkill]?
    let mcpServers: [ExtensionMCPComponent]?
    let scripts: [String]?
    let unsupported: [String]?
    let updateAvailable: Bool?
    let error: String?
    var root: String? = nil
    var screens: [ExtensionPluginScreen]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, author, digest, skills, scripts, unsupported, error, root, screens
        case displayName = "display_name"
        case enabledGlobal = "enabled_global"
        case enabledWorkspaces = "enabled_workspaces"
        case disabledWorkspaces = "disabled_workspaces"
        case previousVersions = "previous_versions"
        case mcpServers = "mcp_servers"
        case updateAvailable = "update_available"
    }
}

struct ExtensionMCPServer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let origin: String?
    let pluginID: String?
    let active: Bool?
    let enabled: Bool?
    let enabledGlobal: Bool?
    let enabledWorkspaces: [String]?
    let disabledWorkspaces: [String]?
    let state: String?
    let error: String?
    let toolCount: Int?
    let hasCredentials: Bool?
    let approvalMode: String?
    let auth: String?
    let oauth: MCPOAuthConfiguration?
    let oauthStrategy: String?
    let presetID: String?
    let authFallback: String?
    let fallbackHeader: String?
    let optionalHeader: String?
    var diagnostics: MCPConnectionDiagnostics? = nil
    var negotiatedCapabilities: [String: JSONValue]? = nil
    var protocolVersion: String? = nil
    var startupTimeoutSeconds: Int? = nil
    var toolTimeoutSeconds: Int? = nil
    var envVars: [String]? = nil
    var envHTTPHeaders: [String: String]? = nil
    var bearerTokenEnvVar: String? = nil
    var envKeys: [String]? = nil
    var headerKeys: [String]? = nil
    var enabledTools: [String]? = nil
    var disabledTools: [String]? = nil
    var enabledResources: [String]? = nil
    var enabledPrompts: [String]? = nil
    var shareWorkspaceRoot: Bool? = nil
    var resourceAccess: String? = nil
    var protocolMode: String? = nil
    var presetProvenance: [String: JSONValue]? = nil
    var toolPolicies: [String: JSONValue]? = nil
    var warnings: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, transport, url, command, args, cwd, origin, active, enabled, state, error, auth, oauth, diagnostics, warnings
        case pluginID = "plugin_id"
        case enabledGlobal = "enabled_global"
        case enabledWorkspaces = "enabled_workspaces"
        case disabledWorkspaces = "disabled_workspaces"
        case toolCount = "tool_count"
        case hasCredentials = "has_credentials"
        case approvalMode = "approval_mode"
        case presetID = "preset_id"
        case authFallback = "auth_fallback"
        case fallbackHeader = "fallback_header"
        case optionalHeader = "optional_header"
        case oauthStrategy = "oauth_strategy"
        case startupTimeoutSeconds = "startup_timeout_sec"
        case toolTimeoutSeconds = "tool_timeout_sec"
        case envVars = "env_vars"
        case envHTTPHeaders = "env_http_headers"
        case bearerTokenEnvVar = "bearer_token_env_var"
        case envKeys = "env_keys"
        case headerKeys = "header_keys"
        case enabledTools = "enabled_tools"
        case disabledTools = "disabled_tools"
        case enabledResources = "enabled_resources"
        case enabledPrompts = "enabled_prompts"
        case protocolMode = "protocol_mode"
        case shareWorkspaceRoot = "share_workspace_root"
        case resourceAccess = "resource_access"
        case negotiatedCapabilities = "negotiated_capabilities"
        case protocolVersion = "protocol_version"
        case presetProvenance = "preset_provenance"
        case toolPolicies = "tool_policies"
    }

    /// Native credential scope. Display names, enablement, timeouts, and access
    /// policy do not change the identity of the server receiving credentials.
    var credentialBinding: String {
        let value: [String: Any] = [
            "transport": transport, "url": url ?? "", "command": command ?? "",
            "auth": auth ?? "none",
            "oauth": [
                "issuer": oauth?.issuer ?? "", "authorization_endpoint": oauth?.authorizationEndpoint ?? "",
                "token_endpoint": oauth?.tokenEndpoint ?? "", "client_id": oauth?.clientID ?? "",
                "scopes": (oauth?.scopes ?? []).sorted(), "redirect_uri": oauth?.redirectURI ?? "",
                "allow_loopback_http": oauth?.allowLoopbackHTTP ?? false,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    var editableConfiguration: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              var value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        value["default_tools_approval_mode"] = approvalMode ?? "annotations"
        if let policies = value.removeValue(forKey: "tool_policies") { value["tools"] = policies }
        for key in ["diagnostics", "negotiated_capabilities", "protocol_version", "warnings", "state", "error", "tool_count", "has_credentials", "active", "env_keys", "header_keys"] {
            value.removeValue(forKey: key)
        }
        return value
    }
}

struct MCPServerCatalog: Decodable {
    var tools: [MCPToolCatalogEntry]?
    let resources: [MCPResourceEntry]
    let templates: [MCPResourceEntry]
    let prompts: [MCPPromptEntry]
}

struct MCPToolCatalogEntry: Decodable {
    let name: String
    var description: String?
    var approvalMode: String?
    var enabled: Bool?
    enum CodingKeys: String, CodingKey {
        case name, description, enabled
        case approvalMode = "approval_mode"
    }
    var permissionMetadata: ExtensionToolMetadata {
        ExtensionToolMetadata(name: name, description: description ?? "", origin: "mcp",
            serverID: nil, serverName: nil, active: enabled ?? true, deferred: false,
            approvalMode: enabled == false ? "disabled" : approvalMode)
    }
}

struct MCPResourceEntry: Decodable, Identifiable {
    let uri: String
    let name: String
    var title: String?
    var description: String?
    var mimeType: String?
    var template: Bool?
    var enabled: Bool?
    var id: String { uri }
    var displayName: String { title?.isEmpty == false ? title! : name }
    enum CodingKeys: String, CodingKey {
        case uri, name, title, description, template, enabled
        case mimeType = "mime_type"
    }
    var parameterNames: [String] {
        guard template == true,
              let expression = try? NSRegularExpression(pattern: "\\{([^}]+)\\}") else { return [] }
        let text = uri as NSString
        var seen: Set<String> = []
        return expression.matches(in: uri, range: NSRange(location: 0, length: text.length)).flatMap { match in
            text.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "+#./;?&"))
                .split(separator: ",").map { String($0).components(separatedBy: ":")[0].replacingOccurrences(of: "*", with: "") }
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct MCPPromptEntry: Decodable, Identifiable {
    let name: String
    var title: String?
    var description: String?
    var arguments: [MCPPromptArgument]?
    var enabled: Bool?
    var id: String { name }
    var displayName: String { title?.isEmpty == false ? title! : name }
}

struct MCPPromptArgument: Decodable, Identifiable {
    let name: String
    var description: String?
    var required: Bool?
    var id: String { name }
}

struct MCPPreviewResponse: Decodable {
    let content: String
    var attachments: [ToolMediaReference]?
    var sessionID: String?
    enum CodingKeys: String, CodingKey {
        case content, attachments
        case sessionID = "session_id"
    }
}

struct MCPCompletionResponse: Decodable {
    let values: [String]
}

struct ExtensionMCPPreset: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let url: String
    let sourceURL: String?
    let auth: String
    let oauthStrategy: String?
    let fallback: String?
    let fallbackHeader: String?
    let optionalHeader: String?
    let scopes: [String]
    let warning: String
    let requiresProjectRef: Bool?
    let installed: Bool
    let serverID: String?
    let defaultToolsApprovalMode: String
    let resourcesDiscoverable: Bool
    let promptsEnabled: Bool
    let catalogVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description, url, auth, fallback, scopes, warning, installed
        case displayName = "display_name"
        case sourceURL = "source_url"
        case fallbackHeader = "fallback_header"
        case optionalHeader = "optional_header"
        case requiresProjectRef = "requires_project_ref"
        case serverID = "server_id"
        case defaultToolsApprovalMode = "default_tools_approval_mode"
        case resourcesDiscoverable = "resources_discoverable"
        case promptsEnabled = "prompts_enabled"
        case catalogVersion = "catalog_version"
        case oauthStrategy = "oauth_strategy"
    }
}

struct MCPOAuthConfiguration: Codable, Hashable {
    let issuer: String?
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let clientID: String
    let scopes: [String]
    let redirectURI: String?
    var allowLoopbackHTTP: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case issuer, scopes
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
        case allowLoopbackHTTP = "allow_loopback_http"
    }
}

struct MCPDeviceAuthorizationPrompt: Identifiable, Hashable {
    let id = UUID()
    let serverID: String
    let serverName: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
}

struct ExtensionsResponse: Codable, Hashable {
    let capabilities: ExtensionCapabilities
    let marketplaces: [ExtensionMarketplace]
    let plugins: [ExtensionPlugin]
    let skills: [ExtensionSkill]
    let mcpServers: [ExtensionMCPServer]
    let mcpPresets: [ExtensionMCPPreset]
    let errors: [String]
    let pendingUpdates: Int?

    enum CodingKeys: String, CodingKey {
        case capabilities, marketplaces, plugins, skills, errors
        case mcpServers = "mcp_servers"
        case mcpPresets = "mcp_presets"
        case pendingUpdates = "pending_updates"
    }

    static let empty = ExtensionsResponse(
        capabilities: ExtensionCapabilities(),
        marketplaces: [],
        plugins: [],
        skills: [],
        mcpServers: [],
        mcpPresets: [],
        errors: [],
        pendingUpdates: 0
    )
}

struct ExtensionCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let description: String?
    let category: String?
    let marketplaceID: String
    let available: Bool
    let installed: Bool
    let installedVersion: String?
    let version: String?
    let author: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, available, installed, version, author, error
        case displayName = "display_name"
        case marketplaceID = "marketplace_id"
        case installedVersion = "installed_version"
    }
}

struct ExtensionCatalogResponse: Codable {
    let entries: [ExtensionCatalogEntry]
}

struct PluginTrustMCPServer: Codable, Hashable {
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let requestedEnv: [String]
    let requestedHeaders: [String]

    enum CodingKeys: String, CodingKey {
        case name, transport, url, command, args, cwd
        case requestedEnv = "requested_env"
        case requestedHeaders = "requested_headers"
    }
}

struct PluginTrustSummary: Codable, Hashable {
    var screens: [ExtensionPluginScreen]? = nil
    let skills: Int
    let skillScripts: [String]
    let mcpServers: [PluginTrustMCPServer]
    let unsupported: [String]

    enum CodingKeys: String, CodingKey {
        case skills, unsupported, screens
        case skillScripts = "skill_scripts"
        case mcpServers = "mcp_servers"
    }
}

struct PluginTrustDescription: Codable, Hashable {
    let name: String
    let displayName: String?
    let description: String?
    let version: String?
    let author: String?

    enum CodingKeys: String, CodingKey {
        case name, description, version, author
        case displayName = "display_name"
    }
}

struct PluginTrustResponse: Codable, Hashable, Identifiable {
    var id: String { digest }
    let plugin: PluginTrustDescription
    let digest: String
    let trust: PluginTrustSummary
    let source: [String: String]?
    let capabilityDiff: PluginCapabilityDiff?

    enum CodingKeys: String, CodingKey {
        case plugin, digest, trust, source
        case capabilityDiff = "capability_diff"
    }
}

struct PluginCapabilityDiff: Codable, Hashable {
    let kind: String
    let requiresRenewedTrust: Bool
    let changes: [String]

    enum CodingKeys: String, CodingKey {
        case kind, changes
        case requiresRenewedTrust = "requires_renewed_trust"
    }
}

struct ExtensionOperationResponse: Codable {
    let ok: Bool
}

struct ProjectContextReloadResponse: Codable {
    let ok: Bool
    let file: String?
}

/// `GET`/`POST /api/config`. Only the fields the app reads back — the route also
/// echoes the model, host and cwd, which the app already knows.
struct ConfigStateResponse: Codable {
    let contextWindow: Int?
    let maxIterations: Int?
    let terminalShell: String?
    let terminalLoginShell: Bool?
    let sessionInfo: SessionInfo?

    enum CodingKeys: String, CodingKey {
        case contextWindow = "context_window"
        case maxIterations = "max_iterations"
        case terminalShell = "terminal_shell"
        case terminalLoginShell = "terminal_login_shell"
        case sessionInfo = "session_info"
    }
}

struct MCPTestResponse: Codable {
    let status: MCPStatusResponse?
}

struct MCPStatusResponse: Codable {
    let id: String
    let name: String
    let state: String
    let error: String?
    let toolCount: Int?
    var diagnostics: MCPConnectionDiagnostics? = nil
    var negotiatedCapabilities: [String: JSONValue]? = nil
    var protocolVersion: String? = nil
    var warnings: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, state, error, diagnostics, warnings
        case toolCount = "tool_count"
        case negotiatedCapabilities = "negotiated_capabilities"
        case protocolVersion = "protocol_version"
    }
}

/// Runtime-produced diagnostics are already bounded and redacted. Never add
/// raw configuration or credentials when displaying or copying this report.
struct MCPConnectionDiagnostics: Codable, Hashable {
    var transport: String?
    var stage: String?
    var target: String?
    var elapsedMS: Double?
    var authPresent: Bool?
    var httpStatus: Int?
    var causes: [String]?
    var stderrTail: String?
    var hints: [String]?

    enum CodingKeys: String, CodingKey {
        case transport, stage, target, causes, hints
        case elapsedMS = "elapsed_ms"
        case authPresent = "auth_present"
        case httpStatus = "http_status"
        case stderrTail = "stderr_tail"
    }

    var report: String {
        var lines: [String] = []
        if let transport { lines.append("Transport: \(transport)") }
        if let target { lines.append("Target: \(target)") }
        if let stage { lines.append("Stage: \(stage)") }
        if let elapsedMS, elapsedMS.isFinite { lines.append("Elapsed: \(elapsedMS.formatted(.number.precision(.fractionLength(0)))) ms") }
        if let authPresent { lines.append("Credentials: \(authPresent ? "provided" : "not provided")") }
        if let httpStatus { lines.append("HTTP status: \(httpStatus)") }
        if let causes, !causes.isEmpty { lines.append("\nDetails:\n" + causes.joined(separator: "\n")) }
        if let stderrTail, !stderrTail.isEmpty { lines.append("\nRecent standard error:\n" + stderrTail) }
        if let hints, !hints.isEmpty { lines.append("\nNext steps:\n" + hints.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }
}

struct MCPStatusCredentialResponse: Codable {
    let ok: Bool
    let id: String
    let hasCredentials: Bool

    enum CodingKeys: String, CodingKey {
        case ok, id
        case hasCredentials = "has_credentials"
    }
}

struct ExtensionToolMetadata: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let origin: String
    let serverID: String?
    let serverName: String?
    let active: Bool
    let deferred: Bool
    let approvalMode: String?

    enum CodingKeys: String, CodingKey {
        case name, description, origin, active, deferred
        case serverID = "server_id"
        case serverName = "server_name"
        case approvalMode = "approval_mode"
    }
}

struct ExtensionToolsResponse: Codable {
    let tools: [ExtensionToolMetadata]
}
