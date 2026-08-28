import Combine
import Foundation

struct ExtensionCapabilities: Codable, Hashable {
    var streamableHTTP = true
    var stdio = false
    var oauth = true
    var mcpApps = false
    var hooks = false
    var sandboxed = false

    enum CodingKeys: String, CodingKey {
        case stdio, oauth, hooks, sandboxed
        case streamableHTTP = "streamable_http"
        case mcpApps = "mcp_apps"
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

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, author, digest, skills, scripts, unsupported, error
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

    enum CodingKeys: String, CodingKey {
        case id, name, transport, url, command, args, cwd, origin, active, enabled, state, error, auth, oauth
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
    }
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

    enum CodingKeys: String, CodingKey {
        case issuer, scopes
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
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
    let skills: Int
    let skillScripts: [String]
    let mcpServers: [PluginTrustMCPServer]
    let unsupported: [String]

    enum CodingKeys: String, CodingKey {
        case skills, unsupported
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

    enum CodingKeys: String, CodingKey {
        case id, name, state, error
        case toolCount = "tool_count"
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
