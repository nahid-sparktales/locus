import XCTest
@testable import Locus

@MainActor
final class ChatModelRoutingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    func testAcceptedChatKeepsExactAccountAndModelAfterGlobalDefaultsChangeAndReload() throws {
        let app = app()
        var first = ProviderAccount(kind: .chatGPT, name: "Same label", preferredModel: "first-model")
        let second = ProviderAccount(kind: .chatGPT, name: "Same label", preferredModel: "second-model")
        app.providerAccounts = [first, second]
        app.settings.activeAccountID = first.id.uuidString
        app.sessionInfo = info("chat", model: "first-model", provider: "chatgpt", accountID: first.id)
        let captured = try app.ordinaryChatRouteSnapshot()
        app.retainAcceptedChatRoute(captured, sessionID: "chat")
        first.preferredModel = "edited-default"
        app.providerAccounts = [first, second]
        app.settings.activeAccountID = second.id.uuidString
        let saved = try JSONEncoder().encode(app.settings)
        let reopened = self.app()
        reopened.providerAccounts = [first, second]
        reopened.settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        let body = try reopened.chatModelProviderBody(reopened.ordinaryChatRouteSnapshot())
        XCTAssertEqual(body["account_id"] as? String, first.id.uuidString)
        XCTAssertEqual(body["model"] as? String, "first-model")
        XCTAssertEqual(reopened.modelPickerLabel, "Same label · first-model")
        XCTAssertTrue(reopened.isCurrentRoute(account: first, model: "first-model"))
        XCTAssertFalse(reopened.isCurrentRoute(account: second, model: "first-model"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("api_key"))
        XCTAssertNoBackendTraffic()
    }

    func testSwitchingChatsRestoresRecordedProviderAccountAndModel() {
        let app = app()
        let account = ProviderAccount(kind: .chatGPT, name: "Personal", preferredModel: "global")
        app.providerAccounts = [account]
        let first = info("chat", model: "recorded", provider: "chatgpt", accountID: account.id, messages: 2)
        app.sessionInfo = first
        app.rememberChatModelRoute(first)
        app.installTranscriptSession("local", blocks: [])
        let local = info("local", model: "local:8b", messages: 2)
        app.sessionInfo = local
        app.rememberChatModelRoute(local)
        XCTAssertEqual(app.modelPickerLabel, "local:8b")
        app.installTranscriptSession("chat", blocks: [])
        XCTAssertEqual(app.modelPickerLabel, "Personal · recorded")
        XCTAssertEqual(app.currentChatModelRoute?.accountID, account.id)
        XCTAssertNil(app.settings.activeAccountID, "Navigation does not overwrite defaults for new chats")
    }

    func testStartedChatRequiresConfirmationAndCancelPreservesTeamAndRoute() {
        let app = app(started: true)
        let account = ProviderAccount(kind: .chatGPT, name: "Other", preferredModel: "new-model")
        app.providerAccounts = [account]
        let teamID = UUID()
        app.selectedAgentTeamID = teamID
        app.requestModelChange(account: account, model: "new-model")
        XCTAssertEqual(app.pendingChatModelChange?.sessionID, "chat")
        XCTAssertEqual(app.selectedModel, "original")
        XCTAssertEqual(app.selectedAgentTeamID, teamID)
        app.cancelChatModelChange()
        XCTAssertNil(app.pendingChatModelChange)
        XCTAssertEqual(app.selectedModel, "original")
        app.requestModelChange(account: account, model: "new-model")
        app.confirmChatModelChange()
        XCTAssertEqual(app.currentChatModelRoute?.accountID, account.id)
        XCTAssertEqual(app.selectedModel, "new-model")
        XCTAssertNil(app.selectedAgentTeamID)
        XCTAssertNil(app.settings.activeAccountID)
        XCTAssertNoBackendTraffic()
    }

    func testSwitchingOnlyAccountWithIdenticalModelStillWarns() {
        let app = app(started: true)
        let first = ProviderAccount(kind: .chatGPT, name: "A", preferredModel: "same")
        let second = ProviderAccount(kind: .chatGPT, name: "B", preferredModel: "same")
        app.providerAccounts = [first, second]
        app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "same", provider: "chatgpt", accountID: first.id, profileID: nil, established: true)
        app.selectModel(account: second, model: "same")
        XCTAssertNotNil(app.pendingChatModelChange)
        XCTAssertEqual(app.currentChatModelRoute?.accountID, first.id)
    }

    func testFreshChatSelectionIsImmediateAndDoesNotChangeAnotherChat() {
        let app = app()
        app.settings.chatModelRoutes["other"] = ChatModelRoute(model: "other-model", provider: "ollama", accountID: nil, profileID: nil, established: true)
        app.selectModel(account: nil, model: "new-model")
        XCTAssertNil(app.pendingChatModelChange)
        XCTAssertEqual(app.selectedModel, "new-model")
        XCTAssertEqual(app.settings.chatModelRoutes["other"]?.model, "other-model")
        XCTAssertEqual(app.currentChatModelRoute?.established, false)
        XCTAssertNoBackendTraffic()
    }

    func testConfirmationCannotApplyAfterNavigation() {
        let app = app(started: true)
        app.selectModel(account: nil, model: "requested")
        app.installTranscriptSession("other", blocks: [])
        app.confirmChatModelChange()
        XCTAssertNil(app.pendingChatModelChange)
        XCTAssertNil(app.settings.chatModelRoutes["other"])
        XCTAssertNotEqual(app.settings.chatModelRoutes["chat"]?.model, "requested")
    }

    func testNextTurnManualChoiceSurvivesOldWorkerMetadataAndCapturedAcceptance() throws {
        let app = app(started: true)
        let captured = try app.ordinaryChatRouteSnapshot()
        app.isBusy = true
        app.selectModel(account: nil, model: "next-model")
        app.confirmChatModelChange()
        app.retainAcceptedChatRoute(captured, sessionID: "chat")
        app.rememberChatModelRoute(info("chat", model: "original", messages: 3))
        XCTAssertEqual(app.currentChatModelRoute?.model, "next-model")
        XCTAssertTrue(app.currentChatModelRoute?.established == true)
        XCTAssertEqual(captured.model, "original")
        XCTAssertNil(app.pendingProviderSwitch)
    }

    func testRemovedAccountCannotFallBackToCurrentGlobalAccount() {
        let app = app()
        let missing = UUID()
        let other = ProviderAccount(kind: .chatGPT, name: "Other", preferredModel: "same")
        app.providerAccounts = [other]
        app.settings.activeAccountID = other.id.uuidString
        app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "same", provider: "chatgpt", accountID: missing, profileID: nil, established: true)
        XCTAssertThrowsError(try app.ordinaryChatRouteSnapshot())
        XCTAssertEqual(app.modelPickerLabel, "Unavailable account · same")
        XCTAssertFalse(app.isCurrentRoute(account: other, model: "same"))
        XCTAssertNoBackendTraffic()
    }

    func testModelOnlyChangeCannotConvertUnknownRemoteAccountIntoLocalRoute() {
        let app = app(started: true)
        app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "legacy-model", provider: "remote", accountID: nil,
            profileID: nil, established: true)
        app.selectModel("replacement")
        XCTAssertNil(app.pendingChatModelChange)
        XCTAssertEqual(app.currentChatModelRoute?.provider, "remote")
        XCTAssertEqual(app.currentChatModelRoute?.model, "legacy-model")
        app.requestModelChange(account: nil, model: "replacement")
        XCTAssertNotNil(app.pendingChatModelChange, "An explicit Local picker choice remains available for recovery")
        app.confirmChatModelChange()
        XCTAssertEqual(app.currentChatModelRoute?.provider, "ollama")
        XCTAssertEqual(app.currentChatModelRoute?.model, "replacement")
        XCTAssertNoBackendTraffic()
    }

    func testWorkerUsesCapturedLocalModelWithoutConsultingGlobalControlProvider() async throws {
        let app = app()
        BackendStub.respond(toPath: "/api/provider") { _ in
            ["provider": "ollama", "host": "localhost", "model": "old", "remote_base_url": "", "remote_model": "", "has_api_key": false]
        }
        BackendStub.respond(toPath: "/api/config") { _ in [:] }
        let route = ChatModelRoute(model: "captured:8b", provider: "ollama", accountID: nil, profileID: nil)
        _ = try await app.prepareChatWorkerCapsuleRoute(using: stubbedBackendService(), capsuleDispatch: nil,
            restoringOverride: true, ordinaryProviderBody: app.chatModelProviderBody(route))
        XCTAssertEqual(BackendStub.requestPaths, ["/api/provider", "/api/config"])
        XCTAssertTrue(BackendStub.requests.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertEqual(try body(BackendStub.requests[1])["model"] as? String, "captured:8b")
    }

    func testFirstSubmittedTaskQueuesAndRetainsSnapshotEvenIfGlobalDefaultsChangeImmediately() async throws {
        let app = app()
        app.agentRuntimePhase = .online
        app.selectedMode = .ask
        BackendStub.respond(toPath: "/api/runs/queue") { _ in
            ["id": "queued", "state": "queued", "request": "hello", "created_at": 1, "updated_at": 1,
             "last_seq": 0, "pinned": false, "legacy": false, "recoverable": true]
        }
        app.send("hello")
        let pending = try XCTUnwrap(app.pendingChatTurns["chat"])
        app.settings.activeAccountID = UUID().uuidString
        app.installTranscriptSession("elsewhere", blocks: [])
        await pending.value
        let queued = try XCTUnwrap(BackendStub.requests.first { $0.url?.path == "/api/runs/queue" })
        let route = try XCTUnwrap(try body(queued)["chat_route"] as? [String: Any])
        XCTAssertEqual(route["model"] as? String, "original")
        XCTAssertEqual(route["provider"] as? String, "ollama")
        XCTAssertNil(route["provider_account_id"])
        XCTAssertEqual(app.settings.chatModelRoutes["chat"]?.model, "original")
        XCTAssertEqual(app.settings.chatModelRoutes["chat"]?.established, true)
        XCTAssertNil(app.settings.chatModelRoutes["elsewhere"])
    }

    func testAgentRetainsAcceptedDefaultAndExplicitPreparedChoiceBypassesPreviousAutomaticChoice() throws {
        let app = app()
        let original = AgentProfile(name: "Agent", model: "first-model")
        app.agentProfiles = [original]
        app.sessions = [SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0, agentProfileID: original.id.uuidString)]
        app.retainAcceptedChatRoute(ChatModelRoute(model: "first-model", provider: "ollama", accountID: nil,
            profileID: original.id, selection: "automatic"), sessionID: "chat")
        app.agentProfiles[0].model = "edited-default"
        let retained = try app.savedAgentProfileDispatch(profileID: original.id, mode: .ask, sessionID: "chat")
        XCTAssertEqual(retained.profile.model, "first-model")
        var prepared = original
        prepared.model = "chosen-for-next-task"
        let next = try app.savedAgentProfileDispatch(profileID: original.id, mode: .ask, sessionID: "chat", selectedProfile: prepared)
        XCTAssertEqual(next.profile.model, "chosen-for-next-task")
        XCTAssertEqual(app.agentProfiles[0].model, "edited-default")
    }

    func testAutomaticAgentPoolContainsAccountReferencesAndManualOverrideDisablesIt() throws {
        let app = app()
        let account = ProviderAccount(kind: .chatGPT, name: "Plan", preferredModel: "assigned")
        app.providerAccounts = [account]
        var profile = AgentProfile(name: "Agent", model: "local")
        profile.additionalModels = [AgentModelChoice(route: .providerAccount(account.id), model: "assigned")]
        app.agentProfiles = [profile]
        app.sessions = [SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0, agentProfileID: profile.id.uuidString)]
        let automatic = try app.savedAgentProfileDispatch(profileID: profile.id, mode: .ask, sessionID: "chat")
        let pool = try XCTUnwrap(app.agentModelChoicesForDispatch(automatic, sessionID: "chat"))
        XCTAssertEqual(pool.map(\.model), ["local", "assigned"])
        XCTAssertEqual(pool[1].wireValue["provider_account_id"] as? String, account.id.uuidString)
        XCTAssertEqual(Set(pool[1].wireValue.keys), ["model", "provider", "provider_account_id"])
        app.selectModel(account: nil, model: "pinned")
        let pinned = try app.savedAgentProfileDispatch(profileID: profile.id, mode: .ask, sessionID: "chat")
        XCTAssertNil(app.agentModelChoicesForDispatch(pinned, sessionID: "chat"))
    }

    func testRecordedRouteMetadataDecodesAndSurvivesPermissionChanges() throws {
        let accountID = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["session_id": "chat", "model": "recorded", "provider": "chatgpt",
            "provider_account_id": accountID.uuidString, "model_route_selection": "automatic", "route_established": true])
        let metadata = try JSONDecoder().decode(SessionInfo.self, from: data)
        let changed = metadata.replacingPermissions(SessionPermissions(skipAll: true, allowed: []))
        XCTAssertEqual(changed.providerAccountID, accountID.uuidString)
        XCTAssertEqual(changed.modelRouteSelection, "automatic")
        XCTAssertEqual(changed.routeEstablished, true)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).chatModelRoutes.isEmpty)
    }

    func testAcceptedAutomaticChoiceImmediatelyReplacesPreviousTaskRoute() {
        let app = app()
        let profile = AgentProfile(name: "Agent", model: "first")
        app.agentProfiles = [profile]
        app.sessions = [SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0, agentProfileID: profile.id.uuidString)]
        app.retainAcceptedChatRoute(ChatModelRoute(model: "first", provider: "ollama", accountID: nil,
            profileID: profile.id, selection: "automatic"), sessionID: "chat")
        app.retainAcceptedChatRoute(ChatModelRoute(model: "chosen-next", provider: "ollama", accountID: nil,
            profileID: profile.id, selection: "automatic"), sessionID: "chat")
        XCTAssertEqual(app.modelPickerLabel, "chosen-next")
        XCTAssertEqual(app.currentChatModelRoute?.selection, "automatic")
        XCTAssertEqual(app.currentChatModelRoute?.established, true)
    }

    func testSingletonAgentMetadataDoesNotConvertAutomaticRouteIntoManualUserPin() throws {
        let app = app()
        let profile = AgentProfile(name: "Agent", model: "original")
        app.agentProfiles = [profile]
        app.sessions = [SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0, agentProfileID: profile.id.uuidString)]
        app.retainAcceptedChatRoute(ChatModelRoute(model: "original", provider: "ollama", accountID: nil,
            profileID: profile.id, selection: "automatic"), sessionID: "chat")
        let metadata = try JSONDecoder().decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: [
            "session_id": "chat", "model": "original", "provider": "ollama", "messages": 2,
            "route_established": true, "model_route_selection": "manual",
        ]))
        app.rememberChatModelRoute(metadata)
        XCTAssertFalse(app.hasManualChatModelSelection(sessionID: "chat"))
        let dispatch = try app.savedAgentProfileDispatch(profileID: profile.id, mode: .ask, sessionID: "chat")
        XCTAssertNil(app.agentModelChoicesForDispatch(dispatch, sessionID: "chat"), "One model sends only the exact chat route")
    }

    func testResetToAutomaticUsesReadyAssignedAlternativeWhenPrimaryAccountIsMissing() {
        let app = app(started: true)
        var profile = AgentProfile(name: "Agent", route: .providerAccount(UUID()), model: "unavailable-primary")
        profile.additionalModels = [AgentModelChoice(route: .localOllama, model: "ready-alternative")]
        app.agentProfiles = [profile]
        app.sessions = [SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0, agentProfileID: profile.id.uuidString)]
        app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "manual-pin", provider: "ollama", accountID: nil,
            profileID: profile.id, established: true)
        app.resetAgentChatModel()
        XCTAssertEqual(app.pendingChatModelChange?.route.model, "ready-alternative")
        XCTAssertTrue(app.hasManualChatModelSelection(sessionID: "chat"))
        app.confirmChatModelChange()
        XCTAssertEqual(app.currentChatModelRoute?.model, "ready-alternative")
        XCTAssertFalse(app.hasManualChatModelSelection(sessionID: "chat"))
        XCTAssertNil(app.currentChatModelRoute?.accountID)
        XCTAssertNoBackendTraffic()
    }

    func testSavedAgentWireBodyIncludesAdditionalRouteReferences() throws {
        let accountID = UUID()
        var profile = AgentProfile(name: "Agent", model: "primary")
        profile.additionalModels = [AgentModelChoice(route: .providerAccount(accountID), model: "alternative")]
        let choices = try XCTUnwrap(AppModel.savedAgentProfileBody(profile)["model_choices"] as? [[String: Any]])
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0]["model"] as? String, "alternative")
        let route = try XCTUnwrap(choices[0]["route"] as? [String: Any])
        XCTAssertEqual(route["accountID"] as? String, accountID.uuidString)
        XCTAssertEqual(route["kind"] as? String, "account")
    }

    func testCapsuleFallbackPoolBelongsToSpecialistDespiteResidentManualPin() throws {
        let app = app()
        app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "resident-pin", provider: "ollama", accountID: nil, profileID: nil, established: true)
        var specialist = AgentProfile(name: "Specialist", model: "planner")
        specialist.additionalModels = [AgentModelChoice(route: .localOllama, model: "backup")]
        let dispatch = TaskCapsuleDispatch(profile: specialist, provider: "ollama", accountID: nil,
            providerBody: ["provider": "ollama"], context: ["stage": "plan"], mode: .plan)
        XCTAssertEqual(app.agentModelChoicesForDispatch(dispatch, sessionID: "chat")?.map(\.model), ["planner", "backup"])
    }

    func testGoalCreationCapturesChatAccountInsteadOfCurrentGlobalDefault() async throws {
        let app = app(started: true)
        let selected = ProviderAccount(kind: .chatGPT, name: "Chat", preferredModel: "chat-model")
        let global = ProviderAccount(kind: .chatGPT, name: "Global", preferredModel: "global-model")
        app.providerAccounts = [selected, global]
        app.settings.activeAccountID = global.id.uuidString
        app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "chat-model", provider: "chatgpt", accountID: selected.id, profileID: nil, established: true)
        app.backendCapabilities["persistent_goals_v1"] = true
        app.draftText = "Complete the task"
        app.presentGoalEditor()
        await app.goals.saveDraft()
        let request = try XCTUnwrap(BackendStub.requests.first { $0.url?.path == "/api/sessions/chat/goal" })
        let execution = try XCTUnwrap(try body(request)["execution"] as? [String: Any])
        XCTAssertEqual(execution["provider_account_id"] as? String, selected.id.uuidString)
        XCTAssertEqual(execution["model"] as? String, "chat-model")
    }

    func testNewScheduleKeepsChatRouteIncludingExplicitLocalChoice() throws {
        for local in [false, true] {
            let app = app(started: true)
            let selected = ProviderAccount(kind: .chatGPT, name: "Chat", preferredModel: "chat-model")
            let global = ProviderAccount(kind: .chatGPT, name: "Global", preferredModel: "global-model")
            app.providerAccounts = [selected, global]
            app.settings.activeAccountID = global.id.uuidString
            app.settings.chatModelRoutes["chat"] = ChatModelRoute(model: "chat-model", provider: local ? "ollama" : "chatgpt",
                accountID: local ? nil : selected.id, profileID: nil, established: true)
            app.presentScheduleEditor(prompt: "Check the project")
            let draft = try XCTUnwrap(app.configureAgentPendingScheduleDraft)
            XCTAssertEqual(draft.model, "chat-model")
            XCTAssertEqual(draft.provider, local ? "ollama" : "chatgpt")
            XCTAssertEqual(draft.providerAccountID, local ? nil : selected.id.uuidString)
            XCTAssertEqual(app.settings.activeAccountID, global.id.uuidString)
        }
    }

    func testStopDuringAutomaticChoiceCannotSubmitTaskLater() async throws {
        let app = app()
        app.agentRuntimePhase = .online
        var profile = AgentProfile(name: "Agent", model: "first")
        profile.additionalModels = [AgentModelChoice(route: .localOllama, model: "second")]
        app.agentProfiles = [profile]
        app.sessions = [SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0, agentProfileID: profile.id.uuidString)]
        app.send("Inspect the files")
        let choosing = try XCTUnwrap(app.pendingChatTurns["chat"])
        app.stop()
        await choosing.value
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/runs/queue"))
        XCTAssertNil(app.pendingChatTurns["chat"])
        XCTAssertFalse(app.isBusy)
    }

    private func app(started: Bool = false) -> AppModel {
        let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        app.installTranscriptSession("chat", blocks: started ? [ChatBlock(kind: .user, text: "First task")] : [])
        app.sessionInfo = info("chat", model: "original", messages: started ? 2 : 0)
        return app
    }

    private func info(_ sessionID: String, model: String, provider: String = "ollama", accountID: UUID? = nil, messages: Int = 0) -> SessionInfo {
        SessionInfo(model: model, host: "localhost", cwd: "/tmp", session: sessionID, sessionID: sessionID,
            messages: messages, approxTokens: 0, promptTokens: 0, completionTokens: 0, contextLimit: 0,
            maxIterations: 40, hasProjectContext: false, provider: provider,
            providerAccountID: accountID?.uuidString, routeEstablished: messages > 0,
            permissions: SessionPermissions(skipAll: false, allowed: []))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
