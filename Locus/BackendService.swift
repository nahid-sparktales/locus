import Foundation

enum BackendSecurity {
    /// Browser pages cannot discover or set this per-launch capability.
    static let launchToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static let header = "X-Locus-Token"
}

/// REST + WebSocket client for the local agent. All mutable connection state
/// is confined to the main actor; URLSession callbacks hop back before
/// touching it, so connect/receive/heartbeat/reconnect can never race.
@MainActor
final class BackendService {
    typealias EventHandler = ([String: Any]) -> Void
    typealias ConnectionHandler = (Bool) -> Void

    /// Pinned direct, over every proxy layer including the system's: the
    /// agent is a loopback child of this process, and no proxy configuration
    /// — however wrong — may ever sit between the app and it.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
    private var socket: URLSessionWebSocketTask?
    private var baseURL: URL
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var intentionallyClosed = false
    private var validatedConnection = false
    private var reconnectAttempt = 0
    private let authToken: String

    var onEvent: EventHandler?
    var onConnectionChange: ConnectionHandler?
    var currentBaseURL: URL { baseURL }

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8791")!,
        authToken: String = BackendSecurity.launchToken
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
    }

    func updateBaseURL(_ url: URL) {
        disconnect()
        baseURL = url
    }

    func connect() {
        intentionallyClosed = false
        reconnectTask?.cancel()
        reconnectTask = nil
        guard socket == nil else { return }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/ws/chat"
        guard let socketURL = components?.url else { return }

        validatedConnection = false
        var request = URLRequest(url: socketURL)
        request.setValue(authToken, forHTTPHeaderField: BackendSecurity.header)
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(from: task)
        startHeartbeat(for: task)
    }

    func disconnect() {
        intentionallyClosed = true
        reconnectTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask = nil
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        validatedConnection = false
        onConnectionChange?(false)
    }

    @discardableResult
    func send(_ payload: [String: Any]) -> Bool {
        guard validatedConnection,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8),
              let socket
        else { return false }
        socket.send(.string(string)) { [weak self, weak socket] error in
            guard error != nil, let socket else { return }
            Task { @MainActor in
                self?.handleDisconnect(socket)
            }
        }
        return true
    }

    func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        let url = try endpointURL(path, query: query)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue(authToken, forHTTPHeaderField: BackendSecurity.header)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    func post<T: Decodable>(
        _ path: String,
        body: [String: Any],
        timeout: TimeInterval = 10,
        as type: T.Type
    ) async throws -> T {
        try await request(path, method: "POST", body: body, timeout: timeout, as: type)
    }

    func patch<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        try await request(path, method: "PATCH", body: body, timeout: 10, as: type)
    }

    func delete<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await request(path, method: "DELETE", body: nil, timeout: 10, as: type)
    }

    nonisolated static func reconnectDelay(for attempt: Int) -> TimeInterval {
        let delays: [TimeInterval] = [1, 2, 4, 8, 15]
        return delays[min(max(attempt, 0), delays.count - 1)]
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        body: [String: Any]?,
        timeout: TimeInterval,
        as type: T.Type
    ) async throws -> T {
        let url = try endpointURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(authToken, forHTTPHeaderField: BackendSecurity.header)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    private func receive(from task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.socket === task else { return }
                switch result {
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let string): data = string.data(using: .utf8)
                    case .data(let received): data = received
                    @unknown default: data = nil
                    }
                    if let data,
                       let object = try? JSONSerialization.jsonObject(with: data),
                       let event = object as? [String: Any]
                    {
                        if !self.validatedConnection {
                            self.validatedConnection = true
                            self.reconnectAttempt = 0
                            self.onConnectionChange?(true)
                        }
                        self.onEvent?(event)
                    }
                    self.receive(from: task)
                case .failure:
                    self.handleDisconnect(task)
                }
            }
        }
    }

    private func startHeartbeat(for task: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, let task, self.socket === task else { return }
                let succeeded = await withCheckedContinuation { continuation in
                    task.sendPing { error in
                        continuation.resume(returning: error == nil)
                    }
                }
                if !succeeded {
                    self.handleDisconnect(task)
                    return
                }
            }
        }
    }

    private func handleDisconnect(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        task.cancel(with: .goingAway, reason: nil)
        socket = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        validatedConnection = false
        onConnectionChange?(false)
        guard !intentionallyClosed else { return }

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reconnectDelay(for: attempt)))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "Locus.Backend",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: Self.backendMessage(from: data)]
            )
        }
    }

    /// The agent reports failures as FastAPI does — `{"detail": "…"}` for a
    /// raised error, `{"detail": [{"msg": "…"}, …]}` for request validation.
    /// Surfacing the body verbatim put the braces in front of the user, so the
    /// carefully worded messages the agent sends arrived as machine output.
    nonisolated static func backendMessage(from data: Data) -> String {
        let fallback = String(data: data, encoding: .utf8) ?? ""
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let body = object as? [String: Any],
              let detail = body["detail"]
        else { return fallback.isEmpty ? "Unknown backend error" : fallback }

        if let message = detail as? String {
            return message.isEmpty ? fallback : message
        }
        if let items = detail as? [[String: Any]] {
            let messages = items.compactMap { $0["msg"] as? String }
            if !messages.isEmpty { return messages.joined(separator: "\n") }
        }
        return fallback.isEmpty ? "Unknown backend error" : fallback
    }

    /// Characters allowed unescaped in a query value. `urlQueryAllowed` alone
    /// would pass `&`, `+`, `=` and `?` through, and Starlette decodes a bare
    /// `+` as a space — either corrupts file paths like `a&b.swift`.
    nonisolated static let querySafeCharacters = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "+&=?"))

    nonisolated static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: querySafeCharacters) ?? value
    }

    private func endpointURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pieces = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard var components = URLComponents(
            url: baseURL.appending(path: String(pieces[0])),
            resolvingAgainstBaseURL: false
        ) else { throw URLError(.badURL) }
        if pieces.count == 2 {
            components.percentEncodedQuery = String(pieces[1])
        }
        if !query.isEmpty {
            components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
                + query.map {
                    URLQueryItem(
                        name: Self.encodeQueryValue($0.name),
                        value: $0.value.map(Self.encodeQueryValue)
                    )
                }
        }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}
