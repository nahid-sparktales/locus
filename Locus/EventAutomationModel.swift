import Combine
import CryptoKit
import Foundation

struct WebhookSetup: Identifiable, Hashable {
    let id: String
    let endpoint: String
    let secret: String
}

@MainActor
final class EventAutomationModel: ObservableObject {
    @Published private(set) var connections: [ConnectorConnection] = []
    @Published private(set) var triggers: [EventTrigger] = []
    @Published private(set) var deliveries: [EventDelivery] = []
    @Published var editorDraft: EventTriggerEditorDraft?
    @Published var webhookSetup: WebhookSetup?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastError: String?

    private var backend: BackendService?
    private let credentials: ConnectorCredentialStore
    private let client: EventConnectorClient
    private let webhookServer: EventWebhookServer
    private let gmailOAuth = GmailOAuthCoordinator()
    private var connectorTasks: [String: Task<Void, Never>] = [:]
    private var dispatchTask: Task<Void, Never>?
    private var runtimeFingerprint = ""
    private var onQueuedRun: ((OrchestrationRun) async -> Void)?
    private var canDispatchToSession: ((String) -> Bool)?
    private var onCapabilityChanged: (() -> Void)?
    private var showMessage: ((String) -> Void)?

    init(credentials: ConnectorCredentialStore = .shared) {
        self.credentials = credentials
        client = EventConnectorClient(credentials: credentials)
        webhookServer = EventWebhookServer(credentials: credentials)
    }

    deinit {
        connectorTasks.values.forEach { $0.cancel() }
        dispatchTask?.cancel()
    }

    func configure(
        backend: BackendService,
        onQueuedRun: @escaping (OrchestrationRun) async -> Void,
        canDispatchToSession: @escaping (String) -> Bool,
        onCapabilityChanged: @escaping () -> Void,
        showMessage: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.onQueuedRun = onQueuedRun
        self.canDispatchToSession = canDispatchToSession
        self.onCapabilityChanged = onCapabilityChanged
        self.showMessage = showMessage
    }

    func start() {
        guard dispatchTask == nil else { return }
        dispatchTask = Task { [weak self] in
            guard let self else { return }
            await refresh(announceFailure: false)
            while !Task.isCancelled {
                await processPendingDeliveries()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        dispatchTask?.cancel()
        dispatchTask = nil
        connectorTasks.values.forEach { $0.cancel() }
        connectorTasks = [:]
        webhookServer.stop()
    }

    func refresh(announceFailure: Bool = true) async {
        guard let backend, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let connectionResponse = backend.get(
                "/api/connectors", as: ConnectorConnectionsResponse.self
            )
            async let triggerResponse = backend.get(
                "/api/event-triggers", as: EventTriggersResponse.self
            )
            async let deliveryResponse = backend.get(
                "/api/event-deliveries",
                query: [URLQueryItem(name: "limit", value: "200")],
                as: EventDeliveriesResponse.self
            )
            let (loadedConnections, loadedTriggers, loadedDeliveries) = try await (
                connectionResponse, triggerResponse, deliveryResponse
            )
            connections = loadedConnections.connections
            triggers = loadedTriggers.triggers
            deliveries = loadedDeliveries.deliveries
            lastError = nil
            restartNativeRuntimeIfNeeded()
            onCapabilityChanged?()
        } catch {
            lastError = error.localizedDescription
            if announceFailure { showMessage?("Could not load event automations: \(error.localizedDescription)") }
        }
    }

    func presentEditor(
        trigger: EventTrigger? = nil,
        targetSessionID: String,
        naturalLanguageRequest: String = ""
    ) {
        if let trigger {
            editorDraft = EventTriggerEditorDraft(trigger: trigger)
            return
        }
        var draft = EventTriggerEditorDraft()
        draft.targetSessionID = targetSessionID
        draft.instruction = naturalLanguageRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.name = Self.suggestedName(from: naturalLanguageRequest)
        if let connection = connections.first(where: { $0.enabled }) {
            draft.connectionID = connection.id
            draft.actionConnectionIDs = [connection.id]
            draft.filters = Self.suggestedFilters(
                from: naturalLanguageRequest, kind: connection.kind
            )
        }
        editorDraft = draft
    }

    func saveTrigger(_ draft: EventTriggerEditorDraft) async -> Bool {
        guard let backend else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !instruction.isEmpty, !draft.connectionID.isEmpty,
              !draft.targetSessionID.isEmpty else {
            showMessage?("Add a name, connection, target chat, and instruction.")
            return false
        }
        guard let filters = Self.encodedObject(draft.filters) else {
            showMessage?("The trigger filters could not be saved.")
            return false
        }
        let actions = draft.actionConnectionIDs.isEmpty
            ? [draft.connectionID] : draft.actionConnectionIDs
        let body: [String: Any] = [
            "name": name,
            "connection_id": draft.connectionID,
            "target_session_id": draft.targetSessionID,
            "instruction": instruction,
            "mode": draft.mode.rawValue,
            "filters": filters,
            "action_connection_ids": actions,
            "enabled": draft.enabled,
        ]
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: EventTrigger
            if let id = draft.id {
                saved = try await backend.patch(
                    "/api/event-triggers/\(id)", body: body, as: EventTrigger.self
                )
            } else {
                saved = try await backend.post(
                    "/api/event-triggers", body: body, as: EventTrigger.self
                )
            }
            replace(saved)
            editorDraft = nil
            showMessage?(draft.id == nil ? "Event trigger activated" : "Event trigger updated")
            return true
        } catch {
            showMessage?("Could not save event trigger: \(error.localizedDescription)")
            return false
        }
    }

    func setTrigger(_ trigger: EventTrigger, enabled: Bool) {
        Task { [weak self] in
            guard let self, let backend else { return }
            do {
                let updated: EventTrigger = try await backend.patch(
                    "/api/event-triggers/\(trigger.id)", body: ["enabled": enabled],
                    as: EventTrigger.self
                )
                replace(updated)
                showMessage?(enabled ? "Event trigger resumed" : "Event trigger paused")
            } catch {
                showMessage?("Could not update event trigger: \(error.localizedDescription)")
            }
        }
    }

    func deleteTrigger(_ trigger: EventTrigger) {
        Task { [weak self] in
            guard let self, let backend else { return }
            do {
                let _: DeleteEventAutomationResponse = try await backend.delete(
                    "/api/event-triggers/\(trigger.id)", as: DeleteEventAutomationResponse.self
                )
                triggers.removeAll { $0.id == trigger.id }
                showMessage?("Event trigger deleted; its run history was kept")
            } catch {
                showMessage?("Could not delete event trigger: \(error.localizedDescription)")
            }
        }
    }

    func retry(_ delivery: EventDelivery) {
        Task { [weak self] in
            guard let self, let backend else { return }
            do {
                let retried: EventDelivery = try await backend.post(
                    "/api/event-deliveries/\(delivery.id)/retry", body: [:],
                    as: EventDelivery.self
                )
                replace(retried)
            } catch {
                showMessage?("Could not retry this event: \(error.localizedDescription)")
            }
        }
    }

    func connectGmail(displayName: String) async {
        guard let backend else { return }
        do {
            let clientID = Bundle.main.object(forInfoDictionaryKey: "LocusGoogleOAuthClientID") as? String ?? ""
            let secret = try await gmailOAuth.authenticate(clientID: clientID)
            let identifier = "gmail-\(UUID().uuidString.lowercased())"
            try credentials.save(secret, for: identifier)
            do {
                let connection: ConnectorConnection = try await backend.post(
                    "/api/connectors", body: [
                        "id": identifier,
                        "kind": "gmail",
                        "display_name": displayName.nilIfBlank ?? "Gmail",
                        "public_config": ["scope": "gmail.modify"],
                        "cursor": [:],
                    ], as: ConnectorConnection.self
                )
                connections.append(connection)
                runtimeFingerprint = ""
                restartNativeRuntimeIfNeeded()
                onCapabilityChanged?()
                showMessage?("Gmail connected")
            } catch {
                try? credentials.delete(for: identifier)
                throw error
            }
        } catch {
            showMessage?("Could not connect Gmail: \(error.localizedDescription)")
        }
    }

    func connectTelegram(displayName: String, botToken: String) async {
        await createSecretConnection(
            kind: .telegram,
            displayName: displayName.nilIfBlank ?? "Telegram Bot",
            secret: ["bot_token": botToken.trimmingCharacters(in: .whitespacesAndNewlines)],
            publicConfig: [:]
        )
    }

    func createWebhook(
        displayName: String,
        port: Int,
        allowLAN: Bool,
        tunnelURL: String
    ) async {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let secret = Data(bytes).base64EncodedString()
        let identifier = "webhook-\(UUID().uuidString.lowercased())"
        guard let backend else { return }
        do {
            try credentials.save(["hmac_secret": secret], for: identifier)
            do {
                let publicConfig: [String: Any] = [
                    "listen_port": max(1, min(port, 65_535)),
                    "allow_lan": allowLAN,
                    "tunnel_url": tunnelURL.trimmingCharacters(in: .whitespacesAndNewlines),
                ]
                let connection: ConnectorConnection = try await backend.post(
                    "/api/connectors", body: [
                        "id": identifier,
                        "kind": "webhook",
                        "display_name": displayName.nilIfBlank ?? "Signed Webhook",
                        "public_config": publicConfig,
                        "cursor": ["recent_event_ids": []],
                    ], as: ConnectorConnection.self
                )
                connections.append(connection)
                let base = tunnelURL.nilIfBlank ?? "http://127.0.0.1:\(port)"
                webhookSetup = WebhookSetup(
                    id: identifier,
                    endpoint: base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        + "/hooks/v1/\(identifier)",
                    secret: secret
                )
                runtimeFingerprint = ""
                restartNativeRuntimeIfNeeded()
                showMessage?("Signed webhook created")
            } catch {
                try? credentials.delete(for: identifier)
                throw error
            }
        } catch {
            showMessage?("Could not create webhook: \(error.localizedDescription)")
        }
    }

    func deleteConnection(_ connection: ConnectorConnection) {
        Task { [weak self] in
            guard let self, let backend else { return }
            do {
                let _: DeleteEventAutomationResponse = try await backend.delete(
                    "/api/connectors/\(connection.id)", as: DeleteEventAutomationResponse.self
                )
                try? credentials.delete(for: connection.id)
                connections.removeAll { $0.id == connection.id }
                runtimeFingerprint = ""
                restartNativeRuntimeIfNeeded()
                onCapabilityChanged?()
            } catch {
                showMessage?("Could not delete connection: \(error.localizedDescription)")
            }
        }
    }

    func connectorCapability() -> [String: Any] {
        let available = connections.filter { connection in
            guard connection.enabled, connection.kind != .webhook else { return false }
            return (try? credentials.load(for: connection.id)) != nil
        }
        return [
            "protocol_version": 1,
            "connections": available.map { ["id": $0.id, "kind": $0.kind.rawValue] },
        ]
    }

    func transcriptContext(for run: OrchestrationRun) -> EventTranscriptContext? {
        guard let manifest = run.manifest,
              manifest["event_triggered"]?.boolean == true,
              let deliveryID = manifest["event_delivery_id"]?.string,
              let triggerID = manifest["event_trigger_id"]?.string,
              let delivery = deliveries.first(where: { $0.id == deliveryID }),
              let trigger = triggers.first(where: { $0.id == triggerID }) else { return nil }
        return EventTranscriptContext(
            triggerID: triggerID,
            deliveryID: deliveryID,
            source: delivery.source,
            sourceEventID: delivery.sourceEventID,
            instruction: trigger.instruction,
            event: delivery.event
        )
    }

    func handleAction(
        _ event: [String: Any],
        workspacePath: String,
        on service: BackendService
    ) {
        guard let requestID = event["request_id"] as? String,
              let tool = event["tool"] as? String,
              let arguments = event["arguments"] as? [String: Any] else { return }
        Task { [weak self] in
            guard let self else { return }
            let result: [String: Any]
            do {
                result = try await client.performAction(
                    tool: tool, arguments: arguments, workspacePath: workspacePath
                )
            } catch {
                result = ["error": error.localizedDescription]
            }
            // Persist the native result before handing it back over the
            // WebSocket. If that response is lost, the same tool-call key can
            // return this receipt without repeating an external side effect.
            if let encodedResult = Self.encodedDictionary(result) {
                let _: ConnectorActionReceipt? = try? await service.post(
                    "/api/connector-actions/receipts",
                    body: [
                        "idempotency_key": requestID,
                        "event_delivery_id": event["event_delivery_id"] as? String ?? "",
                        "tool_name": tool,
                        "result": encodedResult,
                    ],
                    as: ConnectorActionReceipt.self
                )
            }
            _ = service.send([
                "type": "connector_action_result",
                "request_id": requestID,
                "result": result,
            ])
        }
    }

    // MARK: Coordination

    private func createSecretConnection(
        kind: ConnectorKind,
        displayName: String,
        secret: [String: String],
        publicConfig: [String: Any]
    ) async {
        guard let backend, secret.values.allSatisfy({ !$0.isEmpty }) else {
            showMessage?("Add the connector credential first.")
            return
        }
        let identifier = "\(kind.rawValue)-\(UUID().uuidString.lowercased())"
        do {
            try credentials.save(secret, for: identifier)
            do {
                let connection: ConnectorConnection = try await backend.post(
                    "/api/connectors", body: [
                        "id": identifier, "kind": kind.rawValue,
                        "display_name": displayName, "public_config": publicConfig,
                        "cursor": [:],
                    ], as: ConnectorConnection.self
                )
                connections.append(connection)
                runtimeFingerprint = ""
                restartNativeRuntimeIfNeeded()
                onCapabilityChanged?()
                showMessage?("\(kind.title) connected")
            } catch {
                try? credentials.delete(for: identifier)
                throw error
            }
        } catch {
            showMessage?("Could not connect \(kind.title): \(error.localizedDescription)")
        }
    }

    private func restartNativeRuntimeIfNeeded() {
        let fingerprint = connections.map {
            "\($0.id):\($0.kind.rawValue):\($0.enabled):\($0.publicConfig.hashValue)"
        }.sorted().joined(separator: "|")
        guard fingerprint != runtimeFingerprint else { return }
        runtimeFingerprint = fingerprint
        connectorTasks.values.forEach { $0.cancel() }
        connectorTasks = [:]
        for connection in connections where connection.enabled && connection.kind != .webhook {
            connectorTasks[connection.id] = Task { [weak self] in
                await self?.pollLoop(connectionID: connection.id)
            }
        }
        do {
            try webhookServer.configure(connections: connections) { [weak self] connectionID, event in
                guard let self else { return }
                try await self.ingest(connectionID: connectionID, event: event)
                await self.rememberWebhookEvent(connectionID: connectionID, eventID: event.sourceEventID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pollLoop(connectionID: String) async {
        while !Task.isCancelled {
            guard let connection = connections.first(where: { $0.id == connectionID && $0.enabled })
            else { return }
            do {
                let result = try await client.poll(connection)
                for event in result.events {
                    try await ingest(connectionID: connectionID, event: event)
                }
                try await updateCursor(connectionID, cursor: result.cursor, health: "connected", error: "")
            } catch is CancellationError {
                return
            } catch {
                try? await updateCursor(
                    connectionID, cursor: connection.cursor,
                    health: "error", error: error.localizedDescription
                )
            }
            if connection.kind == .gmail {
                try? await Task.sleep(for: .seconds(30))
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func ingest(connectionID: String, event: InboundEvent) async throws {
        guard let backend, let encoded = Self.encodedObject(event) else {
            throw EventConnectorClientError.invalidResponse("The normalized event could not be encoded.")
        }
        let response: EventIngestResponse = try await backend.post(
            "/api/event-triggers/ingest",
            body: ["connection_id": connectionID, "event": encoded],
            timeout: 30,
            as: EventIngestResponse.self
        )
        for delivery in response.deliveries { replace(delivery) }
    }

    private func updateCursor(
        _ connectionID: String,
        cursor: [String: JSONValue],
        health: String,
        error: String
    ) async throws {
        guard let backend, let encoded = Self.encodedObject(cursor) else { return }
        let updated: ConnectorConnection = try await backend.patch(
            "/api/connectors/\(connectionID)/cursor",
            body: ["cursor": encoded, "health": health, "error": error],
            as: ConnectorConnection.self
        )
        if let index = connections.firstIndex(where: { $0.id == updated.id }) {
            connections[index] = updated
        }
    }

    private func rememberWebhookEvent(connectionID: String, eventID: String) async {
        guard let connection = connections.first(where: { $0.id == connectionID }) else { return }
        var recent = connection.cursor["recent_event_ids"]?.strings ?? []
        recent.removeAll { $0 == eventID }
        recent.insert(eventID, at: 0)
        recent = Array(recent.prefix(1_000))
        var cursor = connection.cursor
        cursor["recent_event_ids"] = .array(recent.map(JSONValue.string))
        try? await updateCursor(connectionID, cursor: cursor, health: "connected", error: "")
    }

    private func processPendingDeliveries() async {
        guard let backend else { return }
        do {
            let response: EventDeliveriesResponse = try await backend.get(
                "/api/event-deliveries/pending",
                query: [URLQueryItem(name: "limit", value: "50")],
                as: EventDeliveriesResponse.self
            )
            for pending in response.deliveries {
                guard let targetSessionID = triggers.first(where: {
                    $0.id == pending.triggerID
                })?.targetSessionID,
                      canDispatchToSession?(targetSessionID) != false else { continue }
                do {
                    let dispatched: EventDispatchResponse = try await backend.post(
                        "/api/event-deliveries/\(pending.id)/dispatch", body: [:],
                        timeout: 30, as: EventDispatchResponse.self
                    )
                    replace(dispatched.delivery)
                    await onQueuedRun?(dispatched.run)
                } catch let error as NSError where error.domain == "Locus.Backend"
                    && error.code == 409 {
                    continue
                } catch {
                    // Dispatch failures are durable delivery state. A refresh
                    // exposes the explicit Retry control without rerunning work.
                    continue
                }
            }
            if !response.deliveries.isEmpty { await refresh(announceFailure: false) }
        } catch {
            // Local backend recovery owns connectivity notifications.
        }
    }

    private func replace(_ trigger: EventTrigger) {
        triggers.removeAll { $0.id == trigger.id }
        triggers.append(trigger)
        triggers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func replace(_ delivery: EventDelivery) {
        deliveries.removeAll { $0.id == delivery.id }
        deliveries.insert(delivery, at: 0)
        deliveries = Array(deliveries.prefix(200))
    }

    static func encodedObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func encodedDictionary(_ value: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func suggestedName(from request: String) -> String {
        let first = request.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New event trigger" : String(trimmed.prefix(80))
    }

    static func suggestedFilters(
        from request: String,
        kind: ConnectorKind
    ) -> EventTriggerFilters {
        var filters = EventTriggerFilters()
        if kind == .gmail {
            let pattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
            if let range = request.range(of: pattern, options: .regularExpression) {
                filters.senders = [String(request[range])]
            }
        }
        if kind == .telegram, let command = request.split(whereSeparator: \.isWhitespace)
            .first(where: { $0.hasPrefix("/") }) {
            filters.commandPrefixes = [String(command)]
        }
        return filters
    }
}

private extension JSONValue {
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.string)
    }
}
