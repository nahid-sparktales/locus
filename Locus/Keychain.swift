import Foundation
import AuthenticationServices
import AppKit
import CryptoKit
import Security

/// Keychain storage for provider API keys.
///
/// A key never goes into UserDefaults or the agent's config file: it lives in
/// the login keychain and is handed to the local agent process in memory.
enum Keychain {
    /// The single pre-accounts endpoint key. Kept for the one-time migration
    /// that turns it into a provider account.
    static let remoteAPIKeyAccount = "remote-api-key"

    /// One entry per provider account, so two accounts for the same provider
    /// never share a secret.
    static func providerAccountKey(_ id: UUID) -> String {
        "\(providerAccountPrefix)\(id.uuidString)"
    }

    static let providerAccountPrefix = "provider-account-"

    static func mcpCredentialKey(_ serverID: String) -> String {
        "\(mcpCredentialPrefix)\(serverID)"
    }

    static let mcpCredentialPrefix = "mcp-server-"

    private static let service = "io.sparktales.locus"

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(account: account) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available without unlocking on every app launch, but never
            // synced to iCloud or another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func has(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every account name Locus has stored. Used to sweep up keys whose
    /// account was deleted while the app was not running to see it.
    static func allAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let entries = item as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Deletes provider-account keys with no matching account — the residue of
    /// a crash between writing the key and saving the account list.
    static func removeOrphanedProviderKeys(keeping liveAccounts: Set<String>) {
        for account in allAccounts()
        where account.hasPrefix(providerAccountPrefix) && !liveAccounts.contains(account) {
            remove(account: account)
        }
    }

    /// The same reclamation for MCP credentials. These hold OAuth access and
    /// refresh tokens for third-party servers, so a key left behind by a
    /// server removed outside the app — a hand-edited or reset extensions
    /// state file, or a crash between the backend delete and the Keychain
    /// delete — is a live third-party token nothing else would ever collect.
    static func removeOrphanedMCPCredentials(keeping liveServerIDs: Set<String>) {
        let live = Set(liveServerIDs.map(mcpCredentialKey))
        for account in allAccounts()
        where account.hasPrefix(mcpCredentialPrefix) && !live.contains(account) {
            remove(account: account)
        }
    }
}

/// OAuth 2.0 authorization-code + PKCE broker for remote MCP servers.
/// Tokens are returned to AppModel, which stores them in Keychain and hands
/// them to the local agent only through its transient credential endpoint.
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
