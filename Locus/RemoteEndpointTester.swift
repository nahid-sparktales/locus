import Foundation

final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
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

/// How Locus identifies itself to every host the app talks to directly.
///
/// The agent sends its own equivalent (`ollama_code.USER_AGENT`) for provider
/// traffic and the model's browsing; this covers the requests the app makes
/// itself, which is Test Connection and the model catalogue.
///
/// Deliberately a constant rather than a setting: Moonshot's Kimi Code terms
/// require third-party tools to identify themselves honestly, and a header
/// that configuration could rewrite is the tampering those terms forbid.
enum LocusClientIdentity {
    static let bundleID = "io.sparktales.locus"

    /// Pure, so the test does not depend on which bundle is hosting it.
    static func userAgent(version: String) -> String {
        "Locus/\(version) (macOS; \(bundleID))"
    }

    static let value = userAgent(
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    )

    /// Sets the identity on a request. Separate from `authHeaders` on purpose:
    /// this must travel even when there is no key to send.
    static func apply(to request: inout URLRequest) {
        request.setValue(value, forHTTPHeaderField: "User-Agent")
    }
}

/// Verifies a remote OpenAI-compatible endpoint straight from the app, so
/// "Test Connection" in Settings has no side effects: it must not commit the
/// unsaved draft, write the credential file, or switch the live agent's provider.
enum RemoteEndpointTester {
    struct Outcome {
        let ok: Bool
        let message: String
    }

    /// Proxy-aware: rebuilt when the proxy settings change, so Test
    /// Connection exercises the same route real traffic will take.
    private static let noRedirectSession = ProxyAwareSession(
        scope: .modelAndAgent,
        configuration: { .ephemeral },
        delegate: { NoRedirectSessionDelegate() }
    )

    /// Mirrors the backend's `normalize_base_url`: people paste endpoints
    /// with or without `/v1`, with a trailing slash, or with the full
    /// `/v1/chat/completions` path — accept all of them.
    static func normalizeBaseURL(_ url: String) -> String {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return "" }
        if !base.contains("://") { base = defaultScheme(for: base) + "://" + base }
        for suffix in ["/chat/completions", "/completions", "/messages"]
        where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return base
    }

    /// The scheme to assume when someone types a bare `host:port`.
    ///
    /// `https` is the only safe guess for a name on the public internet, but
    /// for localhost, mDNS names, and private-network IP literals it is almost
    /// always wrong: local OpenAI-compatible servers (llama.cpp, LM Studio,
    /// vLLM, Ollama) speak plain HTTP, and TLS certificates are rarely issued
    /// for bare IPs. Guessing `https` there turns `ip:port/v1` into an opaque
    /// SSL failure that never says the URL was rewritten. Public addresses
    /// keep the `https` default: only hosts that cannot be on the public
    /// internet earn the `http` guess. Mirrors the backend's
    /// `_default_scheme` — the saved endpoint travels to the agent as typed,
    /// so the two guesses must never disagree.
    private static func defaultScheme(for schemelessInput: String) -> String {
        // The two parsers only agree on a plain-ASCII, percent-free
        // authority. `URL.host` percent-decodes and applies IDNA/UTS-46
        // mapping — so "192%2E168%2E1%2E50" and a CJK IME's full-width
        // "192。168。1。50" both become a dotted quad here while Python's
        // urlsplit leaves them alone. Refuse to guess rather than let the
        // app and the agent build different URLs from the same string.
        //
        // Taken by scalar, not by Character: `"/" + U+0301` is a single
        // grapheme cluster, so a Character-wise scan would run past the slash
        // and test a different string than Python's `split("/", 1)`.
        let authority = schemelessInput.unicodeScalars.prefix { $0 != "/" }
        guard authority.allSatisfy({ $0.isASCII }),
              !authority.contains("%"),
              let host = URL(string: "http://" + schemelessInput)?.host?.lowercased(),
              !host.isEmpty
        else { return "https" }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return "http"
        }
        // A colon can only reach a percent-free host inside a bracketed IPv6
        // literal, and a local server is the only plausible reason to type one.
        if host.contains(":") { return "http" }
        guard let octets = strictIPv4Octets(host) else { return "https" }
        let isPrivate = octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
        return isPrivate ? "http" : "https"
    }

    /// The octets of a canonical dotted-quad IPv4 literal, or nil. Strict on
    /// purpose, to match Python's `ipaddress` (CVE-2021-29921 hardening): four
    /// parts, ASCII digits only, no signs, no leading zeros — so
    /// "192.168.001.050" is a hostname here on both sides, never an address.
    private static func strictIPv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ ("0"..."9").contains($0) }),
                  part == "0" || !part.hasPrefix("0"),
                  let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func securityError(baseURL: String, apiKey: String) -> String? {
        let base = normalizeBaseURL(baseURL)
        guard let url = URL(string: base),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return "The endpoint must be a valid HTTP or HTTPS URL."
        }
        if url.user != nil || url.password != nil {
            return "Put credentials in the API key field, not in the endpoint URL."
        }
        if url.query != nil || url.fragment != nil {
            return "The endpoint URL cannot contain a query or fragment."
        }
        guard !apiKey.isEmpty, scheme != "https" else { return nil }
        let isLoopback = host == "localhost"
            || host == "::1"
            || isIPv4Loopback(host)
        return isLoopback ? nil : "API keys require HTTPS unless the endpoint is on this Mac."
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.first == "127",
              octets.allSatisfy({ UInt8($0) != nil })
        else { return false }
        return true
    }

    /// The auth headers each provider's native API expects.
    static func authHeaders(apiKey: String, kind: ProviderKind) -> [String: String] {
        guard !apiKey.isEmpty else { return [:] }
        if kind.authStyle == "anthropic" {
            return [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    static func test(
        baseURL: String,
        model: String,
        apiKey: String,
        kind: ProviderKind = .custom
    ) async -> Outcome {
        let base = normalizeBaseURL(baseURL)
        if let error = securityError(baseURL: base, apiKey: apiKey) {
            return Outcome(ok: false, message: error)
        }
        guard !base.isEmpty, let modelsURL = URL(string: base + "/models") else {
            return Outcome(ok: false, message: "That endpoint URL is not valid.")
        }
        // A provider that does not serve a listing would answer this probe with
        // an auth error, which reads as a bad key. Go straight to the one thing
        // that actually proves the key works.
        guard kind.listsModels else {
            return await chatProbe(base: base, model: model, apiKey: apiKey, kind: kind)
        }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 15
        LocusClientIdentity.apply(to: &request)
        for (field, value) in authHeaders(apiKey: apiKey, kind: kind) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await noRedirectSession.current.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                return Outcome(ok: true, message: "Connected — \(base) answered.")
            }
            // Endpoints that serve exactly one model often reject /models;
            // a one-token chat probe is the authoritative check there.
            if status == 404 || status == 405 {
                return await chatProbe(
                    base: base,
                    model: model.isEmpty ? kind.probeModel : model,
                    apiKey: apiKey,
                    kind: kind
                )
            }
            return Outcome(
                ok: false,
                message: failureMessage(status: status, data: data, apiKey: apiKey)
            )
        } catch {
            return Outcome(ok: false, message: error.localizedDescription)
        }
    }

    private static func chatProbe(
        base: String,
        model: String,
        apiKey: String,
        kind: ProviderKind
    ) async -> Outcome {
        let path = kind.authStyle == "anthropic" ? "/messages" : "/chat/completions"
        guard let url = URL(string: base + path) else {
            return Outcome(ok: false, message: "That endpoint URL is not valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        LocusClientIdentity.apply(to: &request)
        for (field, value) in authHeaders(apiKey: apiKey, kind: kind) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await noRedirectSession.current.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                return Outcome(
                    ok: false,
                    message: failureMessage(status: status, data: data, apiKey: apiKey)
                )
            }
            return Outcome(ok: true, message: "Connected — \(base) answered a chat probe.")
        } catch {
            return Outcome(ok: false, message: error.localizedDescription)
        }
    }

    /// Shared by Test Connection and the background account catalogue so both
    /// surfaces preserve a provider's useful explanation (for example, a vLLM
    /// host saying the endpoint is paused) instead of reducing every failure to
    /// an apparent credential problem.
    static func failureMessage(status: Int, data: Data, apiKey: String) -> String {
        var body = errorDetail(from: data)
        if !apiKey.isEmpty {
            body = body.replacingOccurrences(of: apiKey, with: "[redacted]")
        }
        let hint = switch status {
        // "Rejected the key" would be a riddle when none was sent.
        case 401, 403: apiKey.isEmpty
            ? "The endpoint requires an API key"
            : "The endpoint rejected the API key"
        case 400: "The endpoint rejected the request (400)"
        case 404: "Nothing answered at that path"
        case 429: "The endpoint is rate-limiting requests (429)"
        case 503: "The endpoint is not ready yet (503)"
        default: "The endpoint answered \(status)"
        }
        return body.isEmpty ? "\(hint)." : "\(hint): \(body)"
    }

    private static func errorDetail(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty
            {
                return message
            }
            for key in ["error", "message", "detail"] {
                if let message = root[key] as? String, !message.isEmpty {
                    return message
                }
            }
        }
        return String(data: data.prefix(300), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
