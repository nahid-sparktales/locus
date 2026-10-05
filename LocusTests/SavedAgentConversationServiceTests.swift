import Foundation
import XCTest
@testable import Locus

@MainActor
final class SavedAgentConversationServiceTests: XCTestCase {
    func testCanonicalServiceCreatesAndRetainsIdentityWithoutAnyWorldInstalled() async throws {
        let service = SavedAgentConversationService()
        let profile = AgentProfile(name: "Native agent", model: "native:1")
        var creations = 0
        service.configure(defaults: nil, state: { _ in .init() }, create: { _, _ in
            creations += 1
            try await Task.sleep(for: .milliseconds(20))
            return "canonical-chat"
        }, dispatch: { _, _, _, _, _ in })
        async let first = service.conversation(workspace: "/tmp/project", profile: profile)
        async let second = service.conversation(workspace: "/tmp/project", profile: profile)
        let results = try await [first, second]
        XCTAssertEqual(results, ["canonical-chat", "canonical-chat"])
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(service.boundProfileID(for: "canonical-chat"), profile.id)
        XCTAssertTrue(service.resetCurrentConversation(workspace: "/tmp/project", profileID: profile.id))
        XCTAssertEqual(service.boundProfileID(for: "canonical-chat"), profile.id, "History remains canonical after selection reset")
    }

    func testQueuedNativeWorkAndRemovalGuardDoNotRequirePluginLifecycle() async throws {
        let service = SavedAgentConversationService()
        let profile = AgentProfile(name: "Agent", model: "native:1")
        var dispatched = 0
        service.configure(defaults: nil, state: { _ in .init() }, create: { _, _ in "chat" }, dispatch: { _, _, _, _, _ in
            try await Task.sleep(for: .milliseconds(25))
            dispatched += 1
        })
        service.bind("chat", workspace: "/tmp/project", profileID: profile.id)
        try service.enqueue(text: "User-approved native task", mode: .work, sessionID: "chat", workspace: "/tmp/project", profileID: profile.id)
        XCTAssertTrue(service.hasPendingWork(profileID: profile.id))
        XCTAssertFalse(service.resetCurrentConversation(workspace: "/tmp/project", profileID: profile.id))
        for _ in 0..<50 where service.hasPendingWork(profileID: profile.id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dispatched, 1)
        XCTAssertFalse(service.hasPendingWork(profileID: profile.id))
    }

    func testOrdinaryAppUsesCanonicalServiceWhenExtensionCatalogIsEmpty() {
        let app = AppModel(startImmediately: false)
        app.extensionsModel.extensions = .empty
        let profile = AgentProfile(name: "Native", model: "native:1")
        app.agentProfiles = [profile]
        app.savedAgentConversations.bind("historic-agent-chat", workspace: "/tmp/project", profileID: profile.id)
        XCTAssertNil(app.agentWorld.activeScreen)
        XCTAssertTrue(app.agentWorld.availableScreens.isEmpty)
        XCTAssertEqual(app.savedAgentProfileID(for: "historic-agent-chat"), profile.id)
        XCTAssertNoThrow(try app.savedAgentProfileDispatch(profileID: profile.id, mode: .work))
        XCTAssertEqual(app.savedAgentConversationState("historic-agent-chat").status, "idle")
    }
}
