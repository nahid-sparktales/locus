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
        let inspector = app.inspectorTab
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("Mochi")
        app.finishCompanionSetup(startChat: true)
        let id = try XCTUnwrap(app.agentTeamsModel.primaryCompanionID)
        XCTAssertNil(app.savedAgentOverviewID)
        XCTAssertEqual(app.sidebarDestination, .ask)
        XCTAssertNil(app.emptySidebarDestination)
        XCTAssertEqual(app.inspectorTab, inspector)
        XCTAssertNil(app.companionPanel.selectedSessionID)
        XCTAssertEqual(app.primaryCompanionProfile?.id, id)
        XCTAssertFalse(app.onboarding.isPresented)
        XCTAssertFalse(app.isBusy)
        XCTAssertFalse(app.pendingSessionReset)
        XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty)
        app.finishCompanionSetup(startChat: true)
        XCTAssertEqual(app.agentProfiles.filter { $0.id == id }.count, 1)
        XCTAssertEqual(app.agentTeamsModel.primaryCompanionID, id)
    }

    func testMainCompanionEntryBeforeSetupOpensSetupWithoutChangingWork() {
        let app = AppModel(startImmediately: false)
        app.installTranscriptSession("work", blocks: [ChatBlock(kind: .assistant, text: "Current work")])
        app.draftText = "Keep this draft"
        app.isBusy = true
        let inspector = app.inspectorTab
        app.openCompanionMainConversation()
        XCTAssertTrue(app.onboarding.showsCompanionSetup)
        XCTAssertEqual(app.currentSessionID, "work")
        XCTAssertEqual(app.draftText, "Keep this draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.inspectorTab, inspector)
        XCTAssertTrue(app.agentProfiles.isEmpty)
    }

    func testMainCompanionEntryRevealsCurrentChatWithoutReloadingApprovalOrDraft() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let chat = SessionSummary(id: "current-companion", name: "Current", preview: "", mtime: 1, size: 0,
                                  cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions = [chat]
        app.initialWorkspacePath = "/tmp"
        app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .assistant, text: "Live work")])
        app.draftText = "Unsent follow-up"
        app.isBusy = true
        app.handleEventForTesting(["type": "permission_request", "id": "tool", "tool": "write_file", "request_id": "approval"])
        app.savedAgentOverviewID = profile.id
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        let inspector = app.inspectorTab
        app.openCompanionMainConversation()
        XCTAssertEqual(app.sidebarDestination, .agents)
        XCTAssertNil(app.savedAgentOverviewID)
        XCTAssertEqual(app.selectedSavedAgentID, profile.id)
        XCTAssertEqual(app.currentSessionID, chat.id)
        XCTAssertEqual(app.draftText, "Unsent follow-up")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.activePermissionRequest?.requestID, "approval")
        XCTAssertNil(app.activeTranscriptLoad)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, ownership)
        XCTAssertEqual(app.inspectorTab, inspector)
        XCTAssertNil(app.companionPanel.selectedSessionID)
    }

    func testMainCompanionEntryDoesNotReplaceAnotherForegroundRunOrReset() throws {
        for reason in ["busy", "approval", "reset"] {
            let app = AppModel(startImmediately: false)
            let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
            app.agentProfiles = [profile]
            try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
            app.initialWorkspacePath = "/tmp"
            app.sessions = [SessionSummary(id: "companion", name: "Companion", preview: "", mtime: 1, size: 0,
                                           cwd: "/tmp", agentProfileID: profile.id.uuidString)]
            app.installTranscriptSession("work", blocks: [ChatBlock(kind: .assistant, text: "Live work")])
            app.draftText = "Keep work draft"
            if reason == "busy" { app.isBusy = true }
            if reason == "reset" { app.pendingSessionReset = true }
            if reason == "approval" {
                app.handleEventForTesting(["type": "permission_request", "id": "tool", "tool": "write_file", "request_id": "approval"])
            }
            app.openCompanionMainConversation()
            XCTAssertEqual(app.currentSessionID, "work", reason)
            XCTAssertEqual(app.draftText, "Keep work draft", reason)
            XCTAssertEqual(app.sidebarDestination, .ask, reason)
            XCTAssertNil(app.activeTranscriptLoad, reason)
            XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty, reason)
            app.toastCenter.cancelPendingDismissal()
        }
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
        XCTAssertEqual(app.sidebarDestination, .ask)
        XCTAssertNil(app.emptySidebarDestination)
        XCTAssertEqual(app.inspectorTab, .companion)
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

    func testSingleCompanionChatSpansFoldersAndExcludesOtherAgentsAutomationsAndArchives() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
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
        XCTAssertEqual(app.companionChats(in: "/var/tmp").map(\.id), ["owned"])
        XCTAssertEqual(app.companionSessionKey(workspace: "/tmp"), app.companionSessionKey(workspace: "/var/tmp"))
        XCTAssertEqual(app.savedAgentChats(profile.id).count, 3, "Legacy and automation history remains intact")
    }

    func testCompanionDefaultsToStableLazyHomeIndependentOfCenterProject() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture")
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let old = SessionSummary(id: "old", name: "old", preview: "", mtime: 1, size: 0,
            cwd: "/old/project", workspaceRoot: "/old/project", executionPath: "/tmp/worktree")
        app.sessions = [old]
        app.installTranscriptSession(old.id, blocks: [])
        let home = app.savedAgentHomePath(profile)
        XCTAssertEqual(app.companionWorkspacePath, home)
        XCTAssertTrue(home.hasSuffix("/\(profile.id.uuidString.lowercased())/Workspace"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home))
        app.initialWorkspacePath = "/new/project"
        XCTAssertEqual(app.companionWorkspacePath, home)
        app.initialWorkspacePath = "/tmp/worktree"
        XCTAssertEqual(app.companionWorkspacePath, home)
        app.pendingWorkspacePath = "/newer/project"
        app.openCompanionDestination()
        XCTAssertEqual(app.companionWorkspacePath, home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home), "Opening the panel must not create a directory")
        app.agentProfiles[0].name = "Renamed companion"
        XCTAssertEqual(app.companionWorkspacePath, home)
        app.selectCompanionWorkspace(home + "/.")
        XCTAssertEqual(app.companionWorkspacePath, home)
        XCTAssertNil(app.primaryCompanionProfile?.workspacePreferences?.defaultProjectPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home), "An equivalent home path must also remain lazy")
        app.toastCenter.cancelPendingDismissal()
    }

    func testCompanionExplicitFolderAndResetPreserveCenterProfileAndLinkedHistory() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture", instructions: "Keep instructions",
                                   accessCeiling: .workspaceWrite,
                                   workspacePreferences: .init(projectPaths: ["/tmp"]))
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        app.initialWorkspacePath = "/central-project"
        app.installTranscriptSession("work", blocks: [ChatBlock(kind: .assistant, text: "Central work")])
        app.draftText = "Private central draft"
        app.isBusy = true
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        let original = try XCTUnwrap(app.primaryCompanionProfile)
        let home = app.savedAgentHomePath(profile)
        app.selectCompanionWorkspace("/var/tmp")
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath("/var/tmp"))
        XCTAssertEqual(app.currentSessionID, "work")
        XCTAssertEqual(app.initialWorkspacePath, "/central-project")
        XCTAssertEqual(app.draftText, "Private central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, ownership)
        var expected = original
        expected.workspacePreferences = .init(projectPaths: ["/tmp", "/var/tmp"], defaultProjectPath: "/var/tmp")
        XCTAssertEqual(app.primaryCompanionProfile, expected)
        app.selectCompanionWorkspace(home)
        XCTAssertEqual(app.companionWorkspacePath, home)
        XCTAssertNil(app.primaryCompanionProfile?.workspacePreferences?.defaultProjectPath)
        XCTAssertEqual(app.primaryCompanionProfile?.workspacePreferences?.projectPaths,
                       AgentWorkspacePreferences(projectPaths: ["/tmp", "/var/tmp"]).projectPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home), "Resetting the selection remains lazy")
        XCTAssertEqual(app.currentSessionID, "work")
        XCTAssertEqual(app.draftText, "Private central draft")
        app.toastCenter.cancelPendingDismissal()
    }

    func testCompanionFolderValidationPreservesChoiceAndMissingExplicitFolderNeverFallsBack() throws {
        let app = AppModel(startImmediately: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); app.toastCenter.cancelPendingDismissal() }
        let profile = AgentProfile(name: "Pitou", model: "fixture")
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        app.selectCompanionWorkspace(root.path)
        let selected = SessionSummary.canonicalWorkspacePath(root.path)
        for invalid in ["relative/folder", "/tmp/\u{0}bad", root.appendingPathComponent("missing").path] {
            app.selectCompanionWorkspace(invalid)
            XCTAssertEqual(app.companionWorkspacePath, selected)
        }
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(app.companionWorkspacePath, selected)
        XCTAssertThrowsError(try app.prepareSavedAgentWorkspace(profile, workspace: app.companionWorkspacePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.savedAgentHomePath(profile)))
    }

    func testClickingActiveCompanionRowPreservesRunApprovalAndDraft() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
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
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let chat = SessionSummary(id: "ours", name: "ours", preview: "", mtime: 1, size: 0,
            cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions = [chat]
        app.initialWorkspacePath = "/tmp"
        app.agentRuntimePhase = .unavailable("Fixture offline")
        let ownership = app.beginTranscriptSessionLoad(chat.id)
        app.draftText = "Loading draft"
        app.openCompanionChat(chat)
        app.openCompanionDestination()
        XCTAssertTrue(app.companionConversationIsSelected)
        XCTAssertEqual(app.transcriptInputState, .loading)
        XCTAssertTrue(app.transcriptPresentation.ownsSessionLoad(ownership))
        XCTAssertEqual(app.draftText, "Loading draft")
        XCTAssertNil(app.activeTranscriptLoad, "Explicit navigation must not start a competing central load")
        app.companionPanel.loadTask?.cancel()
    }

    func testAlreadySelectedCompanionChatDoesNotReloadOrLoseDraft() throws {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
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
        XCTAssertTrue(app.companionConversationIsSelected, "The panel and center share the companion conversation")
        app.openCompanionChat(chat)
        XCTAssertTrue(app.companionPanel.isForegroundConversation)
        app.companionPanel.draft = "Must not replace the central draft"
        XCTAssertFalse(app.companionPanel.canSend)
        XCTAssertEqual(app.draftText, "Companion draft")
        XCTAssertNil(app.activeTranscriptLoad)
        XCTAssertNil(app.savedAgentOverviewID)
        XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty)
        XCTAssertEqual(app.lastSidebarSessionIDs[app.companionSessionKey(workspace: "/tmp")], chat.id)
    }
}
