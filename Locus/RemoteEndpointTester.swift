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
        if !base.contains("://") { base = "https://" + base }
        for suffix in ["/chat/completions", "/completions", "/messages"]
        where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return base
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
        case 401, 403: "The endpoint rejected the API key"
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
