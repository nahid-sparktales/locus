import XCTest
@testable import Locus

final class CompanionMenuBarTests: XCTestCase {
    private let profileID = UUID()
    private let otherProfileID = UUID()
    private let workspace = "/tmp/companion-menu-home"

    func testNotificationsKeepDecisionsUnreadResultsAndActiveWorkSeparate() throws {
        let sessions = [session("own"), session("foreign", owner: otherProfileID),
                        session("project", root: "/tmp/another-project")]
        let runs = try [run("waiting", state: "waiting_permission"), run("working", state: "running"),
                        run("done", state: "completed"), run("failed", state: "failed"),
                        run("read", state: "completed"), run("foreign", sessionID: "foreign"),
                        run("project", sessionID: "project", root: "/tmp/another-project")]
        let items = [attention("decision", runID: "waiting"),
                     attention("recovery", runID: "failed", group: .recoveries),
                     attention("foreign", sessionID: "foreign", runID: "foreign"),
                     attention("project", sessionID: "project", runID: "project")]
        let snapshot = CompanionMenuBarActivity(profileID: profileID, workspace: workspace,
            sessionsByID: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
            runs: runs, attentionItems: items, unreadRunIDs: ["done", "failed", "foreign", "project"])
        XCTAssertEqual(Set(snapshot.attentionItems.map(\.id)), ["decision", "recovery"])
        XCTAssertEqual(snapshot.unreadRuns.map(\.id), ["done"])
        XCTAssertTrue(snapshot.inProgressRuns.contains { $0.id == "working" })
        XCTAssertFalse(snapshot.inProgressRuns.contains { ["foreign", "project"].contains($0.id) })
        XCTAssertEqual(snapshot.notificationCount, 3)
    }

    func testNoPrimaryCompanionNeverShowsAnotherAgentsActivity() throws {
        let snapshot = CompanionMenuBarActivity(profileID: nil, workspace: workspace,
            sessionsByID: ["own": session("own")], runs: [try run("done")],
            attentionItems: [attention("approval")], unreadRunIDs: ["done"])
        XCTAssertTrue(snapshot.attentionItems.isEmpty)
        XCTAssertTrue(snapshot.unreadRuns.isEmpty)
        XCTAssertTrue(snapshot.inProgressRuns.isEmpty)
        XCTAssertEqual(snapshot.notificationCount, 0)
    }

    func testCanonicalSessionOwnerOverridesConflictingManifest() throws {
        let foreign = session("foreign", owner: otherProfileID)
        let conflicting = try run("conflicting", sessionID: foreign.id, manifestOwner: profileID)
        let fallback = try run("fallback", sessionID: "uncatalogued", manifestOwner: profileID)
        let snapshot = CompanionMenuBarActivity(profileID: profileID, workspace: workspace,
            sessionsByID: [foreign.id: foreign], runs: [conflicting, fallback],
            attentionItems: [attention("conflict", sessionID: foreign.id, runID: conflicting.id)],
            unreadRunIDs: [conflicting.id, fallback.id])
        XCTAssertEqual(snapshot.unreadRuns.map(\.id), ["fallback"])
        XCTAssertTrue(snapshot.attentionItems.isEmpty)
    }

    func testReadingSnapshotDoesNotConsumeUnreadOrRequestsAndSortsDeterministically() throws {
        let runs = try [run("a"), run("b")]
        let items = [attention("standalone")]
        let first = CompanionMenuBarActivity(profileID: profileID, workspace: workspace,
            sessionsByID: ["own": session("own")], runs: runs,
            attentionItems: items, unreadRunIDs: ["a", "b"])
        let reopened = CompanionMenuBarActivity(profileID: profileID, workspace: workspace,
            sessionsByID: ["own": session("own")], runs: runs.reversed(),
            attentionItems: items, unreadRunIDs: ["a", "b"])
        XCTAssertEqual(first.unreadRuns.map(\.id), reopened.unreadRuns.map(\.id))
        XCTAssertEqual(first.attentionItems, reopened.attentionItems)
        XCTAssertEqual(first.notificationCount, 3)
        XCTAssertEqual(reopened.notificationCount, 3)
    }

    func testStaleNonterminalSnapshotCannotResurrectFinishedWorkInEitherOrder() throws {
        let completed = try run("same", state: "completed")
        let stale = try run("same", state: "running", updatedAt: 999)
        for runs in [[completed, stale], [stale, completed]] {
            let snapshot = CompanionMenuBarActivity(profileID: profileID, workspace: workspace,
                sessionsByID: ["own": session("own")], runs: runs,
                attentionItems: [], unreadRunIDs: ["same"])
            XCTAssertEqual(snapshot.unreadRuns.map(\.id), ["same"])
            XCTAssertTrue(snapshot.inProgressRuns.isEmpty)
            XCTAssertEqual(snapshot.notificationCount, 1)
        }
    }

    private func session(_ id: String, owner: UUID? = nil, root: String? = nil) -> SessionSummary {
        SessionSummary(id: id, name: id, preview: "", mtime: 1, size: 0,
                       cwd: root ?? workspace, agentProfileID: (owner ?? profileID).uuidString)
    }

    private func attention(_ id: String, sessionID: String = "own", runID: String? = nil,
                           group: AttentionGroup = .decisions) -> AttentionItem {
        .init(id: id, kind: group == .decisions ? "permission_request" : "recoverable_run",
              group: group, sessionID: sessionID, runID: runID, title: id, detail: "Fixture",
              timestamp: 1, actions: [])
    }

    private func run(_ id: String, sessionID: String = "own", state: String = "completed",
                     root: String? = nil, manifestOwner: UUID? = nil, updatedAt: Double = 2) throws -> OrchestrationRun {
        var json: [String: Any] = ["id": id, "session_id": sessionID, "workspace_root": root ?? workspace,
            "state": state, "request": "Fixture", "created_at": 1, "updated_at": updatedAt,
            "last_seq": 1, "pinned": false, "legacy": false, "recoverable": false]
        if let manifestOwner { json["manifest"] = ["agent_profile_id": manifestOwner.uuidString] }
        return try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
