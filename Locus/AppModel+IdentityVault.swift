import AppKit
import Foundation

extension AppModel {
    var isIdentityTask: Bool { identityVault.identitySessions.contains(currentSessionID) }

    func configureIdentityVault() {
        identityVault.backendRoot = settings.backendRoot
        identityVault.onLock = { [weak self] in
            guard let self else { return }
            self.browser.closeAllIdentityApplications()
            IdentityPrivacyGuard.shared.applicationSessions.removeAll()
            for runtime in self.taskWorkers.values where self.identityVault.identitySessions.contains(runtime.sessionID) {
                _ = runtime.service.send(["type": "stop"])
            }
        }
    }

    func identityProviderIdentity(accountID: String? = nil, model: String? = nil) -> IdentityProviderIdentity {
        let account = (accountID ?? settings.activeAccountID).flatMap { id in providerAccounts.first { $0.id.uuidString == id } }
        if let account, settings.provider != .ollama || accountID != nil {
            return .init(accountID: account.id.uuidString, provider: account.kind == .chatGPT ? "chatgpt" : "remote",
                         endpoint: account.resolvedBaseURL, model: model ?? selectedModel, label: account.displayName)
        }
        return .init(accountID: "", provider: "ollama", endpoint: ollamaHost,
                     model: model ?? selectedModel, label: "Local Ollama")
    }

    func startIdentityTask(profileID: UUID? = nil, prompt: String? = nil, sendImmediately: Bool = false) {
        Task { await createIdentityTask(profileID: profileID, prompt: prompt, sendImmediately: sendImmediately) }
    }

    private func createIdentityTask(profileID: UUID?, prompt: String?, sendImmediately: Bool) async {
        guard !pendingSessionReset, isAgentOnline else {
            showToast("Wait for Locus to connect before opening an Identity task.")
            return
        }
        guard activeAccount?.kind != .chatGPT else {
            identityVault.notice = "Private Identity tasks currently require Local Ollama or an API provider. ChatGPT-plan sessions retain provider-side tool context and cannot yet enforce private source handling. Choose another model provider first."
            identityVault.isPresented = true
            return
        }
        let path = workspacePath
        let previousSession = currentSessionID
        do {
            let response = try await backend.post("/api/sessions/new", body: [
                "reason": "workspace_chat", "cwd": path, "environment": "local", "identity_mode": true,
            ], as: NewSessionResponse.self)
            // Selection never copies old transcripts, attachments, or workspace
            // context into the private task.
            detachForegroundWorkerUIIfNeeded()
            identityVault.registerSession(response.sessionInfo.sessionID, profileID: profileID)
            pendingSessionReset = true
            applySessionStarted(response.sessionInfo, reason: "workspace_chat")
            contextFiles = []
            chatAttachments = []
            restoredTranscriptContext = nil
            selectedAgentTeamID = nil
            selectedMode = .work
            identityVault.isPresented = false
            draftText = prompt ?? "Help me use my private profile. Start by describing the selected profile through Identity Vault."
            if !previousSession.isEmpty { showToast("Opened a separate private Identity task") }
            if sendImmediately { send(draftText, preservingDraftOnFailure: true, includeAttachments: false) }
        } catch { showToast("The Identity task could not be opened. Try again.") }
    }

    /// Called before any general event logging/overview ingestion. The result
    /// goes only to the originating transport, including for background tasks.
    func handleIdentityEvent(_ event: [String: Any], runtime: ChatWorkerRuntime?, transport: BackendService) {
        guard let type = event["type"] as? String else { return }
        let session = runtime?.sessionID ?? (event["session_id"] as? String ?? currentSessionID)
        if type == "identity_cancelled" {
            identityVault.cancelReviews(sessionID: session)
            return
        }
        guard let requestID = event["request_id"] as? String else { return }
        if let epoch = event["context_epoch"] as? String, let runtime,
           runtime.identityContextEpoch != epoch {
            identityVault.cancelReviews(sessionID: session)
            runtime.identityContextEpoch = epoch
        }
        let replyType = type == "identity_context_request" ? "identity_context_result" : "identity_action_result"
        let reply: @MainActor ([String: Any]) -> Void = { result in
            _ = transport.send(["type": replyType, "request_id": requestID, "result": result])
        }
        guard (event["session_id"] as? String ?? session) == session else {
            reply(["error": "The request does not belong to this task."])
            return
        }
        if !identityVault.identitySessions.contains(session) {
            guard type == "identity_action_request", let args = event["arguments"] as? [String: Any],
                  args["action"] as? String == "select" else {
                reply(["error": "Open a private Identity task from Identity Vault first."])
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let row = IdentityReviewItem(label: "Open a private Identity task", detail: String((args["purpose"] as? String ?? "Use a private profile to help with this request.").prefix(2_000)))
                guard await self.identityVault.review(.init(sessionID: session, title: "Use Identity Vault",
                    destination: "A separate private task", explanation: "The new task has restricted tools and starts without this conversation's files or history. You choose what may be shared.",
                    items: [row], confirmation: "Open Identity task"))?.contains(row.id) == true else {
                    reply(["error": "Identity task creation cancelled."])
                    return
                }
                reply(["text": "The user chose a separate private Identity task. Continue there; no vault content was shared here."])
                await self.createIdentityTask(profileID: nil, prompt: args["purpose"] as? String, sendImmediately: false)
            }
            return
        }
        guard let provider = runtime?.identityProvider,
              provider.provider != "chatgpt",
              (event["provider"] as? String).map({ $0 == provider.provider }) ?? true,
              (event["model"] as? String).map({ $0 == provider.model }) ?? true else {
            reply(["error": "This task's provider changed or is not ready. Reopen the Identity task before sharing."])
            return
        }
        if let account = event["account_id"] as? String, !account.isEmpty, account != provider.accountID {
            reply(["error": "The requesting model account does not match this task."])
            return
        }
        if let endpoint = event["endpoint"] as? String, !endpoint.isEmpty,
           endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != provider.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            reply(["error": "The requesting provider endpoint changed. Reopen the Identity task."])
            return
        }
        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime, self.taskWorkers[session] === runtime else {
                reply(["error": "The private task is no longer active."])
                return
            }
            if type == "identity_context_request" {
                reply(await self.identityVault.resolveSources(event["source_refs"] as? [String] ?? [], session: session, provider: provider))
            } else {
                let args = event["arguments"] as? [String: Any] ?? [:]
                if ["open_application", "request_page_snapshot", "prepare_fill", "attach_document", "browser_action"].contains(args["action"] as? String ?? ""), session == self.currentSessionID {
                    self.selectInspectorTab(.preview)
                }
                reply(await self.identityVault.perform(arguments: args, session: session, provider: provider, browser: self.browser))
            }
        }
    }
}
