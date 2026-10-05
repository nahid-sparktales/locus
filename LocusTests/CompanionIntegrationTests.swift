import XCTest
@testable import Locus

@MainActor
final class CompanionIntegrationTests: XCTestCase {
    func testExploreCommitsIdentityWithoutChangingTheCurrentWork() throws {
        let app = AppModel(startImmediately: false)
        app.draftText = "An unsent private draft"
        let session = app.currentSessionID
        let workspace = app.workspacePath
        let route = app.selectedModel
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settings = try encoder.encode(app.settings)
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("  みどり 🌿  ")
        let appearance = CompanionAppearance(character: .frog, palette: .violet, accessory: .glasses)
        app.onboarding.selectCompanionAppearance(appearance)
        app.finishCompanionSetup(startChat: false)

        let id = try XCTUnwrap(app.agentTeamsModel.primaryCompanionID)
        let profile = try XCTUnwrap(app.agentProfiles.first { $0.id == id })
        XCTAssertEqual(profile.name, "みどり 🌿")
        XCTAssertEqual(app.agentTeamsModel.agentAppearances[id], appearance)
        XCTAssertEqual(app.currentSessionID, session)
        XCTAssertEqual(app.workspacePath, workspace)
        XCTAssertEqual(app.draftText, "An unsent private draft")
        XCTAssertEqual(app.selectedModel, route)
        XCTAssertEqual(try encoder.encode(app.settings), settings)
        XCTAssertFalse(app.isBusy)
        XCTAssertNil(app.onboarding.progress.run)
        XCTAssertFalse(app.onboarding.progress.firstTaskCompleted)
        XCTAssertFalse(app.onboarding.showsCompanionSetup)
        XCTAssertTrue(app.onboarding.isPresented)
    }

    func testOfflineStartSelectsCanonicalProfileAndRemainsRetryable() throws {
        let app = AppModel(startImmediately: false)
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("Mochi")
        app.finishCompanionSetup(startChat: true)
        let id = try XCTUnwrap(app.agentTeamsModel.primaryCompanionID)
        XCTAssertNil(app.savedAgentOverviewID)
        XCTAssertEqual(app.sidebarDestination, .companion)
        XCTAssertEqual(app.emptySidebarDestination, .companion)
        XCTAssertEqual(app.selectedSavedAgentID, id)
        XCTAssertFalse(app.onboarding.isPresented)
        XCTAssertFalse(app.isBusy)
        XCTAssertFalse(app.pendingSessionReset)
        XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty)
        app.finishCompanionSetup(startChat: true)
        XCTAssertEqual(app.agentProfiles.filter { $0.id == id }.count, 1)
        XCTAssertEqual(app.agentTeamsModel.primaryCompanionID, id)
    }

    func testLinkingExistingProfilePreservesRouteAccessMemoryAndCustomPortrait() throws {
        let app = AppModel(startImmediately: false)
        var profile = AgentProfile(name: "Existing", model: "exact-model", instructions: "Keep these instructions",
            accessCeiling: .workspaceWrite, workspacePreferences: AgentWorkspacePreferences())
        profile.behavior?.memoryPolicy.crossChatContextEnabled = false
        app.agentProfiles = [profile]
        let before = try XCTUnwrap(app.agentProfiles.first)
        app.onboarding.beginCompanionSetup()
        app.onboarding.selectExistingCompanion(profile.id)
        app.onboarding.setCompanionName("Must not replace the name")
        app.onboarding.selectCompanionAppearance(.init(character: .fox))
        app.finishCompanionSetup(startChat: false)
        XCTAssertEqual(app.agentProfiles, [before])
        XCTAssertEqual(app.agentTeamsModel.primaryCompanionID, profile.id)
        XCTAssertNil(app.agentTeamsModel.agentAppearances[profile.id])
        XCTAssertNil(app.onboarding.progress.run)
    }

    func testFailedNameValidationNeverCreatesOrLinksProfile() {
        let app = AppModel(startImmediately: false)
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("Bad\u{0000}name")
        app.finishCompanionSetup(startChat: false)
        XCTAssertTrue(app.agentProfiles.isEmpty)
        XCTAssertNil(app.agentTeamsModel.primaryCompanionID)
        XCTAssertNotNil(app.onboarding.error)
        XCTAssertNotEqual(app.onboarding.companion.status, .completed)
    }

    func testCompanionTabBeforeSetupPreservesRunningWorkAndDraft() {
        let app = AppModel(startImmediately: false)
        let work = SessionSummary(id: "work", name: "work", preview: "", mtime: 1, size: 0, cwd: "/tmp")
        app.sessions = [work]
        app.installTranscriptSession(work.id, blocks: [ChatBlock(kind: .assistant, text: "Private work result")])
        app.draftText = "Unsent work draft"
        app.isBusy = true
        app.switchSidebarDestination(.companion)
        XCTAssertEqual(app.sidebarDestination, .companion)
        XCTAssertEqual(app.emptySidebarDestination, .companion)
        XCTAssertEqual(app.currentSessionID, work.id)
        XCTAssertEqual(app.draftText, "Unsent work draft")
        XCTAssertTrue(app.agentProfiles.isEmpty)
        XCTAssertNil(app.activeTranscriptLoad)
        XCTAssertFalse(app.companionConversationIsSelected)
        app.switchSidebarDestination(.ask)
        XCTAssertEqual(app.currentSessionID, work.id)
        XCTAssertEqual(app.draftText, "Unsent work draft")
        XCTAssertEqual(app.blocks.last?.text, "Private work result")
        XCTAssertTrue(app.isBusy)
        XCTAssertNil(app.emptySidebarDestination)
    }

    func testCompanionChatsExcludeOtherProjectsAgentsAutomationsAndArchives() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture")
        let other = AgentProfile(name: "Other", model: "fixture")
        app.agentProfiles = [profile, other]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        func chat(_ id: String, owner: UUID, workspace: String = "/tmp", archived: Bool = false,
                  trigger: String? = nil) -> SessionSummary {
            SessionSummary(id: id, name: id, preview: "", mtime: 1, size: 0, archived: archived,
                cwd: workspace, agentTriggerID: trigger, agentProfileID: owner.uuidString)
        }
        app.sessions = [chat("owned", owner: profile.id), chat("private", owner: profile.id, workspace: "/var/tmp"),
            chat("other-agent", owner: other.id), chat("archived", owner: profile.id, archived: true),
            chat("automation", owner: profile.id, trigger: "scheduled")]
        XCTAssertEqual(app.companionChats(in: "/tmp").map(\.id), ["owned"])
        XCTAssertEqual(app.companionChats(in: "/var/tmp").map(\.id), ["private"])
        XCTAssertNotEqual(app.companionSessionKey(workspace: "/tmp"), app.companionSessionKey(workspace: "/var/tmp"))
    }

    func testCompanionWorkspaceHonorsNewSelectionAndExplicitWorktreeRoot() {
        let app = AppModel(startImmediately: false)
        let old = SessionSummary(id: "old", name: "old", preview: "", mtime: 1, size: 0,
            cwd: "/old/project", workspaceRoot: "/old/project", executionPath: "/tmp/worktree")
        app.sessions = [old]
        app.installTranscriptSession(old.id, blocks: [])
        app.initialWorkspacePath = "/new/project"
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath("/new/project"),
                       "Old transcript metadata must not override the selected project")
        app.initialWorkspacePath = "/tmp/worktree"
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath("/old/project"))
        app.pendingWorkspacePath = "/newer/project"
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath("/newer/project"),
                       "A pending workspace selection wins even before its transcript loads")
    }

    func testClickingActiveCompanionRowPreservesRunApprovalAndDraft() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture")
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let chat = SessionSummary(id: "ours", name: "ours", preview: "", mtime: 1, size: 0,
            cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions = [chat]
        app.initialWorkspacePath = "/tmp"
        app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .assistant, text: "In progress")])
        app.draftText = "Unsent companion follow-up"
        app.isBusy = true
        app.handleEventForTesting([
            "type": "permission_request", "id": "tool-1", "tool": "write_file", "request_id": "approval-1",
        ])
        XCTAssertTrue(app.hasPendingPermission)
        let blockIDs = app.blocks.map(\.id)
        app.openCompanionChat(chat)
        XCTAssertTrue(app.companionConversationIsSelected)
        XCTAssertTrue(app.isBusy)
        XCTAssertTrue(app.hasPendingPermission)
        XCTAssertEqual(app.activePermissionRequest?.requestID, "approval-1")
        XCTAssertEqual(app.blocks.map(\.id), blockIDs)
        XCTAssertEqual(app.draftText, "Unsent companion follow-up")
        XCTAssertNil(app.activeTranscriptLoad)
    }

    func testCompanionActionsDoNotSupersedeCurrentTranscriptLoad() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture")
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let chat = SessionSummary(id: "ours", name: "ours", preview: "", mtime: 1, size: 0,
            cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions = [chat]
        app.initialWorkspacePath = "/tmp"
        app.agentRuntimePhase = .online
        let ownership = app.beginTranscriptSessionLoad(chat.id)
        app.draftText = "Loading draft"
        app.openCompanionChat(chat)
        app.openCompanionDestination()
        XCTAssertTrue(app.companionConversationIsSelected)
        XCTAssertEqual(app.transcriptInputState, .loading)
        XCTAssertTrue(app.transcriptPresentation.ownsSessionLoad(ownership))
        XCTAssertEqual(app.draftText, "Loading draft")
        XCTAssertNil(app.activeTranscriptLoad, "Explicit navigation must not start a competing load")
    }

    func testAlreadySelectedCompanionChatDoesNotReloadOrLoseDraft() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture")
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let chat = SessionSummary(id: "ours", name: "ours", preview: "", mtime: 1, size: 0,
            cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions = [chat]
        app.initialWorkspacePath = "/tmp"
        app.installTranscriptSession(chat.id, blocks: [])
        app.draftText = "Companion draft"
        app.isBusy = true
        app.openCompanionDestination()
        XCTAssertTrue(app.companionConversationIsSelected)
        XCTAssertEqual(app.draftText, "Companion draft")
        XCTAssertNil(app.activeTranscriptLoad)
        XCTAssertNil(app.savedAgentOverviewID)
        XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty)
        XCTAssertEqual(app.lastSidebarSessionIDs[app.companionSessionKey(workspace: "/tmp")], chat.id)
    }
}
