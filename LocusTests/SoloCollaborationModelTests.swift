import XCTest
@testable import Locus

@MainActor
final class SoloCollaborationModelTests: XCTestCase {
    private func helper(state: String, revision: Int) -> [String: Any] {
        ["id": "helper-a", "session_id": "chat-a", "run_id": "run-a", "label": "Research",
         "goal": "Read the tests", "state": state, "revision": revision]
    }

    func testHelperStateRejectsOldSnapshotsAndRoutesStableHelperIdentity() throws {
        let model = SoloCollaborationModel()
        var payload: [String: Any] = [:]
        var owner = ""
        model.send = { sessionID, value in owner = sessionID; payload = value; return true }
        model.receive(["type": "solo_collaboration_snapshot", "agents": [helper(state: "paused", revision: 3)]], sessionID: "chat-a")
        model.receive(["type": "solo_collaboration_snapshot", "agents": [helper(state: "running", revision: 2)]], sessionID: "chat-a")
        XCTAssertEqual(model.agents["chat-a"]?.first?.state, "paused")
        XCTAssertTrue(model.act("resume", agentID: "helper-a", sessionID: "chat-a", text: "Check the remaining test"))
        XCTAssertEqual(owner, "chat-a")
        XCTAssertEqual(payload["agent_id"] as? String, "helper-a")
        XCTAssertEqual(payload["action"] as? String, "resume")
        XCTAssertFalse(model.act("resume", agentID: "helper-a", sessionID: "chat-a"), "No duplicate while waiting for acknowledgement")
    }

    func testDisconnectPreservesDraftAndNeverReplaysWorkWithoutConfirmation() throws {
        let model = SoloCollaborationModel()
        var sends = 0
        model.send = { _, _ in sends += 1; return true }
        let key = SoloCollaborationModel.key("chat-a", "helper-a")
        model.drafts[key] = "Look at retries"
        model.act("followup", agentID: "helper-a", sessionID: "chat-a", text: "Look at retries")
        model.disconnected(sessionID: "chat-a")
        model.receive(["type": "solo_collaboration_snapshot", "agents": [helper(state: "running", revision: 3)]], sessionID: "chat-a")
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(model.drafts[key], "Look at retries")
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNotNil(model.errors[key])
    }

    func testRunningTurnIncludesReusableHelpersCurrentFirstAndKeepsSessionsIsolated() {
        let model = SoloCollaborationModel()
        var earlier = helper(state: "idle", revision: 1)
        earlier["id"] = "earlier-helper"
        earlier["label"] = "A saved helper"
        earlier["run_id"] = "earlier-run"
        var current = helper(state: "running", revision: 1)
        current["id"] = "current-helper"
        current["label"] = "Z current helper"
        var otherSession = helper(state: "paused", revision: 1)
        otherSession["id"] = "other-session-helper"
        otherSession["session_id"] = "chat-b"
        model.receive(["type": "solo_collaboration_snapshot", "agents": [earlier, current, otherSession]], sessionID: "chat-a")
        model.receive(["type": "solo_collaboration_snapshot", "agents": [otherSession]], sessionID: "chat-b")

        XCTAssertEqual(model.visibleHelpers(sessionID: "chat-a", runID: "run-a", isParentRunning: true).map(\.id),
                       ["current-helper", "earlier-helper"], "Current attempts precede alphabetically earlier saved helpers")
        XCTAssertEqual(model.visibleHelpers(sessionID: "chat-a", runID: "run-a", isParentRunning: false).map(\.id),
                       ["current-helper"], "Finished run controls must not include other turns")
        XCTAssertEqual(model.visibleHelpers(sessionID: "chat-a", runID: "earlier-run", isParentRunning: false).map(\.id),
                       ["earlier-helper"])
        XCTAssertEqual(model.visibleHelpers(sessionID: "chat-b", runID: "run-a", isParentRunning: true).map(\.id),
                       ["other-session-helper"])
    }

    func testFollowingUpSavedHelperRetainsItsIdentityDraftAndSingleRow() throws {
        let model = SoloCollaborationModel()
        var earlier = helper(state: "interrupted", revision: 1)
        earlier["run_id"] = "earlier-run"
        model.receive(["type": "solo_collaboration_snapshot", "agents": [earlier]], sessionID: "chat-a")
        let draftKey = SoloCollaborationModel.key("chat-a", "helper-a")
        model.drafts[draftKey] = "Check the remaining retry behavior"
        var sent: [String: Any] = [:]
        model.send = { _, payload in sent = payload; return true }
        let saved = try XCTUnwrap(model.visibleHelpers(sessionID: "chat-a", runID: "run-a", isParentRunning: true).first)
        XCTAssertTrue(model.act("followup", agentID: saved.id, sessionID: saved.sessionID, text: model.drafts[draftKey]!))
        XCTAssertEqual(sent["agent_id"] as? String, "helper-a")

        let reused = helper(state: "running", revision: 2)
        model.receive(["type": "solo_collaboration_snapshot", "agents": [reused]], sessionID: "chat-a")
        let rows = model.visibleHelpers(sessionID: "chat-a", runID: "run-a", isParentRunning: true)
        XCTAssertEqual(rows.map(\.id), ["helper-a"], "Reusing a helper must update its row rather than create another helper")
        XCTAssertEqual(rows.first?.runID, "run-a")
        XCTAssertEqual(model.drafts[draftKey], "Check the remaining retry behavior", "Changing attempt ownership must preserve its instruction draft")
    }
}
