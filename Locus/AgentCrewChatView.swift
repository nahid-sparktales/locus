import AppKit
import SwiftUI

/// The shared crew ledger lives in the workspace and uses the native chat
/// renderer and editor. Agent World embeds this same surface.
struct AgentCrewChatView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @ObservedObject var model: AgentCrewChatModel
    @EnvironmentObject private var appModel: AppModel
    var allowsInteraction = true
    var sidebarVisible = true
    var showSidebar: () -> Void = {}
    @State private var presentedWorkspace: String?
    @StateObject private var selection = TranscriptSelectionStore()
    @StateObject private var scrollCoordinator = TranscriptScrollCoordinator()
    @FocusState private var composerFocused: Bool

    private var projectName: String { URL(fileURLWithPath: model.workspace).lastPathComponent }

    var body: some View {
        Group {
            if let presentedWorkspace, presentedWorkspace != model.workspace {
                ContentUnavailableView {
                    Label("Return to this crew", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Another window is showing a different project’s Crew Chat.")
                } actions: {
                    Button("Open this project’s Crew Chat") { model.activate(workspace: presentedWorkspace) }
                        .disabled(!allowsInteraction)
                }
            } else {
                VStack(spacing: 0) {
                    header
                    members
                    transcript
                    composer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .locusWorkspaceBackground()
        .foregroundStyle(viewColors.ink)
        .onAppear {
            model.refresh()
            if presentedWorkspace == nil { presentedWorkspace = model.workspace }
            composerFocused = true
            syncSelection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("crewChat.workspace")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !sidebarVisible {
                Button(action: showSidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.locus(.icon)).accessibilityLabel("Show sidebar")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Crew Chat").font(.locus(size: 12, weight: .semibold))
                Label(projectName, systemImage: "folder.fill")
                    .font(.locus(size: 10)).foregroundStyle(viewColors.muted).lineLimit(1)
            }
            Spacer()
            if model.pendingReplyCount > 0 {
                Label("\(model.pendingReplyCount) working", systemImage: "ellipsis.bubble")
                    .font(.locus(size: 10)).foregroundStyle(viewColors.muted)
            } else {
                Text("Shared with Agent World").font(.locus(size: 10)).foregroundStyle(viewColors.muted)
            }
        }
        .padding(.leading, sidebarVisible ? 20 : 76).padding(.trailing, 18)
        .frame(height: WorkspaceLayoutMetrics.toolbarHeight)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(viewColors.line).frame(height: 1) }
    }

    private var members: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(model.members) { member in
                    Button {
                        model.mention(profileID: member.id)
                        composerFocused = true
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(member.available ? viewColors.success : viewColors.muted).frame(width: 5, height: 5)
                            Text("@\(member.name)").lineLimit(1)
                        }
                        .font(.locus(size: 10, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(viewColors.ink.opacity(0.045), in: Capsule())
                    }
                    .buttonStyle(.locus()).disabled(!allowsInteraction)
                    .help(member.availabilityReason ?? "Mention \(member.name) · \(member.role)")
                    .accessibilityLabel("Mention \(member.name)")
                    .accessibilityIdentifier("crewChat.member.\(member.id.uuidString)")
                }
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }.scrollIndicators(.hidden)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What should the crew work on?").font(.locus(size: 22, weight: .semibold))
                            Text("Ask a question or give the crew a task. Mention an agent to choose who responds.")
                                .font(.locus(size: 13)).foregroundStyle(viewColors.muted)
                        }.padding(.vertical, 40)
                    }
                    ForEach(model.messages) { message in
                        CrewTranscriptMessage(message: message, blocks: model.visibleBlocks(for: message),
                            workspace: model.workspace, selection: selection, allowsInteraction: allowsInteraction,
                            useDraft: { model.draft = $0; composerFocused = true },
                            open: { model.openReply(messageID: message.id) },
                            stop: { model.stopReply(messageID: message.id) })
                    }
                    Color.clear.frame(height: 1).id("crew-end")
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background { TranscriptSelectionScope().allowsHitTesting(false).accessibilityHidden(true) }
                .background {
                    CrewTranscriptScrollBridge(coordinator: scrollCoordinator) {
                        reader.scrollTo("crew-end", anchor: .bottom)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: model.messages.count) { _, _ in scrollCoordinator.jumpToLatest() }
            .onChange(of: model.messages) { _, _ in syncSelection() }
            .onChange(of: model.outputRevision) { _, _ in
                syncSelection()
                scrollCoordinator.contentMayHaveChanged()
            }
            .overlay(alignment: .bottom) {
                if scrollCoordinator.followState.showsJumpToLatest {
                    Button("Jump to latest", systemImage: "arrow.down") { scrollCoordinator.jumpToLatest() }
                        .buttonStyle(.bordered).padding(10)
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .accessibilityIdentifier("crewChat.history")
    }

    private func syncSelection() {
        selection.syncRows(model.messages.flatMap { message in
            model.visibleBlocks(for: message).map { "crew-\(message.id.uuidString)-\($0.id.uuidString)" }
        })
        selection.onDragActiveChange = { scrollCoordinator.setSelectionDragActive($0) }
        selection.onViewportAnchorChange = { scrollCoordinator.setSelectionViewportAnchor($0) }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.locus(size: 11)).foregroundStyle(viewColors.coral)
                    .textSelection(.enabled).frame(maxWidth: 740, alignment: .leading)
                    .accessibilityIdentifier("crewChat.error")
            }
            VStack(spacing: 0) {
                if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    routingPreview.padding(.horizontal, 12).padding(.top, 10)
                }
                ComposerTextInput(text: $model.draft, placeholder: "Message the crew…", focus: $composerFocused,
                    onReturn: { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        if allowsInteraction && model.canSend { model.submit() }
                        return .handled
                    })
                    .disabled(!allowsInteraction)
                HStack(spacing: 10) {
                    Label("Automatic", systemImage: "sparkles")
                        .font(.locus(size: 10, weight: .medium)).foregroundStyle(viewColors.inkSoft)
                        .help("Agents decide whether to answer directly or use their available tools.")
                    Spacer()
                    if model.isSending {
                        Button(action: model.stopAllReplies) { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                            .buttonStyle(.locus(.icon)).help("Stop crew replies")
                            .accessibilityIdentifier("crewChat.stop")
                    }
                    Button { model.submit(); composerFocused = true } label: {
                        Image(systemName: "arrow.up").font(.locus(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent).tint(appModel.accentActionColor)
                    .disabled(!allowsInteraction || !model.canSend)
                    .help("Send (↵) · New line (⇧↵)")
                    .accessibilityLabel("Send message").accessibilityIdentifier("crewChat.send")
                }.padding(10)
            }
            .modifier(ComposerCardStyle(focused: composerFocused, accent: appModel.accentActionColor))
        }
        .padding(.horizontal, 24).padding(.bottom, 10).frame(maxWidth: .infinity)
    }

    private var routingPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.routingPreview.recipients.isEmpty {
                Text("To: " + model.routingPreview.recipients.map(\.name).joined(separator: ", "))
                    .font(.locus(size: 10, weight: .medium)).foregroundStyle(viewColors.muted)
            }
            ForEach(Array(model.routingPreview.issues.enumerated()), id: \.offset) { _, issue in
                Text(issue).font(.locus(size: 10)).foregroundStyle(viewColors.warning)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reuse native chat's scroll-following behavior, including yielding to the
/// reader when they scroll up or select a passage.
private struct CrewTranscriptScrollBridge: NSViewRepresentable {
    let coordinator: TranscriptScrollCoordinator
    let scrollToBottom: () -> Void

    func makeCoordinator() -> TranscriptScrollCoordinator { coordinator }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        coordinator.setBottomTarget(scrollToBottom)
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, view.window != nil, let coordinator else { return }
            coordinator.attach(from: view)
            coordinator.contentMayHaveChanged()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: TranscriptScrollCoordinator) {
        coordinator.detach(from: view)
    }
}

private struct CrewTranscriptMessage: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var appModel: AppModel
    let message: AgentCrewChatMessage
    let blocks: [ChatBlock]
    let workspace: String
    let selection: TranscriptSelectionStore
    let allowsInteraction: Bool
    let useDraft: (String) -> Void
    let open: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == .agent {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(appModel.accentActionColor)
                    Text(message.authorName).font(.locus(size: 12, weight: .semibold))
                    if message.status.isPending {
                        Text(message.status == .needsAttention ? "Needs attention" : message.status == .queued ? "Queued" : "Working")
                            .font(.locus(size: 10)).foregroundStyle(viewColors.muted)
                    }
                    Spacer()
                }
            }
            ForEach(blocks) { block in
                MessageBlockView(block: block, thinkingVisibility: appModel.thinkingVisibility,
                    accent: appModel.effectiveAccent, workspacePath: workspace, actionsDisabled: !allowsInteraction,
                    canRewind: false, canRegenerate: false, showsAssistantMarker: false,
                    showsAssistantActions: !block.isStreaming, accessibilityIdentifier: "crewChat.message.\(block.id.uuidString)",
                    selectionStore: selection, selectionRowID: "crew-\(message.id.uuidString)-\(block.id.uuidString)",
                    onCopy: { format in appModel.copyResponse(block.text, format: format, reasoningFormat: block.reasoningFormat ?? .legacyTags) },
                    onUseAsDraft: { useDraft(block.text) }, onMakeReusableCheck: {}, onRewind: {}, onRegenerate: {},
                    onOpenWorkspaceReference: appModel.openWorkspaceReference, showsConversationActions: false)
            }
            if let detail = message.statusDetail, !detail.isEmpty {
                Text(detail).font(.locus(size: 11)).foregroundStyle(viewColors.muted)
            }
            if message.role == .agent, message.sessionID != nil {
                HStack(spacing: 12) {
                    Button(message.status == .needsAttention ? "Review request" : "Open task", action: open)
                        .accessibilityIdentifier("crewChat.reply.\(message.id.uuidString).open")
                    if message.status.isPending { Button("Stop", action: stop) }
                }.font(.locus(size: 10)).buttonStyle(.link).disabled(!allowsInteraction)
            }
        }
    }
}

struct CrewChatSidebarEntry: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    let selected: Bool

    var body: some View {
        Button { model.openAgentCrewChat() } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(viewColors.accentAction)
                    .frame(width: 25, height: 25)
                    .background(viewColors.accentAction.opacity(selected ? 0.12 : 0.06),
                                in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crew Chat")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(viewColors.ink)
                        .lineLimit(1)
                    Text("Shared conversation")
                        .font(.locus(size: 8))
                        .foregroundStyle(viewColors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.locus(size: 8, weight: .medium))
                    .foregroundStyle(viewColors.muted)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            // Match the agent icon and title columns without adding a
            // disclosure button to a group that opens directly.
            .padding(.leading, 23)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? viewColors.accentAction.opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .help("Open the shared conversation for your agents")
        .accessibilityLabel("Crew Chat group chat")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("sidebar.crewChat")
    }
}
