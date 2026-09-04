import CryptoKit
import Foundation
import XCTest
@testable import Locus

private actor EventDispatchGate {
    private var arrivedIDs: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func arrive(_ id: String) async {
        arrivedIDs.append(id)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    var arrivals: [String] { arrivedIDs }

    func releaseAll() {
        let waiting = continuations
        continuations = []
        waiting.forEach { $0.resume() }
    }
}

final class EventAutomationTests: XCTestCase {
    private func deliveryPayload(
        id: String,
        triggerID: String,
        targetSessionID: String,
        state: String = "pending"
    ) -> [String: Any] {
        [
            "id": id,
            "trigger_id": triggerID,
            "source_event_id": "message-\(id)",
            "source": "gmail",
            "received_at": 10,
            "occurred_at": 9,
            "event": [
                "source": "gmail",
                "source_event_id": "message-\(id)",
                "event_type": "message",
                "occurred_at": 9,
                "actor": [:],
                "subject": "Locus ab",
                "text": "",
                "recipients": [],
                "labels": [],
                "attachments": [],
                "data": [:],
            ],
            "state": state,
            "attempt": 0,
            "target_session_id": targetSessionID,
            "matched_trigger_count": 2,
            "created_at": 10,
            "updated_at": 10,
        ]
    }

    private func dispatchPayload(
        delivery: [String: Any],
        runID: String,
        sessionID: String
    ) -> [String: Any] {
        var queuedDelivery = delivery
        queuedDelivery["state"] = "queued"
        queuedDelivery["session_id"] = sessionID
        queuedDelivery["run_id"] = runID
        return [
            "ok": true,
            "delivery": queuedDelivery,
            "run": [
                "id": runID,
                "session_id": sessionID,
                "state": "queued",
                "request": "Handle event",
                "created_at": 10,
                "updated_at": 10,
                "last_seq": 0,
                "pinned": false,
                "legacy": false,
                "recoverable": false,
            ],
        ]
    }

    private func triggerPayload(
        id: String,
        enabled: Bool,
        lastError: String?
    ) -> [String: Any] {
        [
            "id": id,
            "name": "Inbox agent",
            "connection_id": "gmail",
            "target_session_id": "chat-a",
            "instruction": "Handle the message",
            "mode": "work",
            "trigger_kind": "event",
            "filters": [:],
            "runtime_state": [:],
            "action_connection_ids": [],
            "enabled": enabled,
            "created_at": 1,
            "updated_at": 12,
            "last_event_at": 10,
            "last_run_id": "run-failed",
            "last_error": lastError ?? NSNull(),
        ]
    }

    func testEventDeliveryDecodesQueueAndFanOutMetadataCompatibly() throws {
        let legacy = try JSONDecoder().decode(
            EventDelivery.self,
            from: Data(#"{"id":"delivery-1","trigger_id":"trigger-1","source_event_id":"message-1","source":"gmail","received_at":10,"occurred_at":9,"event":{"source":"gmail","source_event_id":"message-1","event_type":"message","occurred_at":9,"actor":{},"subject":"Locus ab","text":"","recipients":[],"labels":[],"attachments":[],"data":{}},"state":"pending","attempt":0,"session_id":"chat-1","created_at":10,"updated_at":10}"#.utf8)
        )

        XCTAssertEqual(legacy.targetSessionID, "chat-1")
        XCTAssertEqual(legacy.conversationSessionID, "chat-1")
        XCTAssertEqual(legacy.matchedTriggerCount, 1)
        XCTAssertEqual(legacy.displayState, "Waiting in chat queue")

        let fanOut = EventDelivery(
            id: "delivery-2",
            triggerID: "trigger-2",
            sourceEventID: "message-1",
            source: .gmail,
            receivedAt: 10,
            occurredAt: 9,
            event: legacy.event,
            state: "pending",
            runState: nil,
            attempt: 0,
            sessionID: nil,
            runID: nil,
            error: nil,
            createdAt: 10,
            updatedAt: 10,
            targetSessionID: "chat-2",
            matchedTriggerCount: 2
        )
        XCTAssertEqual(fanOut.conversationSessionID, "chat-2")
        XCTAssertEqual(fanOut.matchedTriggerCount, 2)
    }

    @MainActor
    func testUnchangedRefreshOnlyAnnouncesConnectorCapabilityOnce() async {
        BackendStub.reset()
        BackendStub.respond(toPath: "/api/connectors") { _ in
            ["connections": [], "read_only": false]
        }
        BackendStub.respond(toPath: "/api/event-triggers") { _ in
            ["triggers": [], "read_only": false]
        }
        BackendStub.respond(toPath: "/api/event-deliveries") { _ in
            ["deliveries": []]
        }
        let model = EventAutomationModel()
        var announcementCount = 0
        model.configure(
            backend: stubbedBackendService(),
            onQueuedRun: { _ in },
            canDispatchToSession: { _ in true },
            onCapabilityChanged: { announcementCount += 1 },
            refreshSessions: {},
            agentProviderRoute: { [:] },
            openAgentSession: { _ in },
            showMessage: { _ in }
        )

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(announcementCount, 1)
    }

    @MainActor
    func testRetryIsSingleFlightAndImmediatelyClearsTheMatchingAgentWarning() async {
        BackendStub.reset()
        var retried = deliveryPayload(
            id: "failed", triggerID: "trigger-a", targetSessionID: "chat-a",
            state: "pending"
        )
        retried["attempt"] = 2
        retried["run_id"] = NSNull()
        retried["session_id"] = NSNull()
        BackendStub.respond(toPath: "/api/event-deliveries/failed/retry") { _ in
            [
                "delivery": retried,
                "trigger": self.triggerPayload(
                    id: "trigger-a", enabled: true, lastError: nil
                ),
            ]
        }
        let model = EventAutomationModel()
        var resolvedRunIDs: [String?] = []
        model.seedForUITesting(
            connections: [],
            triggers: [decode(EventTrigger.self, from: triggerPayload(
                id: "trigger-a", enabled: false, lastError: "worker stopped"
            ))!],
            deliveries: []
        )
        model.configure(
            backend: stubbedBackendService(),
            onQueuedRun: { _ in },
            canDispatchToSession: { _ in true },
            onCapabilityChanged: {},
            refreshSessions: {},
            agentProviderRoute: { [:] },
            openAgentSession: { _ in },
            showMessage: { _ in },
            onWarningResolved: { resolvedRunIDs.append($0) }
        )

        var failedPayload = deliveryPayload(
            id: "failed", triggerID: "trigger-a", targetSessionID: "chat-a",
            state: "failed"
        )
        failedPayload["run_id"] = "run-failed"
        failedPayload["error"] = "worker stopped"
        let failedDelivery = decode(EventDelivery.self, from: failedPayload)!
        model.retry(failedDelivery)
        model.retry(failedDelivery)
        for _ in 0..<100 {
            if model.deliveries.first?.state == "pending" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            BackendStub.requestPaths.filter { $0 == "/api/event-deliveries/failed/retry" }.count,
            1
        )
        XCTAssertEqual(model.triggers.first?.enabled, true)
        XCTAssertNil(model.triggers.first?.lastError)
        XCTAssertEqual(model.deliveries.first?.state, "pending")
        XCTAssertTrue(model.retryingDeliveryIDs.isEmpty)
        XCTAssertEqual(resolvedRunIDs.compactMap { $0 }, ["run-failed"])
    }

    @MainActor
    func testAcknowledgingRemovedEventImmediatelyClearsTheMatchingAgentWarning() async {
        BackendStub.reset()
        BackendStub.respond(toPath: "/api/event-deliveries/failed/acknowledge") { _ in
            self.triggerPayload(id: "trigger-a", enabled: false, lastError: nil)
        }
        let model = EventAutomationModel()
        var resolvedRunIDs: [String?] = []
        model.seedForUITesting(
            connections: [],
            triggers: [decode(EventTrigger.self, from: triggerPayload(
                id: "trigger-a", enabled: false, lastError: "worker stopped"
            ))!],
            deliveries: []
        )
        model.configure(
            backend: stubbedBackendService(),
            onQueuedRun: { _ in },
            canDispatchToSession: { _ in true },
            onCapabilityChanged: {},
            refreshSessions: {},
            agentProviderRoute: { [:] },
            openAgentSession: { _ in },
            showMessage: { _ in },
            onWarningResolved: { resolvedRunIDs.append($0) }
        )

        let acknowledged = await model.acknowledgeFailure(
            deliveryID: "failed",
            runID: "run-failed"
        )

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(model.triggers.first?.enabled, false)
        XCTAssertNil(model.triggers.first?.lastError)
        XCTAssertEqual(resolvedRunIDs.compactMap { $0 }, ["run-failed"])
        let request = BackendStub.requests.first
        var requestData = request?.httpBody ?? Data()
        if requestData.isEmpty, let stream = request?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                requestData.append(contentsOf: buffer.prefix(count))
            }
        }
        let requestBody = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        XCTAssertEqual(requestBody?["run_id"] as? String, "run-failed")
    }

    @MainActor
    func testClearWarningIsSingleFlightAndLeavesTheAgentPaused() async {
        BackendStub.reset()
        BackendStub.respond(toPath: "/api/event-triggers/trigger-a/acknowledge") { _ in
            self.triggerPayload(id: "trigger-a", enabled: false, lastError: nil)
        }
        let warningTrigger = decode(EventTrigger.self, from: triggerPayload(
            id: "trigger-a", enabled: false, lastError: "worker stopped"
        ))!
        let model = EventAutomationModel()
        var messages: [String] = []
        var resolvedRunIDs: [String?] = []
        model.seedForUITesting(
            connections: [], triggers: [warningTrigger], deliveries: []
        )
        model.configure(
            backend: stubbedBackendService(),
            onQueuedRun: { _ in },
            canDispatchToSession: { _ in true },
            onCapabilityChanged: {},
            refreshSessions: {},
            agentProviderRoute: { [:] },
            openAgentSession: { _ in },
            showMessage: { messages.append($0) },
            onWarningResolved: { resolvedRunIDs.append($0) }
        )

        model.clearWarning(warningTrigger)
        model.clearWarning(warningTrigger)
        for _ in 0..<100 {
            if model.triggers.first?.lastError == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            BackendStub.requestPaths.filter {
                $0 == "/api/event-triggers/trigger-a/acknowledge"
            }.count,
            1
        )
        XCTAssertEqual(model.triggers.first?.enabled, false)
        XCTAssertNil(model.triggers.first?.lastError)
        XCTAssertTrue(model.clearingWarningIDs.isEmpty)
        XCTAssertEqual(messages, ["Agent warning cleared; the agent remains paused"])
        XCTAssertEqual(resolvedRunIDs.compactMap { $0 }, ["run-failed"])
    }

    @MainActor
    func testDispatcherStartsDifferentChatsTogetherAndOneDeliveryPerChat() async throws {
        BackendStub.reset()
        let chatAFirst = deliveryPayload(
            id: "a-first", triggerID: "trigger-a", targetSessionID: "chat-a"
        )
        let chatASecond = deliveryPayload(
            id: "a-second", triggerID: "trigger-a", targetSessionID: "chat-a"
        )
        let chatBFirst = deliveryPayload(
            id: "b-first", triggerID: "trigger-b", targetSessionID: "chat-b"
        )
        BackendStub.respond(toPath: "/api/connectors") { _ in
            ["connections": [], "read_only": false]
        }
        BackendStub.respond(toPath: "/api/event-triggers") { _ in
            ["triggers": [], "read_only": false]
        }
        BackendStub.respond(toPath: "/api/event-deliveries") { _ in
            ["deliveries": []]
        }
        BackendStub.respond(toPath: "/api/event-deliveries/pending") { _ in
            ["deliveries": [chatAFirst, chatASecond, chatBFirst]]
        }
        BackendStub.respond(whenPathHasPrefix: "/api/event-deliveries/") { url in
            let deliveryID = url.path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            let selected = deliveryID == "b-first" ? chatBFirst : chatAFirst
            let sessionID = deliveryID == "b-first" ? "chat-b" : "chat-a"
            return self.dispatchPayload(
                delivery: selected,
                runID: "run-\(deliveryID)",
                sessionID: sessionID
            )
        }
        let gate = EventDispatchGate()
        let model = EventAutomationModel()
        model.configure(
            backend: stubbedBackendService(),
            onQueuedRun: { run in await gate.arrive(run.id) },
            canDispatchToSession: { _ in true },
            onCapabilityChanged: {},
            refreshSessions: {},
            agentProviderRoute: { [:] },
            openAgentSession: { _ in },
            showMessage: { _ in }
        )
        model.start()
        defer {
            model.stop()
            Task { await gate.releaseAll() }
        }

        for _ in 0..<100 {
            if await gate.arrivals.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let arrivals = await gate.arrivals
        let dispatchPaths = BackendStub.requestPaths.filter { $0.hasSuffix("/dispatch") }

        XCTAssertEqual(Set(arrivals), ["run-a-first", "run-b-first"])
        XCTAssertEqual(Set(dispatchPaths), [
            "/api/event-deliveries/a-first/dispatch",
            "/api/event-deliveries/b-first/dispatch",
        ])
        XCTAssertFalse(dispatchPaths.contains("/api/event-deliveries/a-second/dispatch"))
    }

    func testWebhookSignatureAcceptsExactFreshBodyAndRejectsStaleOrModifiedData() {
        let secret = "local-secret"
        let timestamp = "1700000000"
        let body = Data(#"{"event":"order.created"}"#.utf8)
        let payload = Data(timestamp.utf8) + Data(".".utf8) + body
        let signature = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: Data(secret.utf8))
        ).map { String(format: "%02x", $0) }.joined()

        XCTAssertTrue(EventWebhookServer.verify(
            secret: secret,
            timestamp: timestamp,
            signature: "v1=\(signature)",
            body: body,
            now: 1_700_000_100
        ))
        XCTAssertFalse(EventWebhookServer.verify(
            secret: secret,
            timestamp: timestamp,
            signature: signature,
            body: body + Data(" ".utf8),
            now: 1_700_000_100
        ))
        XCTAssertFalse(EventWebhookServer.verify(
            secret: secret,
            timestamp: timestamp,
            signature: signature,
            body: body,
            now: 1_700_001_000
        ))
    }

    @MainActor
    func testChatShortcutBuildsAnInspectableDeterministicDraft() {
        XCTAssertEqual(
            EventAutomationModel.suggestedName(
                from: "When boss@example.com writes, summarize the request."
            ),
            "When boss@example.com writes, summarize the request."
        )
        XCTAssertEqual(
            EventAutomationModel.suggestedFilters(
                from: "When boss@example.com writes, summarize the request.",
                kind: .gmail
            ).senders,
            ["boss@example.com"]
        )
        XCTAssertEqual(
            EventAutomationModel.suggestedFilters(
                from: "Watch /triage commands", kind: .telegram
            ).commandPrefixes,
            ["/triage"]
        )
    }

    @MainActor
    func testFilterEncodingUsesTheBackendContractAndOmitsEditorIdentity() throws {
        var filters = EventTriggerFilters()
        filters.subjectContains = ["invoice"]
        filters.hasAttachments = true
        filters.predicates = [EventFilterPredicate(
            path: "order.status", operation: .equals, value: "paid"
        )]

        let object = try XCTUnwrap(EventAutomationModel.encodedObject(filters))
        XCTAssertEqual(object["subject_contains"] as? [String], ["invoice"])
        XCTAssertEqual(object["has_attachments"] as? Bool, true)
        let predicates = try XCTUnwrap(object["predicates"] as? [[String: Any]])
        XCTAssertEqual(predicates[0]["path"] as? String, "order.status")
        XCTAssertEqual(predicates[0]["op"] as? String, "equals")
        XCTAssertNil(predicates[0]["id"])
    }

    @MainActor
    func testGmailFilterEncodingOmitsBlankAndOtherProviderFields() throws {
        var filters = EventTriggerFilters()
        filters.senders = ["boss@example.com"]
        filters.recipients = ["me@example.com"]
        filters.subjectContains = ["invoice"]
        filters.labels = ["important"]
        filters.hasAttachments = true
        filters.chatIDs = ["hidden-telegram-filter"]

        let object = try XCTUnwrap(EventAutomationModel.encodedFilters(filters, for: .gmail))
        XCTAssertEqual(object["senders"] as? [String], ["boss@example.com"])
        XCTAssertEqual(object["recipients"] as? [String], ["me@example.com"])
        XCTAssertEqual(object["subject_contains"] as? [String], ["invoice"])
        XCTAssertEqual(object["labels"] as? [String], ["important"])
        XCTAssertEqual(object["has_attachments"] as? Bool, true)
        XCTAssertNil(object["chat_ids"])

        let matchAll = try XCTUnwrap(EventAutomationModel.encodedFilters(
            EventTriggerFilters(), for: .gmail
        ))
        XCTAssertTrue(matchAll.isEmpty)
    }

    func testSparseGmailFilterResponseDecodesMissingOptionalFieldsAsDefaults() throws {
        let filters = try JSONDecoder().decode(
            EventTriggerFilters.self,
            from: Data(#"{"subject_contains":["locus"]}"#.utf8)
        )

        XCTAssertEqual(filters.subjectContains, ["locus"])
        XCTAssertTrue(filters.senders.isEmpty)
        XCTAssertTrue(filters.recipients.isEmpty)
        XCTAssertTrue(filters.labels.isEmpty)
        XCTAssertNil(filters.hasAttachments)
        XCTAssertTrue(filters.chatIDs.isEmpty)
        XCTAssertTrue(filters.senderIDs.isEmpty)
        XCTAssertTrue(filters.commandPrefixes.isEmpty)
        XCTAssertTrue(filters.messageTypes.isEmpty)
        XCTAssertTrue(filters.eventNames.isEmpty)
        XCTAssertTrue(filters.predicates.isEmpty)
        XCTAssertNil(filters.priceCondition)

        let matchAll = try JSONDecoder().decode(
            EventTriggerFilters.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(matchAll, EventTriggerFilters())
    }

    @MainActor
    func testNewEventAgentDefaultsToDedicatedChatWithStableCreationID() {
        let model = EventAutomationModel()

        model.presentEditor(targetSessionID: "template-chat", triggerKind: .event)
        let draft = model.editorDraft

        XCTAssertEqual(draft?.targetSessionID, EventTriggerEditorDraft.dedicatedAgentChat)
        XCTAssertEqual(draft?.templateSessionID, "template-chat")
        XCTAssertFalse(draft?.creationID.isEmpty ?? true)
    }

    @MainActor
    func testEditingDedicatedAgentRepairsItsStableTarget() {
        let model = EventAutomationModel()
        let trigger = EventTrigger(
            id: "weather-agent",
            name: "Weather",
            connectionID: "gmail",
            targetSessionID: "agent-chat",
            instruction: "Summarize weather emails",
            mode: .work,
            triggerKind: .event,
            filters: EventTriggerFilters(),
            runtimeState: PriceTriggerState(),
            actionConnectionIDs: [],
            enabled: true,
            createdAt: 1,
            updatedAt: 1,
            lastEventAt: nil,
            lastRunID: nil,
            lastError: nil
        )

        model.presentEditor(
            trigger: trigger,
            targetSessionID: trigger.targetSessionID,
            isDedicatedAgent: true
        )

        XCTAssertEqual(
            model.editorDraft?.targetSessionID,
            EventTriggerEditorDraft.dedicatedAgentChat
        )
        XCTAssertEqual(model.editorDraft?.templateSessionID, "agent-chat")
    }

    func testAgentSessionSummaryDecodesDurableAgentIdentity() throws {
        let summary = try JSONDecoder().decode(
            SessionSummary.self,
            from: Data(#"{"id":"agent-chat","name":"agent.jsonl","preview":"","mtime":1,"size":2,"agent_trigger_id":"weather-agent","agent_name":"Weather"}"#.utf8)
        )

        XCTAssertTrue(summary.isAgentChat)
        XCTAssertEqual(summary.agentTriggerID, "weather-agent")
        XCTAssertEqual(summary.agentName, "Weather")
    }

    @MainActor
    func testScheduledRunsResolveLegacyAccountLabelsAndStableIDs() {
        let account = ProviderAccount(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .kimiCode,
            name: "new kimi",
            preferredModel: "k3"
        )

        XCTAssertEqual(
            AppModel.scheduledProviderAccount(
                provider: "remote", reference: account.displayName, accounts: [account]
            )?.id,
            account.id
        )
        XCTAssertEqual(
            AppModel.scheduledProviderAccount(
                provider: "remote", reference: account.id.uuidString, accounts: [account]
            )?.id,
            account.id
        )
        XCTAssertEqual(
            AppModel.scheduledProviderAccount(
                provider: "remote", reference: "Kimi Code — renamed", accounts: [account]
            )?.id,
            account.id
        )

        let second = ProviderAccount(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            kind: .kimiCode,
            name: "another kimi",
            preferredModel: "k3"
        )
        XCTAssertNil(AppModel.scheduledProviderAccount(
            provider: "remote", reference: "Kimi Code — renamed",
            accounts: [account, second]
        ))
    }

    @MainActor
    func testFinancialChatShortcutPrefillsInspectablePriceDraft() throws {
        let condition = try XCTUnwrap(EventAutomationModel.suggestedPriceCondition(
            from: "When bitcoin hits 100k implement the safety plan"
        ))
        XCTAssertEqual(condition.providerSymbol, "BTCUSDT")
        XCTAssertEqual(condition.displaySymbol, "Bitcoin")
        XCTAssertEqual(condition.assetClass, "crypto")
        XCTAssertEqual(condition.threshold, "100000")
        XCTAssertEqual(condition.comparison, .crossesAbove)

        let below = try XCTUnwrap(EventAutomationModel.suggestedPriceCondition(
            from: "If AAPL drops below $175 implement X"
        ))
        XCTAssertEqual(below.providerSymbol, "AAPL")
        XCTAssertEqual(below.threshold, "175")
        XCTAssertEqual(below.comparison, .crossesBelow)
    }

    func testPriceJSONPathAndCanonicalDecimalParsingAreBounded() throws {
        let object: [String: Any] = [
            "data": ["ticks": [["last": "100000.5000"]]],
        ]
        let value = EventConnectorClient.resolveJSONPath(
            object, path: "data.ticks.0.last"
        )
        XCTAssertEqual(EventConnectorClient.canonicalPrice(try XCTUnwrap(value)), "100000.5")
        XCTAssertNil(EventConnectorClient.resolveJSONPath(object, path: "data..last"))
        XCTAssertNil(EventConnectorClient.canonicalPrice("nan"))
        XCTAssertNil(EventConnectorClient.canonicalPrice("-1"))
    }

    func testPriceSourceURLRejectsCredentialsAndPrivateHostsByDefault() {
        XCTAssertNil(EventConnectorClient.priceFeedSecurityError(
            endpoint: "https://api.example.com/ticker/BTCUSDT", allowLocalNetwork: false
        ))
        XCTAssertNotNil(EventConnectorClient.priceFeedSecurityError(
            endpoint: "http://api.example.com/ticker/BTCUSDT", allowLocalNetwork: false
        ))
        XCTAssertNotNil(EventConnectorClient.priceFeedSecurityError(
            endpoint: "https://user:secret@example.com/ticker/BTCUSDT",
            allowLocalNetwork: false
        ))
        XCTAssertNotNil(EventConnectorClient.priceFeedSecurityError(
            endpoint: "https://192.168.1.5/ticker/BTCUSDT", allowLocalNetwork: false
        ))
        XCTAssertNil(EventConnectorClient.priceFeedSecurityError(
            endpoint: "https://192.168.1.5/ticker/BTCUSDT", allowLocalNetwork: true
        ))
    }

    func testPriceSourceConfigurationRejectsDuplicateCredentialNames() throws {
        let config = PriceFeedConfiguration(
            endpointTemplate: "https://api.example.com/{symbol}",
            priceJSONPath: "data.price",
            secretFields: [
                PriceFeedSecretField(key: "Authorization", placement: .header),
                PriceFeedSecretField(key: "authorization", placement: .query),
            ]
        )
        let data = try JSONEncoder().encode(config)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertThrowsError(try EventConnectorClient.priceFeedConfiguration(object))
    }

    @MainActor
    func testPriceSourcePublicConfigContainsNamesButNotSecretValues() throws {
        let config = PriceFeedConfiguration(
            endpointTemplate: "https://api.example.com/{symbol}",
            priceJSONPath: "data.price",
            timestampJSONPath: "data.time",
            secretFields: [PriceFeedSecretField(key: "Authorization", placement: .header)]
        )
        let object = try XCTUnwrap(EventAutomationModel.encodedObject(config))
        XCTAssertEqual(object["endpoint_template"] as? String, "https://api.example.com/{symbol}")
        XCTAssertFalse(String(describing: object).contains("super-secret"))
        let fields = try XCTUnwrap(object["secret_fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["key"] as? String, "Authorization")
        XCTAssertNil(fields[0]["value"])
    }
}
