import SwiftUI

extension AppModel {
    func startCompanionVoice() {
        guard settings.voiceControlsEnabled else { presentSettings(.chat); return }
        companionPanel.activate()
        guard let session = companionConversation, let profile = primaryCompanionProfile else {
            companionPanel.createConversation()
            showToast("Open your companion chat, then start voice.")
            return
        }
        let workspace = companionWorkspacePath
        voiceControl.enterExternalVoiceMode(sessionID: session.id, isValid: { [weak self] in
            self?.primaryCompanionProfile?.id == profile.id && self?.companionConversation?.id == session.id
                && self?.companionWorkspacePath == workspace
        }, transcript: { [weak self] text, purpose in
            guard let self else { return false }
            // Speech always belongs to the captured companion. It never inherits
            // the center's workspace, pending attachments or slash commands.
            let keepDraft = {
                if self.currentSessionID == session.id { self.appendTranscriptToDraft(text) }
                else {
                    let draft = self.paneDraft(for: session.id)
                    self.setPaneDraft(draft.isEmpty ? text : draft + " " + text, for: session.id)
                }
            }
            guard purpose == .conversation, self.settings.resolvedVoiceSendBehavior == .sendOnStop,
                  self.isAgentOnline, !self.savedAgentConversationState(session.id).busy else {
                keepDraft(); return false
            }
            let mode = self.companionPanel.mode
            let scope = CompanionConversationScope(sessionID: session.id, workspace: workspace, profileID: profile.id)
            let attachments = self.companionContext.scope == scope ? self.companionContext.attachments : []
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.companionConversation?.id == session.id,
                      self.primaryCompanionProfile?.id == profile.id else {
                    keepDraft(); self.voiceControl.failExternalTurn(sessionID: session.id); return
                }
                do {
                    try await self.sendSavedAgentTurn(sessionID: session.id, workspace: workspace,
                        profileID: profile.id, text: text, mode: mode, preservingForeground: true, attachments: attachments)
                    self.companionContext.consume(Set(attachments.map(\.id)), for: scope)
                } catch {
                    keepDraft()
                    self.voiceControl.failExternalTurn(sessionID: session.id)
                    self.showToast("Voice text kept as a draft: \(error.localizedDescription)")
                }
            }
            return true
        })
    }

    func completeCompanionVoiceTurnIfNeeded(sessionID: String) {
        guard voiceControl.externalSessionID == sessionID, companionConversation?.id == sessionID else { return }
        let state = savedAgentConversationState(sessionID)
        if state.status == "failed" { voiceControl.failExternalTurn(sessionID: sessionID); return }
        let attention: VoiceAttentionKind? = state.status == "needs_attention" ? .permission : nil
        if let attention {
            voiceControl.announceAttention(attention, token: taskConversationStates[sessionID]?.runID ?? sessionID)
            return
        }
        let runID = taskConversationStates[sessionID]?.runID
        Task { @MainActor [weak self] in
            guard let self,
                  let detail = try? await self.backend.get("/api/sessions/\(sessionID)", as: SessionDetailResponse.self),
                  self.voiceControl.externalSessionID == sessionID, self.companionConversation?.id == sessionID,
                  self.taskConversationStates[sessionID]?.runID == runID,
                  self.voiceControl.state == .waiting else { return }
            self.voiceControl.handleCompletedTurn(sessionID: sessionID,
                blocks: ChatTranscriptBuilder.blocks(from: detail.messages), attention: nil)
        }
    }
}

struct CompanionVoiceControls: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var voice: VoiceControlModel
    private var isCompanionVoice: Bool {
        voice.isVoiceModeActive && voice.externalSessionID == model.companionConversation?.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCompanionVoice {
                VoiceComposerStrip(voice: voice)
            } else {
                Button { model.startCompanionVoice() } label: { Label("Talk with companion", systemImage: "mic") }
                    .buttonStyle(.locus()).accessibilityIdentifier("companion.voice.start")
            }
        }
        .alert("Allow Apple online speech recognition?", isPresented: $voice.networkRecognitionConsentRequested) {
            Button("Keep on-device", role: .cancel) { voice.respondToAppleNetworkConsent(allowed: false) }
            Button("Allow") { voice.respondToAppleNetworkConsent(allowed: true) }
        } message: { Text("This language needs Apple’s online recognition. Audio will be sent to Apple while you record.") }
        .onChange(of: model.companionScope) { _, _ in
            if voice.externalSessionID != nil { voice.sessionDidChange() }
        }
        .onDisappear { if isCompanionVoice { voice.cancelRecording() } }
    }
}
