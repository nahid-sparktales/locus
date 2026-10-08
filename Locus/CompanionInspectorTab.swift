import SwiftUI

/// A companion conversation beside other work, or its overview while that same
/// conversation is already open in the center.
struct CompanionInspectorTab: View {
    @EnvironmentObject private var model: AppModel
    var revealMainWindow: () -> Void = {}
    var tracksPointer = true
    var showsCharacterHeader = true

    var body: some View {
        CompanionInspectorContent(panel: model.companionPanel, context: model.companionContext, revealMainWindow: revealMainWindow, showsCharacterHeader: showsCharacterHeader)
            .companionPointerScope(enabled: tracksPointer)
    }
}

private struct CompanionInspectorContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var runtime: RuntimeStatusModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @EnvironmentObject private var runs: OrchestrationRunsModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.companionActivityPresentation) private var activitySource
    @ObservedObject var panel: CompanionPanelModel
    @ObservedObject var context: CompanionContextSharingModel
    let revealMainWindow: () -> Void
    let showsCharacterHeader: Bool
    @StateObject private var selection = TranscriptSelectionStore()
    @StateObject private var scroll = TranscriptScrollCoordinator()
    @FocusState private var composerFocused: Bool
    @State private var clearConfirmationPresented = false
    @State private var toolsPresented = false
    @State private var tool: CompanionTool = .context

    private var scopeKey: String {
        "\(agentTeams.primaryCompanionID?.uuidString ?? "none")|\(model.companionWorkspacePath)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let profile = panel.profile {
                if showsCharacterHeader { header(profile); Divider() }
                if panel.isForegroundConversation {
                    overview(profile)
                } else {
                    conversationControls
                    transcript
                    composer(profile)
                }
            } else {
                VStack(spacing: 14) {
                    Text("Your companion").font(.locus(size: 20, weight: .semibold))
                    Text("A familiar face to talk with while you work.")
                        .foregroundStyle(colors.textSecondary)
                    Button("Set up your companion") {
                        revealMainWindow()
                        model.onboarding.beginCompanionSetup()
                    }
                        .buttonStyle(.locus(.primary))
                        .accessibilityIdentifier("companion.panel.setup")
                }
                .multilineTextAlignment(.center).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .locusWorkspaceBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.isForegroundConversation ? "Companion overview panel" : "Companion conversation panel")
        .accessibilityIdentifier("companion.panel")
        .task(id: scopeKey) { panel.activate() }
        .onChange(of: runtime.agentPhase.isOnline) { _, online in
            if online { panel.activate() }
        }
        .onChange(of: model.currentSessionID) { _, _ in panel.activate() }
        .sheet(isPresented: $toolsPresented) { CompanionToolsView(initialTool: tool) }
        .alert("Clear this companion chat?", isPresented: $clearConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Chat") { panel.clearConversation() }
                .accessibilityIdentifier("companion.panel.clear.confirm")
        } message: {
            Text("This conversation will be archived and a fresh chat with your companion will open.")
        }
    }

    private func header(_ profile: AgentProfile) -> some View {
        let isHome = SessionSummary.canonicalWorkspacePath(panel.conversationWorkspacePath)
            == SessionSummary.canonicalWorkspacePath(model.savedAgentHomePath(profile))
        let folderTitle = isHome ? "Companion home"
            : model.savedAgentWorkspaceTitle(profile, path: panel.conversationWorkspacePath)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(folderTitle, systemImage: isHome ? "house" : "folder")
                    .font(.locus(size: 10)).foregroundStyle(colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(panel.conversationWorkspacePath)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Companion folder, \(folderTitle)")
                    .accessibilityIdentifier("companion.panel.workspace")
                Spacer(minLength: 0)
                Menu {
                    Button("Companion tools…") { tool = .context; toolsPresented = true }
                    Button("Show desktop companion") { model.companionDesktop.show() }
                    Divider()
                    Button("Profile and activity") { revealMainWindow(); model.selectSavedAgent(profile) }
                    Button("Edit companion") { revealMainWindow(); model.presentSavedAgentEditor(profile) }
                    Button("Models & Providers") { revealMainWindow(); model.presentSettings(.accounts) }
                    Divider()
                    Button(model.companionHasUnread ? "Mark as read" : "Mark as unread") {
                        model.markCompanionRead(!model.companionHasUnread)
                    }
                    .disabled(panel.selectedSessionID == nil)
                    .accessibilityIdentifier("companion.panel.markReadState")
                    Button("Open full conversation") { revealMainWindow(); panel.openFullConversation() }
                        .disabled(panel.selectedSessionID == nil || panel.isLoading)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Companion options")
                .accessibilityIdentifier("companion.panel.options")
            }
            HStack {
                AgentAvatarView(profileID: profile.id, name: profile.name, size: 94)
                    .frame(width: 80, height: 80)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(profile.name), your companion")
            .accessibilityIdentifier("companion.panel.character")
            Text(profile.name)
                .font(.locus(size: 18, weight: .semibold)).lineLimit(1)
                .accessibilityIdentifier("companion.panel.name")
            if let activitySource {
                CompanionSidebarStatus(source: activitySource, profileID: profile.id)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func overview(_ profile: AgentProfile) -> some View {
        let activeProfile = panel.selectedSessionID.map { model.agentChatProfile(profile, sessionID: $0) } ?? profile
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your companion at a glance")
                    .font(.locus(size: 13, weight: .semibold))
                LabeledContent("Role", value: activeProfile.role.title)
                LabeledContent("Model", value: activeProfile.model.nilIfEmpty ?? "Choose a model")
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button { tool = .context; toolsPresented = true } label: {
                        Label("Companion tools", systemImage: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("companion.panel.tools")
                    Spacer(minLength: 0)
                    Button("Profile") { revealMainWindow(); model.selectSavedAgent(profile) }
                        .accessibilityIdentifier("companion.panel.profile")
                }
                .buttonStyle(.locus(.quiet))
                .foregroundStyle(colors.accentAction)
            }
            .font(.locus(size: 11)).padding(16)
            Divider()
            CompanionActivityCardsView(revealMainWindow: revealMainWindow, minimumWidth: 0, minimumHeight: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.panel.overview")
    }

    private var conversationControls: some View {
        HStack(spacing: 8) {
            Text("Your conversation")
                .foregroundStyle(colors.textSecondary)
            Spacer(minLength: 0)
            Button { clearConfirmationPresented = true } label: {
                Label(panel.isClearing ? "Clearing…" : "Clear chat", systemImage: "eraser")
            }
            .buttonStyle(.locus(.quiet))
            .disabled(!panel.canClearConversation)
            .help("Start fresh with your companion")
            .accessibilityIdentifier("companion.panel.clear")
        }
        .font(.locus(size: 11)).padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let scope = model.companionScope, panel.selectedSessionID == scope.sessionID {
                        CompanionFocusCheckInView(sessionID: scope.sessionID) {
                            tool = .focus; toolsPresented = true
                        }
                        CompanionCatchUpView(backend: model.backend, scope: scope,
                            openConversation: { revealMainWindow(); panel.openFullConversation() },
                            reviewChanges: { revealMainWindow(); model.showTaskDetail(sessionID: scope.sessionID) },
                            resume: { saved in
                                if saved.goal?.isCompanionSession == true { tool = .focus; toolsPresented = true }
                                else { model.resumeCompanionTask(saved, scope: scope) }
                            })
                    }
                    if panel.isLoading || panel.isCreating {
                        ProgressView(panel.isCreating ? "Creating conversation…" : "Opening conversation…")
                            .controlSize(.small).frame(maxWidth: .infinity, minHeight: 100)
                    } else if panel.selectedSessionID == nil {
                        VStack(spacing: 12) {
                            Text("Talk with your companion")
                                .font(.locus(size: 17, weight: .semibold))
                            Text("One ongoing conversation with your companion, always here when you need it.")
                                .font(.locus(size: 12)).foregroundStyle(colors.textSecondary)
                            Button("Start conversation") { panel.createConversation() }
                                .buttonStyle(.locus(.primary))
                                .disabled(!runtime.agentPhase.isOnline)
                                .accessibilityIdentifier("companion.panel.start")
                        }
                        .multilineTextAlignment(.center).padding(.vertical, 26)
                    } else if panel.blocks.isEmpty {
                        Text("What would you like to talk about?")
                            .font(.locus(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    if !panel.isLoading {
                        ForEach(panel.blocks) { block in
                            MessageBlockView(block: block, thinkingVisibility: model.thinkingVisibility,
                                accent: model.effectiveAccent, workspacePath: panel.conversationWorkspacePath,
                                actionsDisabled: panel.isForegroundConversation,
                                canRewind: false, canRegenerate: false, showsAssistantMarker: false,
                                showsAssistantActions: !block.isStreaming,
                                accessibilityIdentifier: "companion.panel.message.\(block.id.uuidString)",
                                selectionStore: selection, selectionRowID: "companion-\(block.id.uuidString)",
                                onCopy: { format in model.copyResponse(block.text, format: format,
                                    reasoningFormat: block.reasoningFormat ?? .legacyTags) },
                                onUseAsDraft: { panel.draft = block.text; composerFocused = true },
                                onMakeReusableCheck: {}, onRewind: {}, onRegenerate: {},
                                onOpenWorkspaceReference: {
                                    revealMainWindow()
                                    model.openWorkspaceReference($0, workspace: panel.conversationWorkspacePath)
                                },
                                showsConversationActions: false)
                                .environment(\.responseOutputContext,
                                    outputContext)
                        }
                    }
                    Color.clear.frame(height: 1).id("companion-end")
                }
                .padding(16).frame(maxWidth: .infinity)
                .background { TranscriptSelectionScope().allowsHitTesting(false).accessibilityHidden(true) }
                .background {
                    CrewTranscriptScrollBridge(coordinator: scroll) { reader.scrollTo("companion-end", anchor: .bottom) }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: panel.selectedSessionID) { _, _ in scroll.jumpToLatest(); syncSelection() }
            .onChange(of: panel.blocks) { _, _ in syncSelection(); scroll.contentMayHaveChanged() }
            .overlay(alignment: .bottom) {
                if scroll.followState.showsJumpToLatest {
                    Button("Jump to latest", systemImage: "arrow.down") { scroll.jumpToLatest() }
                        .buttonStyle(.bordered).padding(8)
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .accessibilityIdentifier("companion.panel.transcript")
        .task(id: "\(panel.selectedSessionID ?? "")|\(panel.hasLoadedConversation)|\(model.companionReadRevision)") {
            if panel.hasLoadedConversation { model.markCompanionRead() }
        }
    }

    private func syncSelection() {
        selection.syncRows(panel.blocks.map { "companion-\($0.id.uuidString)" })
        selection.onDragActiveChange = { scroll.setSelectionDragActive($0) }
        selection.onViewportAnchorChange = { scroll.setSelectionViewportAnchor($0) }
    }

    private var outputContext: ResponseOutputContext {
        var context = model.responseOutputContext(sessionID: panel.selectedSessionID ?? "")
        // Image editing uses the full conversation's attachment composer.
        // It must never attach a side-panel image to the unrelated center chat.
        context.allowsImageEditing = false
        context.attachImage = { _ in }
        context.allowsForegroundToolResults = false
        context.openFullConversation = { revealMainWindow(); panel.openFullConversation() }
        let root = panel.conversationWorkspacePath
        let foregroundShowFiles = context.showFiles
        context.showFiles = { workspace, showHidden in
            guard SessionSummary.canonicalWorkspacePath(workspace) == SessionSummary.canonicalWorkspacePath(root) else { return }
            if SessionSummary.canonicalWorkspacePath(root) == SessionSummary.canonicalWorkspacePath(model.workspacePath) {
                foregroundShowFiles(workspace, showHidden)
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
            }
        }
        return context
    }

    private func composer(_ profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = panel.error ?? panel.availabilityIssue {
                Text(issue).font(.locus(size: 11)).foregroundStyle(colors.textSecondary)
                    .textSelection(.enabled).accessibilityIdentifier("companion.panel.notice")
            }
            if panel.canRetryLoading {
                Button("Retry conversation") { panel.retryLoading() }
                    .accessibilityIdentifier("companion.panel.retry")
            }
            if panel.state.status == "needs_attention" {
                Button("Review request in conversation") { revealMainWindow(); panel.openFullConversation() }
                    .buttonStyle(.locus()).accessibilityIdentifier("companion.panel.review")
            }
            if !runtime.agentPhase.isOnline {
                Button("Reconnect Locus") { Task { await model.bootstrap() } }
                    .accessibilityIdentifier("companion.panel.reconnect")
            }
            CompanionContextSharingView(model: context)
            CompanionVoiceControls()
            VStack(spacing: 0) {
                ComposerTextInput(text: $panel.draft, placeholder: "Message \(profile.name)…",
                    focus: $composerFocused, accessibilityID: "companion.panel.input",
                    accessibilityName: "Message \(profile.name) in companion panel",
                    onReturn: { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        if panel.canSend { panel.send() }
                        return .handled
                    })
                    .disabled(panel.selectedSessionID == nil || panel.isLoading || panel.isForegroundConversation)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if panel.state.busy || panel.isSending {
                        Text(panel.state.status == "queued" ? "Queued" : panel.state.status == "needs_attention" ? "Needs attention" : panel.state.busy ? "Working" : "Sending…")
                            .font(.locus(size: 10)).foregroundStyle(colors.textSecondary)
                        Button("Stop") { panel.stop() }
                            .disabled(panel.isForegroundConversation)
                            .accessibilityIdentifier("companion.panel.stop")
                    } else {
                        Button { panel.send() } label: {
                            Image(systemName: "arrow.up").frame(width: 28, height: 28)
                        }
                        .buttonStyle(.locus(.primary)).disabled(!panel.canSend)
                        .accessibilityLabel("Send to \(profile.name)")
                        .accessibilityIdentifier("companion.panel.send")
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            .modifier(ComposerCardStyle(focused: composerFocused, accent: colors.accentAction))
        }
        .padding(12)
    }
}
