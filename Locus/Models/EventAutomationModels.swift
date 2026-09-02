import Foundation

enum ConnectorKind: String, CaseIterable, Codable, Identifiable {
    case gmail
    case telegram
    case webhook
    case priceFeed = "price_feed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .telegram: "Telegram"
        case .webhook: "Signed Webhook"
        case .priceFeed: "Price Source"
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope"
        case .telegram: "paperplane"
        case .webhook: "point.3.connected.trianglepath.dotted"
        case .priceFeed: "chart.line.uptrend.xyaxis"
        }
    }
}

enum EventTriggerKind: String, CaseIterable, Codable, Identifiable {
    case event
    case price
    var id: String { rawValue }
    var title: String { self == .price ? "Price Alert" : "Incoming Event" }
}

enum PriceComparison: String, CaseIterable, Codable, Identifiable {
    case crossesAbove = "crosses_above"
    case crossesBelow = "crosses_below"
    var id: String { rawValue }
    var title: String { self == .crossesAbove ? "Crosses above" : "Crosses below" }
}

enum PriceLifecycle: String, CaseIterable, Codable, Identifiable {
    case once
    case rearm
    case `repeat`
    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: "Fire once"
        case .rearm: "Fire on every recross"
        case .repeat: "Repeat while true"
        }
    }
}

struct PriceCondition: Codable, Hashable {
    var providerSymbol = ""
    var displaySymbol = ""
    var assetClass = "crypto"
    var quoteCurrency = "USD"
    var comparison: PriceComparison = .crossesAbove
    var threshold = ""
    var lifecycle: PriceLifecycle = .once
    var repeatIntervalSeconds = 900

    enum CodingKeys: String, CodingKey {
        case comparison, threshold, lifecycle
        case providerSymbol = "provider_symbol"
        case displaySymbol = "display_symbol"
        case assetClass = "asset_class"
        case quoteCurrency = "quote_currency"
        case repeatIntervalSeconds = "repeat_interval_seconds"
    }

    var thresholdDecimal: Decimal? {
        Decimal(string: threshold, locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct PriceTriggerState: Codable, Hashable {
    var lastPrice: String?
    var lastQuoteAt: Double?
    var lastSide: String?
    var lastFiredAt: Double?
    var fired: Bool?
    var oneShotDeliveryID: String?

    enum CodingKeys: String, CodingKey {
        case fired
        case lastPrice = "last_price"
        case lastQuoteAt = "last_quote_at"
        case lastSide = "last_side"
        case lastFiredAt = "last_fired_at"
        case oneShotDeliveryID = "one_shot_delivery_id"
    }
}

struct PriceFeedSecretField: Codable, Hashable, Identifiable {
    enum Placement: String, CaseIterable, Codable, Identifiable {
        case header
        case query
        var id: String { rawValue }
    }

    var id: String { key }
    var key = ""
    var placement: Placement = .header
}

struct PriceFeedConfiguration: Codable, Hashable {
    var endpointTemplate = ""
    var priceJSONPath = ""
    var timestampJSONPath = ""
    var pollIntervalSeconds = 60
    var maxQuoteAgeSeconds = 300
    var allowLocalNetwork = false
    var secretFields: [PriceFeedSecretField] = []

    enum CodingKeys: String, CodingKey {
        case endpointTemplate = "endpoint_template"
        case priceJSONPath = "price_json_path"
        case timestampJSONPath = "timestamp_json_path"
        case pollIntervalSeconds = "poll_interval_seconds"
        case maxQuoteAgeSeconds = "max_quote_age_seconds"
        case allowLocalNetwork = "allow_local_network"
        case secretFields = "secret_fields"
    }
}

struct MarketQuote: Codable, Hashable {
    var providerSymbol: String
    var displaySymbol: String
    var assetClass: String
    var price: String
    var quoteCurrency: String
    var venue: String
    var providerTimestamp: Double?

    enum CodingKeys: String, CodingKey {
        case price, venue
        case providerSymbol = "provider_symbol"
        case displaySymbol = "display_symbol"
        case assetClass = "asset_class"
        case quoteCurrency = "quote_currency"
        case providerTimestamp = "provider_timestamp"
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
    var priceCondition: PriceCondition?

    enum CodingKeys: String, CodingKey {
        case senders, recipients, labels, predicates
        case subjectContains = "subject_contains"
        case hasAttachments = "has_attachments"
        case chatIDs = "chat_ids"
        case senderIDs = "sender_ids"
        case commandPrefixes = "command_prefixes"
        case messageTypes = "message_types"
        case eventNames = "event_names"
        case priceCondition = "price_condition"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        senders = try container.decodeIfPresent([String].self, forKey: .senders) ?? []
        recipients = try container.decodeIfPresent([String].self, forKey: .recipients) ?? []
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        subjectContains = try container.decodeIfPresent(
            [String].self, forKey: .subjectContains
        ) ?? []
        hasAttachments = try container.decodeIfPresent(Bool.self, forKey: .hasAttachments)
        chatIDs = try container.decodeIfPresent([String].self, forKey: .chatIDs) ?? []
        senderIDs = try container.decodeIfPresent([String].self, forKey: .senderIDs) ?? []
        commandPrefixes = try container.decodeIfPresent(
            [String].self, forKey: .commandPrefixes
        ) ?? []
        messageTypes = try container.decodeIfPresent(
            [String].self, forKey: .messageTypes
        ) ?? []
        eventNames = try container.decodeIfPresent([String].self, forKey: .eventNames) ?? []
        predicates = try container.decodeIfPresent(
            [EventFilterPredicate].self, forKey: .predicates
        ) ?? []
        priceCondition = try container.decodeIfPresent(
            PriceCondition.self, forKey: .priceCondition
        )
    }
}

struct EventTrigger: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var connectionID: String
    var targetSessionID: String
    var instruction: String
    var mode: WorkMode
    var triggerKind: EventTriggerKind
    var filters: EventTriggerFilters
    var runtimeState: PriceTriggerState
    var actionConnectionIDs: [String]
    var enabled: Bool
    var createdAt: Double
    var updatedAt: Double
    var lastEventAt: Double?
    var lastRunID: String?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, instruction, mode, filters, enabled
        case triggerKind = "trigger_kind"
        case runtimeState = "runtime_state"
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
    static let dedicatedAgentChat = "__dedicated_agent_chat__"

    var id: String?
    var creationID = UUID().uuidString.lowercased()
    var name = ""
    var connectionID = ""
    var targetSessionID = ""
    var templateSessionID = ""
    var instruction = ""
    var mode: WorkMode = .work
    var triggerKind: EventTriggerKind = .event
    var filters = EventTriggerFilters()
    var actionConnectionIDs: [String] = []
    var enabled = true
    /// Set when the person asks an existing agent to move to the model the app
    /// is on now. Off by default: an ordinary edit keeps the agent's route.
    var adoptCurrentRoute = false

    init() {}

    init(trigger: EventTrigger) {
        id = trigger.id
        creationID = trigger.id
        name = trigger.name
        connectionID = trigger.connectionID
        targetSessionID = trigger.targetSessionID
        templateSessionID = trigger.targetSessionID
        instruction = trigger.instruction
        mode = trigger.mode
        triggerKind = trigger.triggerKind
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
