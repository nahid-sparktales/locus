import Foundation

/// A conversation owns references to its route, never credentials. Automatic
/// agent choices remember the last task; a manual choice pins future tasks.
struct ChatModelRoute: Codable, Hashable {
    let model: String
    let provider: String
    let accountID: UUID?
    let profileID: UUID?
    var selection: String = "manual"
    var established = false

    var wireValue: [String: Any] {
        var value: [String: Any] = ["model": model, "provider": provider]
        if let accountID { value["provider_account_id"] = accountID.uuidString }
        return value
    }
}

struct PendingChatModelChange: Identifiable {
    let id = UUID()
    let sessionID: String
    let currentLabel: String
    let newLabel: String
    let route: ChatModelRoute
    var resetsAgentDefault = false
}

extension AppModel {
    func chatModelRoute(for sessionID: String) -> ChatModelRoute? {
        guard sessionCatalog.snapshot.sessionsByID[sessionID]?.isAgentEventChat != true else { return nil }
        let profileID = savedAgentProfileID(for: sessionID)
        if let route = settings.chatModelRoutes[sessionID], route.profileID == profileID { return route }
        if let selection = settings.agentChatModelSelections[sessionID], selection.profileID == profileID {
            return ChatModelRoute(model: selection.model,
                provider: selection.accountID.flatMap { id in providerAccounts.first { $0.id == id } }?.kind.backendProvider ?? (selection.accountID == nil ? "ollama" : "remote"),
                accountID: selection.accountID, profileID: selection.profileID,
                established: chatHasStarted(sessionID))
        }
        if let info = taskWorkers[sessionID]?.sessionInfo ?? (sessionInfo?.sessionID == sessionID ? sessionInfo : nil),
           info.routeEstablished == true || info.messages > 0, !info.model.isEmpty {
            return ChatModelRoute(model: info.model, provider: info.provider ?? "ollama",
                accountID: info.providerAccountID.flatMap(UUID.init(uuidString:)), profileID: profileID,
                selection: info.modelRouteSelection ?? (profileID == nil ? "manual" : "automatic"), established: true)
        }
        if let session = sessionCatalog.snapshot.sessionsByID[sessionID], session.routeEstablished == true,
           let name = session.model?.nilIfEmpty {
            return ChatModelRoute(model: name, provider: session.provider ?? "ollama",
                accountID: session.providerAccountID.flatMap(UUID.init(uuidString:)), profileID: profileID,
                selection: session.modelRouteSelection ?? (profileID == nil ? "manual" : "automatic"), established: true)
        }
        return nil
    }

    func chatHasStarted(_ sessionID: String) -> Bool {
        if settings.chatModelRoutes[sessionID]?.established == true
            || sessionCatalog.snapshot.sessionsByID[sessionID]?.routeEstablished == true { return true }
        if let info = taskWorkers[sessionID]?.sessionInfo ?? (sessionInfo?.sessionID == sessionID ? sessionInfo : nil),
           info.routeEstablished == true || info.messages > 0 { return true }
        return paneBlocks(for: sessionID).contains { $0.kind == .user }
    }

    func hasManualChatModelSelection(sessionID: String) -> Bool {
        chatModelRoute(for: sessionID)?.selection == "manual"
    }

    var currentChatModelRoute: ChatModelRoute? { chatModelRoute(for: currentSessionID) }

    func requestModelChange(account: ProviderAccount?, model: String) {
        selectModel(account: account, model: model)
    }

    /// All picker and slash-command entry points use this gate. Restoration of
    /// workspace defaults is not a user choice and cannot replace a chat pin.
    @discardableResult
    func stageChatModelChange(account: ProviderAccount?, model: String, resetsAgentDefault: Bool = false) -> Bool {
        guard !currentSessionID.isEmpty else { return false }
        if isRestoringManualModelRoute, currentChatModelRoute != nil { return true }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return true }
        let route = ChatModelRoute(model: name, provider: account?.kind.backendProvider ?? "ollama",
            accountID: account?.id, profileID: savedAgentProfileID(for: currentSessionID),
            selection: resetsAgentDefault ? "automatic" : "manual", established: chatHasStarted(currentSessionID))
        do { _ = try chatModelProviderBody(route) }
        catch { showToast(error.localizedDescription); return true }
        let current = currentChatModelRoute
        let currentAccountID: UUID?
        if let current { currentAccountID = current.accountID }
        else if let profile = currentAgentChatProfile { currentAccountID = profile.route.accountID }
        else { currentAccountID = activeAccount?.id }
        let currentModel = current?.model ?? currentAgentChatProfile?.model ?? selectedModel
        let changed = currentAccountID != route.accountID || currentModel != route.model
            || (resetsAgentDefault && current?.selection == "manual")
        let pinsAutomaticChoice = !resetsAgentDefault && route.profileID != nil && current?.selection != "manual"
        guard changed || pinsAutomaticChoice else { return true }
        let pending = PendingChatModelChange(sessionID: currentSessionID,
            currentLabel: current.map { taskModelPickerLabel(model: $0.model, accountID: $0.accountID, provider: $0.provider) } ?? modelPickerLabel,
            newLabel: taskModelPickerLabel(model: route.model, accountID: route.accountID, provider: route.provider),
            route: route, resetsAgentDefault: resetsAgentDefault)
        if changed && route.established && !isRestoringManualModelRoute { pendingChatModelChange = pending }
        else { applyChatModelChange(pending) }
        return true
    }

    func cancelChatModelChange() { pendingChatModelChange = nil }

    func confirmChatModelChange() {
        guard let pending = pendingChatModelChange else { return }
        pendingChatModelChange = nil
        guard currentSessionID == pending.sessionID,
              modelSelectionLockReason == nil,
              savedAgentProfileID(for: pending.sessionID) == pending.route.profileID else { return }
        applyChatModelChange(pending)
    }

    private func applyChatModelChange(_ change: PendingChatModelChange) {
        do { _ = try chatModelProviderBody(change.route) }
        catch { showToast(error.localizedDescription); return }
        pauseGoalForRouteChange()
        selectedAgentTeamID = nil
        settings.chatModelRoutes[change.sessionID] = change.route
        if let profileID = change.route.profileID, !change.resetsAgentDefault {
            settings.agentChatModelSelections[change.sessionID] = AgentChatModelSelection(
                profileID: profileID, accountID: change.route.accountID, model: change.route.model)
        } else { settings.agentChatModelSelections.removeValue(forKey: change.sessionID) }
        persistSettings()
        showToast("\(change.route.model) will be used for your next message in this chat")
    }

    func chatModelProviderBody(_ route: ChatModelRoute) throws -> [String: Any] {
        if route.provider != "ollama", route.accountID == nil {
            throw SavedAgentConversationError.unavailable("This chat’s saved model account is unavailable. Choose an account in the model picker.")
        }
        let profile = AgentProfile(name: "This chat", route: route.accountID.map(AgentRoute.providerAccount) ?? .localOllama, model: route.model)
        let resolved = try agentProfileProvider(profile)
        guard resolved.provider == route.provider else {
            throw SavedAgentConversationError.unavailable("This chat’s saved model account changed. Choose an account in the model picker.")
        }
        var body = resolved.body
        body["model"] = route.model
        return body
    }

    func queuedChatModelRoute(_ run: OrchestrationRun) throws -> ChatModelRoute? {
        guard case .object(let value) = run.manifest?["chat_route"] else { return nil }
        guard let name = value["model"]?.string?.nilIfEmpty,
              let provider = value["provider"]?.string?.nilIfEmpty else {
            throw SavedAgentConversationError.unavailable("This queued chat’s saved model route is invalid.")
        }
        let route = ChatModelRoute(model: name, provider: provider,
            accountID: value["provider_account_id"]?.string.flatMap(UUID.init(uuidString:)), profileID: nil, established: true)
        _ = try chatModelProviderBody(route)
        return route
    }

    func ordinaryChatRouteSnapshot() throws -> ChatModelRoute {
        if let route = currentChatModelRoute {
            _ = try chatModelProviderBody(route)
            return route
        }
        let route = ChatModelRoute(model: activeAccount.map { routedModel(for: $0) } ?? selectedModel,
            provider: activeAccount?.kind.backendProvider ?? sessionInfo?.provider ?? "ollama",
            accountID: activeAccount?.id, profileID: nil)
        _ = try chatModelProviderBody(route)
        return route
    }

    func retainAcceptedChatRoute(_ route: ChatModelRoute, sessionID: String) {
        // A later picker choice may already target the next task. Preserve it
        // while marking the chat established, rather than rolling it back.
        let existing = settings.chatModelRoutes[sessionID]
        var retained: ChatModelRoute
        if let existing, existing.selection == "manual" { retained = existing }
        else { retained = route }
        retained.established = true
        settings.chatModelRoutes[sessionID] = retained
        persistSettings()
    }

    func rememberChatModelRoute(_ info: SessionInfo) {
        guard info.routeEstablished == true || info.messages > 0,
              sessionCatalog.snapshot.sessionsByID[info.sessionID]?.isAgentEventChat != true,
              !info.model.isEmpty else { return }
        let existing = chatModelRoute(for: info.sessionID)
        // Manual choices may target the next turn while this event describes
        // the current one. A background completion must never overwrite them.
        if let existing, existing.selection == "manual" {
            retainAcceptedChatRoute(existing, sessionID: info.sessionID)
            return
        }
        let provider = info.provider ?? "ollama"
        let accountID = info.providerAccountID.flatMap(UUID.init(uuidString:))
        let route = ChatModelRoute(model: info.model, provider: provider, accountID: accountID,
            profileID: savedAgentProfileID(for: info.sessionID),
            selection: existing?.selection ?? info.modelRouteSelection ?? (savedAgentProfileID(for: info.sessionID) == nil ? "manual" : "automatic"), established: true)
        settings.chatModelRoutes[info.sessionID] = route
        persistSettings()
    }

    func agentModelChoicesForDispatch(_ dispatch: TaskCapsuleDispatch, sessionID: String) -> [ChatModelRoute]? {
        guard !dispatch.profileOnly || (!hasManualChatModelSelection(sessionID: sessionID)
              && sessionCatalog.snapshot.sessionsByID[sessionID]?.isAgentEventChat != true) else { return nil }
        let routes = dispatch.profile.resolvedModelChoices.compactMap { choice -> ChatModelRoute? in
            var candidate = dispatch.profile
            candidate.route = choice.route
            candidate.model = choice.model
            guard let resolved = try? agentProfileProvider(candidate) else { return nil }
            return ChatModelRoute(model: choice.model, provider: resolved.provider,
                accountID: resolved.accountID.flatMap(UUID.init(uuidString:)), profileID: dispatch.profile.id,
                selection: "automatic")
        }
        return routes.count > 1 ? routes : nil
    }

    func prepareAgentModelChoiceCredentials(_ routes: [ChatModelRoute]) async throws {
        for route in routes { _ = try await prepareChatQueueRoute(route) }
    }

    func prepareChatQueueRoute(_ route: ChatModelRoute) async throws -> [String: Any] {
        var provider = try chatModelProviderBody(route)
        if route.provider == "ollama" { provider["host"] = lastOllamaHost }
        if RuntimeInstallation.enabled, persistenceEnabled, !isUITesting {
            let _: [String: Bool] = try await backend.post("/api/runtime/credentials", body: [
                "kind": "account", "id": route.accountID?.uuidString ?? "local", "configuration": provider,
            ], as: [String: Bool].self)
        }
        return route.wireValue
    }
}
