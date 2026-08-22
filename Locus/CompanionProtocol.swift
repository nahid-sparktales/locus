import Foundation

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
