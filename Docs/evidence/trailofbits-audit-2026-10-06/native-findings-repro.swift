import Foundation
import AppKit
@testable import Locus

final class ProbeProtocol: URLProtocol, @unchecked Sendable {
    static let owner = UUID()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let body: [String: Any] = ["id": "override-chat", "preview": "", "cwd": "/tmp", "agent_profile_id": Self.owner.uuidString, "messages": []]
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: configuration))
        let app = AppModel(startImmediately: false, backendOverride: backend)
        defer {
            app.companionPanel.loadTask?.cancel()
            app.knowledge.cancelAll()
            app.agentInstructions.cancelAll()
            app.toastCenter.cancelPendingDismissal()
        }
        var profile = AgentProfile(id: ProbeProtocol.owner, name: "Audit", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp/audit-project/subproject"))
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let isolated = SessionSummary(id: "isolated-chat", name: "Isolated", preview: "", mtime: 1, size: 0,
            cwd: "/tmp/audit-project", workspaceRoot: "/tmp/audit-project", executionPath: "/tmp/audit-checkout",
            environment: ["type": "worktree", "source_workspace": "/tmp/audit-project/subproject"], agentProfileID: profile.id.uuidString)
        app.sessions = [isolated]
        app.companionPanel.activate()
        print("N1 belongsToWorkspace=\(isolated.belongsToWorkspace(app.companionWorkspacePath)) companionChats=\(app.companionChats().count) selected=\(app.companionPanel.selectedSessionID ?? "nil")")
        precondition(isolated.belongsToWorkspace(app.companionWorkspacePath))
        precondition(app.companionChats().isEmpty)
        precondition(app.companionPanel.selectedSessionID == nil)

        profile.workspacePreferences = .init(defaultProjectPath: "/tmp")
        profile.route = .providerAccount(UUID())
        app.agentProfiles = [profile]
        app.sessions = [SessionSummary(id: "override-chat", name: "Override", preview: "", mtime: 1, size: 0, cwd: "/tmp", agentProfileID: profile.id.uuidString)]
        app.settings.agentChatModelSelections["override-chat"] = AgentChatModelSelection(profileID: profile.id, accountID: nil, model: "healthy-local")
        app.agentRuntimePhase = .online
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Authorized local task"
        let dispatch = try app.agentWorldProfileDispatch(profileID: profile.id, mode: .work, sessionID: "override-chat")
        print("N2 route=\(dispatch.provider)/\(dispatch.profile.model) selected=\(app.companionPanel.selectedSessionID ?? "nil") canSend=\(app.companionPanel.canSend) error=\(app.companionPanel.availabilityIssue ?? "nil")")
        precondition(dispatch.provider == "ollama" && dispatch.profile.model == "healthy-local")
        precondition(app.companionPanel.selectedSessionID == "override-chat")
        precondition(!app.companionPanel.canSend && app.companionPanel.availabilityIssue != nil)
    }
}
