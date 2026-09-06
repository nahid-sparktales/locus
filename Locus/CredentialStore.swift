import Foundation
import AuthenticationServices
import AppKit
import CryptoKit
import Security

enum GitHubConnectionCapability: String, Equatable {
    case deviceFlowAvailable
    case tokenFallbackOnly
    case connected
    case authorizationFailed
}

enum GitHubConnectionConfiguration {
    static func clientID(
        configured: String? = nil,
        bundleValue: String? = Bundle.main.object(
            forInfoDictionaryKey: "LocusGitHubOAuthClientID"
        ) as? String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let candidates = [
            configured,
            bundleValue,
            environment["LOCUS_GITHUB_OAUTH_CLIENT_ID"],
        ]
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, !value.contains("$(") { return value }
        }
        return nil
    }

    static func capability(
        configured: String? = nil,
        bundleValue: String? = Bundle.main.object(
            forInfoDictionaryKey: "LocusGitHubOAuthClientID"
        ) as? String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasCredentials: Bool = false,
        authorizationError: String? = nil
    ) -> GitHubConnectionCapability {
        if hasCredentials { return .connected }
        guard clientID(
            configured: configured,
            bundleValue: bundleValue,
            environment: environment
        ) != nil else { return .tokenFallbackOnly }
        if authorizationError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .authorizationFailed
        }
        return .deviceFlowAvailable
    }
}

/// Credential storage for provider API keys and MCP server tokens.
///
/// One JSON file, `~/.locus/auth.json`, mode `0600` inside a `0700` directory —
/// the same shape Codex uses for `~/.codex/auth.json`. In the sandboxed App
/// Store build `~` is the app container, so the file lands there instead.
///
/// Be clear about what this protects against: file permissions keep the secrets
/// away from *other* users on the Mac. They do not keep them away from anything
/// running as you. There is no per-application access control and no
/// authorization prompt — that is what the login keychain provided, and this
/// deliberately does not. The UI says so where the user enters a secret.
enum CredentialStore {
    /// The single pre-accounts endpoint key. Kept for the one-time migration
    /// that turns it into a provider account, and because an account migrated
    /// that way keeps pointing at this name forever.
    static let remoteAPIKeyAccount = "remote-api-key"

    /// One entry per provider account, so two accounts for the same provider
    /// never share a secret. Derived from the account's immutable id, so a
    /// rename never moves the secret.
    static func providerAccountKey(_ id: UUID) -> String {
        "\(providerAccountPrefix)\(id.uuidString)"
    }

    static let providerAccountPrefix = "provider-account-"

    static func mcpCredentialKey(_ serverID: String) -> String {
        "\(mcpCredentialPrefix)\(serverID)"
    }

    static let mcpCredentialPrefix = "mcp-server-"

    /// The manual proxy's password. One entry, in its own `network` section of
    /// the file. A version of Locus from before proxy support rebuilds the file
    /// from the sections it knows on its next credential write, dropping this
    /// one — the same accepted downgrade behavior the file already has, and the
    /// cost is re-entering one password.
    static let proxyCredentialKey = "network-proxy"

    /// Additional named proxy profiles keep independent passwords. The legacy
    /// primary profile intentionally retains `network-proxy` so an upgrade
    /// never asks the user to re-enter its secret.
    static let proxyProfileCredentialPrefix = "network-proxy-profile-"

    static func proxyCredentialKey(profileID: UUID) -> String {
        profileID == ProxyProfile.primaryID
            ? proxyCredentialKey
            : "\(proxyProfileCredentialPrefix)\(profileID.uuidString)"
    }

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".locus", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// The location to show the user. In the sandboxed App Store build
    /// `NSHomeDirectory()` is the container, so this is not always
    /// `~/.locus/auth.json` — never hardcode that in a string.
    static var displayPath: String {
        (fileURL.path as NSString).abbreviatingWithTildeInPath
    }

    // The production facade retains its original location and behavior. Tests
    // receive independent instances; they never redirect this shared store.
    static let shared = FileCredentialStore(fileURL: fileURL)
    static var isDegraded: Bool { shared.isDegraded }
    @discardableResult static func set(_ value: String, account: String) -> Bool {
        shared.set(value, account: account)
    }
    static func get(account: String) -> String? { shared.get(account: account) }
    static func has(account: String) -> Bool { shared.has(account: account) }
    @discardableResult static func remove(account: String) -> Bool { shared.remove(account: account) }
    static func proxyPassword() -> String? { shared.proxyPassword() }
    static func proxyPassword(profileID: UUID) -> String? { shared.proxyPassword(profileID: profileID) }
    @discardableResult static func setProxyPassword(_ value: String) -> Bool {
        shared.setProxyPassword(value)
    }
    @discardableResult static func setProxyPassword(_ value: String, profileID: UUID) -> Bool {
        shared.setProxyPassword(value, profileID: profileID)
    }
    static func proxyPasswords(for profiles: [ProxyProfile]) -> [UUID: String] {
        shared.proxyPasswords(for: profiles)
    }
    static func removeOrphanedProxyProfilePasswords(keeping ids: Set<UUID>) {
        shared.removeOrphanedProxyProfilePasswords(keeping: ids)
    }
    static func allAccounts() -> [String] { shared.allAccounts() }
    static func removeOrphanedProviderKeys(keeping accounts: Set<String>) {
        shared.removeOrphanedProviderKeys(keeping: accounts)
    }
    static func removeOrphanedMCPCredentials(keeping ids: Set<String>) {
        shared.removeOrphanedMCPCredentials(keeping: ids)
    }
    static func resetCacheForTesting() { shared.resetCacheForTesting() }
}

protocol CredentialStoring: Sendable {
    var displayPath: String { get }
    func get(account: String) -> String?
    @discardableResult func set(_ value: String, account: String) -> Bool
    @discardableResult func remove(account: String) -> Bool
}

extension CredentialStoring {
    func has(account: String) -> Bool { get(account: account)?.isEmpty == false }
}

/// An explicitly located file store, with its own cache and lock. Synthetic
/// file-format fixtures supply a fresh owned temporary directory, not a copy
/// or backup of the production credential file.
final class FileCredentialStore: CredentialStoring, @unchecked Sendable {
    let fileURL: URL
    var displayPath: String { (fileURL.path as NSString).abbreviatingWithTildeInPath }

    init(fileURL: URL) { self.fileURL = fileURL }

    // MARK: - Cache

    /// `hasKey` is read during SwiftUI body evaluation — once per account per
    /// render — so every lookup must stay in memory. The file is read once and
    /// written through on change.
    private let lock = NSLock()
    private var cache: [String: String]?
    /// Set when a file exists but could not be understood. Anything
    /// destructive must refuse to act on that, because the entries it could
    /// not read are exactly the ones that would look orphaned.
    private var readDegraded = false

    /// True when the stored file could not be parsed. Callers that delete must
    /// not act while this holds.
    var isDegraded: Bool {
        lock.lock(); defer { lock.unlock() }
        _ = loadLocked()
        return readDegraded
    }

    private func loadLocked() -> [String: String] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else {
            // No file is a first run, not a degradation.
            cache = [:]
            readDegraded = false
            return [:]
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            readDegraded = true
            cache = [:]
            return [:]
        }
        // Read entry by entry. `as? [String: String]` on a whole section is
        // all-or-nothing — one `null` or number anywhere in it and the entire
        // section casts to nil, which would look like "these accounts have no
        // keys" and let the next write overwrite the survivors.
        var merged: [String: String] = [:]
        for section in [providerSection, mcpSection, networkSection] {
            guard let raw = root[section] else { continue }
            guard let entries = raw as? [String: Any] else {
                return degradedLocked()
            }
            for (key, value) in entries {
                guard let string = value as? String else {
                    return degradedLocked()
                }
                merged[key] = string
            }
        }
        readDegraded = false
        cache = merged
        return merged
    }

    /// Refuse to serve a partial view of a file we only half understood: the
    /// entries that failed to read are exactly the ones a sweep would treat as
    /// orphans, and the ones a write would drop.
    private func degradedLocked() -> [String: String] {
        readDegraded = true
        cache = [:]
        return [:]
    }

    private let providerSection = "provider_accounts"
    private let mcpSection = "mcp_servers"
    private let networkSection = "network"

    /// A name no earlier salvage already owns, so corrupting the file twice
    /// never destroys the first copy.
    private func uniqueSalvageURL(in directory: URL) -> URL {
        let base = directory.appendingPathComponent("auth.json.corrupt")
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        for suffix in 2...999 {
            let candidate = directory.appendingPathComponent("auth.json.corrupt.\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("auth.json.corrupt.\(UUID().uuidString)")
    }

    // MARK: - Persistence

    @discardableResult
    private func writeLocked(_ entries: [String: String]) -> Bool {
        var provider: [String: String] = [:]
        var mcp: [String: String] = [:]
        var network: [String: String] = [:]
        for (key, value) in entries {
            if key.hasPrefix(CredentialStore.mcpCredentialPrefix) {
                mcp[key] = value
            } else if key == CredentialStore.proxyCredentialKey || key.hasPrefix(CredentialStore.proxyProfileCredentialPrefix) {
                // Its own section, not the provider fallback: the orphan sweep
                // walks provider keys, and a proxy password that landed there
                // would be collected as an account nothing owns.
                network[key] = value
            } else {
                provider[key] = value
            }
        }
        let root: [String: Any] = [
            "version": 1,
            providerSection: provider,
            mcpSection: mcp,
            networkSection: network,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Re-assert on an existing directory, which createDirectory leaves alone.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )

            // A file we could not parse may still hold recoverable secrets, so
            // moving it aside is a precondition of writing, not a courtesy: if
            // it cannot be saved, do not overwrite it. The name is unique so a
            // second corruption never destroys the first salvage.
            var salvaged = false
            if readDegraded, FileManager.default.fileExists(atPath: fileURL.path) {
                let salvage = uniqueSalvageURL(in: directory)
                do {
                    try FileManager.default.moveItem(at: fileURL, to: salvage)
                    salvaged = true
                } catch {
                    return false
                }
            }

            // Create the temp file already restricted rather than writing it
            // wide and narrowing after — otherwise the secret exists, however
            // briefly, at mode 0644 & ~umask. Same ordering the agent uses in
            // extensions.py::_save.
            let temporary = directory.appendingPathComponent("auth.json.\(UUID().uuidString).tmp")
            // A failed rename must not strand a plaintext copy of every secret.
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else { return false }

            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            // replaceItemAt can carry the *replaced* file's attributes over, so
            // re-assert rather than trusting the temp file's mode to survive.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
            // Only now is the old file genuinely superseded.
            if salvaged { readDegraded = false }
            cache = entries
            return true
        } catch {
            return false
        }
    }

    // MARK: - API

    @discardableResult
    func set(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(account: account) }
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        entries[account] = trimmed
        return writeLocked(entries)
    }

    func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = loadLocked()[account]
        return (value?.isEmpty ?? true) ? nil : value
    }

    func has(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }

    @discardableResult
    func remove(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard entries.removeValue(forKey: account) != nil else { return true }
        return writeLocked(entries)
    }

    /// The manual proxy's password, through the same entry API as every other
    /// secret so writes share the salvage and permission discipline.
    func proxyPassword() -> String? {
        get(account: CredentialStore.proxyCredentialKey)
    }

    func proxyPassword(profileID: UUID) -> String? {
        get(account: CredentialStore.proxyCredentialKey(profileID: profileID))
    }

    /// An empty value deletes the entry, so switching auth off leaves nothing.
    @discardableResult
    func setProxyPassword(_ value: String) -> Bool {
        set(value, account: CredentialStore.proxyCredentialKey)
    }

    @discardableResult
    func setProxyPassword(_ value: String, profileID: UUID) -> Bool {
        set(value, account: CredentialStore.proxyCredentialKey(profileID: profileID))
    }

    func proxyPasswords(for profiles: [ProxyProfile]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
            proxyPassword(profileID: profile.id).map { (profile.id, $0) }
        })
    }

    func removeOrphanedProxyProfilePasswords(keeping profileIDs: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard !readDegraded else { return }
        let live = Set(profileIDs.map { CredentialStore.proxyCredentialKey(profileID: $0) })
        let doomed = entries.keys.filter {
            $0.hasPrefix(CredentialStore.proxyProfileCredentialPrefix) && !live.contains($0)
        }
        guard !doomed.isEmpty else { return }
        doomed.forEach { entries.removeValue(forKey: $0) }
        writeLocked(entries)
    }

    /// Every account name Locus has stored. Used to sweep up keys whose
    /// account was deleted while the app was not running to see it.
    func allAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadLocked().keys)
    }

    /// Deletes provider-account keys with no matching account — the residue of
    /// a crash between writing the key and saving the account list.
    func removeOrphanedProviderKeys(keeping liveAccounts: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard !readDegraded else { return }
        let doomed = entries.keys.filter {
            $0.hasPrefix(CredentialStore.providerAccountPrefix) && !liveAccounts.contains($0)
        }
        guard !doomed.isEmpty else { return }
        doomed.forEach { entries.removeValue(forKey: $0) }
        writeLocked(entries)
    }

    /// The same reclamation for MCP credentials. These hold OAuth access and
    /// refresh tokens for third-party servers, so an entry left behind by a
    /// server removed outside the app — a hand-edited or reset extensions
    /// state file, or a crash between the backend delete and the local delete —
    /// is a live third-party token nothing else would ever collect.
    func removeOrphanedMCPCredentials(keeping liveServerIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard !readDegraded else { return }
        let live = Set(liveServerIDs.map(CredentialStore.mcpCredentialKey))
        let doomed = entries.keys.filter {
            $0.hasPrefix(CredentialStore.mcpCredentialPrefix) && !live.contains($0)
        }
        guard !doomed.isEmpty else { return }
        doomed.forEach { entries.removeValue(forKey: $0) }
        writeLocked(entries)
    }

    /// Drops the in-memory copy. Tests use this to observe a fresh read.
    func resetCacheForTesting() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
        readDegraded = false
    }
}

/// Per-model synthetic credentials. No disk path, migration, or Keychain API
/// is reachable from this implementation.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    let displayPath = "temporary memory storage"
    private let lock = NSLock()
    private var entries: [String: String] = [:]

    func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[account]
    }

    @discardableResult func set(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        entries[account] = trimmed.isEmpty ? nil : trimmed
        return true
    }

    @discardableResult func remove(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: account)
        return true
    }
}

@MainActor
protocol MCPCredentialStoring {
    var displayName: String { get }
    func get(serverID: String) -> [String: Any]?
    @discardableResult func set(_ values: [String: Any], serverID: String) -> Bool
    @discardableResult func remove(serverID: String) -> Bool
    func removeOrphaned(keeping liveServerIDs: Set<String>)
}

@MainActor
struct KeychainMCPCredentialStore: MCPCredentialStoring {
    var displayName: String { MCPCredentialStore.displayName }
    func get(serverID: String) -> [String: Any]? { MCPCredentialStore.get(serverID: serverID) }
    @discardableResult func set(_ values: [String: Any], serverID: String) -> Bool {
        MCPCredentialStore.set(values, serverID: serverID)
    }
    @discardableResult func remove(serverID: String) -> Bool { MCPCredentialStore.remove(serverID: serverID) }
    func removeOrphaned(keeping liveServerIDs: Set<String>) {
        MCPCredentialStore.removeOrphaned(keeping: liveServerIDs)
    }
}

@MainActor
final class InMemoryMCPCredentialStore: MCPCredentialStoring {
    let displayName = "temporary memory storage"
    private var entries: [String: Data] = [:]

    func get(serverID: String) -> [String: Any]? {
        guard let data = entries[serverID] else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult func set(_ values: [String: Any], serverID: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        else { return false }
        entries[serverID] = data
        return true
    }

    @discardableResult func remove(serverID: String) -> Bool {
        entries.removeValue(forKey: serverID)
        return true
    }

    func removeOrphaned(keeping liveServerIDs: Set<String>) {
        entries = entries.filter { liveServerIDs.contains($0.key) }
    }
}

/// MCP OAuth and token material is app-owned Keychain data. A one-time lazy
/// migration preserves credentials written by older Locus releases.
enum MCPCredentialStore {
    private static let service = "io.sparktales.locus.mcp"
    static var displayName: String { "macOS Keychain" }

    static func get(serverID: String) -> [String: Any]? {
        if let data = data(serverID: serverID),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return root
        }
        let legacyAccount = CredentialStore.mcpCredentialKey(serverID)
        guard let encoded = CredentialStore.get(account: legacyAccount),
              let legacyData = encoded.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any],
              set(root, serverID: serverID)
        else { return nil }
        _ = CredentialStore.remove(account: legacyAccount)
        return root
    }

    @discardableResult
    static func set(_ values: [String: Any], serverID: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(
                withJSONObject: values,
                options: [.sortedKeys]
              )
        else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID,
        ]
        let updates: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var created = query
        created[kSecValueData] = data
        created[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(created as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(serverID: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        _ = CredentialStore.remove(account: CredentialStore.mcpCredentialKey(serverID))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func removeOrphaned(keeping liveServerIDs: Set<String>) {
        for serverID in allServerIDs() where !liveServerIDs.contains(serverID) {
            _ = remove(serverID: serverID)
        }
        CredentialStore.removeOrphanedMCPCredentials(keeping: liveServerIDs)
    }

    private static func data(serverID: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func allServerIDs() -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return []
        }
        let rows: [[CFString: Any]]
        if let values = result as? [[CFString: Any]] { rows = values }
        else if let value = result as? [CFString: Any] { rows = [value] }
        else { rows = [] }
        return rows.compactMap { $0[kSecAttrAccount] as? String }
    }
}

private final class MCPNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Standards-discovered MCP OAuth with issuer-bound registrations and tokens.
/// Discovery is performed only after the user chooses Connect.
@MainActor
final class MCPAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private struct Context {
        let issuer: String
        let authorizationURL: URL
        let tokenURL: URL
        let clientID: String
        let clientSecret: String?
        let redirectURI: String
        let scopes: [String]
        let resource: String
        let requireIssuerResponse: Bool
    }

    private struct ProtectedResourceContext {
        let metadata: [String: Any]
        let challengedScopes: [String]
    }

    private let maximumMetadataBytes = 1_048_576
    private let testConfiguration: URLSessionConfiguration?
    private let credentialStore: any MCPCredentialStoring
    private var session: ASWebAuthenticationSession?
    private var deviceTask: Task<Void, Never>?

    override init() {
        testConfiguration = nil
        credentialStore = KeychainMCPCredentialStore()
        super.init()
    }

    init(credentialStore: any MCPCredentialStoring) {
        testConfiguration = nil
        self.credentialStore = credentialStore
        super.init()
    }

    init(configurationForTesting: URLSessionConfiguration, credentialStore: any MCPCredentialStoring) {
        testConfiguration = configurationForTesting
        self.credentialStore = credentialStore
        super.init()
    }

    func authorize(
        server: ExtensionMCPServer,
        onDeviceCode: ((MCPDeviceAuthorizationPrompt) -> Void)? = nil,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        if server.oauthStrategy == "github_device" {
            startGitHubDeviceAuthorization(
                server: server,
                onDeviceCode: onDeviceCode,
                completion: completion
            )
            return
        }
        Task { @MainActor in
            do {
                let context = try await resolve(server: server)
                startAuthorization(context: context, completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        deviceTask?.cancel()
        deviceTask = nil
    }

    func resolvedConfigurationForTesting(
        server: ExtensionMCPServer
    ) async throws -> [String: Any] {
        let context = try await resolve(server: server)
        return [
            "issuer": context.issuer,
            "authorization_endpoint": context.authorizationURL.absoluteString,
            "token_endpoint": context.tokenURL.absoluteString,
            "client_id": context.clientID,
            "resource": context.resource,
            "scopes": context.scopes,
        ]
    }

    func refreshedCredentialsIfNeeded(_ credentials: [String: Any]) async throws -> [String: Any] {
        let expiresAt = (credentials["expires_at"] as? NSNumber)?.doubleValue
            ?? .greatestFiniteMagnitude
        guard expiresAt <= Date().timeIntervalSince1970 + 60,
              let refreshToken = credentials["refresh_token"] as? String,
              let endpoint = credentials["token_endpoint"] as? String,
              let tokenURL = try? secureURL(endpoint, label: "token endpoint"),
              let clientID = credentials["client_id"] as? String,
              let issuer = credentials["issuer"] as? String,
              !issuer.isEmpty
        else { return credentials }

        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let clientSecret = credentials["client_secret"] as? String, !clientSecret.isEmpty {
            fields["client_secret"] = clientSecret
        }
        if credentials["auth_strategy"] as? String != "github_device",
           let resource = credentials["resource"] as? String,
           !resource.isEmpty {
            fields["resource"] = resource
        }
        let root = try await tokenRequest(url: tokenURL, fields: fields, operation: "refresh")
        guard let accessToken = root["access_token"] as? String, !accessToken.isEmpty else {
            throw authError("The OAuth refresh response did not contain an access token.")
        }
        var updated = credentials
        updated["access_token"] = accessToken
        if let nextRefresh = root["refresh_token"] as? String, !nextRefresh.isEmpty {
            updated["refresh_token"] = nextRefresh
        }
        if let expiresIn = root["expires_in"] as? NSNumber {
            updated["expires_at"] = Date().timeIntervalSince1970 + expiresIn.doubleValue
        }
        updated["issuer"] = issuer
        return updated
    }

    private func startGitHubDeviceAuthorization(
        server: ExtensionMCPServer,
        onDeviceCode: ((MCPDeviceAuthorizationPrompt) -> Void)?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        deviceTask?.cancel()
        deviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let values = try await githubDeviceCredentials(
                    server: server,
                    onDeviceCode: onDeviceCode
                )
                guard !Task.isCancelled else {
                    throw authError("GitHub sign-in was cancelled.")
                }
                deviceTask = nil
                completion(.success(values))
            } catch is CancellationError {
                deviceTask = nil
                completion(.failure(authError("GitHub sign-in was cancelled.")))
            } catch {
                deviceTask = nil
                completion(.failure(error))
            }
        }
    }

    private func githubDeviceCredentials(
        server: ExtensionMCPServer,
        onDeviceCode: ((MCPDeviceAuthorizationPrompt) -> Void)?
    ) async throws -> [String: Any] {
        let clientID = try githubClientID(server: server)
        guard let resourceURL = try? secureURL(server.url ?? "", label: "GitHub MCP server")
        else { throw authError("The GitHub MCP server URL is invalid.") }
        let deviceURL = URL(string: "https://github.com/login/device/code")!
        let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
        let device = try await githubFormRequest(
            url: deviceURL,
            fields: ["client_id": clientID],
            operation: "device authorization"
        )
        guard let deviceCode = device["device_code"] as? String,
              let userCode = device["user_code"] as? String,
              let verification = device["verification_uri"] as? String,
              let verificationURL = URL(string: verification),
              let expiresIn = device["expires_in"] as? NSNumber
        else {
            throw authError("GitHub returned an incomplete device authorization response.")
        }
        var interval = max((device["interval"] as? NSNumber)?.intValue ?? 5, 1)
        let expiresAt = Date().addingTimeInterval(expiresIn.doubleValue)
        onDeviceCode?(
            MCPDeviceAuthorizationPrompt(
                serverID: server.id,
                serverName: server.name,
                userCode: userCode,
                verificationURL: verificationURL,
                expiresAt: expiresAt
            )
        )

        while Date() < expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()
            let response = try await githubFormRequest(
                url: tokenURL,
                fields: [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ],
                operation: "device token"
            )
            if let accessToken = response["access_token"] as? String,
               !accessToken.isEmpty {
                let login = try await validateGitHubAccount(accessToken: accessToken)
                var credentials: [String: Any] = [
                    "access_token": accessToken,
                    "token_endpoint": tokenURL.absoluteString,
                    "client_id": clientID,
                    "issuer": "https://github.com/login/oauth",
                    "resource": resourceURL.absoluteString,
                    "auth_strategy": "github_device",
                    "account_login": login,
                ]
                if let refreshToken = response["refresh_token"] as? String,
                   !refreshToken.isEmpty {
                    credentials["refresh_token"] = refreshToken
                }
                if let tokenExpires = response["expires_in"] as? NSNumber {
                    credentials["expires_at"] = Date().timeIntervalSince1970
                        + tokenExpires.doubleValue
                }
                if let scope = response["scope"] as? String { credentials["scope"] = scope }
                return credentials
            }
            switch response["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                throw authError("GitHub sign-in was denied. You can try again or use a personal token instead.")
            case "expired_token":
                throw authError("The GitHub sign-in code expired. Start Connect account again for a new code.")
            case "device_flow_disabled":
                throw authError("Device flow is disabled for the configured Locus GitHub App.")
            case let value?:
                let description = response["error_description"] as? String
                throw authError(description?.isEmpty == false ? description! : "GitHub sign-in failed (\(value)).")
            case nil:
                throw authError("GitHub returned neither a token nor a device-flow status.")
            }
        }
        throw authError("The GitHub sign-in code expired. Start Connect account again for a new code.")
    }

    private func githubClientID(server: ExtensionMCPServer) throws -> String {
        guard let clientID = GitHubConnectionConfiguration.clientID(
            configured: server.oauth?.clientID
        ) else {
            throw authError(
                "GitHub account sign-in is unavailable in this build because its public app client ID is not configured. Use a personal token instead."
            )
        }
        return clientID
    }

    private func githubFormRequest(
        url: URL,
        fields: [String: String],
        operation: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await dataWithoutRedirects(for: request)
        guard (200..<300).contains(response.statusCode),
              data.count <= maximumMetadataBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw authError("GitHub \(operation) failed. Check your network and release configuration.")
        }
        return root
    }

    private func validateGitHubAccount(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await dataWithoutRedirects(for: request)
        guard response.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = root["login"] as? String,
              !login.isEmpty
        else {
            if response.statusCode == 403 {
                throw authError("GitHub accepted the sign-in but the account or organization blocked access. Ask an organization owner to approve and install the Locus GitHub App, or use a permitted personal token.")
            }
            throw authError("GitHub returned credentials that could not validate the signed-in account.")
        }
        return login
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }

    nonisolated static func callbackMatches(
        _ callback: URLComponents,
        expected: URLComponents
    ) -> Bool {
        callback.scheme?.lowercased() == expected.scheme?.lowercased()
            && callback.host?.lowercased() == expected.host?.lowercased()
            && callback.port == expected.port
            && callback.path == expected.path
            && callback.user == nil
            && callback.password == nil
            && callback.fragment == nil
    }

    nonisolated static func authorizationResponseIssuerIsValid(
        _ returned: String?,
        expected: String,
        required: Bool
    ) -> Bool {
        guard let returned else { return !required }
        // RFC 9207 requires simple string comparison: deliberately do not
        // fold case, remove a trailing slash, or otherwise normalize here.
        return returned == expected
    }

    private func startAuthorization(
        context: Context,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)
        guard let expectedRedirect = URLComponents(string: context.redirectURI),
              let callbackScheme = expectedRedirect.scheme?.lowercased(),
              callbackScheme == "locus",
              var components = URLComponents(url: context.authorizationURL, resolvingAgainstBaseURL: false)
        else {
            completion(.failure(authError("The MCP OAuth redirect or authorization URL is invalid.")))
            return
        }
        var query = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: context.clientID),
            URLQueryItem(name: "redirect_uri", value: context.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: context.resource),
        ]
        if !context.scopes.isEmpty {
            query.append(URLQueryItem(name: "scope", value: context.scopes.joined(separator: " ")))
        }
        components.queryItems = (components.queryItems ?? []) + query
        guard let authorizationURL = components.url else {
            completion(.failure(authError("The MCP authorization URL is invalid.")))
            return
        }
        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            self.session = nil
            if let error {
                completion(.failure(error))
                return
            }
            guard let callbackURL,
                  let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  Self.callbackMatches(callback, expected: expectedRedirect),
                  callback.queryItems?.first(where: { $0.name == "state" })?.value == state,
                  let code = callback.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty
            else {
                completion(.failure(self.authError("The MCP OAuth callback did not pass redirect and state validation.")))
                return
            }
            let returnedIssuer = callback.queryItems?.first(where: { $0.name == "iss" })?.value
            if !Self.authorizationResponseIssuerIsValid(
                returnedIssuer,
                expected: context.issuer,
                required: context.requireIssuerResponse
            ) {
                completion(.failure(self.authError("The MCP OAuth callback issuer did not match the authorization server.")))
                return
            }
            Task { @MainActor in
                do {
                    let values = try await self.exchangeCode(
                        code,
                        verifier: verifier,
                        context: context
                    )
                    completion(.success(values))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            completion(.failure(authError("The system browser could not start MCP authentication.")))
        }
    }

    private func resolve(server: ExtensionMCPServer) async throws -> Context {
        guard let resourceURL = try? secureURL(server.url ?? "", label: "MCP server"),
              var resourceComponents = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false)
        else { throw authError("Remote MCP authentication requires a credential-free HTTPS server URL.") }
        resourceComponents.fragment = nil
        guard let normalizedResource = resourceComponents.url?.absoluteString else {
            throw authError("The MCP resource URL is invalid.")
        }
        let redirectURI = try validatedRedirectURI(
            server.oauth?.redirectURI ?? "locus://mcp/oauth"
        )

        if server.auth == "oauth", let oauth = server.oauth {
            let authorizationURL = try secureURL(oauth.authorizationEndpoint, label: "authorization endpoint")
            let tokenURL = try secureURL(oauth.tokenEndpoint, label: "token endpoint")
            let issuer = try validatedIssuer(
                oauth.issuer ?? originString(for: authorizationURL)
            )
            return Context(
                issuer: issuer,
                authorizationURL: authorizationURL,
                tokenURL: tokenURL,
                clientID: oauth.clientID,
                clientSecret: nil,
                redirectURI: redirectURI,
                scopes: oauth.scopes,
                resource: normalizedResource,
                requireIssuerResponse: false
            )
        }

        guard server.auth == "auto" else {
            throw authError("This MCP server is not configured for OAuth discovery.")
        }
        let protectedResource = try await discoverProtectedResource(
            resourceURL: resourceURL,
            resource: normalizedResource
        )
        let protectedMetadata = protectedResource.metadata
        guard let servers = protectedMetadata["authorization_servers"] as? [String],
              let first = servers.first
        else { throw authError("The MCP protected-resource metadata did not name an authorization server.") }
        let issuer = try validatedIssuer(first)
        let authorizationMetadata = try await discoverAuthorizationServer(issuer: issuer)
        guard authorizationMetadata["issuer"] as? String == issuer else {
            throw authError("Authorization metadata returned a different issuer.")
        }
        guard let authorization = authorizationMetadata["authorization_endpoint"] as? String,
              let token = authorizationMetadata["token_endpoint"] as? String
        else { throw authError("Authorization metadata is missing required endpoints.") }
        let authorizationURL = try secureURL(authorization, label: "authorization endpoint")
        let tokenURL = try secureURL(token, label: "token endpoint")
        guard let challengeMethods = authorizationMetadata["code_challenge_methods_supported"] as? [String],
              challengeMethods.contains("S256")
        else { throw authError("The authorization server does not advertise S256 PKCE.") }

        let stored = credentialStore.get(serverID: server.id) ?? [:]
        let storedIssuer = stored["issuer"] as? String ?? ""
        var clientID = storedIssuer == issuer ? (stored["client_id"] as? String ?? "") : ""
        var clientSecret = storedIssuer == issuer ? stored["client_secret"] as? String : nil
        var registeredNow = false
        if clientID.isEmpty, let configured = server.oauth?.clientID, !configured.isEmpty {
            clientID = configured
        }
        if URLComponents(string: clientID)?.scheme?.lowercased() == "https" {
            guard authorizationMetadata["client_id_metadata_document_supported"] as? Bool == true else {
                throw authError("The authorization server does not support client ID metadata documents.")
            }
            try await validateClientMetadataDocument(clientID, redirectURI: redirectURI)
        } else if clientID.isEmpty {
            guard let registration = authorizationMetadata["registration_endpoint"] as? String else {
                throw authError("This server offers neither a client metadata document nor dynamic registration. Use its token fallback instead.")
            }
            let registered = try await registerClient(
                endpoint: try secureURL(registration, label: "registration endpoint"),
                redirectURI: redirectURI
            )
            clientID = registered.clientID
            clientSecret = registered.clientSecret
            registeredNow = true
        }
        guard !clientID.isEmpty else { throw authError("OAuth client registration returned no client ID.") }
        var scopes = server.oauth?.scopes ?? []
        let discoveredScopes = protectedResource.challengedScopes.isEmpty
            ? (scopes.isEmpty ? protectedMetadata["scopes_supported"] as? [String] ?? [] : [])
            : protectedResource.challengedScopes
        for scope in discoveredScopes where !scopes.contains(scope) { scopes.append(scope) }
        guard scopes.count <= 100, scopes.allSatisfy(Self.validScope) else {
            throw authError("The OAuth server returned an invalid or oversized scope set.")
        }
        if registeredNow {
            var registration = storedIssuer == issuer ? stored : [:]
            registration["issuer"] = issuer
            registration["client_id"] = clientID
            if let clientSecret, !clientSecret.isEmpty {
                registration["client_secret"] = clientSecret
            } else {
                registration.removeValue(forKey: "client_secret")
            }
            registration["token_endpoint"] = tokenURL.absoluteString
            registration["resource"] = normalizedResource
            guard credentialStore.set(registration, serverID: server.id) else {
                throw authError("The OAuth registration could not be stored in \(credentialStore.displayName).")
            }
        }
        return Context(
            issuer: issuer,
            authorizationURL: authorizationURL,
            tokenURL: tokenURL,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            scopes: scopes,
            resource: normalizedResource,
            requireIssuerResponse: authorizationMetadata["authorization_response_iss_parameter_supported"] as? Bool == true
        )
    }

    private func discoverProtectedResource(
        resourceURL: URL,
        resource: String
    ) async throws -> ProtectedResourceContext {
        // The 2026-07-28 authorization spec gives an explicit challenge URL
        // priority over guessed well-known locations.
        if let challenge = try await resourceMetadataFromChallenge(resourceURL) {
            let metadata = try await fetchJSON(challenge.url)
            guard try resourceMatches(metadata["resource"] as? String, expected: resource) else {
                throw authError("Protected-resource metadata named a different MCP resource.")
            }
            return ProtectedResourceContext(
                metadata: metadata,
                challengedScopes: challenge.scopes
            )
        }
        guard var components = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false) else {
            throw authError("The MCP resource URL is invalid.")
        }
        let resourcePath = components.path == "/" ? "" : components.path
        components.path = "/.well-known/oauth-protected-resource" + resourcePath
        components.query = nil
        var candidates = components.url.map { [$0] } ?? []
        components.path = "/.well-known/oauth-protected-resource"
        if let root = components.url, !candidates.contains(root) { candidates.append(root) }

        for candidate in candidates {
            if let metadata = try? await fetchJSON(candidate),
               try resourceMatches(metadata["resource"] as? String, expected: resource) {
                return ProtectedResourceContext(metadata: metadata, challengedScopes: [])
            }
        }
        throw authError("The MCP server did not provide valid protected-resource metadata.")
    }

    private func resourceMetadataFromChallenge(
        _ resourceURL: URL
    ) async throws -> (url: URL, scopes: [String])? {
        var request = URLRequest(url: resourceURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("server/discover", forHTTPHeaderField: "Mcp-Method")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "server/discover",
            "params": [
                "_meta": [
                    "io.modelcontextprotocol/clientInfo": [
                        "name": "Locus", "version": "1",
                    ],
                ],
            ],
        ])
        let (_, response) = try await dataWithoutRedirects(for: request)
        guard response.statusCode == 401,
              let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")
        else { return nil }
        guard let metadataValue = Self.challengeParameter(
            "resource_metadata",
            in: challenge
        ) else {
            if challenge.localizedCaseInsensitiveContains("resource_metadata") {
                throw authError("The MCP authorization challenge has invalid protected-resource metadata.")
            }
            return nil
        }
        let scopes = Self.challengeParameter("scope", in: challenge)?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        return (
            try secureURL(metadataValue, label: "resource metadata URL"),
            scopes
        )
    }

    private func discoverAuthorizationServer(issuer: String) async throws -> [String: Any] {
        guard var components = URLComponents(string: issuer) else {
            throw authError("The authorization issuer is invalid.")
        }
        let issuerPath = components.path == "/" ? "" : components.path
        components.path = "/.well-known/oauth-authorization-server" + issuerPath
        components.query = nil
        var candidates = components.url.map { [$0] } ?? []
        components = URLComponents(string: issuer)!
        components.path = "/.well-known/openid-configuration" + issuerPath
        components.query = nil
        if let oidcInserted = components.url { candidates.append(oidcInserted) }
        components = URLComponents(string: issuer)!
        components.path = issuerPath + "/.well-known/openid-configuration"
        components.query = nil
        if let oidc = components.url, !candidates.contains(oidc) { candidates.append(oidc) }
        for candidate in candidates {
            if let metadata = try? await fetchJSON(candidate),
               metadata["issuer"] as? String == issuer {
                return metadata
            }
        }
        throw authError("OAuth and OpenID discovery did not return issuer-bound metadata.")
    }

    private func validateClientMetadataDocument(
        _ identifier: String,
        redirectURI: String
    ) async throws {
        let documentURL = try secureURL(identifier, label: "client metadata document")
        guard !documentURL.path.isEmpty, documentURL.path != "/" else {
            throw authError("A client metadata document URL must include a path.")
        }
        let metadata = try await fetchJSON(documentURL)
        guard metadata["client_id"] as? String == identifier,
              let clientName = metadata["client_name"] as? String,
              !clientName.isEmpty
        else { throw authError("The client metadata document has missing or mismatched identity fields.") }
        guard let redirects = metadata["redirect_uris"] as? [String], redirects.contains(redirectURI) else {
            throw authError("The client metadata document does not allow the Locus callback.")
        }
    }

    private func registerClient(endpoint: URL, redirectURI: String) async throws -> (clientID: String, clientSecret: String?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Locus",
            "application_type": "native",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await dataWithoutRedirects(for: request)
        guard (200..<300).contains(response.statusCode),
              data.count <= maximumMetadataBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = root["client_id"] as? String,
              !clientID.isEmpty
        else { throw authError("Dynamic OAuth client registration failed.") }
        return (clientID, root["client_secret"] as? String)
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        context: Context
    ) async throws -> [String: Any] {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": context.redirectURI,
            "client_id": context.clientID,
            "code_verifier": verifier,
            "resource": context.resource,
        ]
        if let secret = context.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        let root = try await tokenRequest(url: context.tokenURL, fields: fields, operation: "exchange")
        guard let accessToken = root["access_token"] as? String, !accessToken.isEmpty else {
            throw authError("The token endpoint returned no access token.")
        }
        var credentials: [String: Any] = [
            "access_token": accessToken,
            "token_endpoint": context.tokenURL.absoluteString,
            "client_id": context.clientID,
            "issuer": context.issuer,
            "resource": context.resource,
            "scope": context.scopes.joined(separator: " "),
        ]
        if let secret = context.clientSecret, !secret.isEmpty { credentials["client_secret"] = secret }
        if let refreshToken = root["refresh_token"] as? String, !refreshToken.isEmpty {
            credentials["refresh_token"] = refreshToken
        }
        if let expiresIn = root["expires_in"] as? NSNumber {
            credentials["expires_at"] = Date().timeIntervalSince1970 + expiresIn.doubleValue
        }
        return credentials
    }

    private func tokenRequest(
        url: URL,
        fields: [String: String],
        operation: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await dataWithoutRedirects(for: request)
        guard (200..<300).contains(response.statusCode), data.count <= maximumMetadataBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let message = String(data: data.prefix(4_096), encoding: .utf8)
                ?? "MCP OAuth \(operation) failed."
            throw authError(message)
        }
        return root
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithoutRedirects(for: request)
        guard response.statusCode == 200,
              data.count <= maximumMetadataBytes,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw authError("OAuth metadata returned an invalid or oversized response.") }
        return value
    }

    private func dataWithoutRedirects(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = MCPNoRedirectDelegate()
        let configuration = (testConfiguration?.copy() as? URLSessionConfiguration)
            ?? ProxyRuntime.shared.configuration(scope: .modelAndAgent)
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              !(300..<400).contains(http.statusCode)
        else { throw authError("OAuth redirects are not accepted during discovery or token exchange.") }
        return (data, http)
    }

    private func resourceMatches(_ declared: String?, expected: String) throws -> Bool {
        guard let declared,
              let url = try? secureURL(declared, label: "protected resource")
        else { return false }
        return url.absoluteString == expected
    }

    private func secureURL(_ value: String, label: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url
        else { throw authError("The \(label) must be a credential-free HTTPS URL.") }
        return url
    }

    private func validatedIssuer(_ value: String) throws -> String {
        let url = try secureURL(value, label: "authorization issuer")
        guard url.query == nil else { throw authError("The authorization issuer cannot contain a query.") }
        return value
    }

    private func validatedRedirectURI(_ value: String) throws -> String {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "locus",
              components.host?.lowercased() == "mcp",
              components.port == nil,
              components.path == "/oauth",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw authError("The MCP OAuth redirect must be locus://mcp/oauth.") }
        return "locus://mcp/oauth"
    }

    private func originString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = ""
        components.query = nil
        return components.url!.absoluteString.hasSuffix("/")
            ? String(components.url!.absoluteString.dropLast())
            : components.url!.absoluteString
    }

    private nonisolated static func challengeParameter(
        _ name: String,
        in challenge: String
    ) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)(?:^|[,\\s])\(escaped)\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|([^,\\s]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: challenge,
                range: NSRange(challenge.startIndex..., in: challenge)
              )
        else { return nil }
        for index in 1...2 where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: challenge) {
                return String(challenge[range])
            }
        }
        return nil
    }

    private nonisolated static func validScope(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy { byte in
            byte == 0x21 || (0x23...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
        }
    }

    private nonisolated static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return base64URL(Data(bytes))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        ) ?? value
    }

    private func authError(_ message: String) -> NSError {
        NSError(
            domain: "Locus.MCPOAuth",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
