import Foundation

/// Product identity and app-owned storage. Workspace conventions and helper
/// identities are shared contracts and deliberately do not depend on edition.
enum AppEdition: String, CaseIterable {
    case locus
    case locusX = "locusx"

    #if LOCUS_WALLET
    static let current: AppEdition = .locusX
    #else
    static let current: AppEdition = .locus
    #endif

    var displayName: String { self == .locus ? "Locus" : "LocusX" }
    var bundleIdentifier: String { "io.sparktales.\(rawValue)" }
    var credentialDirectoryName: String { ".\(rawValue)" }
    var mcpCallbackScheme: String { rawValue }
    var mcpRedirectURI: String { "\(mcpCallbackScheme)://mcp/oauth" }
    var companionCertificateLabel: String { "\(displayName) Companion TLS" }

    func canonicalMCPRedirectURI(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == mcpCallbackScheme,
              components.host?.lowercased() == "mcp",
              components.port == nil, components.path == "/oauth",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        return mcpRedirectURI
    }

    func supportDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(displayName, isDirectory: true)
    }

    var supportDirectory: URL {
        supportDirectory(in: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()))
    }

    func credentialFile(in home: URL) -> URL {
        home.appendingPathComponent(credentialDirectoryName, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    func keychainService(_ suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }

    /// Keep existing Locus cookies addressable; X never selects that profile.
    func browserProfileKey(for canonicalWorkspacePath: String) -> String {
        self == .locus ? canonicalWorkspacePath : "\(bundleIdentifier)\n\(canonicalWorkspacePath)"
    }

    func backendHomes(in applicationSupport: URL, sandboxed: Bool) -> [String: String] {
        let support = supportDirectory(in: applicationSupport)
        var values = ["LOCUS_CODEX_HOME": support.appendingPathComponent("Codex").path]
        if sandboxed || self == .locusX {
            values["OLLAMA_CODE_HOME"] = support.appendingPathComponent("Agent").path
        }
        return values
    }
}
