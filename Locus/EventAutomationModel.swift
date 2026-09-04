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
    @Published private(set) var retryingDeliveryIDs: Set<String> = []
    @Published private(set) var clearingWarningIDs: Set<String> = []
    /// Whether the trigger list has ever loaded. Until it has, an agent that
    /// is not in `triggers` may simply not have arrived yet.
    @Published private(set) var hasLoaded = false

    private var backend: BackendService?
    private let credentials: ConnectorCredentialStore
    private let client: EventConnectorClient
    private let webhookServer: EventWebhookServer
    private let gmailOAuth = GmailOAuthCoordinator()
    private var connectorTasks: [String: Task<Void, Never>] = [:]
    private var dispatchTask: Task<Void, Never>?
    private var deliveryDispatchTasks: [String: Task<Void, Never>] = [:]
    private var dispatcherStarted = false
    private var isScanningPendingDeliveries = false
    private var pendingDeliveryScanRequested = false
    private var runtimeFingerprint = ""
    private var lastConnectorCapabilityFingerprint: String?
    private var onQueuedRun: ((OrchestrationRun) async -> Void)?
    private var canDispatchToSession: ((String) -> Bool)?
    private var onCapabilityChanged: (() -> Void)?
    private var refreshSessions: (() async -> Void)?
    private var agentProviderRoute: (() -> [String: String])?
    private var openAgentSession: ((SessionSummary) -> Void)?
    private var showMessage: ((String) -> Void)?
    private var notifyPaused: ((String) -> Void)?
    private var onWarningResolved: ((String?) -> Void)?
    private var supportsWorkflows: () -> Bool = { false }

    init(credentials: ConnectorCredentialStore = .shared) {
        self.credentials = credentials
        client = EventConnectorClient(credentials: credentials)
        webhookServer = EventWebhookServer(credentials: credentials)
    }

    deinit {
        connectorTasks.values.forEach { $0.cancel() }
        deliveryDispatchTasks.values.forEach { $0.cancel() }
        dispatchTask?.cancel()
    }

    func configure(
        backend: BackendService,
        onQueuedRun: @escaping (OrchestrationRun) async -> Void,
        canDispatchToSession: @escaping (String) -> Bool,
        onCapabilityChanged: @escaping () -> Void,
        refreshSessions: @escaping () async -> Void,
        agentProviderRoute: @escaping () -> [String: String],
        openAgentSession: @escaping (SessionSummary) -> Void,
        showMessage: @escaping (String) -> Void,
        notifyPaused: @escaping (String) -> Void = { _ in },
        onWarningResolved: @escaping (String?) -> Void = { _ in },
        supportsWorkflows: @escaping () -> Bool = { false }
    ) {
        self.backend = backend
        self.onQueuedRun = onQueuedRun
        self.canDispatchToSession = canDispatchToSession
        self.onCapabilityChanged = onCapabilityChanged
        self.refreshSessions = refreshSessions
        self.agentProviderRoute = agentProviderRoute
        self.openAgentSession = openAgentSession
        self.showMessage = showMessage
        self.notifyPaused = notifyPaused
        self.onWarningResolved = onWarningResolved
        self.supportsWorkflows = supportsWorkflows
    }

    /// UI-test fixtures need agents without a backend. The stored arrays are
    /// otherwise write-protected so only refreshes and mutations change them.
    func seedForUITesting(
        connections: [ConnectorConnection],
        triggers: [EventTrigger],
        deliveries: [EventDelivery]
    ) {
        self.connections = connections
        self.triggers = triggers
        self.deliveries = deliveries
        hasLoaded = true
    }

    func start() {
        guard dispatchTask == nil else { return }
        dispatcherStarted = true
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
        dispatcherStarted = false
        dispatchTask?.cancel()
        dispatchTask = nil
        deliveryDispatchTasks.values.forEach { $0.cancel() }
        deliveryDispatchTasks = [:]
        isScanningPendingDeliveries = false
        pendingDeliveryScanRequested = false
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
            let previous = triggers
            connections = loadedConnections.connections
            triggers = loadedTriggers.triggers
            hasLoaded = true
            deliveries = loadedDeliveries.deliveries
            announceAgentsStoppedByLocus(previous: previous, current: triggers)
            lastError = nil
            restartNativeRuntimeIfNeeded()
            announceConnectorCapabilityIfChanged()
        } catch {
            // A refresh cancelled with its caller (a panel's poll ending as
            // the chat changes) is not a failure of the automations.
            guard !Task.isCancelled else { return }
            lastError = error.localizedDescription
            if announceFailure { showMessage?("Could not load event automations: \(error.localizedDescription)") }
        }
    }

    /// A failed dispatch disables the trigger in the backend and records why.
    /// Nothing restarts it, so a person who is not looking at the Agent panel
    /// would never learn their agent stopped. Schedules already announce this;
    /// event agents now do too.
    private func announceAgentsStoppedByLocus(
        previous: [EventTrigger],
        current: [EventTrigger]
    ) {
        guard !previous.isEmpty else { return }
        let wasStopped = Set(
            previous.filter { !$0.enabled && $0.lastError?.isEmpty == false }.map(\.id)
        )
        for trigger in current
        where !trigger.enabled
            && trigger.lastError?.isEmpty == false
            && !wasStopped.contains(trigger.id)
        {
            let reason = AgentOverview.humanizedError(trigger.lastError ?? "")
            showMessage?("\(trigger.name) was stopped: \(reason)")
            notifyPaused?("\(trigger.name) was stopped: \(reason)")
        }
    }

    func presentEditor(
        trigger: EventTrigger? = nil,
        targetSessionID: String,
        isDedicatedAgent: Bool = false,
        naturalLanguageRequest: String = "",
        triggerKind requestedKind: EventTriggerKind? = nil
    ) {
        if let trigger {
            var draft = EventTriggerEditorDraft(trigger: trigger)
            if isDedicatedAgent {
                // Editing an existing agent passes through the stable target
                // endpoint again so its chat is recovered and its placement
                // repaired. The route it runs on is left alone unless the
                // person asks for the current one.
                draft.targetSessionID = EventTriggerEditorDraft.dedicatedAgentChat
                draft.templateSessionID = targetSessionID
            }
            editorDraft = draft
            return
        }
        var draft = EventTriggerEditorDraft()
        draft.targetSessionID = EventTriggerEditorDraft.dedicatedAgentChat
        draft.templateSessionID = targetSessionID
        draft.instruction = naturalLanguageRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.workflow = .singleAgent(instruction: draft.instruction, mode: draft.mode)
        draft.name = Self.suggestedName(from: naturalLanguageRequest)
        let priceSuggestion = Self.suggestedPriceCondition(from: naturalLanguageRequest)
        draft.triggerKind = requestedKind ?? (priceSuggestion == nil ? .event : .price)
        if draft.triggerKind == .price {
            draft.filters.priceCondition = priceSuggestion ?? PriceCondition()
        }
        let connection = connections.first { connection in
            guard connection.enabled else { return false }
            return draft.triggerKind == .price
                ? [.priceFeed, .webhook].contains(connection.kind)
                : connection.kind != .priceFeed
        }
        if let connection {
            draft.connectionID = connection.id
            if draft.triggerKind == .price {
                draft.actionConnectionIDs = []
                if connection.kind == .webhook { draft.filters.eventNames = ["price.quote"] }
            } else {
                draft.actionConnectionIDs = connection.kind == .webhook ? [] : [connection.id]
                draft.filters = Self.suggestedFilters(
                    from: naturalLanguageRequest, kind: connection.kind
                )
            }
        }
        editorDraft = draft
    }

    func saveTrigger(_ draft: EventTriggerEditorDraft) async -> Bool {
        guard let backend else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var workflow = draft.workflow
        if workflow.steps.count == 1,
           workflow.steps[0].type == .agent,
           workflow.steps[0].instructionTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workflow.steps[0].instructionTemplate = draft.instruction
            workflow.steps[0].mode = draft.mode
        }
        let instruction = (workflow.firstAgent?.instructionTemplate ?? draft.instruction)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !instruction.isEmpty, !draft.connectionID.isEmpty,
              !draft.targetSessionID.isEmpty else {
            showMessage?("Add a name, connection, destination, and instruction.")
            return false
        }
        guard let sourceKind = connections.first(where: {
            $0.id == draft.connectionID
        })?.kind else {
            showMessage?("Choose a connected source.")
            return false
        }
        guard let filters = Self.encodedFilters(draft.filters, for: sourceKind) else {
            showMessage?("The trigger filters could not be saved.")
            return false
        }
        if draft.triggerKind == .price {
            guard let condition = draft.filters.priceCondition,
                  let threshold = condition.thresholdDecimal, threshold > 0 else {
                showMessage?("Add a positive price threshold.")
                return false
            }
            if condition.lifecycle == .repeat && condition.repeatIntervalSeconds < 900 {
                showMessage?("Repeating price alerts must wait at least 15 minutes.")
                return false
            }
        }
        let actions = draft.triggerKind == .price
            ? draft.actionConnectionIDs.filter { id in
                connections.first(where: { $0.id == id })?.kind != .priceFeed
            }
            : (draft.actionConnectionIDs.isEmpty
                ? [draft.connectionID] : draft.actionConnectionIDs)
        isSaving = true
        defer { isSaving = false }
        let targetSessionID: String
        var agentSession: SessionSummary?
        do {
            if draft.targetSessionID == EventTriggerEditorDraft.dedicatedAgentChat {
                guard !draft.templateSessionID.isEmpty else {
                    showMessage?("Choose an existing workspace chat to base this agent on.")
                    return false
                }
                var targetBody: [String: Any] = [
                    "trigger_id": draft.creationID,
                    "template_session_id": draft.templateSessionID,
                    "name": name,
                ]
                // A new agent takes the app's current route. An existing one
                // keeps the route its chat already records — sending the
                // current route on every edit re-pointed the agent's model,
                // however unrelated the edit — unless the person asked for the
                // current model, which is also how a broken route is repaired.
                if draft.id == nil || draft.adoptCurrentRoute {
                    for (key, value) in agentProviderRoute?() ?? [:] where !value.isEmpty {
                        targetBody[key] = value
                    }
                }
                let response: AgentTargetSessionResponse = try await backend.post(
                    "/api/event-triggers/target-session",
                    body: targetBody,
                    as: AgentTargetSessionResponse.self
                )
                targetSessionID = response.session.id
                agentSession = response.session
                await refreshSessions?()
            } else {
                targetSessionID = draft.targetSessionID
            }
        } catch {
            showMessage?("Could not create the dedicated agent chat: \(error.localizedDescription)")
            return false
        }
        var body: [String: Any] = [
            "name": name,
            "connection_id": draft.connectionID,
            "target_session_id": targetSessionID,
            "instruction": instruction,
            "mode": draft.mode.rawValue,
            "trigger_kind": draft.triggerKind.rawValue,
            "filters": filters,
            "action_connection_ids": actions,
            "enabled": draft.enabled,
        ]
        if supportsWorkflows(), let encodedWorkflow = encodedJSONObject(workflow) {
            body["workflow"] = encodedWorkflow
            body["runner"] = draft.runner.rawValue
            body["team_id"] = draft.teamID ?? ""
            body["team_name"] = draft.teamName
        }
        if draft.id == nil { body["id"] = draft.creationID }
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
            runtimeFingerprint = ""
            restartNativeRuntimeIfNeeded()
            editorDraft = nil
            showMessage?(draft.id == nil ? "Agent configuration activated" : "Agent configuration updated")
            if let agentSession { openAgentSession?(agentSession) }
            return true
        } catch {
            showMessage?("Could not save event trigger: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func createTask(for agent: SessionSummary, name: String) async -> Bool {
        guard let backend,
              let triggerID = agent.agentTriggerID?.nilIfBlank else {
            showMessage?("Choose an agent before starting a chat.")
            return false
        }
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? "New chat",
        ]
        for (key, value) in agentProviderRoute?() ?? [:] where !value.isEmpty {
            body[key] = value
        }
        do {
            let response: AgentTargetSessionResponse = try await backend.post(
                "/api/event-triggers/\(triggerID)/tasks",
                body: body,
                as: AgentTargetSessionResponse.self
            )
            await refreshSessions?()
            openAgentSession?(response.session)
            showMessage?("New chat opened in \(agent.agentName ?? agent.displayTitle)")
            return true
        } catch {
            showMessage?("Could not start a chat for this agent: \(error.localizedDescription)")
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

    func clearWarning(_ trigger: EventTrigger) {
        Task { @MainActor [weak self] in
            _ = await self?.acknowledgeWarning(trigger)
        }
    }

    @discardableResult
    func acknowledgeWarning(_ trigger: EventTrigger) async -> Bool {
        guard let backend, clearingWarningIDs.insert(trigger.id).inserted else { return false }
        defer { clearingWarningIDs.remove(trigger.id) }
        do {
            let updated: EventTrigger = try await backend.post(
                "/api/event-triggers/\(trigger.id)/acknowledge", body: [:],
                as: EventTrigger.self
            )
            replace(updated)
            onWarningResolved?(trigger.lastRunID)
            showMessage?(updated.enabled
                ? "Agent warning cleared"
                : "Agent warning cleared; the agent remains paused")
            return true
        } catch {
            showMessage?("Could not clear this warning: \(error.localizedDescription)")
            return false
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
        guard retryingDeliveryIDs.insert(delivery.id).inserted else { return }
        Task { [weak self] in
            _ = await self?.performRetry(
                delivery.id,
                previousRunID: delivery.runID
            )
        }
    }

    @discardableResult
    func retryDelivery(_ deliveryID: String, previousRunID: String? = nil) async -> Bool {
        guard let backend, retryingDeliveryIDs.insert(deliveryID).inserted else { return false }
        return await performRetry(deliveryID, previousRunID: previousRunID, backend: backend)
    }

    private func performRetry(
        _ deliveryID: String,
        previousRunID: String?,
        backend suppliedBackend: BackendService? = nil
    ) async -> Bool {
        defer { retryingDeliveryIDs.remove(deliveryID) }
        guard let backend = suppliedBackend ?? backend else { return false }
        do {
            let response: EventDeliveryRetryResponse = try await backend.post(
                "/api/event-deliveries/\(deliveryID)/retry", body: [:],
                as: EventDeliveryRetryResponse.self
            )
            replace(response.delivery)
            replace(response.trigger)
            onWarningResolved?(previousRunID)
            wakeDispatcher()
            return true
        } catch {
            showMessage?("Could not retry this event: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func acknowledgeFailure(deliveryID: String, runID: String?) async -> Bool {
        guard let backend else { return false }
        do {
            var body: [String: Any] = [:]
            if let runID { body["run_id"] = runID }
            let trigger: EventTrigger = try await backend.post(
                "/api/event-deliveries/\(deliveryID)/acknowledge", body: body,
                as: EventTrigger.self
            )
            replace(trigger)
            onWarningResolved?(runID)
            return true
        } catch {
            // Removing an Activity item is local presentation state. A later
            // refresh keeps the persistent warning honest if the backend did
            // not accept the acknowledgement; avoid a noisy secondary toast.
            return false
        }
    }

    func rearm(_ trigger: EventTrigger) {
        Task { [weak self] in
            guard let self, let backend else { return }
            do {
                let updated: EventTrigger = try await backend.post(
                    "/api/event-triggers/\(trigger.id)/rearm", body: [:],
                    as: EventTrigger.self
                )
                replace(updated)
                showMessage?("Price alert re-armed")
            } catch {
                showMessage?("Could not re-arm price alert: \(error.localizedDescription)")
            }
        }
    }

    func connectGmail(displayName: String) async {
        guard let backend else { return }
        do {
            let clientID = Bundle.main.object(forInfoDictionaryKey: "LocusGoogleOAuthClientID") as? String ?? ""
            let callbackScheme = Bundle.main.object(
                forInfoDictionaryKey: "LocusGoogleOAuthCallbackScheme"
            ) as? String ?? ""
            let secret = try await gmailOAuth.authenticate(
                clientID: clientID,
                callbackScheme: callbackScheme
            )
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
                announceConnectorCapabilityIfChanged()
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

    @discardableResult
    func connectPriceFeed(
        displayName: String,
        configuration: PriceFeedConfiguration,
        secrets: [String: String],
        testCondition: PriceCondition
    ) async -> Bool {
        guard let backend, let publicConfig = Self.encodedObject(configuration) else {
            return false
        }
        do {
            let quote = try await client.testPriceFeed(
                configuration: configuration, secrets: secrets,
                condition: testCondition,
                displayName: displayName.nilIfBlank ?? "Price Source"
            )
            let identifier = "price-feed-\(UUID().uuidString.lowercased())"
            if !secrets.isEmpty { try credentials.save(secrets, for: identifier) }
            do {
                let connection: ConnectorConnection = try await backend.post(
                    "/api/connectors", body: [
                        "id": identifier, "kind": ConnectorKind.priceFeed.rawValue,
                        "display_name": displayName.nilIfBlank ?? "Price Source",
                        "public_config": publicConfig, "cursor": [:],
                    ], as: ConnectorConnection.self
                )
                connections.append(connection)
                runtimeFingerprint = ""
                restartNativeRuntimeIfNeeded()
                announceConnectorCapabilityIfChanged()
                showMessage?("Price source connected · \(quote.price) \(quote.quoteCurrency)")
                return true
            } catch {
                try? credentials.delete(for: identifier)
                throw error
            }
        } catch {
            showMessage?("Could not connect price source: \(error.localizedDescription)")
            return false
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
                announceConnectorCapabilityIfChanged()
            } catch {
                showMessage?("Could not delete connection: \(error.localizedDescription)")
            }
        }
    }

    func connectorCapability() -> [String: Any] {
        let available = connections.filter { connection in
            guard connection.enabled,
                  connection.kind != .webhook,
                  connection.kind != .priceFeed else { return false }
            return (try? credentials.load(for: connection.id)) != nil
        }
        return [
            "protocol_version": 1,
            "connections": available.map { ["id": $0.id, "kind": $0.kind.rawValue] },
        ]
    }

    private func announceConnectorCapabilityIfChanged() {
        let capability = connectorCapability()
        let connections = (capability["connections"] as? [[String: String]] ?? [])
            .map { "\($0["id"] ?? ""):\($0["kind"] ?? "")" }
            .sorted()
        let fingerprint = connections.joined(separator: "|")
        guard fingerprint != lastConnectorCapabilityFingerprint else { return }
        lastConnectorCapabilityFingerprint = fingerprint
        onCapabilityChanged?()
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
                        "idempotency_key": event["idempotency_key"] as? String ?? requestID,
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
                announceConnectorCapabilityIfChanged()
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
        var consecutiveFailures = 0
        while !Task.isCancelled {
            guard let connection = connections.first(where: { $0.id == connectionID && $0.enabled })
            else { return }
            do {
                let priceConditions = triggers.compactMap { trigger -> PriceCondition? in
                    guard trigger.enabled, trigger.connectionID == connectionID,
                          trigger.triggerKind == .price else { return nil }
                    return trigger.filters.priceCondition
                }
                let result = try await client.poll(
                    connection, priceConditions: priceConditions
                )
                for event in result.events {
                    try await ingest(connectionID: connectionID, event: event)
                }
                try await updateCursor(connectionID, cursor: result.cursor, health: "connected", error: "")
                consecutiveFailures = 0
            } catch is CancellationError {
                return
            } catch EventConnectorClientError.retryAfter(let seconds) {
                try? await updateCursor(
                    connectionID, cursor: connection.cursor,
                    health: "rate_limited", error: "The source asked Locus to retry later."
                )
                try? await Task.sleep(for: .seconds(min(max(seconds, 1), 900)))
                continue
            } catch {
                consecutiveFailures += 1
                try? await updateCursor(
                    connectionID, cursor: connection.cursor,
                    health: "error", error: error.localizedDescription
                )
                if connection.kind == .priceFeed {
                    let base = connection.publicConfig["poll_interval_seconds"]?.integerValue ?? 60
                    let multiplier = pow(2.0, Double(min(consecutiveFailures - 1, 6)))
                    try? await Task.sleep(for: .seconds(min(Double(base) * multiplier, 900)))
                    continue
                }
            }
            if connection.kind == .gmail {
                try? await Task.sleep(for: .seconds(30))
            } else if connection.kind == .priceFeed {
                let interval = connection.publicConfig["poll_interval_seconds"]?.integerValue ?? 60
                try? await Task.sleep(for: .seconds(min(max(interval, 15), 86_400)))
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
        if !response.deliveries.isEmpty { wakeDispatcher() }
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

    /// Polling is the recovery fallback; ingestion and terminal turns use this
    /// path to drain the durable queue without waiting for the next interval.
    func wakeDispatcher() {
        guard dispatcherStarted else { return }
        pendingDeliveryScanRequested = true
        Task { [weak self] in await self?.processPendingDeliveries() }
    }

    private func processPendingDeliveries() async {
        guard dispatcherStarted, let backend else { return }
        if isScanningPendingDeliveries {
            pendingDeliveryScanRequested = true
            return
        }
        isScanningPendingDeliveries = true
        pendingDeliveryScanRequested = false
        defer {
            isScanningPendingDeliveries = false
            if pendingDeliveryScanRequested {
                pendingDeliveryScanRequested = false
                Task { [weak self] in await self?.processPendingDeliveries() }
            }
        }
        do {
            let response: EventDeliveriesResponse = try await backend.get(
                "/api/event-deliveries/pending",
                query: [URLQueryItem(name: "limit", value: "50")],
                as: EventDeliveriesResponse.self
            )
            var visitedSessions = Set<String>()
            for pending in response.deliveries {
                let targetSessionID = pending.targetSessionID
                    ?? triggers.first(where: { $0.id == pending.triggerID })?.targetSessionID
                guard let targetSessionID,
                      visitedSessions.insert(targetSessionID).inserted,
                      deliveryDispatchTasks[targetSessionID] == nil,
                      canDispatchToSession?(targetSessionID) != false
                else { continue }
                deliveryDispatchTasks[targetSessionID] = Task { [weak self] in
                    guard let self else { return }
                    defer { self.deliveryDispatchTasks.removeValue(forKey: targetSessionID) }
                    do {
                        let dispatched: EventDispatchResponse = try await backend.post(
                            "/api/event-deliveries/\(pending.id)/dispatch", body: [:],
                            timeout: 30, as: EventDispatchResponse.self
                        )
                        self.replace(dispatched.delivery)
                        if let run = dispatched.run {
                            await self.onQueuedRun?(run)
                        }
                    } catch let error as NSError where error.domain == "Locus.Backend"
                        && error.code == 409 {
                        // Another process or the previous turn won the durable
                        // claim. The next poll/terminal wake will try the head.
                    } catch {
                        // Dispatch failures are durable delivery state. A
                        // refresh exposes Retry without replaying the event.
                    }
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

    static func encodedFilters(
        _ filters: EventTriggerFilters,
        for sourceKind: ConnectorKind
    ) -> [String: Any]? {
        guard let object = encodedObject(filters) else { return nil }
        let allowedKeys: Set<String> = switch sourceKind {
        case .gmail:
            ["senders", "recipients", "labels", "subject_contains", "has_attachments"]
        case .telegram:
            ["chat_ids", "sender_ids", "command_prefixes", "message_types"]
        case .webhook:
            ["event_names", "predicates", "price_condition"]
        case .priceFeed:
            ["price_condition"]
        }
        return object.filter { key, value in
            guard allowedKeys.contains(key) else { return false }
            if let values = value as? [Any] { return !values.isEmpty }
            return true
        }
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

    static func suggestedPriceCondition(from request: String) -> PriceCondition? {
        let lowered = request.lowercased()
        guard lowered.contains("price") || lowered.contains("hits")
            || lowered.contains("above") || lowered.contains("below")
            || lowered.contains("over") || lowered.contains("under") else { return nil }
        let pattern = #"(?i)(?:hits?|reaches?|cross(?:es)?|above|below|over|under)\s*\$?([0-9][0-9,.]*\s*[km]?)"#
        guard let range = request.range(of: pattern, options: .regularExpression),
              let numberRange = request[range].range(
                of: #"(?i)[0-9][0-9,.]*\s*[km]?"#, options: .regularExpression
              ) else { return nil }
        var number = String(request[numberRange]).lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        var multiplier = Decimal(1)
        if number.hasSuffix("k") { number.removeLast(); multiplier = 1_000 }
        if number.hasSuffix("m") { number.removeLast(); multiplier = 1_000_000 }
        guard let raw = Decimal(
            string: number, locale: Locale(identifier: "en_US_POSIX")
        ), raw > 0 else { return nil }
        let threshold = NSDecimalNumber(decimal: raw * multiplier).stringValue
        let comparison: PriceComparison = (
            lowered.contains("below") || lowered.contains("under")
                || lowered.contains("drops") || lowered.contains("falls")
        ) ? .crossesBelow : .crossesAbove
        if lowered.contains("bitcoin") || lowered.contains("btc") {
            return PriceCondition(
                providerSymbol: "BTCUSDT", displaySymbol: "Bitcoin",
                assetClass: "crypto", quoteCurrency: "USD",
                comparison: comparison, threshold: threshold
            )
        }
        if lowered.contains("ethereum") || lowered.contains("ether")
            || lowered.contains("eth") {
            return PriceCondition(
                providerSymbol: "ETHUSDT", displaySymbol: "Ethereum",
                assetClass: "crypto", quoteCurrency: "USD",
                comparison: comparison, threshold: threshold
            )
        }
        let tickerPattern = #"\b[A-Z]{1,6}\b"#
        let ticker = request.range(of: tickerPattern, options: .regularExpression)
            .map { String(request[$0]) } ?? ""
        guard !ticker.isEmpty else { return nil }
        return PriceCondition(
            providerSymbol: ticker, displaySymbol: ticker,
            assetClass: "stock", quoteCurrency: "USD",
            comparison: comparison, threshold: threshold
        )
    }
}

private extension JSONValue {
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.string)
    }

    var integerValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }
}
