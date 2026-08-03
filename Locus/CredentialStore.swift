import Foundation
import AuthenticationServices
import AppKit
import CryptoKit

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

    // MARK: - Cache

    /// `hasKey` is read during SwiftUI body evaluation — once per account per
    /// render — so every lookup must stay in memory. The file is read once and
    /// written through on change.
    private static let lock = NSLock()
    private static var cache: [String: String]?
    /// Set when a file exists but could not be understood. Anything
    /// destructive must refuse to act on that, because the entries it could
    /// not read are exactly the ones that would look orphaned.
    private static var readDegraded = false

    /// True when the stored file could not be parsed. Callers that delete must
    /// not act while this holds.
    static var isDegraded: Bool {
        lock.lock(); defer { lock.unlock() }
        _ = loadLocked()
        return readDegraded
    }

    private static func loadLocked() -> [String: String] {
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
        for section in [providerSection, mcpSection] {
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
    private static func degradedLocked() -> [String: String] {
        readDegraded = true
        cache = [:]
        return [:]
    }

    private static let providerSection = "provider_accounts"
    private static let mcpSection = "mcp_servers"

    /// A name no earlier salvage already owns, so corrupting the file twice
    /// never destroys the first copy.
    private static func uniqueSalvageURL(in directory: URL) -> URL {
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
    private static func writeLocked(_ entries: [String: String]) -> Bool {
        var provider: [String: String] = [:]
        var mcp: [String: String] = [:]
        for (key, value) in entries {
            if key.hasPrefix(mcpCredentialPrefix) { mcp[key] = value } else { provider[key] = value }
        }
        let root: [String: Any] = [
            "version": 1,
            providerSection: provider,
            mcpSection: mcp,
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
    static func set(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(account: account) }
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        entries[account] = trimmed
        return writeLocked(entries)
    }

    static func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = loadLocked()[account]
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func has(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard entries.removeValue(forKey: account) != nil else { return true }
        return writeLocked(entries)
    }

    /// Every account name Locus has stored. Used to sweep up keys whose
    /// account was deleted while the app was not running to see it.
    static func allAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadLocked().keys)
    }

    /// Deletes provider-account keys with no matching account — the residue of
    /// a crash between writing the key and saving the account list.
    static func removeOrphanedProviderKeys(keeping liveAccounts: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard !readDegraded else { return }
        let doomed = entries.keys.filter {
            $0.hasPrefix(providerAccountPrefix) && !liveAccounts.contains($0)
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
    static func removeOrphanedMCPCredentials(keeping liveServerIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked()
        guard !readDegraded else { return }
        let live = Set(liveServerIDs.map(mcpCredentialKey))
        let doomed = entries.keys.filter {
            $0.hasPrefix(mcpCredentialPrefix) && !live.contains($0)
        }
        guard !doomed.isEmpty else { return }
        doomed.forEach { entries.removeValue(forKey: $0) }
        writeLocked(entries)
    }

    /// Drops the in-memory copy. Tests use this to observe a fresh read.
    static func resetCacheForTesting() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
        readDegraded = false
    }
}

/// OAuth 2.0 authorization-code + PKCE broker for remote MCP servers.
/// Tokens are returned to AppModel, which stores them in the credential file
/// and hands them to the local agent only through its transient credential
/// endpoint.
@MainActor
final class MCPAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(
        server: ExtensionMCPServer,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let oauth = server.oauth,
              var components = URLComponents(string: oauth.authorizationEndpoint),
              let tokenURL = URL(string: oauth.tokenEndpoint)
        else {
            completion(.failure(authError("This MCP server has incomplete OAuth settings.")))
            return
        }
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)
        let redirectURI = oauth.redirectURI ?? "locus://mcp/oauth"
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: oauth.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: oauth.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components.url else {
            completion(.failure(authError("The MCP authorization URL is invalid.")))
            return
        }
        let callbackScheme = URL(string: redirectURI)?.scheme ?? "locus"
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
                  callback.queryItems?.first(where: { $0.name == "state" })?.value == state,
                  let code = callback.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty
            else {
                completion(.failure(self.authError("The MCP OAuth callback did not pass state validation.")))
                return
            }
            Task { @MainActor in
                do {
                    let values = try await self.exchangeCode(
                        code,
                        verifier: verifier,
                        clientID: oauth.clientID,
                        redirectURI: redirectURI,
                        tokenURL: tokenURL
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

    func cancel() {
        session?.cancel()
        session = nil
    }

    func refreshedCredentialsIfNeeded(_ credentials: [String: Any]) async throws -> [String: Any] {
        let expiresAt = (credentials["expires_at"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude
        guard expiresAt <= Date().timeIntervalSince1970 + 60,
              let refreshToken = credentials["refresh_token"] as? String,
              let endpoint = credentials["token_endpoint"] as? String,
              let tokenURL = URL(string: endpoint),
              tokenURL.scheme?.lowercased() == "https",
              let clientID = credentials["client_id"] as? String
        else { return credentials }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        request.httpBody = fields
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String
        else {
            throw authError(String(data: data, encoding: .utf8) ?? "MCP OAuth refresh failed.")
        }
        var updated = credentials
        updated["access_token"] = accessToken
        if let nextRefresh = root["refresh_token"] as? String {
            updated["refresh_token"] = nextRefresh
        }
        if let expiresIn = root["expires_in"] as? NSNumber {
            updated["expires_at"] = Date().timeIntervalSince1970 + expiresIn.doubleValue
        }
        return updated
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        clientID: String,
        redirectURI: String,
        tokenURL: URL
    ) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        request.httpBody = fields
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String,
              !accessToken.isEmpty
        else {
            let message = String(data: data, encoding: .utf8) ?? "The token endpoint rejected the request."
            throw authError(message)
        }
        var credentials: [String: Any] = [
            "access_token": accessToken,
            "token_endpoint": tokenURL.absoluteString,
            "client_id": clientID,
        ]
        if let refreshToken = root["refresh_token"] as? String {
            credentials["refresh_token"] = refreshToken
        }
        if let expiresIn = root["expires_in"] as? NSNumber {
            credentials["expires_at"] = Date().timeIntervalSince1970 + expiresIn.doubleValue
        }
        return credentials
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
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
