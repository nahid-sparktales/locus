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
                && !account.resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Pushes the image provider to the local agent, and to the current
    /// session's worker when one is live. Like the chat provider, the key
    /// travels in memory only and is re-sent after every agent restart.
    @discardableResult
    func applyImageProvider(announce: Bool = false) async -> Bool {
        // An agent that has switched the capability off has no route to push
        // to; the Settings section already explains why the controls are off.
        guard backendCapabilities["image_generation_v1"] != false else { return true }
        let body = imageProviderRequestBody()
        do {
            let state = try await imageGeneration.apply(body: body)
            if let worker = taskWorkers[currentSessionID] {
                _ = try? await worker.service.post(
                    "/api/images/provider",
                    body: body,
                    as: ImageProviderStateResponse.self
                )
            }
            guard announce else { return true }
            showToast(
                state.configured
                    ? "Image generation uses \(state.model) on \(selectedImageAccount?.displayName ?? shortHost(state.host))"
                    : "Image generation is off"
            )
            return true
        } catch {
            if announce {
                showToast("Could not update image generation: \(error.localizedDescription)")
            }
            return false
        }
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
