import XCTest
@testable import Locus

final class IndependentRuntimeProtocolTests: XCTestCase {
    func testSubscriptionAndUnknownPricesDoNotDecodeAsZero() throws {
        let payload = #"{"invocations":1,"model_calls":2,"total_tokens":42,"estimated_api_cost":null,"cost_coverage":"subscription","pending_calls":0,"uncertain_calls":0,"pricing_versions":[],"by_purpose":{"worker":1},"coverage_counts":{"subscription":1}}"#
        let summary = try JSONDecoder().decode(UsageAccounting.self, from: Data(payload.utf8))
        XCTAssertNil(summary.estimatedAPICost)
        XCTAssertEqual(summary.costText, "Subscription usage")
        XCTAssertEqual(summary.modelCalls, 2)
    }

    func testReusableProposalDecodesWithItsVersionAndScope() throws {
        let payload = #"{"id":"check","version":3,"revision":5,"state":"proposed","correction":"Keep output ready","workspace_root":"/project","check":{"id":"ready","kind":"file_contains","path":"result.txt","value":"ready","requirement":"Output is ready"},"scope":{"agent_id":"agent","files":["Sources/**"]},"source":{"session_id":"chat"},"verification_limits":"Text only"}"#
        let proposal = try JSONDecoder().decode(ReusableCheckRecord.self, from: Data(payload.utf8))
        XCTAssertEqual(proposal.version, 3)
        XCTAssertEqual(proposal.state, "proposed")
        XCTAssertEqual(proposal.scope.agentID, "agent")
        XCTAssertEqual(proposal.check["path"]?.string, "result.txt")
        XCTAssertNil(proposal.lastTest)
    }

    func testRemoteResultKeepsVerificationSeparateFromCompletion() throws {
        let payload = #"{"changes":[],"runs":[],"task_contracts":[{"id":"run:one","request":"Create output","verification_status":"failed","verification_reason":"Changed after verification","evidence":[]}]}"#
        let result = try JSONDecoder().decode(RuntimeReturnedResult.self, from: Data(payload.utf8))
        XCTAssertEqual(result.taskContracts?.first?.verificationStatus, "failed")
        XCTAssertNil(result.accounting)
    }
}
