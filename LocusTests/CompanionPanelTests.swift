import Combine
import Foundation
import XCTest
@testable import Locus

@MainActor
final class CompanionPanelTests: XCTestCase {
    func testCompanionOverviewPreservesRunningWorkDraftAndInspector() throws {
        let (app, profile, _) = try fixture()
        defer { cleanup(app) }
        app.isBusy = true
        app.handleEventForTesting(["type": "permission_request", "id": "tool", "tool": "write_file", "request_id": "center-approval"])
        app.selectInspectorTab(.companion)
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        app.openCompanionOverview()
        XCTAssertEqual(app.savedAgentOverviewID, profile.id)
        XCTAssertEqual(app.sidebarDestination, .agents)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertEqual(app.activePermissionRequest?.requestID, "center-approval")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, ownership)
        XCTAssertEqual(app.inspectorTab, .companion)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") })
    }

    func testCompanionOverviewSelectsAgentInspectorWithoutReloadingItsCurrentChat() throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .assistant, text: "Keep this answer")])
        app.draftText = "Keep my companion draft"
        app.selectInspectorTab(.companion)
        app.inspectorCollapsed = true
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        app.openCompanionOverview()
        XCTAssertEqual(app.savedAgentOverviewID, profile.id)
        XCTAssertEqual(app.selectedSavedAgentID, profile.id)
        XCTAssertEqual(app.inspectorTab, .agent)
        XCTAssertFalse(app.inspectorCollapsed)
        XCTAssertTrue(app.openInspectorTabs.contains(.agent))
        XCTAssertEqual(app.currentSessionID, chat.id)
        XCTAssertEqual(app.draftText, "Keep my companion draft")
        XCTAssertEqual(app.blocks.last?.text, "Keep this answer")
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, ownership)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") })
        app.openCompanionMainConversation()
        XCTAssertNil(app.savedAgentOverviewID)
        XCTAssertEqual(app.currentSessionID, chat.id)
        XCTAssertEqual(app.draftText, "Keep my companion draft")
    }

    func testOrdinaryAgentOverviewDoesNotSwitchTheCompanionInspector() throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        let ordinary = AgentProfile(name: "Worker", model: "fixture")
        app.agentProfiles.append(ordinary)
        app.installTranscriptSession(chat.id, blocks: [])
        app.selectInspectorTab(.companion)
        app.selectSavedAgent(ordinary)
        XCTAssertEqual(app.savedAgentOverviewID, ordinary.id)
        XCTAssertEqual(app.inspectorTab, .companion)
    }

    func testReopeningAlreadyVisibleCompanionClearsManualUnreadWithoutReloadingChat() throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [])
        app.markCompanionRead(false)
        XCTAssertTrue(app.companionHasUnread)
        app.openCompanionMainConversation()
        XCTAssertFalse(app.companionHasUnread)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") })
    }

    func testCompanionAskPromptAllowsReadOnlyRetrievalWithoutChangingOrdinaryAsk() {
        let attachment = CompanionContextSharingModel.textAttachment("Reference", name: "Example")
        let companion = AppModel.decoratedPrompt("Find related chats", mode: .ask,
            chatAttachments: [attachment], contextFiles: [], restoredTranscriptContext: nil, companionContext: true)
        let ordinary = AppModel.decoratedPrompt("Find related chats", mode: .ask,
            chatAttachments: [attachment], contextFiles: [], restoredTranscriptContext: nil)
        XCTAssertTrue(companion.contains("permitted read-only Locus tools"))
        XCTAssertFalse(companion.contains("Do not call tools"))
        XCTAssertTrue(companion.contains("Do not modify files"))
        XCTAssertTrue(ordinary.contains("Do not call tools"))
        XCTAssertTrue(ordinary.contains("any other workspace data"))
    }

    func testCompanionModeRemainsAskAcrossCommandsAndSplitRestorationWithoutChangingOtherChats() throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.inspectorCollapsed = false
        app.installTranscriptSession(chat.id, blocks: [])
        XCTAssertEqual(app.selectedMode, .ask)
        XCTAssertFalse(app.justChatEnabled, "Companion Ask must keep its Locus context inspector available")
        XCTAssertFalse(app.inspectorCollapsed)
        for requested in WorkMode.allCases {
            app.selectedMode = requested
            XCTAssertEqual(app.selectedMode, .ask)
            XCTAssertEqual(try app.savedAgentProfileDispatch(profileID: profile.id, mode: requested, sessionID: chat.id).mode, .ask)
        }
        app.splitPaneModes["center"] = .plan
        app.prepareSplitSelection("center")
        app.installTranscriptSession("center", blocks: [])
        XCTAssertEqual(app.selectedMode, .plan, "Leaving Companion restores the other chat's saved mode")
        app.selectedMode = .work
        XCTAssertEqual(app.selectedMode, .work)
        app.splitPaneModes[chat.id] = .grill
        app.prepareSplitSelection(chat.id)
        app.installTranscriptSession(chat.id, blocks: [])
        XCTAssertEqual(app.selectedMode, .ask, "Old saved companion modes must not restore")
        XCTAssertTrue(app.usesCompanionContext(sessionID: chat.id, profileID: profile.id))
        XCTAssertFalse(app.usesCompanionContext(sessionID: "center", profileID: profile.id))
        XCTAssertFalse(app.usesCompanionContext(sessionID: chat.id, profileID: UUID()))
    }

    func testCompanionChatCreationOverridesAgentDefaultToAsk() async throws {
        let (app, original, _) = try fixture()
        defer { cleanup(app) }
        var profile = original
        profile.defaultMode = .work
        app.agentProfiles = [profile]
        let created = try await app.createSavedAgentConversation(profile, workspace: "/tmp", preservingForeground: true)
        XCTAssertEqual(CompanionPanelURLProtocol.bodies(for: "/api/sessions/detached").last?["mode"] as? String, "ask")
        XCTAssertEqual(app.splitPaneModes[created.id], .ask)
        XCTAssertEqual(app.currentSessionID, "center")
    }

    func testBackgroundAndMainCompanionDispatchPersistAskContextInQueue() async throws {
        for foreground in [false, true] {
            let (app, profile, chat) = try fixture()
            defer { cleanup(app) }
            if foreground {
                app.installTranscriptSession(chat.id, blocks: [])
                app.sessionInfo = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp", session: chat.id,
                    sessionID: chat.id, messages: 2, approxTokens: 0, promptTokens: 0, completionTokens: 0,
                    maxIterations: 10, hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
                app.selectedMode = .work
                app.send("Find my earlier image generation chat")
                XCTAssertEqual(app.turnDispatchedMode, .ask)
                await app.pendingChatTurns[chat.id]?.value
            } else {
                do {
                    try await app.sendSavedAgentTurn(sessionID: chat.id, workspace: "/tmp", profileID: profile.id,
                                                    text: "Find my earlier image generation chat", mode: .work)
                } catch { /* The fixture rejects queue admission before a real worker could launch. */ }
            }
            let body = try XCTUnwrap(CompanionPanelURLProtocol.bodies(for: "/api/runs/queue").last)
            XCTAssertEqual(body["mode"] as? String, "ask")
            XCTAssertEqual(body["companion_context"] as? Bool, true)
            XCTAssertEqual((body["agent_chat_route"] as? [String: Any])?["profile_id"] as? String, profile.id.uuidString)
            XCTAssertEqual(body["solo_swarm"] as? Bool, false)
        }
    }

    func testOrdinarySavedAgentDispatchKeepsWorkWithoutCompanionContext() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        let ordinary = AgentProfile(name: "Worker", model: "fixture")
        app.agentProfiles.append(ordinary)
        CompanionPanelURLProtocol.setOwner(ordinary.id, for: "ordinary-agent")
        app.sessions.append(SessionSummary(id: "ordinary-agent", name: "Worker", preview: "", mtime: 3,
            size: 0, cwd: "/tmp", agentProfileID: ordinary.id.uuidString))
        do {
            try await app.sendSavedAgentTurn(sessionID: "ordinary-agent", workspace: "/tmp", profileID: ordinary.id,
                                            text: "Continue the task", mode: .work)
        } catch { /* The fixture rejects queue admission before a real worker could launch. */ }
        let body = try XCTUnwrap(CompanionPanelURLProtocol.bodies(for: "/api/runs/queue").last)
        XCTAssertEqual(body["mode"] as? String, "work")
        XCTAssertNil(body["companion_context"])
    }

    func testOpeningAndLoadingPanelPreservesCentralDraftTaskAndApproval() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.isBusy = true
        app.handleEventForTesting(["type": "permission_request", "id": "tool", "tool": "write_file", "request_id": "center-approval"])
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        let blocks = app.blocks.map(\.id)
        app.openCompanionDestination()
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.profileID, profile.id)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.sidebarDestination, .ask)
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.activePermissionRequest?.requestID, "center-approval")
        XCTAssertEqual(app.blocks.map(\.id), blocks)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, ownership)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") || $0 == "/api/sessions/detached" })
        app.companionPanel.draft = "Independent draft"
        app.companionPanel.activate()
        XCTAssertEqual(app.companionPanel.draft, "Independent draft")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testFailedLoadRetriesWithoutTouchingCenter() async throws {
        let (app, _, _) = try fixture(failures: 1)
        defer { cleanup(app) }
        app.markCompanionRead(false)
        app.companionPanel.activate()
        XCTAssertFalse(app.companionPanel.canRetryLoading, "An in-flight read cannot be restarted")
        XCTAssertFalse(app.companionPanel.hasLoadedConversation, "Selecting a conversation is not a read receipt")
        await app.companionPanel.loadTask?.value
        XCTAssertNotNil(app.companionPanel.error)
        XCTAssertTrue(app.companionPanel.blocks.isEmpty)
        XCTAssertTrue(app.companionPanel.canRetryLoading)
        XCTAssertFalse(app.companionPanel.hasLoadedConversation, "A failed request cannot acknowledge unseen messages")
        XCTAssertTrue(app.companionHasUnread)
        app.companionPanel.retryLoading()
        await app.companionPanel.loadTask?.value
        XCTAssertNil(app.companionPanel.error)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertFalse(app.companionPanel.canRetryLoading, "A loaded transcript does not show Retry")
        XCTAssertTrue(app.companionPanel.hasLoadedConversation)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testActualOwnerWorkspaceAndArchiveAreValidatedBeforeDisplaying() async throws {
        for mismatch in ["owner", "workspace", "archive"] {
            let (app, _, chat) = try fixture(mismatch: mismatch)
            defer { cleanup(app) }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
            XCTAssertNotNil(app.companionPanel.error, mismatch)
            XCTAssertTrue(app.companionPanel.blocks.isEmpty, mismatch)
            XCTAssertFalse(app.companionPanel.hasLoadedConversation, mismatch)
            XCTAssertNil(app.splitPaneBlocks[chat.id], mismatch)
            XCTAssertFalse(app.companionPanel.canSend)
        }
    }

    func testChangingPreferredFolderKeepsTheSingleCompanionConversation() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        let oldTask = app.companionPanel.loadTask
        app.selectCompanionWorkspace("/var/tmp")
        await oldTask?.value
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.companionPanel.selectedSessionID, "companion")
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testCenterProjectChangesDoNotChangeCompanionSelectionOrDraft() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Independent companion draft"
        let requestCount = CompanionPanelURLProtocol.paths().count
        app.initialWorkspacePath = "/var/tmp"
        app.pendingWorkspacePath = "/different-center-project"
        app.companionPanel.activate()
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Independent companion draft")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().count, requestCount)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testConversationArtifactsUseExecutionFolderWithoutChangingCompanionScope() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        let execution = "/tmp/companion-execution"
        let executingChat = SessionSummary(id: chat.id, name: chat.name, preview: "", mtime: 1, size: 0,
                                           cwd: execution, workspaceRoot: "/tmp", executionPath: execution,
                                           agentProfileID: profile.id.uuidString)
        app.sessions = app.sessions.map { $0.id == chat.id ? executingChat : $0 }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.conversationWorkspacePath, execution)
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.initialWorkspacePath, "/tmp")
        app.selectCompanionWorkspace("/var/tmp")
        XCTAssertEqual(app.companionPanel.conversationWorkspacePath, execution,
                       "Changing the next chat's folder does not retarget the current conversation")
    }

    func testGitSubfolderSelectionSurvivesCatalogRefreshAndRejectsSiblingAlias() async throws {
        let root = "/tmp/companion-repository"
        let source = root + "/subproject"
        let execution = "/tmp/companion-checkout"
        let (app, profile, chat) = try fixture(workspace: source, workspaceRoot: root, executionPath: execution)
        defer { cleanup(app) }
        let sibling = SessionSummary(id: "sibling", name: "Sibling", preview: "", mtime: 2, size: 0,
            cwd: execution, workspaceRoot: root, executionPath: execution,
            environment: ["type": "worktree", "source_workspace": root + "/other"],
            agentProfileID: profile.id.uuidString)
        app.sessions.append(sibling)
        XCTAssertEqual(app.companionChats().map(\.id), [chat.id])
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertNil(app.companionPanel.error)
        app.companionPanel.draft = "Keep this subproject draft"

        try await app.refreshCompanionConversationCatalog()
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Keep this subproject draft")
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath(source))
        XCTAssertEqual(app.companionPanel.conversationWorkspacePath, execution)
        XCTAssertEqual(app.sessions.first { $0.id == chat.id }?.workspacePath,
                       SessionSummary.canonicalWorkspacePath(root))
        app.companionPanel.select(sibling)
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)

        // A catalog update moving this same session to a sibling must revoke it.
        app.sessions = [SessionSummary(id: chat.id, name: chat.name, preview: "", mtime: 3, size: 0,
            cwd: execution, workspaceRoot: root, executionPath: execution,
            environment: sibling.environment, agentProfileID: profile.id.uuidString)]
        XCTAssertNil(app.companionPanel.selectedSessionID)
        XCTAssertTrue(app.companionPanel.blocks.isEmpty)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testGitSubfolderNewConversationSelectsCreatedWorktreeWithoutChangingCenter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("subproject")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let execution = directory.appendingPathComponent("checkout").path
        let (app, _, _) = try fixture(workspace: source.path, workspaceRoot: directory.path, executionPath: execution)
        defer { cleanup(app) }
        app.sessions = app.sessions.filter { $0.id == "center" }
        app.companionPanel.createConversation()
        await app.companionPanel.creationTask?.value
        await app.companionPanel.loadTask?.value

        XCTAssertEqual(app.companionPanel.selectedSessionID, "companion-created")
        XCTAssertNil(app.companionPanel.error)
        XCTAssertEqual(app.companionPanel.conversationWorkspacePath, execution)
        XCTAssertEqual(app.sessions.first { $0.id == "companion-created" }?.workspacePath,
                       SessionSummary.canonicalWorkspacePath(directory.path))
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/detached" }.count, 1)
    }

    func testMainCompanionEntryCreatesAndReusesGitSubfolderConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("subproject")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let execution = directory.appendingPathComponent("checkout").path
        let (app, _, _) = try fixture(workspace: source.path, workspaceRoot: directory.path, executionPath: execution)
        defer { app.activeTranscriptLoad?.task.cancel(); cleanup(app) }
        app.sessions = app.sessions.filter { $0.id == "center" }
        app.openCompanionMainConversation()
        for _ in 0..<100 {
            if app.creatingSavedAgentChatIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await app.activeTranscriptLoad?.task.value
        XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty)
        XCTAssertEqual(app.currentSessionID, "companion-created")
        XCTAssertEqual(app.transcriptInputState, .ready)
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath(source.path))
        XCTAssertEqual(app.sessionInfo?.executionPath, execution)

        app.installTranscriptSession("center", blocks: [])
        app.lastSidebarSessionIDs[app.companionSessionKey(workspace: source.path)] = "companion-created"
        app.openCompanionMainConversation()
        await app.activeTranscriptLoad?.task.value
        XCTAssertEqual(app.currentSessionID, "companion-created")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/detached" }.count, 1)
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0.hasSuffix("/resume") }.count, 2)
    }

    func testSendAcknowledgesComposerBeforeDelayedOwnershipValidation() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app); CompanionPanelURLProtocol.releaseExecutionContextResponses() }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "  Visible immediately  "
        let enteredValidation = expectation(description: "Metadata request is pending")
        CompanionPanelURLProtocol.holdExecutionContextResponses { enteredValidation.fulfill() }

        app.companionPanel.send()
        // These assertions run before yielding the main actor to any request.
        XCTAssertEqual(app.companionPanel.draft, "")
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Visible immediately")
        XCTAssertEqual(app.companionPanel.blocks.last?.kind, .user)
        XCTAssertTrue(app.companionPanel.isSending)
        XCTAssertFalse(app.companionPanel.canSend)
        XCTAssertEqual(app.draftText, "Central draft")
        let submission = app.companionPanel.sendingTask
        await fulfillment(of: [enteredValidation], timeout: 2)
        XCTAssertFalse(dispatched)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Visible immediately")
        XCTAssertEqual(app.companionPanel.draft, "")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/\(chat.id)" }.count, 1,
                       "Only the initial panel load reads the transcript")
        CompanionPanelURLProtocol.releaseExecutionContextResponses()
        await submission?.value
        XCTAssertTrue(dispatched)
        XCTAssertEqual(app.companionPanel.draft, "")
    }

    func testDefaultPanelDispatchValidatesMetadataOnlyOnceAndRestoresRejectedDraft() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Retry after queue rejection"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/\(chat.id)/execution-context" }.count, 1)
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/\(chat.id)" }.count, 1)
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/runs/queue" }.count, 1)
        XCTAssertEqual(app.companionPanel.draft, "Retry after queue rejection")
        XCTAssertFalse(app.companionPanel.blocks.contains { $0.kind == .user })
        XCTAssertNotNil(app.companionPanel.error)
    }

    func testOlderBackendFallsBackToOneAuthoritativeDetailReadBeforeDispatch() async throws {
        for status in [404, 405] {
            let (app, _, chat) = try fixture()
            defer { cleanup(app) }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            CompanionPanelURLProtocol.setExecutionContextResponse(status: status)
            app.companionPanel.draft = "Send through the installed older runtime"
            app.companionPanel.send()
            await app.companionPanel.sendingTask?.value
            XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/\(chat.id)/execution-context" }.count, 1)
            XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/\(chat.id)" }.count, 2,
                           "One initial transcript load and one authoritative legacy preflight")
            XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/runs/queue" }.count, 1,
                           "The saved-agent runtime must reuse the panel's validated fallback result")
            XCTAssertEqual(app.companionPanel.draft, "Send through the installed older runtime",
                           "The fixture rejects queue admission after successful compatibility preflight")
        }
    }

    func testOlderBackendFallbackRejectsFreshOwnershipChanges() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        CompanionPanelURLProtocol.setExecutionContextResponse(status: 404)
        CompanionPanelURLProtocol.setOwner(UUID(), for: chat.id)
        app.companionPanel.draft = "Keep this private request"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertFalse(dispatched)
        XCTAssertEqual(app.companionPanel.draft, "Keep this private request")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/\(chat.id)" }.count, 2)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains("/api/runs/queue"))
        XCTAssertNotNil(app.companionPanel.error)
    }

    func testMetadataAuthorizationAndServerErrorsDoNotFetchLegacyHistory() async throws {
        for status in [401, 403, 409, 429, 500, 503] {
            let (app, _, chat) = try fixture()
            defer { cleanup(app) }
            CompanionPanelURLProtocol.setExecutionContextResponse(status: status)
            do {
                _ = try await app.loadSavedAgentConversationMetadata(sessionID: chat.id)
                XCTFail("Expected metadata error \(status)")
            } catch {
                XCTAssertEqual((error as NSError).domain, "Locus.Backend")
                XCTAssertEqual((error as NSError).code, status)
            }
            XCTAssertEqual(CompanionPanelURLProtocol.paths(), ["/api/sessions/\(chat.id)/execution-context"])
        }
    }

    func testMetadataCancellationAndTransportErrorsDoNotFetchLegacyHistory() async throws {
        for code in [URLError.Code.cancelled, .cannotConnectToHost] {
            let (app, _, chat) = try fixture()
            defer { cleanup(app) }
            CompanionPanelURLProtocol.setExecutionContextResponse(transportError: code)
            do {
                _ = try await app.loadSavedAgentConversationMetadata(sessionID: chat.id)
                XCTFail("Expected metadata transport failure")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
                XCTAssertEqual((error as NSError).code, code.rawValue)
            }
            XCTAssertEqual(CompanionPanelURLProtocol.paths(), ["/api/sessions/\(chat.id)/execution-context"])
        }
    }

    func testPendingBubbleReconcilesWithDurableRunWithoutTextGuessing() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            let pending = try XCTUnwrap(app.companionPanel.blocks.last)
            // Backend history can decorate shared context and assigns fresh IDs.
            app.splitPaneBlocks[chat.id, default: []].append(ChatBlock(kind: .user,
                text: "Durable decorated request", runID: pending.runID))
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Original request"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(app.companionPanel.blocks.filter { $0.kind == .user }.map(\.text), ["Durable decorated request"])
        app.splitPaneBlocks[chat.id] = []
        XCTAssertTrue(app.companionPanel.blocks.isEmpty, "Acknowledged local rows no longer shadow the canonical transcript")
    }

    func testPendingBubbleReconcilesAfterOpeningCompanionInForeground() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            let pending = try XCTUnwrap(app.companionPanel.blocks.last)
            app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .user,
                text: pending.text, runID: pending.runID)])
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Open this while sending"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertTrue(app.companionPanel.isForegroundConversation)
        XCTAssertEqual(app.companionPanel.blocks.filter { $0.kind == .user }.map(\.text), ["Open this while sending"])
    }

    func testRejectedSendPreservesLaterEditsIncludingIntentionallyEmptyDraft() async throws {
        for replacement in ["A new question", ""] {
            let (app, _, _) = try fixture()
            defer { cleanup(app) }
            app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
                app.companionPanel.draft = "An edit before clearing"
                app.companionPanel.draft = replacement
                throw SavedAgentConversationError.unavailable("Fixture rejection")
            }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            app.companionPanel.draft = "Original submission"
            app.companionPanel.send()
            await app.companionPanel.sendingTask?.value
            XCTAssertEqual(app.companionPanel.draft, replacement)
            XCTAssertEqual(app.companionPanel.blocks.filter { $0.kind == .user }.map(\.text), ["Original submission"])
            XCTAssertTrue(app.companionPanel.blocks.contains { $0.kind == .error && $0.text.contains("not sent") })
        }
    }

    func testRejectedSendPreservesEditsFromAnotherComposerIncludingClearedDraft() async throws {
        for replacement in ["Another pane's question", ""] {
            let (app, _, chat) = try fixture()
            defer { cleanup(app) }
            app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
                app.setPaneDraft("Another pane's first edit", for: chat.id)
                app.setPaneDraft(replacement, for: chat.id)
                throw SavedAgentConversationError.unavailable("Fixture rejection")
            }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            app.companionPanel.draft = "Original submission"
            app.companionPanel.send()
            await app.companionPanel.sendingTask?.value
            XCTAssertEqual(app.paneDraft(for: chat.id), replacement)
            XCTAssertEqual(app.companionPanel.draft, replacement)
            XCTAssertEqual(app.companionPanel.blocks.filter { $0.kind == .user }.map(\.text), ["Original submission"])
            XCTAssertTrue(app.companionPanel.blocks.contains { $0.kind == .error && $0.text.contains("not sent") })
            XCTAssertEqual(app.draftText, "Central draft")
        }
    }

    func testRejectedSendPreservesClearedForegroundDraftAfterHandoff() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            app.installTranscriptSession(chat.id, blocks: [])
            app.setPaneDraft("New foreground question", for: chat.id)
            app.setPaneDraft("", for: chat.id)
            throw SavedAgentConversationError.unavailable("Fixture rejection")
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Original submission"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(app.currentSessionID, chat.id)
        XCTAssertEqual(app.draftText, "")
        XCTAssertEqual(app.blocks.filter { $0.kind == .user }.map(\.text), ["Original submission"])
        XCTAssertTrue(app.blocks.contains { $0.kind == .error && $0.text.contains("not sent") })
    }

    func testCancelledSendKeepsOriginalCopyableWhenAnotherComposerWasEdited() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            app.setPaneDraft("Later question", for: chat.id)
            app.setPaneDraft("", for: chat.id)
            throw CancellationError()
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Cancelled original"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(app.companionPanel.draft, "")
        XCTAssertEqual(app.companionPanel.blocks.filter { $0.kind == .user }.map(\.text), ["Cancelled original"])
        XCTAssertTrue(app.companionPanel.blocks.contains { $0.kind == .error && $0.text.contains("not sent") })
        XCTAssertTrue(app.companionPanel.error?.contains("not sent") == true)
    }

    func testCancelledSendRestoresUntouchedDraftAndSharedContext() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        let enteredDispatch = expectation(description: "Waiting for admission")
        var continuation: CheckedContinuation<Void, Never>?
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            await withCheckedContinuation { continuation = $0; enteredDispatch.fulfill() }
            try Task.checkCancellation()
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Cancel before acceptance"
        app.companionContext.activate(try XCTUnwrap(app.companionScope))
        app.companionContext.previewText("Keep this context", name: "Context")
        XCTAssertTrue(app.companionContext.approvePreview())
        app.companionPanel.send()
        let submission = app.companionPanel.sendingTask
        await fulfillment(of: [enteredDispatch], timeout: 2)
        XCTAssertEqual(app.companionPanel.draft, "")
        submission?.cancel()
        continuation?.resume()
        await submission?.value
        XCTAssertEqual(app.companionPanel.draft, "Cancel before acceptance")
        XCTAssertEqual(app.companionContext.attachments.first?.textContent, "Keep this context")
        XCTAssertFalse(app.companionPanel.blocks.contains { $0.kind == .user })
        XCTAssertNil(app.companionPanel.error)
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testChangedDurableOwnershipRejectsOptimisticSendAndRestoresDraft() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        CompanionPanelURLProtocol.setOwner(UUID(), for: chat.id)
        app.companionPanel.draft = "Keep my private request"
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertFalse(dispatched)
        XCTAssertEqual(app.companionPanel.draft, "Keep my private request")
        XCTAssertFalse(app.companionPanel.blocks.contains { $0.kind == .user })
        XCTAssertNotNil(app.companionPanel.error)
    }

    func testMainCompanionSendAcknowledgesComposerBeforeQueueRequest() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [])
        app.sessionInfo = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp", session: chat.id,
            sessionID: chat.id, messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            maxIterations: 10, hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
        app.draftText = "Immediate main message"
        app.send(app.draftText)
        XCTAssertEqual(app.draftText, "")
        XCTAssertEqual(app.blocks.last?.text, "Immediate main message")
        XCTAssertEqual(app.blocks.last?.kind, .user)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains("/api/runs/queue"),
                       "Presentation updates synchronously before admission starts")
        await app.pendingChatTurns[chat.id]?.value
    }

    func testDesktopForegroundSendUsesImmediateMainConversationPresentation() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [])
        app.sessionInfo = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp", session: chat.id,
            sessionID: chat.id, messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            maxIterations: 10, hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
        app.draftText = "Immediate desktop message"
        app.sendCompanionDesktopMessage(sessionID: chat.id)
        XCTAssertEqual(app.draftText, "")
        XCTAssertEqual(app.blocks.last?.text, "Immediate desktop message")
        XCTAssertEqual(app.blocks.last?.kind, .user)
        XCTAssertEqual(app.turnDispatchedMode, .ask)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains("/api/runs/queue"))
        await app.pendingChatTurns[chat.id]?.value
    }

    func testDesktopForegroundSendCannotRetargetAnUnrelatedChat() throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        let originalBlocks = app.blocks
        app.sendCompanionDesktopMessage(sessionID: chat.id)
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertEqual(app.blocks, originalBlocks)
        XCTAssertTrue(CompanionPanelURLProtocol.paths().isEmpty)
    }

    func testHealthyConversationOverrideCanSendWithUnavailableDefaultAccount() async throws {
        let (app, original, chat) = try fixture()
        defer { cleanup(app) }
        var profile = original
        profile.route = .providerAccount(UUID())
        app.agentProfiles = [profile]
        app.settings.agentChatModelSelections[chat.id] = .init(profileID: profile.id, accountID: nil, model: "healthy-local")
        var dispatchedModel: String?
        var dispatchedMode: WorkMode?
        app.companionPanel.configure(app: app) { id, _, owner, _, mode, _ in
            dispatchedModel = try app.savedAgentProfileDispatch(profileID: owner, mode: mode, sessionID: id).profile.model
            dispatchedMode = mode
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Use this conversation's model"
        XCTAssertThrowsError(try app.agentProfileProvider(profile))
        XCTAssertNil(app.companionPanel.availabilityIssue)
        XCTAssertTrue(app.companionPanel.canSend)
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(dispatchedModel, "healthy-local")
        XCTAssertEqual(dispatchedMode, .ask, "Companion retrieval always runs in Ask mode")
        XCTAssertEqual(app.companionPanel.draft, "")
        XCTAssertEqual(app.agentProfiles.first, profile, "The per-chat override must not replace the owner's default")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testUnavailableConversationOverrideCannotFallBackToHealthyDefault() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.settings.agentChatModelSelections[chat.id] = .init(profileID: profile.id, accountID: UUID(), model: "unavailable-model")
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep this draft"
        XCTAssertNoThrow(try app.agentProfileProvider(profile))
        XCTAssertThrowsError(try app.savedAgentProfileDispatch(profileID: profile.id, mode: .ask, sessionID: chat.id))
        XCTAssertNotNil(app.companionPanel.availabilityIssue)
        XCTAssertFalse(app.companionPanel.canSend)
        app.companionPanel.send()
        XCTAssertNil(app.companionPanel.sendingTask)
        XCTAssertFalse(dispatched)
        XCTAssertEqual(app.companionPanel.draft, "Keep this draft")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testPreferredFolderChangeDoesNotRetargetPendingCompanionSend() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep in the original folder"
        app.companionPanel.send()
        let oldSubmission = app.companionPanel.sendingTask
        app.selectCompanionWorkspace("/var/tmp")
        await oldSubmission?.value
        XCTAssertTrue(dispatched)
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.paneDraft(for: chat.id), "")
        XCTAssertEqual(app.currentSessionID, "center")
        app.selectCompanionWorkspace("/tmp")
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "")
    }

    func testSendingUsesCapturedCanonicalScopeAndPreservesCenterAndLaterEdits() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        var captured: (String, String, UUID, String, WorkMode)?
        app.companionPanel.configure(app: app) { id, workspace, owner, text, mode, _ in
            captured = (id, workspace, owner, text, mode)
            app.companionPanel.draft = "Later edit"
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "  Hello companion  "
        XCTAssertEqual(app.companionPanel.mode, .ask)
        app.isBusy = true
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(captured?.0, chat.id)
        XCTAssertEqual(captured?.1, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(captured?.2, profile.id)
        XCTAssertEqual(captured?.3, "Hello companion")
        XCTAssertEqual(captured?.4, .ask)
        XCTAssertEqual(app.companionPanel.draft, "Later edit")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
    }

    func testFailedSendPreservesPanelDraftAndCentralExecutionAndProvider() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            throw SavedAgentConversationError.unavailable("Fixture provider unavailable")
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep after failure"
        app.isBusy = true
        app.orchestrationRunID = "central-run"
        app.orchestrationState = .running
        let provider = app.settings.activeAccountID
        let selectedModel = app.selectedModel
        let owner = app.transcriptPresentation.sessionOwnershipToken
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(app.companionPanel.error, "Fixture provider unavailable")
        XCTAssertFalse(app.companionPanel.canRetryLoading, "A send failure is not a transcript load failure")
        XCTAssertEqual(app.companionPanel.draft, "Keep after failure")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.orchestrationRunID, "central-run")
        XCTAssertEqual(app.orchestrationState, .running)
        XCTAssertEqual(app.selectedModel, selectedModel)
        XCTAssertEqual(app.settings.activeAccountID, provider)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, owner)
    }

    func testLegacyChatCannotReplaceSingleConversationDuringPendingSubmission() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        let other = SessionSummary(id: "other", name: "Other", preview: "", mtime: 0, size: 0,
                                   cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions.append(other)
        let enteredDispatch = expectation(description: "First chat awaits normal admission")
        var continuation: CheckedContinuation<Void, Never>?
        var firstSubmissionWasCancelled = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            await withCheckedContinuation { continuation = $0; enteredDispatch.fulfill() }
            firstSubmissionWasCancelled = Task.isCancelled
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "First submission"
        app.companionPanel.send()
        let firstTask = app.companionPanel.sendingTask
        await fulfillment(of: [enteredDispatch], timeout: 2)
        defer { continuation?.resume() }
        XCTAssertTrue(app.companionPanel.isSending)
        app.companionPanel.select(other)
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertTrue(app.companionPanel.isSending)
        XCTAssertNotNil(app.companionPanel.sendingTask)
        app.companionPanel.draft = "Later companion draft"
        let pending = try XCTUnwrap(continuation)
        continuation = nil
        pending.resume()
        await firstTask?.value
        XCTAssertFalse(firstSubmissionWasCancelled)
        XCTAssertEqual(app.companionPanel.draft, "Later companion draft")
        XCTAssertEqual(app.paneDraft(for: chat.id), "Later companion draft", "A later edit survives the accepted turn")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testCatalogOnlyRenamePublishesPanelHistoryWithoutReloadingTranscript() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Preserved draft"
        var publications = 0
        let observation = app.companionPanel.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        let renamed = SessionSummary(id: chat.id, name: "Renamed", preview: "", mtime: 2, size: 0,
                                     cwd: "/tmp", agentProfileID: profile.id.uuidString)
        let requestCount = CompanionPanelURLProtocol.paths().count
        app.sessions = app.sessions.map { $0.id == chat.id ? renamed : $0 }
        XCTAssertGreaterThan(publications, 0)
        XCTAssertEqual(app.companionPanel.chats.first?.name, "Renamed")
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Preserved draft")
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().count, requestCount)
    }

    func testCatalogRemovalArchiveOrOwnershipChangeImmediatelyHidesPrivateSelection() async throws {
        for change in ["remove", "archive", "owner", "workspace", "deleted-profile"] {
            let (app, profile, chat) = try fixture()
            defer { cleanup(app) }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            app.companionPanel.draft = "Private draft"
            if change == "deleted-profile" {
                app.agentProfiles = []
                app.companionPanel.activate()
            } else if change == "remove" {
                app.sessions.removeAll { $0.id == chat.id }
            } else {
                let updated = SessionSummary(id: chat.id, name: chat.name, preview: "", mtime: 1, size: 0,
                                             archived: change == "archive",
                                             cwd: change == "workspace" ? "/var/tmp" : "/tmp",
                                             agentProfileID: (change == "owner" ? UUID() : profile.id).uuidString)
                app.sessions = app.sessions.map { $0.id == chat.id ? updated : $0 }
            }
            XCTAssertNil(app.companionPanel.selectedSessionID, change)
            XCTAssertTrue(app.companionPanel.blocks.isEmpty, change)
            XCTAssertEqual(app.companionPanel.draft, "", change)
            XCTAssertFalse(app.companionPanel.canSend, change)
            XCTAssertEqual(app.currentSessionID, "center", change)
            XCTAssertEqual(app.draftText, "Central draft", change)
        }
    }

    func testExistingBackgroundWorkerPublishesStreamingAndApprovalStateToPanel() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        let runtime = ChatWorkerRuntime(requestedSessionID: chat.id, workspacePath: "/tmp",
                                        process: BackendProcess(), endpoint: URL(string: "http://127.0.0.1:9")!)
        app.taskWorkers[chat.id] = runtime
        defer { app.taskWorkers[chat.id] = nil; runtime.stop() }
        var publications = 0
        let observation = app.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        runtime.streamingBlockID = UUID()
        runtime.streamingText = "Live worker output"
        runtime.executionState = .running
        app.updateBackgroundChatState(runtime)
        XCTAssertGreaterThan(publications, 0, "The panel observes AppModel's existing worker publications")
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Live worker output")
        XCTAssertEqual(app.companionPanel.blocks.last?.isStreaming, true)
        XCTAssertEqual(app.companionPanel.state.status, "working")
        runtime.pendingForegroundEvent = ["type": "permission_request", "request_id": "panel-approval"]
        runtime.executionState = .waitingPermission
        app.updateBackgroundChatState(runtime)
        XCTAssertEqual(app.companionPanel.state.status, "needs_attention")
        XCTAssertFalse(app.companionPanel.canSend)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertFalse(app.hasPendingPermission, "Background approval does not replace the center's permission state")
    }

    func testNoModelOrOfflineSendNeverDispatchesOrClearsDraft() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep this draft"
        app.agentProfiles[0].model = ""
        XCTAssertNotNil(app.companionPanel.availabilityIssue)
        app.companionPanel.send()
        app.agentProfiles[0].model = "fixture"
        app.agentRuntimePhase = .unavailable("Offline")
        app.companionPanel.send()
        XCTAssertFalse(dispatched)
        XCTAssertEqual(app.companionPanel.draft, "Keep this draft")
        XCTAssertNil(app.companionPanel.sendingTask)
    }

    func testExplicitCreateReusesTheSingleChatAndDoesNotReconcileCenter() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.isBusy = true
        app.companionPanel.createConversation()
        app.companionPanel.createConversation()
        await app.companionPanel.creationTask?.value
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/detached" }.count, 0)
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.savedAgentProfileID(for: chat.id), profile.id)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertNil(app.activeTranscriptLoad)
        XCTAssertNil(app.companionPanel.error)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") || $0 == "/api/runs/queue" })
    }

    func testNewChatActionKeepsConversationAcrossPreferredFolderChanges() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.createConversation()
        app.selectCompanionWorkspace("/var/tmp")
        await app.companionPanel.creationTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.savedAgentProfileID(for: chat.id), profile.id)
        XCTAssertEqual(app.sessions.first { $0.id == chat.id }?.workspacePath,
                       SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testSharedContextIsCapturedForCompanionAndConsumedOnlyAfterAcceptance() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        let scope = try XCTUnwrap(app.companionScope)
        app.companionContext.activate(scope)
        app.companionContext.previewText("Original error", name: "Error")
        XCTAssertTrue(app.companionContext.approvePreview())
        var captured: [ChatAttachment] = []
        app.companionPanel.configure(app: app) { id, _, _, _, _, attachments in
            XCTAssertEqual(id, chat.id)
            captured = attachments
            app.companionContext.previewText("Next message", name: "Later")
            XCTAssertTrue(app.companionContext.approvePreview())
        }
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(captured.map(\.textContent), ["Original error"])
        XCTAssertEqual(app.companionContext.attachments.map(\.name), ["Later"])
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.chatAttachments.isEmpty)
    }

    func testSharedContextRemainsAfterFailedCompanionSend() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionContext.activate(try XCTUnwrap(app.companionScope))
        app.companionContext.previewText("Keep for retry", name: "Error")
        XCTAssertTrue(app.companionContext.approvePreview())
        app.companionPanel.configure(app: app) { _, _, _, _, _, _ in
            throw SavedAgentConversationError.unavailable("Offline")
        }
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(app.companionContext.attachments.first?.textContent, "Keep for retry")
        XCTAssertNotNil(app.companionPanel.error)
    }

    func testForegroundConversationIsReadOnlyInPanel() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .assistant, text: "Live central answer")])
        app.companionPanel.activate()
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        app.companionPanel.select(chat)
        await app.companionPanel.loadTask?.value
        XCTAssertTrue(app.companionPanel.isForegroundConversation)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Live central answer")
        app.companionPanel.draft = "Do not replace center"
        app.companionPanel.send()
        app.companionPanel.stop()
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertFalse(app.companionPanel.canSend)
        XCTAssertNil(app.companionPanel.sendingTask)
    }

    func testMainAndInspectorCreationShareOneInFlightChat() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        app.sessions.removeAll { $0.id == "companion" }
        app.companionPanel.createConversation()
        app.openCompanionMainConversation()
        app.companionPanel.createConversation()
        await app.companionPanel.creationTask?.value
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, "companion-created")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/detached" }.count, 1)
        XCTAssertEqual(app.companionChats().count, 1)
    }

    func testLateCreationRemembersOnlyItsCapturedCompanionProfile() async throws {
        let (app, original, _) = try fixture()
        defer { cleanup(app) }
        app.sessions.removeAll { $0.id == "companion" }
        app.companionPanel.createConversation()
        let creation = app.companionPanel.creationTask
        let replacement = AgentProfile(name: "Other companion", model: "fixture",
                                       workspacePreferences: .init(defaultProjectPath: "/tmp"))
        XCTAssertTrue(app.agentTeamsModel.removeAgentProfile(original))
        app.agentProfiles.append(contentsOf: [original, replacement])
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: replacement.id))
        XCTAssertEqual(app.agentTeamsModel.primaryCompanionID, replacement.id)
        app.companionPanel.activate()
        await creation?.value
        XCTAssertNil(app.companionPanel.selectedSessionID)
        XCTAssertNil(app.lastSidebarSessionIDs[app.companionSessionKey(workspace: "/tmp")])
        XCTAssertEqual(app.lastSidebarSessionIDs["companion:\(original.id.uuidString)"], "companion-created")
        XCTAssertEqual(app.currentSessionID, "center")
    }

    func testClearCompanionArchivesPreviousChatAndPreservesCenter() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Previous draft"
        app.isBusy = true
        XCTAssertTrue(app.companionPanel.canClearConversation)
        app.companionPanel.clearConversation()
        app.companionPanel.clearConversation()
        await app.companionPanel.clearingTask?.value
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionConversation?.id, "companion-created")
        XCTAssertEqual(app.companionPanel.selectedSessionID, "companion-created")
        XCTAssertTrue(app.companionPanel.blocks.isEmpty)
        XCTAssertEqual(app.companionPanel.draft, "")
        XCTAssertEqual(CompanionPanelURLProtocol.archivedIDs(), [chat.id])
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/detached" }.count, 1)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertNil(app.companionPanel.error)
    }

    func testClearForegroundCompanionStaysWithCompanionAndArchivesOnlyAfterResume() async throws {
        let (app, profile, chat) = try fixture()
        defer { app.activeTranscriptLoad?.task.cancel(); cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .assistant, text: "Old conversation")])
        app.clearChatConfirmed()
        await app.companionPanel.clearingTask?.value
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.currentSessionID, "companion-created")
        XCTAssertEqual(app.currentCompanionConversationProfile?.id, profile.id)
        XCTAssertEqual(CompanionPanelURLProtocol.archivedIDs(), [chat.id])
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains("/api/sessions/new"))
        XCTAssertNil(app.companionPanel.error)
    }

    func testClearFailureKeepsOriginalConversationAndDraft() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep on failure"
        CompanionPanelURLProtocol.failNextCreation()
        app.companionPanel.clearConversation()
        await app.companionPanel.clearingTask?.value
        XCTAssertEqual(app.companionConversation?.id, chat.id)
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Keep on failure")
        XCTAssertTrue(CompanionPanelURLProtocol.archivedIDs().isEmpty)
        XCTAssertNotNil(app.companionPanel.error)
        XCTAssertEqual(app.currentSessionID, "center")
    }

    func testBusyCompanionCannotClear() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [])
        app.isBusy = true
        app.companionPanel.activate()
        XCTAssertFalse(app.companionPanel.canClearConversation)
        app.clearChatConfirmed()
        XCTAssertNil(app.companionPanel.clearingTask)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains("/api/sessions/detached"))
    }

    private func fixture(failures: Int = 0, mismatch: String? = nil, workspace: String = "/tmp",
                         workspaceRoot: String? = nil, executionPath: String? = nil) throws -> (AppModel, AgentProfile, SessionSummary) {
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: workspace))
        let environment = workspaceRoot.map { _ in ["type": "worktree", "source_workspace": workspace] }
        let chat = SessionSummary(id: "companion", name: "Companion", preview: "", mtime: 1, size: 0,
                                  cwd: executionPath ?? workspace, workspaceRoot: workspaceRoot,
                                  executionPath: executionPath, environment: environment,
                                  agentProfileID: profile.id.uuidString)
        var context: [String: Any] = ["cwd": executionPath ?? workspace]
        context["workspace_root"] = workspaceRoot
        context["execution_path"] = executionPath
        context["environment"] = environment
        CompanionPanelURLProtocol.reset(profileID: profile.id, failures: failures, mismatch: mismatch, context: context)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompanionPanelURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: config))
        let app = AppModel(startImmediately: false, backendOverride: backend)
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        app.sessions = [chat, SessionSummary(id: "center", name: "Center", preview: "", mtime: 2, size: 0, cwd: "/tmp")]
        app.initialWorkspacePath = "/tmp"
        app.installTranscriptSession("center", blocks: [ChatBlock(kind: .assistant, text: "Central work")])
        app.draftText = "Central draft"
        app.agentRuntimePhase = .online
        return (app, profile, chat)
    }

    private func cleanup(_ app: AppModel) {
        app.companionPanel.loadTask?.cancel()
        app.companionPanel.creationTask?.cancel()
        app.companionPanel.clearingTask?.cancel()
        app.companionPanel.sendingTask?.cancel()
        app.knowledge.cancelAll()
        app.agentInstructions.cancelAll()
        app.toastCenter.cancelPendingDismissal()
    }
}

private final class CompanionPanelURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var profileID = UUID()
    private static var failures = 0
    private static var mismatch: String?
    private static var requestedPaths: [String] = []
    private static var requestedBodies: [String: [[String: Any]]] = [:]
    private static var created = false
    private static var archived: Set<String> = []
    private static var rejectCreation = false
    private static var sessionContext: [String: Any] = [:]
    private static var owners: [String: UUID] = [:]
    private static var holdExecutionContext = false
    private static var executionContextStarted: (() -> Void)?
    private static var heldResponses: [() -> Void] = []
    private static var executionContextStatus = 200
    private static var executionContextError: URLError.Code?
    static func reset(profileID: UUID, failures: Int, mismatch: String?, context: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        self.profileID = profileID; self.failures = failures; self.mismatch = mismatch; requestedPaths = []; created = false
        requestedBodies = [:]
        sessionContext = context
        archived = []; rejectCreation = false; owners = [:]
        holdExecutionContext = false; executionContextStarted = nil; heldResponses = []
        executionContextStatus = 200; executionContextError = nil
    }
    static func setExecutionContextResponse(status: Int = 200, transportError: URLError.Code? = nil) {
        lock.lock(); defer { lock.unlock() }
        executionContextStatus = status; executionContextError = transportError
    }
    static func setOwner(_ profileID: UUID, for sessionID: String) {
        lock.lock(); defer { lock.unlock() }; owners[sessionID] = profileID
    }
    static func holdExecutionContextResponses(onStart: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        holdExecutionContext = true; executionContextStarted = onStart
    }
    static func releaseExecutionContextResponses() {
        lock.lock()
        holdExecutionContext = false; executionContextStarted = nil
        let responses = heldResponses; heldResponses = []
        lock.unlock()
        responses.forEach { $0() }
    }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return requestedPaths }
    static func bodies(for path: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return requestedBodies[path] ?? []
    }
    static func archivedIDs() -> Set<String> { lock.lock(); defer { lock.unlock() }; return archived }
    static func failNextCreation() { lock.lock(); defer { lock.unlock() }; rejectCreation = true }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        Self.requestedPaths.append(path)
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            Self.requestedBodies[path, default: []].append(body)
        }
        let isExecutionContext = path.hasSuffix("/execution-context")
        if isExecutionContext, let code = Self.executionContextError {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let defaultStatus = path == "/api/runs/queue" || Self.failures > 0 || (Self.rejectCreation && path == "/api/sessions/detached") ? 503 : 200
        let status = isExecutionContext && Self.executionContextStatus != 200 ? Self.executionContextStatus : defaultStatus
        Self.failures = max(0, Self.failures - 1)
        let sessionID = isExecutionContext ? request.url!.pathComponents.dropLast().last! : request.url!.lastPathComponent
        let owner = Self.mismatch == "owner" ? UUID() : Self.owners[sessionID] ?? Self.profileID
        let archived = Self.mismatch == "archive"
        let payload: [String: Any]
        if status >= 400 {
            payload = ["detail": "Temporary fixture failure"]
        } else if path == "/api/sessions/detached" {
            Self.created = true
            payload = ["session_id": "companion-created"]
        } else if path == "/api/sessions" {
            let ids = Self.created ? ["companion", "companion-created"] : ["companion"]
            let rows = ids.filter { !Self.archived.contains($0) }.map { id -> [String: Any] in
                ["id": id, "name": id, "preview": "", "mtime": 1, "size": 0,
                 "agent_profile_id": Self.profileID.uuidString].merging(Self.sessionContext) { _, new in new }
            }
            payload = ["sessions": rows, "current": "must-not-replace-center"]
        } else if request.httpMethod == "PATCH" {
            let id = request.url!.lastPathComponent
            Self.archived.insert(id)
            payload = ["ok": true, "id": id, "title": id, "pinned": false, "archived": true]
        } else if path.hasSuffix("/resume") {
            let id = request.url!.pathComponents.dropLast().last!
            var info: [String: Any] = ["model": "fixture", "host": "localhost", "session": id,
                "session_id": id, "messages": 0, "approx_tokens": 0, "prompt_tokens": 0,
                "completion_tokens": 0, "max_iterations": 10, "has_project_context": false,
                "permissions": ["skip_all": false, "allowed": []] as [String: Any]]
            info.merge(Self.sessionContext) { _, new in new }
            payload = ["ok": true, "messages": [], "session_info": info]
        } else {
            var detail: [String: Any] = ["id": sessionID, "preview": "",
                "archived": archived, "agent_profile_id": owner.uuidString,
                "messages": sessionID == "companion-created" ? [] : [["role": "assistant", "content": "Saved companion answer"]]]
            if isExecutionContext { detail.removeValue(forKey: "messages") }
            detail.merge(Self.sessionContext) { _, new in new }
            if Self.mismatch == "workspace" { detail["cwd"] = "/var/tmp" }
            payload = detail
        }
        let respond = {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if isExecutionContext && Self.holdExecutionContext {
            Self.heldResponses.append(respond)
            let started = Self.executionContextStarted
            Self.lock.unlock()
            started?()
        } else {
            Self.lock.unlock()
            respond()
        }
    }
}
