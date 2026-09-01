import Foundation

extension AppModel {
    var eligibleVoiceAccounts: [ProviderAccount] {
        providerAccounts.filter { account in
            (account.kind == .codex || account.kind == .custom)
                && account.isCredentialReady
                && !account.resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var selectedVoiceAccount: ProviderAccount? {
        guard let rawID = settings.voiceCloudAccountID,
              let id = UUID(uuidString: rawID)
        else { return nil }
        return eligibleVoiceAccounts.first(where: { $0.id == id })
    }

    var voiceCloudConfiguration: VoiceCloudConfiguration? {
        guard settings.resolvedVoiceSpeechEngine == .openAICompatible,
              let account = selectedVoiceAccount,
              let baseURL = URL(string: RemoteEndpointTester.normalizeBaseURL(account.resolvedBaseURL))
        else { return nil }
        let language = settings.voiceLanguageIdentifier
            .split(maxSplits: 1, whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init) ?? ""
        return VoiceCloudConfiguration(
            accountID: account.id.uuidString,
            baseURL: baseURL,
            apiKey: CredentialStore.get(account: account.credentialAccount) ?? "",
            transcriptionModel: settings.voiceCloudTranscriptionModel
                .trimmingCharacters(in: .whitespacesAndNewlines),
            speechModel: settings.voiceCloudSpeechModel
                .trimmingCharacters(in: .whitespacesAndNewlines),
            voiceIdentifier: settings.voiceCloudVoiceIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines),
            languageIdentifier: language
        )
    }

    @discardableResult
    func acceptVoiceTranscript(_ text: String, purpose: VoiceInputPurpose) -> Bool {
        switch purpose {
        case .dictation:
            appendTranscriptToDraft(text)
            return false
        case .capabilityTest:
            return false
        case .conversation:
            guard settings.resolvedVoiceSendBehavior == .sendOnStop else {
                appendTranscriptToDraft(text)
                composerFocusToken = UUID()
                return false
            }
            guard isAgentOnline else {
                appendTranscriptToDraft(text)
                composerFocusToken = UUID()
                showToast("Voice text kept as a draft — reconnect the local agent to send")
                return false
            }
            send(
                text,
                preservingDraftOnFailure: false,
                requeueingOnFailure: true,
                includeAttachments: false,
                consumeMatchingDraft: false,
                allowLocalCommands: false
            )
            return true
        }
    }

    func appendTranscriptToDraft(_ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if draftText.isEmpty || draftText.last?.isWhitespace == true {
            draftText += text
        } else {
            draftText += " \(text)"
        }
    }

    func setAppleNetworkRecognitionConsent(_ allowed: Bool) {
        var updated = settings
        updated.voiceAppleNetworkRecognitionAllowed = allowed
        applySettings(updated, showConfirmation: false)
    }

    func announceVoiceAttention(_ kind: VoiceAttentionKind, token: String) {
        voiceControl.announceAttention(kind, token: token)
    }

    func completeVoiceTurnIfNeeded() {
        let attention: VoiceAttentionKind?
        let attentionToken: String?
        if let pendingUserQuestion {
            attention = .structuredQuestion
            attentionToken = pendingUserQuestion.id
        } else if planApprovalPending {
            attention = .planApproval
            attentionToken = activePlan?.id
        } else {
            attention = nil
            attentionToken = nil
        }
        voiceControl.handleCompletedTurn(
            sessionID: currentSessionID,
            blocks: blocks,
            attention: attention,
            attentionToken: attentionToken
        )
    }
}
