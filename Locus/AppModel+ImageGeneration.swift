import Foundation

/// The image provider handoff: which accounts qualify, the
/// `/api/images/provider` body, the push itself, and "Edit in chat" from a
/// generated image card. Mirrors the voice account rules and the provider
/// route push — the key leaves the credential file only inside the request.
extension AppModel {
    /// Accounts able to serve the OpenAI Images API: an image-capable kind
    /// with its credential in place and an endpoint to call.
    var eligibleImageAccounts: [ProviderAccount] {
        providerAccounts.filter { account in
            account.kind.supportsImageGeneration
                && account.isCredentialReady(in: credentialStore)
                && (account.kind == .chatGPT
                    || !account.resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The chosen image account, or nil when none is chosen, it was removed,
    /// or it no longer qualifies — all of which read as "off".
    var selectedImageAccount: ProviderAccount? {
        guard let rawID = settings.imageGenerationAccountID,
              let id = UUID(uuidString: rawID)
        else { return nil }
        return eligibleImageAccounts.first(where: { $0.id == id })
    }

    /// The `/api/images/provider` payload for the current choice.
    ///
    /// Pure, so the rules can be tested without a backend: an eligible account
    /// contributes its endpoint, label, and key; anything else disables the
    /// tools. The key is omitted, not sent empty, when the store has none.
    func imageProviderRequestBody() -> [String: Any] {
        guard let account = selectedImageAccount else {
            return ["enabled": false]
        }
        if account.kind == .chatGPT {
            return [
                "enabled": true, "provider": "chatgpt", "account_id": account.id.uuidString,
                "account_label": account.displayName, "codex_home_id": account.codexHomeIdentifier,
                "model": "gpt-image-2", "chat_model": account.preferredModel,
            ]
        }
        let model = settings.imageGenerationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "enabled": true,
            "account_id": account.id.uuidString,
            "account_label": account.displayName,
            "base_url": account.resolvedBaseURL,
            "model": model.isEmpty ? AppSettings().imageGenerationModel : model,
            "size": settings.imageGenerationSize,
            "quality": settings.imageGenerationQuality,
        ]
        if let key = credentialStore.get(account: account.credentialAccount), !key.isEmpty {
            body["api_key"] = key
        }
        return body
    }

    /// Pushes the image provider to the local agent and to every live chat
    /// worker, the way `applyProvider` fans the chat route out: a rotated or
    /// removed key must reach each process that holds a copy. Like the chat
    /// provider, the key travels in memory only and is re-sent after every
    /// agent restart. A process that refused because a turn was running is
    /// pushed again when that turn ends.
    @discardableResult
    func applyImageProvider(announce: Bool = false) async -> Bool {
        // An agent that has switched the capability off has no route to push
        // to; the Settings section already explains why the controls are off.
        guard backendCapabilities["image_generation_v1"] != false else { return true }
        let body = imageProviderRequestBody()
        var applied = true
        var state: ImageProviderStateResponse?
        do {
            state = try await imageGeneration.apply(body: body)
        } catch {
            applied = false
            if ImageGenerationModel.isBusyRefusal(error) || isBusy {
                imageGeneration.deferPushUntilIdle()
            }
            if announce {
                showToast("Could not update image generation: \(error.localizedDescription)")
            }
        }
        for worker in Array(taskWorkers.values) {
            if await pushImageProvider(to: worker.service, body: body, announceFailure: announce) == .busy {
                imageGeneration.deferPushUntilIdle()
            }
        }
        guard announce, let state else { return applied }
        showToast(
            state.configured
                ? "Image generation uses \(state.model) on \(selectedImageAccount?.displayName ?? shortHost(state.host))"
                : "Image generation is off"
        )
        return applied
    }

    /// How one agent process answered an image provider push.
    enum ImageProviderPushOutcome: Equatable {
        case applied
        /// Refused because a turn was running (HTTP 409); worth retrying once
        /// the turn ends.
        case busy
        case failed
        /// The agent reports the capability off, so there is nothing to push.
        case skipped
    }

    /// Hands the image provider to one chat worker — a freshly spawned one
    /// before it resumes its conversation, or every live one after a change.
    /// Internal for regression tests. A failure never costs the worker: the
    /// image tools are simply absent in it, which is announced once so a
    /// "no provider configured" answer is not a mystery.
    @discardableResult
    func pushImageProvider(
        to service: BackendService,
        body: [String: Any]? = nil,
        announceFailure: Bool = true
    ) async -> ImageProviderPushOutcome {
        guard backendCapabilities["image_generation_v1"] != false else { return .skipped }
        let body = body ?? imageProviderRequestBody()
        do {
            _ = try await imageGeneration.push(body: body, to: service)
            return .applied
        } catch {
            let busy = ImageGenerationModel.isBusyRefusal(error)
            // A worker told "off" that stays off has lost nothing worth a toast.
            if announceFailure, body["enabled"] as? Bool == true {
                showToast(
                    busy
                        ? "Image generation will update in this chat after the current turn"
                        : "Image generation is unavailable in this chat: \(error.localizedDescription)"
                )
            }
            return busy ? .busy : .failed
        }
    }

    /// A push the agent refused mid-turn, re-sent once it is idle. Called from
    /// the turn-done and slash-result handlers beside the pending chat
    /// provider switch.
    func applyPendingImageProviderIfNeeded() {
        guard imageGeneration.takeDeferredPush() else { return }
        Task { await applyImageProvider(announce: false) }
    }

    /// "Edit in chat" on a generated image: attaches the file to the composer
    /// and, when the draft is empty, starts the request with its workspace
    /// path so the model passes that path to `edit_image`.
    func attachWorkspaceImageForEditing(_ reference: WorkspaceArtifactReference) {
        // Re-checked rather than trusted: the reference was classified when the
        // card rendered, and this is the security boundary at activation.
        guard reference.kind == .image,
              let contained = MarkdownLinkPolicy.containedWorkspaceFileURL(
                reference.relativePath,
                workspacePath: workspacePath
              ),
              contained == reference.url.standardizedFileURL.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: contained.path)
        else {
            showToast("That image is no longer available in this workspace")
            return
        }
        guard chatAttachments.count < 10 else {
            chatAttachmentNotice = "A chat message can include up to 10 attachments."
            showToast("A chat message can include up to 10 attachments.")
            return
        }
        loadChatAttachments(from: [contained])
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = "Edit `\(reference.relativePath)`: "
        }
        composerFocusToken = UUID()
    }
}
