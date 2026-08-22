import Foundation

enum CompanionProtocolV1 {
    static let version = 1
    static let serviceType = "_locus-remote._tcp"
    static let maximumPayloadBytes = 256 * 1_024
    static let maximumConnections = 4
    static let pairingLifetime: TimeInterval = 5 * 60
    static let idempotencyLifetime: TimeInterval = 10 * 60
}

enum CompanionMethod: String, Codable, CaseIterable {
    case pairExchange = "pair.exchange"
    case statusGet = "status.get"
    case chatsList = "chats.list"
    case chatGet = "chat.get"
    case chatSend = "chat.send"
    case chatCreate = "chat.create"
    case activityList = "activity.list"
    case runStop = "run.stop"
    case approvalRespond = "approval.respond"
    case schedulesList = "schedules.list"
    case scheduleRunNow = "schedule.runNow"
    case scheduleSetEnabled = "schedule.setEnabled"
}

struct CompanionRequest: Codable, Hashable {
    var version: Int
    var id: String
    var method: CompanionMethod
    var token: String?
    var payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id, method, token, payload
        case version = "v"
    }

    init(
        version: Int = CompanionProtocolV1.version,
        id: String,
        method: CompanionMethod,
        token: String? = nil,
        payload: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.id = id
        self.method = method
        self.token = token
        self.payload = payload
    }
}

struct CompanionProtocolError: Codable, Hashable, Error {
    let code: String
    let message: String
    var retryable = false
}

struct CompanionResponse: Codable, Hashable {
    let version: Int
    let id: String
    let ok: Bool
    let data: JSONValue?
    let error: CompanionProtocolError?

    enum CodingKeys: String, CodingKey {
        case id, ok, data, error
        case version = "v"
    }

    static func success(id: String, data: JSONValue = .object([:])) -> Self {
        Self(version: CompanionProtocolV1.version, id: id, ok: true, data: data, error: nil)
    }

    static func failure(
        id: String,
        code: String,
        message: String,
        retryable: Bool = false
    ) -> Self {
        Self(
            version: CompanionProtocolV1.version,
            id: id,
            ok: false,
            data: nil,
            error: CompanionProtocolError(code: code, message: message, retryable: retryable)
        )
    }
}

struct CompanionEvent: Codable, Hashable {
    let version: Int
    let event: String
    let data: JSONValue
    let sequence: UInt64

    enum CodingKeys: String, CodingKey {
        case event, data, sequence
        case version = "v"
    }
}

struct CompanionPairingPayload: Codable, Hashable {
    let version: Int
    let serviceID: String
    let endpoints: [String]
    let certificateFingerprint: String
    let nonce: String
    let expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case endpoints, nonce
        case version = "v"
        case serviceID = "service_id"
        case certificateFingerprint = "certificate_fingerprint"
        case expiresAt = "expires_at"
    }
}

struct CompanionPairedDevice: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var platform: String
    let tokenHash: String
    let pairedAt: Double
    var lastSeenAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, platform
        case tokenHash = "token_hash"
        case pairedAt = "paired_at"
        case lastSeenAt = "last_seen_at"
    }

    var safeDescription: CompanionDeviceDescription {
        CompanionDeviceDescription(
            id: id, name: name, platform: platform,
            pairedAt: pairedAt, lastSeenAt: lastSeenAt
        )
    }
}

struct CompanionDeviceDescription: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let platform: String
    let pairedAt: Double
    let lastSeenAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, platform
        case pairedAt = "paired_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct CompanionGatewayState: Hashable {
    var enabled = false
    var running = false
    var status = "Mobile Access is off"
    var port: UInt16?
    var serviceID = ""
    var certificateFingerprint = ""
    var endpoints: [String] = []
    var activeConnections = 0
    var pairedDevices: [CompanionDeviceDescription] = []

    static let disabled = CompanionGatewayState()
}

enum CompanionPayload {
    static func object(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
    static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    static func string(_ key: String, in payload: [String: JSONValue]) -> String? {
        payload[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bool(_ key: String, in payload: [String: JSONValue]) -> Bool? {
        payload[key]?.boolean
    }
}

/// Defense in depth for every event and response leaving the Mac. Product
/// adapters should build a narrow DTO first; this final pass strips dangerous
/// keys and bounds strings if a future adapter accidentally includes more.
enum CompanionEventSanitizer {
    private static let blockedFragments = [
        "credential", "password", "secret", "token", "api_key", "apikey",
        "environment_variables", "system_prompt", "hidden", "raw_tool", "tool_result",
    ]
    private static let maximumStringLength = 120_000

    static func sanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.compactMap { key, value in
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                guard !blockedFragments.contains(where: normalized.contains) else { return nil }
                return (key, sanitize(value))
            }))
        case .array(let array):
            return .array(array.prefix(1_000).map(sanitize))
        case .string(let string):
            return .string(String(string.prefix(maximumStringLength)))
        case .number, .bool, .null:
            return value
        }
    }
}

struct CompanionIdempotencyCache {
    private var values: [String: (expiresAt: Date, response: CompanionResponse)] = [:]
    let lifetime: TimeInterval
    let limit: Int

    init(
        lifetime: TimeInterval = CompanionProtocolV1.idempotencyLifetime,
        limit: Int = 512
    ) {
        self.lifetime = lifetime
        self.limit = limit
    }

    mutating func response(for id: String, now: Date = Date()) -> CompanionResponse? {
        prune(now: now)
        return values[id]?.response
    }

    mutating func insert(_ response: CompanionResponse, now: Date = Date()) {
        prune(now: now)
        if values.count >= limit, let oldest = values.min(by: {
            $0.value.expiresAt < $1.value.expiresAt
        })?.key {
            values.removeValue(forKey: oldest)
        }
        values[response.id] = (now.addingTimeInterval(lifetime), response)
    }

    mutating func prune(now: Date = Date()) {
        values = values.filter { $0.value.expiresAt > now }
    }
}

struct CompanionRateLimiter {
    private var requests: [String: [Date]] = [:]
    let maximumRequests: Int
    let window: TimeInterval

    init(maximumRequests: Int = 90, window: TimeInterval = 60) {
        self.maximumRequests = maximumRequests
        self.window = window
    }

    mutating func allows(_ deviceID: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = (requests[deviceID] ?? []).filter { $0 > cutoff }
        guard recent.count < maximumRequests else {
            requests[deviceID] = recent
            return false
        }
        recent.append(now)
        requests[deviceID] = recent
        return true
    }
}
