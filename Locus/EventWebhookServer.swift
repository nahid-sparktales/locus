import CryptoKit
import Foundation
import Network

@MainActor
final class EventWebhookServer {
    static let defaultPort: UInt16 = 8789
    static let maximumBodyBytes = 256 * 1_024

    typealias Ingest = (String, InboundEvent) async throws -> Void

    private let credentials: ConnectorCredentialStore
    private var listeners: [String: NWListener] = [:]
    private var connections: [String: ConnectorConnection] = [:]
    private var replayIDs: [String: [String]] = [:]
    private var ingest: Ingest?

    init(credentials: ConnectorCredentialStore = .shared) {
        self.credentials = credentials
    }

    func configure(connections: [ConnectorConnection], ingest: @escaping Ingest) throws {
        let webhookConnections = connections.filter { $0.kind == .webhook && $0.enabled }
        self.connections = Dictionary(uniqueKeysWithValues: webhookConnections.map { ($0.id, $0) })
        self.ingest = ingest
        replayIDs = Dictionary(uniqueKeysWithValues: webhookConnections.map { connection in
            (connection.id, connection.cursor["recent_event_ids"]?.strings ?? [])
        })
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
        var bindingByPort: [Int: Bool] = [:]
        for connection in webhookConnections {
            let port = connection.publicConfig["listen_port"]?.integer ?? Int(Self.defaultPort)
            let allowLAN = connection.publicConfig["allow_lan"]?.boolean ?? false
            if let existing = bindingByPort[port], existing != allowLAN {
                throw EventConnectorClientError.invalidResponse(
                    "Webhook connections sharing a port must use the same LAN setting."
                )
            }
            bindingByPort[port] = allowLAN
        }
        let grouped = Dictionary(grouping: webhookConnections) { connection in
            let port = connection.publicConfig["listen_port"]?.integer ?? Int(Self.defaultPort)
            let allowLAN = connection.publicConfig["allow_lan"]?.boolean ?? false
            return "\(port):\(allowLAN)"
        }
        for (key, group) in grouped {
            guard let first = group.first else { continue }
            let portValue = first.publicConfig["listen_port"]?.integer ?? Int(Self.defaultPort)
            guard (1...65_535).contains(portValue),
                  let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
                throw EventConnectorClientError.invalidResponse("The webhook listener port is invalid.")
            }
            let allowLAN = first.publicConfig["allow_lan"]?.boolean ?? false
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(allowLAN ? "0.0.0.0" : "127.0.0.1"),
                port: port
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { _ in }
            listener.start(queue: DispatchQueue(label: "io.sparktales.locus.webhooks.\(key)"))
            listeners[key] = listener
        }
    }

    func stop() {
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
        connections = [:]
        replayIDs = [:]
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "io.sparktales.locus.webhook-request"))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1_024) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var next = buffer
                if let data { next.append(data) }
                if next.count > Self.maximumBodyBytes + 16 * 1_024 {
                    self.respond(connection, status: 413, message: "Payload Too Large")
                    return
                }
                if let request = Self.completeRequest(next) {
                    await self.handle(request, on: connection)
                } else if complete || error != nil {
                    self.respond(connection, status: 400, message: "Bad Request")
                } else {
                    self.receive(connection, buffer: next)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        guard request.method == "POST",
              request.path.hasPrefix("/hooks/v1/") else {
            respond(connection, status: 404, message: "Not Found")
            return
        }
        let connectionID = String(request.path.dropFirst("/hooks/v1/".count))
        guard let configured = connections[connectionID] else {
            respond(connection, status: 404, message: "Not Found")
            return
        }
        guard request.body.count <= Self.maximumBodyBytes else {
            respond(connection, status: 413, message: "Payload Too Large")
            return
        }
        guard let eventID = request.headers["x-locus-event-id"], Self.validIdentifier(eventID),
              let timestamp = request.headers["x-locus-timestamp"],
              let signature = request.headers["x-locus-signature"],
              replayIDs[connectionID]?.contains(eventID) != true,
              let secret = try? credentials.load(for: connectionID)?["hmac_secret"],
              !secret.isEmpty,
              Self.verify(secret: secret, timestamp: timestamp, signature: signature, body: request.body)
        else {
            respond(connection, status: 401, message: "Unauthorized")
            return
        }
        guard let raw = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let eventName = raw["event"] as? String, !eventName.isEmpty,
              let data = Self.jsonValues(raw["data"] as? [String: Any] ?? raw) else {
            respond(connection, status: 422, message: "Invalid Event")
            return
        }
        let event = InboundEvent(
            source: .webhook,
            sourceEventID: eventID,
            eventType: String(eventName.prefix(120)),
            occurredAt: Double(timestamp) ?? Date().timeIntervalSince1970,
            actor: [:],
            subject: String((raw["subject"] as? String ?? eventName).prefix(4_000)),
            text: String((raw["text"] as? String ?? "").prefix(120_000)),
            recipients: [], labels: [], attachments: [], data: data
        )
        do {
            try await ingest?(configured.id, event)
            var remembered = replayIDs[connectionID] ?? []
            remembered.removeAll { $0 == eventID }
            remembered.insert(eventID, at: 0)
            replayIDs[connectionID] = Array(remembered.prefix(1_000))
            respond(connection, status: 202, message: "Accepted")
        } catch let error as NSError where error.domain == "Locus.Backend" && error.code == 429 {
            respond(connection, status: 429, message: "Queue Full", retryAfter: 30)
        } catch {
            respond(connection, status: 503, message: "Unavailable", retryAfter: 30)
        }
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        message: String,
        retryAfter: Int? = nil
    ) {
        var headers = [
            "HTTP/1.1 \(status) \(message)",
            "Content-Length: 0",
            "Connection: close",
        ]
        if let retryAfter { headers.append("Retry-After: \(retryAfter)") }
        let data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func completeRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = headers["content-length"].flatMap(Int.init),
              length >= 0, length <= maximumBodyBytes else { return nil }
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return HTTPRequest(
            method: String(first[0]), path: String(first[1]), headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        )
    }

    nonisolated static func verify(
        secret: String,
        timestamp: String,
        signature: String,
        body: Data,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let sentAt = Double(timestamp), sentAt.isFinite,
              abs(now - sentAt) <= 300 else { return false }
        let supplied = signature.hasPrefix("v1=") ? String(signature.dropFirst(3)) : signature
        guard supplied.count == 64, let suppliedData = Data(hex: supplied) else { return false }
        let key = SymmetricKey(data: Data(secret.utf8))
        let payload = Data(timestamp.utf8) + Data(".".utf8) + body
        let expected = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        return expected == suppliedData
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$"#, options: .regularExpression) != nil
    }

    private static func jsonValues(_ value: [String: Any]) -> [String: JSONValue]? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return decoded
    }
}

private extension JSONValue {
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.string)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
