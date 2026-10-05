import SwiftUI

/// A second view of canonical saved-agent chats. The panel's presentation owner
/// uses the existing background workers without taking over the central chat.
struct CompanionInspectorTab: View {
    @EnvironmentObject private var model: AppModel
    var revealMainWindow: () -> Void = {}

    var body: some View {
        CompanionInspectorContent(panel: model.companionPanel, revealMainWindow: revealMainWindow)
    }
}

private struct CompanionInspectorContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var runtime: RuntimeStatusModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.companionActivityPresentation) private var activitySource
    @ObservedObject var panel: CompanionPanelModel
    let revealMainWindow: () -> Void
    @StateObject private var selection = TranscriptSelectionStore()
    @StateObject private var scroll = TranscriptScrollCoordinator()
    @FocusState private var composerFocused: Bool

    private var scopeKey: String {
        "\(agentTeams.primaryCompanionID?.uuidString ?? "none")|\(model.companionWorkspacePath)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let profile = panel.profile {
                header(profile)
                Divider()
                conversationControls
                transcript
                composer(profile)
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
        .accessibilityLabel("Companion conversation panel")
        .accessibilityIdentifier("companion.panel")
        .task(id: scopeKey) { panel.activate() }
        .onChange(of: runtime.agentPhase.isOnline) { _, online in
            if online { panel.activate() }
        }
        .onChange(of: model.currentSessionID) { _, _ in panel.activate() }
    }

    private func header(_ profile: AgentProfile) -> some View {
        HStack(spacing: 12) {
            Button { revealMainWindow(); model.selectSavedAgent(profile) } label: {
                AgentAvatarView(profileID: profile.id, name: profile.name, size: 72)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(profile.name)’s profile")
            .help("Open profile and activity")
            VStack(alignment: .leading, spacing: 4) {
                Button { revealMainWindow(); model.selectSavedAgent(profile) } label: {
                    Text(profile.name).font(.locus(size: 18, weight: .semibold)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("companion.panel.name")
                .help("Open profile and activity")
                workspaceMenu(profile)
                if let activitySource {
                    CompanionSidebarStatus(source: activitySource, profileID: profile.id)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Profile and activity") { revealMainWindow(); model.selectSavedAgent(profile) }
                Button("Edit companion") { revealMainWindow(); model.presentSavedAgentEditor(profile) }
                Button("Models & Providers") { revealMainWindow(); model.presentSettings(.accounts) }
                Divider()
                Button("Open full conversation") { revealMainWindow(); panel.openFullConversation() }
                    .disabled(panel.selectedSessionID == nil || panel.isLoading)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Companion options")
            .accessibilityIdentifier("companion.panel.options")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func workspaceMenu(_ profile: AgentProfile) -> some View {
        Menu {
            ForEach(model.savedAgentWorkspaceChoices(profile), id: \.path) { choice in
                Button { model.selectCompanionWorkspace(choice.path) } label: {
                    let title = choice.path == model.savedAgentHomePath(profile) ? "Companion home" : choice.title
                    if choice.path == panel.workspace { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
                .help(choice.path)
            }
            Divider()
            Button("Choose a folder…") {
                if let path = model.chooseSavedAgentProjectFolder() { model.selectCompanionWorkspace(path) }
            }
        } label: {
            Label(panel.workspace == model.savedAgentHomePath(profile) ? "Companion home"
                  : model.savedAgentWorkspaceTitle(profile, path: panel.workspace),
                  systemImage: panel.workspace == model.savedAgentHomePath(profile) ? "house" : "folder")
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.locus(size: 10)).foregroundStyle(colors.textSecondary)
        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        .help("Choose your companion’s folder. Existing conversations keep their folders.")
        .accessibilityLabel("Companion folder")
        .accessibilityValue(panel.workspace == model.savedAgentHomePath(profile) ? "Companion home"
                            : model.savedAgentWorkspaceTitle(profile, path: panel.workspace))
        .accessibilityIdentifier("companion.panel.workspace")
    }

    private var conversationControls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(panel.chats) { chat in
                    Button { panel.select(chat) } label: {
                        if panel.selectedSessionID == chat.id {
                            Label(chat.displayTitle, systemImage: "checkmark")
                        } else { Text(chat.displayTitle) }
                    }
                }
            } label: {
                Label(panel.chats.first { $0.id == panel.selectedSessionID }?.displayTitle ?? "Conversations",
                      systemImage: "bubble.left.and.bubble.right")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .disabled(panel.chats.isEmpty)
            .accessibilityIdentifier("companion.panel.history")
            Spacer(minLength: 0)
            Button { panel.createConversation() } label: {
                Image(systemName: "square.and.pencil").frame(width: 26, height: 26)
            }
            .buttonStyle(.locus(.icon))
            .disabled(panel.isCreating || !runtime.agentPhase.isOnline)
            .help("New companion conversation in the selected folder")
            .accessibilityLabel("New companion conversation")
            .accessibilityIdentifier("companion.panel.new")
        }
        .font(.locus(size: 11)).padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if panel.isLoading || panel.isCreating {
                        ProgressView(panel.isCreating ? "Creating conversation…" : "Opening conversation…")
                            .controlSize(.small).frame(maxWidth: .infinity, minHeight: 100)
                    } else if panel.selectedSessionID == nil {
                        VStack(spacing: 12) {
                            Text("Talk with your companion")
                                .font(.locus(size: 17, weight: .semibold))
                            Text("Start a conversation in your companion’s selected folder. Your current task stays open.")
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
                    Picker("Companion mode", selection: $panel.mode) {
                        Text("Ask").tag(WorkMode.ask)
                        Text("Work").tag(WorkMode.work)
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel("Companion mode").accessibilityIdentifier("companion.panel.mode")
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
