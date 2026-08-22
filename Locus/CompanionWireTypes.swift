// Shared companion wire surface.
//
// This file is vendored byte-for-byte by the Locus iOS companion client, so the
// two ends of the mobile protocol decode the same bytes with the same code. Edit
// it only as a deliberate protocol change, and re-vendor downstream in the same
// change. Keep it Foundation-only and free of any AppKit or gateway dependency.
//
// Gateway-only machinery — the event sanitizer, rate limiter, idempotency cache
// and paired-device records — deliberately stays in CompanionProtocol.swift.

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
