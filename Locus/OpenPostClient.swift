import Foundation

/// Native-only adapter. Tokens never enter plugin HTML, draft files, or chats.
/// Decline all redirects so credentials cannot move to a different endpoint.
final class OpenPostNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OpenPostClient {
    private static let liveSession = URLSession(configuration: .ephemeral, delegate: OpenPostNoRedirect(), delegateQueue: nil)
    let origin: URL
    let token: String
    let session: URLSession

    init(origin: String, token: String, session: URLSession? = nil) throws {
        self.origin = try Self.validatedOrigin(origin)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\n"), !token.contains("\r") else {
            throw SocialStudioError.message("Enter an OpenPost developer token.")
        }
        self.token = token
        self.session = session ?? Self.liveSession
    }

    static func validatedOrigin(_ raw: String) throws -> URL {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
            throw SocialStudioError.message("Enter an HTTPS origin, such as https://app.openpo.st. Localhost may use HTTP. Leave off /api/v1.")
        }
        components.path = ""
        guard let url = components.url else { throw SocialStudioError.message("The OpenPost address is invalid.") }
        return url
    }

    static func publicationBody(draft: SocialDraft, workspaceID: String, accounts: [OpenPostAccount]) throws -> Data {
        guard !draft.isEmpty else { throw SocialStudioError.message("Write a post before sending it to OpenPost.") }
        let renditions: [[String: Any]] = accounts.map { account in
            ["social_account_id": account.id, "body": account.channel.map { draft.text(for: $0) } ?? draft.text]
        }
        var body: [String: Any] = ["workspace_id": workspaceID, "title": draft.displayTitle,
                                   "content_profile": "short_text", "creation_preset": "post",
                                   "source_text": draft.text, "renditions": renditions]
        if let date = draft.plannedAt { body["scheduled_at"] = ISO8601DateFormatter().string(from: date) }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func request<T: Decodable>(_ path: [String], query: [URLQueryItem] = [], method: String = "GET",
                               body: Data? = nil, key: String? = nil, as: T.Type = T.self) async throws -> T {
        var url = origin.appendingPathComponent("api/v1")
        for component in path {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"), !component.contains("%") else {
                throw SocialStudioError.message("OpenPost returned an invalid resource identifier.")
            }
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SocialStudioError.message("OpenPost did not return an HTTP response.") }
        guard (200..<300).contains(response.statusCode) else {
            // Provider error bodies may include request or credential material.
            // Keep errors actionable without reflecting arbitrary server text.
            let detail: String
            switch response.statusCode {
            case 301...399: detail = "The server redirected the request. Check the instance's final HTTPS address."
            case 401: detail = "The token expired or is invalid. Reconnect in Accounts."
            case 403: detail = "This token cannot perform that action in this workspace. Check its read/write permissions."
            case 409: detail = "The publication changed. Refresh Activity and review it before trying again."
            case 422: detail = "OpenPost rejected the content or schedule. Review the publication in OpenPost."
            case 429: detail = "OpenPost is rate limiting requests. Try again later."
            default: detail = "OpenPost returned HTTP \(response.statusCode). Try again or check the instance."
            }
            throw SocialStudioError.message(detail)
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    func workspaces() async throws -> [OpenPostWorkspace] {
        try await request(["workspaces"], as: [OpenPostWorkspace]?.self) ?? []
    }
    func accounts(workspaceID: String) async throws -> [OpenPostAccount] {
        try await request(["accounts"], query: [.init(name: "workspace_id", value: workspaceID)], as: [OpenPostAccount]?.self) ?? []
    }
    func publications(workspaceID: String) async throws -> [OpenPostPublication] {
        try await request(["publications"], query: [.init(name: "workspace_id", value: workspaceID), .init(name: "limit", value: "100")],
                          as: [OpenPostPublication]?.self) ?? []
    }
}
