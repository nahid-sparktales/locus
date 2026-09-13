import Foundation
import XCTest
@testable import Locus

final class SavedAgentTests: XCTestCase {
    func testExistingAgentProfileRestoresAfterServicePolicyUpgrade() throws {
        let json = #"{"route":{"kind":"account","accountID":"11111111-2222-3333-4444-555555555555"},"capabilityTags":[],"accessCeiling":"computer_control","tokenLimit":64000,"name":"Existing agent","instructions":"Review evidence","behavior":{"custom_instructions":"Review evidence","version":1,"mode_instructions":{"grill":"","work":"","plan":"","ask":""},"memory_policy":{"scopes":["personal","workspace","agent"],"max_automatic_memories":8,"recall_enabled":true,"proposals_enabled":true,"max_automatic_tokens":1200,"search_enabled":true,"cross_chat_context_enabled":true,"max_automatic_context_snapshots":2,"max_automatic_context_tokens":1200},"runtime_policy":{},"display_name":"Existing agent","response_style":{"cite_evidence":true,"tone":"balanced","use_markdown":true,"verbosity":"balanced"},"self_description":"A specialist for delegated tasks.","capability_policy":{"mcp":true,"network":true,"workspace_write":true,"computer_control":true,"workspace_read":true,"shell":true,"simulator_control":true}},"role":"generalist","mcpPolicy":{"prompts":[],"tools":[],"resources":[],"server_ids":[]},"metering":"self_hosted","id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","timeoutSeconds":600,"model":"fixture"}"#
        let profile = try JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
        let suite = "saved-agent-restore-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(("[" + json + "]").utf8), forKey: AgentTeamStore.profilesKey)
        XCTAssertEqual(AgentTeamStore.loadProfiles(from: defaults).map(\.name), ["Existing agent"])
        XCTAssertEqual(profile.name, "Existing agent")
        XCTAssertEqual(profile.accessCeiling, .computerControl)
        XCTAssertEqual(profile.mcpPolicy?.allowsAllServices, false)
    }

    func testNewWritableAgentsDefaultToAllServicesWithoutUndoingOptOuts() {
        for ceiling in [AgentAccessCeiling.workspaceWrite, .computerControl] {
            var profile = AgentProfile(name: "Test", model: "fixture", accessCeiling: ceiling)
            profile.applyNewAgentServiceDefaults()
            XCTAssertTrue(profile.mcpPolicy?.allowsAllServices == true)
            profile.mcpPolicy?.setServer("mail", enabled: false)
            profile.applyNewAgentServiceDefaults()
            XCTAssertFalse(profile.mcpPolicy?.allowsServer("mail") == true)
            profile.mcpPolicy = MCPAgentPolicy()
            profile.applyNewAgentServiceDefaults()
            XCTAssertFalse(profile.mcpPolicy?.allowsAllServices == true)
        }
        var readOnly = AgentProfile(name: "Review", model: "fixture")
        readOnly.applyNewAgentServiceDefaults()
        XCTAssertNil(readOnly.mcpPolicy)
    }

    @MainActor
    func testWorldConversationUsesSavedAgentChatFlowAndSidebarOwnership() async throws {
        SavedAgentURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SavedAgentURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: config))
        let model = AppModel(startImmediately: false, backendOverride: backend)
        let profile = AgentProfile(name: "World Agent", model: "fixture")
        model.agentProfiles = [profile]
        model.configureAgentWorld()
        let firstID = try await model.agentWorld.conversation(workspace: "/tmp", profile: profile)
        XCTAssertEqual(model.savedAgentChats(profile.id).first?.id, firstID)
        XCTAssertEqual(model.savedAgentChats(profile.id).first?.displayTitle, "Chat 1")
        XCTAssertEqual(model.agentTeamsModel.agentProfiles.first?.id, profile.id)
        let next = try await model.createSavedAgentConversation(profile, workspace: "/tmp")
        let worldID = try await model.agentWorld.conversation(workspace: "/tmp", profile: profile)
        XCTAssertEqual(worldID, next.id)
        XCTAssertEqual(model.savedAgentChats(profile.id).count, 2)
        XCTAssertEqual(model.agentWorld.residents.map(\.id), [profile.id.uuidString])
        model.knowledge.cancelAll()
        model.agentInstructions.cancelAll()
        model.toastCenter.cancelPendingDismissal()
    }

    func testServiceDefaultsRoundTripWithIndividualOptOutsAndLegacyPolicy() throws {
        var policy = MCPAgentPolicy.allConnected
        XCTAssertTrue(policy.allowsServer("new-extension"))
        policy.setServer("mail", enabled: false)
        policy.excludedConnectionIDs = ["gmail"]
        policy.clamp()
        let restored = try JSONDecoder().decode(MCPAgentPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.allowsServer("mail"))
        XCTAssertTrue(restored.allowsServer("new-extension"))
        XCTAssertEqual(restored.excludedConnectionIDs, ["gmail"])
        policy.setServer("mail", enabled: true)
        XCTAssertTrue(policy.allowsServer("mail"))
        let legacy = try JSONDecoder().decode(MCPAgentPolicy.self,
            from: Data(#"{"server_ids":["mail"],"tools":["read"],"resources":[],"prompts":[]}"#.utf8))
        XCTAssertTrue(legacy.allowsServer("mail"))
        XCTAssertFalse(legacy.allowsServer("new-extension"))
    }

    func testProfileGroupsOwnManualAndAutomationChatsWithoutDuplicateParents() {
        let profile = AgentProfile(name: "Bob", model: "fixture")
        let chats = [
            SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0,
                           title: "Chat 1", agentProfileID: profile.id.uuidString.lowercased()),
            SessionSummary(id: "event", name: "event", preview: "", mtime: 2, size: 0,
                           title: "Price watch", agentTriggerID: "price", agentProfileID: profile.id.uuidString,
                           agentKind: "event", agentPrimary: true),
        ]
        var trigger = EventTrigger(id: "price", name: "Price watch", connectionID: "prices",
            targetSessionID: "event", instruction: "Review the quote", mode: .work, triggerKind: .price,
            filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [], enabled: true,
            createdAt: 1, updatedAt: 1)
        let groups = AgentSidebarCatalog.groups(definitions: [.trigger(trigger)], sessions: chats,
            query: "", showArchived: false, runningSessionIDs: [], profiles: [profile])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Bob")
        XCTAssertEqual(groups.first?.profileID, profile.id)
        XCTAssertEqual(groups.first?.totalChatCount, 2)
        XCTAssertFalse(groups.first?.needsAttention ?? true)
        XCTAssertTrue(chats[0].isAgentChat)
        XCTAssertEqual(chats[0].withOrganization(folderID: nil, sortOrder: 3).savedAgentProfileID, profile.id)
        trigger.lastError = "Quote source disconnected"
        let warning = AgentSidebarCatalog.groups(definitions: [.trigger(trigger)], sessions: chats,
            query: "", showArchived: false, runningSessionIDs: [], profiles: [profile])
        XCTAssertEqual(warning.count, 1)
        XCTAssertEqual(warning.first?.needsAttention, true)
        XCTAssertEqual(warning.first?.statusTitle, "Needs attention")
    }

    @MainActor
    func testProfileAndAutomationSelectionKeepTheCorrectInspectorContext() {
        let model = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Bob", model: "fixture")
        model.agentProfiles = [profile]
        let chat = SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0,
            title: "Chat 1", agentProfileID: profile.id.uuidString)
        model.sessions = [chat]
        model.installTranscriptSession(chat.id, blocks: [])
        let automation = AgentInspectorAgent(kind: .event, agentID: "inbox")
        model.selectAgent(automation)
        XCTAssertNil(model.selectedSavedAgentProfile)
        XCTAssertEqual(model.agentInspector.context, .agent(automation))
        model.agentInspector.show(.event(automation, deliveryID: "delivery"))
        model.inspectAgentChat(chat)
        XCTAssertEqual(model.selectedSavedAgentProfile?.id, profile.id)
        XCTAssertEqual(model.agentInspector.context, .fleet)
        XCTAssertNil(model.agentInspector.selectedAgent)
    }

    @MainActor
    func testChatCreationPersistsOwnershipAndKeepsEarlierChatsBound() async throws {
        SavedAgentURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SavedAgentURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!,
            session: URLSession(configuration: config))
        let model = AppModel(startImmediately: false, backendOverride: backend)
        let profile = AgentProfile(name: "Bob", model: "fixture")
        model.agentProfiles = [profile]
        model.installTranscriptSession("foreground", blocks: [])
        let first = try await model.createSavedAgentConversation(profile, workspace: "/tmp")
        let second = try await model.createSavedAgentConversation(profile, workspace: "/tmp")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.displayTitle, "Chat 1")
        XCTAssertEqual(second.displayTitle, "Chat 2")
        XCTAssertEqual(first.savedAgentProfileID, profile.id)
        XCTAssertEqual(second.savedAgentProfileID, profile.id)
        XCTAssertEqual(model.agentWorld.boundProfileID(for: first.id), profile.id)
        XCTAssertEqual(model.agentWorld.boundProfileID(for: second.id), profile.id)
        XCTAssertEqual(model.currentSessionID, "foreground")
        XCTAssertEqual(model.savedAgentChats(profile.id).count, 2)
        model.knowledge.cancelAll()
        model.agentInstructions.cancelAll()
        model.toastCenter.cancelPendingDismissal()
    }

    @MainActor
    func testProfileEditorWaitsUntilManagementDismisses() {
        let model = AppModel(startImmediately: false)
        model.configureAgentPresented = true
        model.presentNewAgent()
        XCTAssertFalse(model.configureAgentPresented)
        XCTAssertNotNil(model.pendingSavedAgentEditor)
        XCTAssertNil(model.savedAgentEditor)
        model.dismissConfigureAgent()
        XCTAssertNotNil(model.savedAgentEditor)
        XCTAssertNil(model.pendingSavedAgentEditor)
    }
}

private final class SavedAgentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var rows: [[String: Any]] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; rows = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var result: [String: Any] = [:]
        switch request.url!.path {
        case "/api/sessions/detached":
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let id = "saved-\(Self.rows.count + 1)"
            Self.rows.append(["id": id, "name": id, "preview": "", "mtime": Self.rows.count + 1,
                "size": 0, "title": body["title"] ?? "", "cwd": body["cwd"] ?? "/tmp",
                "agent_profile_id": body["agent_profile_id"] ?? ""])
            result = ["session_id": id]
        case "/api/sessions": result = ["sessions": Self.rows, "current": "foreground"]
        case "/api/models": result = ["models": ["fixture"]]
        case "/api/chat-folders": result = ["folders": []]
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
}
