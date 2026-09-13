import Foundation
import XCTest
@testable import Locus

@MainActor
final class AgentCrewChatTests: XCTestCase {
    private func profile(_ name: String, role: AgentRole = .generalist, tags: [String] = []) -> AgentProfile {
        AgentProfile(name: name, model: "fixture-only", role: role, capabilityTags: tags)
    }

    func testMultipleFullNameMentionsPreferLongestAndDoNotBroadcast() {
        let short = profile("Alex"), full = profile("Alex Smith"), other = profile("Mira Jones"), idle = profile("Idle")
        let decision = AgentCrewChatRouter.route("@Alex Smith and @\"mira jones\", compare these.", profiles: [short, idle, full, other])
        XCTAssertTrue(decision.canDispatch)
        XCTAssertTrue(decision.isExplicit)
        XCTAssertEqual(decision.recipients.map(\.id), [full.id, other.id])
    }

    func testDuplicateAndUnknownNamesRequireResolution() {
        let a = profile("Robin"), b = profile("Robin"), coder = profile("Coder", role: .implementer)
        let ambiguous = AgentCrewChatRouter.route("@Robin fix the bug", profiles: [a, b, coder])
        XCTAssertFalse(ambiguous.canDispatch)
        XCTAssertTrue(ambiguous.recipients.isEmpty)
        XCTAssertFalse(AgentCrewChatRouter.route("@Nobody fix the bug", profiles: [coder]).canDispatch)
        let exact = AgentCrewChatRouter.route("@{\(b.id.uuidString)} help", profiles: [a, b, coder])
        XCTAssertEqual(exact.recipients.map(\.id), [b.id])
        XCTAssertTrue(exact.canDispatch)
        XCTAssertEqual(AgentCrewChatRouter.mention(for: a, profiles: [a, b]), "@{\(a.id.uuidString)}")
    }

    func testEmailAndCodeAreNotAgentMentions() {
        let coder = profile("Coder", role: .implementer)
        let result = AgentCrewChatRouter.route("Fix the code for person@example.com using `@unknown` and ```@decorator```.", profiles: [coder])
        XCTAssertFalse(result.isExplicit)
        XCTAssertTrue(result.canDispatch)
        XCTAssertEqual(result.recipients.map(\.id), [coder.id])
    }

    func testMentionBoundariesAndRepeatedMentions() {
        let a = profile("Ann")
        XCTAssertFalse(AgentCrewChatRouter.route("@Anna help", profiles: [a]).canDispatch)
        XCTAssertEqual(AgentCrewChatRouter.route("@Ann, @Ann!", profiles: [a]).recipients.count, 1)
        XCTAssertFalse(AgentCrewChatRouter.route("@\"Ann help", profiles: [a]).canDispatch)
    }

    func testUnavailableExplicitAgentNeverFallsBack() {
        let a = profile("A", role: .implementer), b = profile("B", role: .implementer)
        let result = AgentCrewChatRouter.route("@A fix it", profiles: [a, b]) { $0.id == a.id ? "Connect this provider." : nil }
        XCTAssertFalse(result.canDispatch)
        XCTAssertEqual(result.recipients.map(\.id), [a.id])
        XCTAssertTrue(result.issues[0].contains("Connect this provider"))
    }

    func testCapabilityMatchIsSelectiveAndGeneralistHandlesConversation() {
        let swift = profile("Swift", tags: ["swift"]), ui = profile("UI", tags: ["design"]), general = profile("General")
        XCTAssertEqual(AgentCrewChatRouter.route("Explain this Swift expression", profiles: [general, ui, swift]).recipients.map(\.id), [swift.id])
        XCTAssertEqual(AgentCrewChatRouter.route("Hello everybody", profiles: [general, ui, swift]).recipients.map(\.id), [general.id])
        XCTAssertEqual(AgentCrewChatRouter.route("Calculate a mortgage", profiles: [general, ui, swift]).recipients.map(\.id), [general.id])
    }

    func testOnlyExplicitComplementaryIntentAddsOneHelper() {
        let code = profile("Code", role: .implementer), test = profile("QA", role: .tester), test2 = profile("QA2", role: .tester)
        let solo = AgentCrewChatRouter.route("Fix this implementation", profiles: [test, code, test2])
        XCTAssertEqual(solo.recipients.map(\.id), [code.id])
        let pair = AgentCrewChatRouter.route("Implement it and test the regression", profiles: [test, code, test2])
        XCTAssertEqual(pair.recipients.count, 2)
        XCTAssertTrue(pair.recipients.contains(where: { $0.id == code.id }))
        XCTAssertEqual(Set(pair.recipients.map(\.id)), Set(AgentCrewChatRouter.route("Implement it and test the regression", profiles: [code, test2, test]).recipients.map(\.id)))
    }

    func testReplyExtractionUsesTurnBoundaryNotOldOrLaterOutput() {
        let id = UUID()
        let blocks = [ChatBlock(kind: .user, text: "old"), ChatBlock(kind: .assistant, text: "old reply"),
                      ChatBlock(kind: .user, text: "[Crew turn \(id.uuidString)]\nrequest"),
                      ChatBlock(kind: .assistant, text: "Actual commentary"), ChatBlock(kind: .tool, text: "tool secret"),
                      ChatBlock(kind: .assistant, text: "Actual answer"),
                      ChatBlock(kind: .user, text: "later native turn"), ChatBlock(kind: .assistant, text: "later reply")]
        XCTAssertEqual(AgentCrewChatModel.replyText(in: blocks, messageID: id), "Actual commentary\n\nActual answer")
        XCTAssertEqual(AgentCrewChatModel.replyText(in: blocks, messageID: UUID()), "")
        XCTAssertEqual(AgentCrewChatModel.replyBlocks(in: blocks, messageID: id).map(\.text),
                       ["Actual commentary", "tool secret", "Actual answer"])
    }

    func testAutomaticTurnsKeepToolsAvailableForConversationAndWork() async throws {
        let fixture = Fixture(profiles: [profile("Luffy")])
        let model = fixture.model()
        model.draft = "hey"
        model.submit()
        try await settle(model)
        model.draft = "Read the project files and explain what needs fixing"
        model.submit()
        try await settle(model)
        XCTAssertEqual(fixture.dispatched.count, 2)
        XCTAssertTrue(fixture.dispatched.allSatisfy { $0.mode == .work })
        XCTAssertEqual(Set(fixture.dispatched.map(\.sessionID)).count, 1)
        XCTAssertEqual(model.messages.filter { $0.role == .user }.map(\.text),
                       ["hey", "Read the project files and explain what needs fixing"])
        XCTAssertFalse(model.visibleBlocks(for: try XCTUnwrap(model.messages.last)).isEmpty)
    }

    func testUnmentionedFollowupContinuesWithPreviousAgentWithoutBroadcast() async throws {
        let fixture = Fixture(profiles: [profile("A"), profile("B")])
        let model = fixture.model()
        model.draft = "@B hello"; model.submit(); try await settle(model)
        model.draft = "Tell me more"; model.submit(); try await settle(model)
        XCTAssertEqual(fixture.dispatched.map(\.profileID), [fixture.profiles[1].id, fixture.profiles[1].id])
        XCTAssertEqual(model.conversationWorkspaces, [fixture.path])
    }

    func testSharedLedgerOnlyDispatchesTaggedProfileAndMirrorsRealText() async throws {
        let fixture = Fixture(profiles: [profile("Navigator"), profile("Shipwright")])
        let model = fixture.model()
        model.draft = "@Navigator find the route"
        model.submit()
        try await settle(model)
        XCTAssertEqual(model.members.count, 2)
        XCTAssertEqual(fixture.dispatched.count, 1)
        XCTAssertEqual(fixture.dispatched[0].profileID, fixture.profiles[0].id)
        XCTAssertEqual(model.messages.last?.text, "Actual answer from Navigator")
        XCTAssertEqual(model.messages.last?.status, .completed)
        XCTAssertEqual(model.boundProfileID(for: try XCTUnwrap(model.messages.last?.sessionID)), fixture.profiles[0].id)
        XCTAssertTrue(model.handoffs(for: fixture.path).isEmpty)
    }

    func testSharedActualContextCreatesHandoffOnlyAfterAcceptedDispatch() async throws {
        let fixture = Fixture(profiles: [profile("Navigator"), profile("Shipwright")])
        let model = fixture.model()
        model.draft = "@Navigator locate the damaged mast"
        model.submit()
        try await settle(model)
        let source = try XCTUnwrap(model.messages.last)
        model.draft = "@Shipwright use that finding"
        model.submit()
        try await settle(model)
        XCTAssertEqual(fixture.dispatched.count, 2)
        XCTAssertTrue(fixture.dispatched[1].prompt.contains("Actual answer from Navigator"))
        XCTAssertTrue(fixture.dispatched[1].prompt.contains("Navigator [agent]"))
        let transfer = try XCTUnwrap(model.handoffs(for: fixture.path).first)
        XCTAssertEqual(transfer.fromAgentID, fixture.profiles[0].id)
        XCTAssertEqual(transfer.toAgentID, fixture.profiles[1].id)
        XCTAssertEqual(transfer.sourceMessageID, source.id)
        XCTAssertEqual(transfer.recipientSessionID, fixture.dispatched[1].sessionID)
    }

    func testFailedDispatchDoesNotCreateHandoffOrFabricateReply() async throws {
        let fixture = Fixture(profiles: [profile("A"), profile("B")])
        let model = fixture.model()
        model.draft = "@A inspect"; model.submit(); try await settle(model)
        fixture.reject = true
        model.draft = "@B follow up"; model.submit(); try await settle(model)
        XCTAssertEqual(model.messages.last?.status, .failed)
        XCTAssertEqual(model.messages.last?.text, "")
        XCTAssertTrue(model.handoffs(for: fixture.path).isEmpty)
    }

    func testWorkspaceSwitchKeepsRunningReplyAndHistoryInOriginalLedger() async throws {
        let fixture = Fixture(profiles: [profile("A")])
        fixture.hold = true
        let model = fixture.model()
        model.draft = "@A inspect"; model.submit()
        try await waitUntil { fixture.dispatched.count == 1 }
        let original = fixture.path
        model.activate(workspace: "/tmp/crew-other-workspace")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNotNil(model.activity(for: fixture.profiles[0].id, workspace: original))
        fixture.finishAll()
        try await waitUntil { model.activity(for: fixture.profiles[0].id, workspace: original) == nil }
        XCTAssertTrue(model.messages.isEmpty)
        model.activate(workspace: original)
        XCTAssertEqual(model.messages.last?.text, "Actual answer from A")
        XCTAssertEqual(model.messages.last?.status, .completed)
    }

    func testPersistenceReconcilesUnfinishedReplyWithoutRedispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true
        let first = fixture.model(storage: directory)
        first.draft = "@A inspect"; first.submit()
        try await waitUntil { fixture.dispatched.count == 1 && first.messages.last?.accepted == true }
        let secondFixture = Fixture(profiles: fixture.profiles)
        let restored = secondFixture.model(storage: directory)
        try await settle(restored)
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.messages.last?.status, .interrupted)
        XCTAssertTrue(secondFixture.dispatched.isEmpty)
        XCTAssertEqual(restored.messages.last?.text, "")
        first.stopReply(messageID: try XCTUnwrap(first.messages.last?.id))
    }

    func testStoppedQueuedReplyIsNeverSentAndBusyReplyUsesRealStop() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true
        let model = fixture.model()
        model.draft = "@A first"; model.submit()
        try await waitUntil { fixture.dispatched.count == 1 && model.messages.last?.accepted == true }
        let first = try XCTUnwrap(model.messages.last)
        model.draft = "@A second"; model.submit()
        model.stopReply(messageID: try XCTUnwrap(model.messages.last?.id))
        model.stopReply(messageID: first.id)
        try await settle(model)
        XCTAssertEqual(fixture.dispatched.count, 1)
        XCTAssertEqual(fixture.stopped, [first.sessionID!])
        XCTAssertEqual(model.messages.filter { $0.role == .agent }.map(\.status), [.cancelled, .cancelled])
    }

    func testStopDuringAdmissionStopsThatSessionBeforeAcceptance() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true; fixture.awaitAdmission = true
        let model = fixture.model()
        model.draft = "@A inspect"; model.submit()
        try await waitUntil { fixture.admission != nil }
        let reply = try XCTUnwrap(model.messages.last)
        XCTAssertFalse(reply.accepted)
        model.stopReply(messageID: reply.id)
        try await settle(model)
        XCTAssertEqual(fixture.stopped, [try XCTUnwrap(reply.sessionID)])
        XCTAssertEqual(model.messages.last?.status, .cancelled)
        XCTAssertEqual(model.messages.last?.text, "")
    }

    func testStoppingQueuedReplyDoesNotStopEarlierAgentTurn() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true
        let model = fixture.model()
        model.draft = "@A first"; model.submit()
        try await waitUntil { model.messages.last?.accepted == true }
        let first = try XCTUnwrap(model.messages.last)
        model.draft = "@A second"; model.submit()
        model.stopReply(messageID: try XCTUnwrap(model.messages.last?.id))
        XCTAssertTrue(fixture.stopped.isEmpty)
        XCTAssertEqual(fixture.states[first.sessionID!]?.busy, true)
        fixture.finishAll(); try await settle(model)
        XCTAssertEqual(fixture.dispatched.count, 1)
    }

    func testRemovedAgentDoesNotWaitForeverBehindBusySession() async throws {
        let fixture = Fixture(profiles: [profile("A")])
        let session = fixture.path + "/session-" + fixture.profiles[0].id.uuidString
        fixture.states[session] = .init(status: "working", busy: true)
        let model = fixture.model()
        model.draft = "@A inspect"; model.submit()
        try await waitUntil { model.messages.last?.sessionID != nil }
        fixture.profiles = []
        try await settle(model)
        XCTAssertEqual(model.messages.last?.status, .failed)
        XCTAssertTrue(fixture.dispatched.isEmpty)
        XCTAssertTrue(fixture.stopped.isEmpty)
    }

    func testSavedSessionMustMatchItsProfileAndWorkspace() throws {
        let id = UUID()
        let json = "{\"id\":\"session-a\",\"agent_profile_id\":\"\(id.uuidString)\",\"cwd\":\"/tmp/crew-a\"}"
        let identity = try JSONDecoder().decode(AgentCrewChatSessionIdentity.self, from: Data(json.utf8))
        XCTAssertTrue(identity.matches(sessionID: "session-a", profileID: id, workspace: "/tmp/crew-a/./"))
        XCTAssertFalse(identity.matches(sessionID: "session-b", profileID: id, workspace: "/tmp/crew-a"))
        XCTAssertFalse(identity.matches(sessionID: "session-a", profileID: UUID(), workspace: "/tmp/crew-a"))
        XCTAssertFalse(identity.matches(sessionID: "session-a", profileID: id, workspace: "/tmp/crew-b"))
        let unbound = try JSONDecoder().decode(AgentCrewChatSessionIdentity.self, from: Data("{\"id\":\"session-a\",\"cwd\":\"/tmp/crew-a\"}".utf8))
        XCTAssertFalse(unbound.matches(sessionID: "session-a", profileID: id, workspace: "/tmp/crew-a"))
    }

    func testQueuedFollowupDoesNotHideActualPermissionRequest() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true
        let model = fixture.model()
        model.draft = "@A first"; model.submit()
        try await waitUntil { model.messages.last?.accepted == true }
        let session = try XCTUnwrap(model.messages.last?.sessionID)
        fixture.states[session]?.status = "needs_attention"
        fixture.states[session]?.detail = "Approve the requested tool."
        model.draft = "@A next"; model.submit()
        XCTAssertEqual(model.activity(for: fixture.profiles[0].id, workspace: fixture.path)?.status, "needs_attention")
        for message in model.messages where message.role == .agent { model.stopReply(messageID: message.id) }
    }

    func testStoppingEarlierReplyNeverInterruptsLaterNativeTurn() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true
        let model = fixture.model()
        model.draft = "@A inspect"; model.submit()
        try await waitUntil { model.messages.last?.accepted == true }
        let reply = try XCTUnwrap(model.messages.last), session = try XCTUnwrap(reply.sessionID)
        fixture.states[session]?.blocks.append(ChatBlock(kind: .assistant, text: "Finished crew answer"))
        fixture.states[session]?.blocks.append(ChatBlock(kind: .user, text: "Later native task"))
        fixture.states[session]?.blocks.append(ChatBlock(kind: .assistant, text: "Later output"))
        model.stopReply(messageID: reply.id)
        XCTAssertTrue(fixture.stopped.isEmpty)
        XCTAssertEqual(model.messages.last?.status, .completed)
        XCTAssertEqual(model.messages.last?.text, "Finished crew answer")
        XCTAssertEqual(fixture.states[session]?.busy, true)
    }

    func testObserverFinishesEarlierReplyWhileLaterNativeTurnRuns() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.hold = true
        let model = fixture.model()
        model.draft = "@A inspect"; model.submit()
        try await waitUntil { model.messages.last?.accepted == true }
        let session = try XCTUnwrap(model.messages.last?.sessionID)
        fixture.states[session]?.blocks.append(ChatBlock(kind: .assistant, text: "Crew answer"))
        fixture.states[session]?.blocks.append(ChatBlock(kind: .user, text: "Next native task"))
        try await settle(model)
        XCTAssertEqual(model.messages.last?.status, .completed)
        XCTAssertEqual(model.messages.last?.text, "Crew answer")
        XCTAssertTrue(fixture.stopped.isEmpty)
    }

    func testPastedLegacyPromptWrapperKeepsReplyIdentity() async throws {
        let fixture = Fixture(profiles: [profile("A")]); fixture.stripLegacyWrapper = true
        let model = fixture.model()
        model.draft = "@A review this prompt:\nUser request:\nExplain the result."
        model.submit(); try await settle(model)
        XCTAssertEqual(model.messages.last?.status, .completed)
        XCTAssertEqual(model.messages.last?.text, "Actual answer from A")
    }

    private func settle(_ model: AgentCrewChatModel) async throws { try await waitUntil { model.pendingReplyCount == 0 } }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Crew chat did not reach the expected state")
    }

    @MainActor
    private final class Fixture {
        struct Dispatch { let sessionID: String; let profileID: UUID; let prompt: String; let mode: WorkMode }
        var profiles: [AgentProfile]
        let path = "/tmp/crew-chat-fixture"
        var states: [String: AgentWorldConversationState] = [:]
        var dispatched: [Dispatch] = []
        var stopped: [String] = []
        var hold = false
        var reject = false
        var stripLegacyWrapper = false
        var awaitAdmission = false
        var admission: CheckedContinuation<Void, Never>?
        init(profiles: [AgentProfile]) { self.profiles = profiles }
        func model(storage: URL? = nil) -> AgentCrewChatModel {
            let model = AgentCrewChatModel(storageDirectory: storage)
            model.configure(profiles: { self.profiles }, workspace: { self.path }, availability: { _ in nil },
                            state: { self.states[$0] ?? .init() },
                            create: { workspace, profile in workspace + "/session-" + profile.id.uuidString }, load: { _ in },
                            dispatch: { session, _, profileID, text, mode in
                if self.reject { throw AgentWorldError.unavailable("Fixture rejected this dispatch") }
                self.dispatched.append(.init(sessionID: session, profileID: profileID, prompt: text, mode: mode))
                var blocks = self.states[session]?.blocks ?? []
                let displayed: String
                if self.stripLegacyWrapper, let range = text.range(of: "User request:\n", options: .backwards) {
                    displayed = String(text[range.upperBound...])
                } else { displayed = text }
                blocks.append(ChatBlock(kind: .user, text: displayed))
                if !self.hold {
                    blocks.append(ChatBlock(kind: .assistant, text: "Actual answer from " + self.profiles.first(where: { $0.id == profileID })!.name))
                }
                self.states[session] = .init(status: self.hold ? "working" : "completed", busy: self.hold, blocks: blocks)
                if self.awaitAdmission { await withCheckedContinuation { self.admission = $0 } }
            }, stop: { session in
                self.stopped.append(session); self.states[session]?.busy = false
                self.admission?.resume(); self.admission = nil
            }, open: { _, _ in })
            return model
        }
        func finishAll() {
            for record in dispatched {
                states[record.sessionID]?.blocks.append(ChatBlock(kind: .assistant, text: "Actual answer from " + profiles.first(where: { $0.id == record.profileID })!.name))
                states[record.sessionID]?.busy = false; states[record.sessionID]?.status = "completed"
            }
        }
    }
}
