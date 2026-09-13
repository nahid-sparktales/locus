import Foundation
import XCTest
@testable import Locus

@MainActor
final class AgentWorldSignalsTests: XCTestCase {
    private let sender = UUID(), receiver = UUID()

    private func fixtureRun(sourceCompleted: Double? = 10, recipientStarted: Double? = 11,
                     output: String = "Verified research", workspace: String = "/tmp/crew-project") throws -> OrchestrationRun {
        var source: [String: Any] = ["run_id": "run", "job_id": "research", "attempt": 1, "attempt_id": "source-attempt",
                                    "agent_id": sender.uuidString, "agent_name": "Researcher", "state": "completed",
                                    "goal": "Find evidence", "started_at": 8, "result": ["output": output, "evidence": ["report.md"]]]
        if let sourceCompleted { source["completed_at"] = sourceCompleted }
        var target: [String: Any] = ["run_id": "run", "job_id": "write", "attempt": 1, "attempt_id": "recipient-attempt",
                                    "agent_id": receiver.uuidString, "agent_name": "Writer", "state": "running", "goal": "Write report"]
        if let recipientStarted { target["started_at"] = recipientStarted }
        let raw: [String: Any] = [
            "id": "run", "session_id": "real-session", "workspace_root": workspace,
            "state": "running", "request": "A report", "created_at": 5, "updated_at": 12,
            "last_seq": 3, "pinned": false, "legacy": false, "recoverable": false,
            "attempts": [source, target], "plan": ["summary": "Research then write", "jobs": [
                ["id": "research", "agent_id": sender.uuidString, "goal": "Find evidence", "dependencies": [], "kind": "specialist"],
                ["id": "write", "agent_id": receiver.uuidString, "goal": "Write report", "dependencies": ["research"], "kind": "specialist"],
            ]],
        ]
        return try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testCourierRequiresDeliveredResultsBetweenKnownAgentsInThisWorkspace() throws {
        let profiles = Set([sender, receiver])
        let recorded = try fixtureRun()
        let deliveries = AgentWorldSignals.transfers(in: recorded, profiles: profiles, workspace: "/tmp/crew-project")
        let delivery = try XCTUnwrap(deliveries.first)
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(delivery.fromAgentID, sender.uuidString)
        XCTAssertEqual(delivery.toAgentID, receiver.uuidString)
        XCTAssertEqual(delivery.sessionID, "real-session")
        XCTAssertEqual(delivery.kind, "artifact")
        XCTAssertEqual(delivery.occurredAt.timeIntervalSince1970, 11)
        XCTAssertNotNil(UUID(uuidString: delivery.id))
        XCTAssertEqual(AgentWorldSignals.transfers(in: recorded, profiles: profiles, workspace: "/tmp/crew-project"), deliveries)
        XCTAssertTrue(AgentWorldSignals.transfers(in: recorded, profiles: [sender], workspace: "/tmp/crew-project").isEmpty)
        XCTAssertTrue(AgentWorldSignals.transfers(in: recorded, profiles: profiles, workspace: "/tmp/other-project").isEmpty)
        for pending in [try fixtureRun(sourceCompleted: nil), try fixtureRun(recipientStarted: nil), try fixtureRun(sourceCompleted: 12), try fixtureRun(output: "")] {
            XCTAssertTrue(AgentWorldSignals.transfers(in: pending, profiles: profiles, workspace: "/tmp/crew-project").isEmpty)
        }
    }

    func testMapReceivesOnlyDisplayMetadataAndOpaqueTokens() throws {
        let attention = AgentWorldAttention(id: UUID().uuidString, agentID: sender.uuidString, kind: "input",
                                            title: "Needs an answer", sessionID: "private-session")
        XCTAssertEqual(Set(attention.snapshot.keys), ["id", "agentID", "kind", "title"])
        let delivery = try XCTUnwrap(AgentWorldSignals.transfers(in: fixtureRun(), profiles: [sender, receiver], workspace: "/tmp/crew-project").first)
        XCTAssertEqual(Set(delivery.snapshot.keys), ["id", "fromAgentID", "toAgentID", "kind", "title", "occurredAt"])
        let serialized = String(data: try JSONSerialization.data(withJSONObject: delivery.snapshot), encoding: .utf8)!
        XCTAssertFalse(serialized.contains("Verified research"))
        XCTAssertFalse(serialized.contains("real-session"))
        XCTAssertFalse(serialized.contains("report.md"))
        XCTAssertNotEqual(AgentWorldSignals.token("request", "first"), AgentWorldSignals.token("request", "second"))
    }

    private func foregroundTeam() -> AppModel {
        let model = AppModel(startImmediately: false)
        model.agentProfiles = [AgentProfile(id: sender, name: "Captain", model: "fixture", role: .dispatcher),
                               AgentProfile(id: receiver, name: "Researcher", model: "fixture", role: .researcher)]
        model.sessionInfo = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp/crew-project",
            session: "team-session", sessionID: "team-session", messages: 0, approxTokens: 0,
            promptTokens: 0, completionTokens: 0, contextLimit: 0, maxIterations: 40,
            hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
        model.installTranscriptSession("team-session", blocks: [])
        model.orchestrationRunID = "run"
        return model
    }

    func testForegroundTeamPermissionKeepsTheExactRequestOwnerAfterEventReduction() throws {
        let model = foregroundTeam()
        XCTAssertNil(model.savedAgentProfileID(for: "team-session"))
        model.handle(["type": "permission_request", "session_id": "team-session", "run_id": "run",
                      "request_id": "approve-research", "id": "tool-research", "tool": "read_file",
                      "agent_id": receiver.uuidString, "summary": "Read the requested report"])
        let signal = try XCTUnwrap(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.first)
        XCTAssertEqual(signal.agentID, receiver.uuidString)
        XCTAssertEqual(signal.sessionID, "team-session")
        XCTAssertEqual(signal.id, AgentWorldSignals.token("attention", "team-session", "permission_request:approve-research"))
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/another-project").attention.isEmpty)

        // The old event must not be used for a later unowned request.
        model.blocks = [ChatBlock(kind: .tool, tool: ToolPayload(toolID: "next", tool: "read_file",
            summary: "Another request", detail: "", status: .awaitingPermission, requestID: "next-request"))]
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
        model.blocks = []
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
    }

    func testForegroundTeamQuestionUsesItsRealOwnerWithoutAssigningTheSelectedTeam() throws {
        let model = foregroundTeam()
        let unrelated = AgentTeam(name: "Unrelated selection", dispatcherID: sender, memberIDs: [sender])
        model.agentTeams = [unrelated]; model.selectedAgentTeamID = unrelated.id
        model.handle(["type": "question_required", "session_id": "team-session", "run_id": "run",
                      "request_id": "research-question", "agent_id": receiver.uuidString,
                      "questions": [["id": "format", "header": "Format", "question": "Which format?"]]])
        let signal = try XCTUnwrap(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.first)
        XCTAssertEqual(signal.agentID, receiver.uuidString)
        XCTAssertEqual(signal.kind, "input")
        model.handle(["type": "question_resolved", "request_id": "research-question"])
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
    }

    func testDispatcherOwnershipComesFromThisRunsEventOrManifest() throws {
        let model = foregroundTeam()
        let unrelated = AgentTeam(name: "Different crew", dispatcherID: receiver, memberIDs: [receiver])
        model.agentTeams = [unrelated]; model.selectedAgentTeamID = unrelated.id
        model.handle(["type": "dispatcher_started", "session_id": "team-session", "run_id": "run", "agent_id": sender.uuidString])
        model.handle(["type": "dispatch_plan_ready", "session_id": "team-session", "run_id": "run",
                      "plan": ["summary": "A real recorded plan", "jobs": []]])
        XCTAssertEqual(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.first?.agentID, sender.uuidString)

        model.agentWorldRequestOwners = [:]
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty,
                      "The selected team alone is not evidence that it owns this request")
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixtureRun())) as! [String: Any]
        raw["manifest"] = ["team": ["dispatcher_id": sender.uuidString]]
        func decoded() throws -> OrchestrationRun {
            try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        model.agentWorldRunSignals["run"] = try decoded()
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty, "A different session's run must be rejected")
        raw["session_id"] = "team-session"; raw["workspace_root"] = "/tmp/another-project"
        model.agentWorldRunSignals["run"] = try decoded()
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
        raw["workspace_root"] = "/tmp/crew-project"
        model.agentWorldRunSignals["run"] = try decoded()
        XCTAssertEqual(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.first?.agentID, sender.uuidString)
        model.orchestrationRunID = "a-new-run"
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty, "Prior dispatcher identity must not leak into a later run")
    }

    func testOwnerRecordsRejectForeignSessionWorkspaceRunTransportAndRemovedProfiles() {
        let model = foregroundTeam()
        model.blocks = [ChatBlock(kind: .tool, tool: ToolPayload(toolID: "tool", tool: "read_file", summary: "Read", detail: "",
            status: .awaitingPermission, requestID: "request"))]
        let original: [String: Any] = ["type": "permission_request", "session_id": "team-session", "run_id": "run",
                                      "request_id": "request", "agent_id": receiver.uuidString]
        for (key, value) in [("session_id", "another-session"), ("workspace_root", "/tmp/another-project"),
                             ("run_id", "another-run"), ("agent_id", UUID().uuidString)] {
            var event = original; event[key] = value
            model.recordAgentWorldRequestOwner(event)
            XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty, key)
        }
        model.recordAgentWorldRequestOwner(original, source: BackendService(baseURL: URL(string: "http://127.0.0.1:1")!))
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
        model.recordAgentWorldRequestOwner(original)
        XCTAssertEqual(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.first?.agentID, receiver.uuidString)
        model.orchestrationRunID = "another-run"
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
        model.orchestrationRunID = "run"
        model.agentProfiles = model.agentProfiles.filter { $0.id != receiver }
        XCTAssertTrue(model.agentWorldSignals(workspace: "/tmp/crew-project").attention.isEmpty)
    }
}
