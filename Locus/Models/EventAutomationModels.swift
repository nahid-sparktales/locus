import Foundation

enum ConnectorKind: String, CaseIterable, Codable, Identifiable {
    case gmail
    case telegram
    case webhook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .telegram: "Telegram"
        case .webhook: "Signed Webhook"
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope"
        case .telegram: "paperplane"
        case .webhook: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct ConnectorConnection: Identifiable, Codable, Hashable {
    let id: String
    var kind: ConnectorKind
    var displayName: String
    var publicConfig: [String: JSONValue]
    var cursor: [String: JSONValue]
    var enabled: Bool
    var health: String
    var lastError: String?
    var lastPolledAt: Double?
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, enabled, health, cursor
        case displayName = "display_name"
        case publicConfig = "public_config"
        case lastError = "last_error"
        case lastPolledAt = "last_polled_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct EventFilterPredicate: Codable, Hashable, Identifiable {
    enum Operation: String, CaseIterable, Codable, Identifiable {
        case exists
        case equals
        case contains
        var id: String { rawValue }
    }

    var id = UUID()
    var path = ""
    var operation: Operation = .equals
    var value = ""

    enum CodingKeys: String, CodingKey {
        case path, value
        case operation = "op"
    }
}

struct EventTriggerFilters: Codable, Hashable {
    var senders: [String] = []
    var recipients: [String] = []
    var labels: [String] = []
    var subjectContains: [String] = []
    var hasAttachments: Bool?
    var chatIDs: [String] = []
    var senderIDs: [String] = []
    var commandPrefixes: [String] = []
    var messageTypes: [String] = []
    var eventNames: [String] = []
    var predicates: [EventFilterPredicate] = []

    enum CodingKeys: String, CodingKey {
        case senders, recipients, labels, predicates
        case subjectContains = "subject_contains"
        case hasAttachments = "has_attachments"
        case chatIDs = "chat_ids"
        case senderIDs = "sender_ids"
        case commandPrefixes = "command_prefixes"
        case messageTypes = "message_types"
        case eventNames = "event_names"
    }
}

struct EventTrigger: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var connectionID: String
    var targetSessionID: String
    var instruction: String
    var mode: WorkMode
    var filters: EventTriggerFilters
    var actionConnectionIDs: [String]
    var enabled: Bool
    var createdAt: Double
    var updatedAt: Double
    var lastEventAt: Double?
    var lastRunID: String?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, instruction, mode, filters, enabled
        case connectionID = "connection_id"
        case targetSessionID = "target_session_id"
        case actionConnectionIDs = "action_connection_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastEventAt = "last_event_at"
        case lastRunID = "last_run_id"
        case lastError = "last_error"
    }
}

struct InboundEvent: Codable, Hashable {
    var source: ConnectorKind
    var sourceEventID: String
    var eventType: String
    var occurredAt: Double
    var actor: [String: JSONValue]
    var subject: String
    var text: String
    var recipients: [String]
    var labels: [String]
    var attachments: [[String: JSONValue]]
    var data: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case source, actor, subject, text, recipients, labels, attachments, data
        case sourceEventID = "source_event_id"
        case eventType = "event_type"
        case occurredAt = "occurred_at"
    }
}

struct EventTranscriptContext: Codable, Hashable {
    let triggerID: String
    let deliveryID: String
    let source: ConnectorKind
    let sourceEventID: String
    let instruction: String
    let event: InboundEvent

    enum CodingKeys: String, CodingKey {
        case source, instruction, event
        case triggerID = "trigger_id"
        case deliveryID = "delivery_id"
        case sourceEventID = "source_event_id"
    }
}

struct EventDelivery: Identifiable, Codable, Hashable {
    let id: String
    let triggerID: String
    let sourceEventID: String
    let source: ConnectorKind
    let receivedAt: Double
    let occurredAt: Double
    let event: InboundEvent
    let state: String
    let runState: String?
    let attempt: Int
    let sessionID: String?
    let runID: String?
    let error: String?
    let createdAt: Double
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, source, event, state, attempt, error
        case triggerID = "trigger_id"
        case sourceEventID = "source_event_id"
        case receivedAt = "received_at"
        case occurredAt = "occurred_at"
        case runState = "run_state"
        case sessionID = "session_id"
        case runID = "run_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct EventTriggerEditorDraft: Identifiable, Hashable {
    var id: String?
    var name = ""
    var connectionID = ""
    var targetSessionID = ""
    var instruction = ""
    var mode: WorkMode = .work
    var filters = EventTriggerFilters()
    var actionConnectionIDs: [String] = []
    var enabled = true

    init() {}

    init(trigger: EventTrigger) {
        id = trigger.id
        name = trigger.name
        connectionID = trigger.connectionID
        targetSessionID = trigger.targetSessionID
        instruction = trigger.instruction
        mode = trigger.mode
        filters = trigger.filters
        actionConnectionIDs = trigger.actionConnectionIDs
        enabled = trigger.enabled
    }
}

struct ConnectorConnectionsResponse: Codable {
    let connections: [ConnectorConnection]
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case connections
        case readOnly = "read_only"
    }
}

struct EventTriggersResponse: Codable {
    let triggers: [EventTrigger]
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case triggers
        case readOnly = "read_only"
    }
}

struct EventDeliveriesResponse: Codable { let deliveries: [EventDelivery] }
struct EventIngestResponse: Codable { let ok: Bool; let deliveries: [EventDelivery] }
struct EventDispatchResponse: Codable {
    let ok: Bool
    let delivery: EventDelivery
    let run: OrchestrationRun
}

struct ConnectorActionReceipt: Codable {
    let idempotencyKey: String
    let eventDeliveryID: String?
    let toolName: String
    let result: [String: JSONValue]
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case result
        case idempotencyKey = "idempotency_key"
        case eventDeliveryID = "event_delivery_id"
        case toolName = "tool_name"
        case createdAt = "created_at"
    }
}

struct DeleteEventAutomationResponse: Codable { let ok: Bool; let id: String }
