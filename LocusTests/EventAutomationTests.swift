import CryptoKit
import Foundation
import XCTest
@testable import Locus

final class EventAutomationTests: XCTestCase {
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
