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
}
