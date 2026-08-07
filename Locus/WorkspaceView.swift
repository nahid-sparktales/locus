import AppKit
import QuartzCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    private var sessionTitle: String {
        model.sessions.first(where: { $0.id == model.currentSessionID })?.displayTitle
            ?? (model.blocks.isEmpty ? "New session" : "Active session")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            switch model.agentRuntimePhase {
            case .recovering(let message):
                runtimeBanner(message, recovering: true)
            case .unavailable(let message):
                runtimeBanner(message, recovering: false)
            case .starting, .online:
                EmptyView()
            }

            if model.transcriptSearchPresented {
                TranscriptSearchBar()
                    .environmentObject(model)
            }

            ConversationView(streamingReply: model.streamingReply)
                .frame(maxHeight: .infinity)

            WorkStatusStrip(streamingReply: model.streamingReply)
                .environmentObject(model)

            ComposerView()
        }
        .background(LocusTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 16) {
            if model.sidebarCollapsed {
                HeaderIconButton(
                    symbol: "sidebar.left",
                    label: "Show sidebar",
                    identifier: "workspace.showSidebar"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.sidebarCollapsed = false
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                    if let branch = model.gitBranch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 7))
                            Text(branch)
                        }
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityLabel("Git branch \(branch)")
                        .accessibilityIdentifier("workspace.gitBranch")
                    }
                    Text("/")
                    Text("sessions")
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted.opacity(0.8))

                Text(sessionTitle)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
            }

            Spacer()

            ContextUsageChip()
                .environmentObject(model)

            Menu {
                ForEach(model.modelPickerSections) { section in
                    Section(section.title) {
                        if let message = section.emptyMessage {
                            Text(message)
                        }
                        ForEach(section.models, id: \.self) { name in
                            Button {
                                model.selectModel(account: section.account, model: name)
                            } label: {
                                // The checkmark answers "which one am I using",
                                // and the same model name can appear under two
                                // accounts — so the account has to match too.
                                if model.isCurrentRoute(account: section.account, model: name) {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Browse Hugging Face Models…") {
                    model.modelLibraryPresented = true
                }
                .accessibilityIdentifier("workspace.modelPicker.browseHuggingFace")
                Button("Refresh Models") {
                    Task {
                        await model.refreshMetadata()
                        await model.refreshAccountCatalogs(force: true)
                    }
                }
                Button("Manage Accounts…") {
                    model.settingsPage = .accounts
                    model.settingsPresented = true
                }
                .accessibilityIdentifier("workspace.modelPicker.manageAccounts")
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.activeAccount == nil ? "bolt.fill" : "cloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LocusTheme.signalDeep)
                    Text(model.modelPickerLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(LocusTheme.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
                .frame(maxWidth: 190)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Select Ollama model")
            .accessibilityIdentifier("workspace.modelPicker")

            Button {
                model.commandPalettePresented = true
            } label: {
                Image(systemName: "command")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 32, height: 32)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Command palette (⌘K)")
            .accessibilityLabel("Open command palette")
            .accessibilityIdentifier("workspace.commandPalette")

            Menu {
                // ⌘⇧K lives on the app menu's Clear Chat only — declaring it
                // here as well would register the same shortcut twice.
                Button("Clear Chat…") { model.requestClearChat() }
                    .disabled(model.isBusy || model.hasPendingPermission)
                    .accessibilityIdentifier("workspace.actions.clearChat")
                Button("Start New Session") { model.newSession() }
                    .disabled(model.isBusy || model.hasPendingPermission)
                    .accessibilityIdentifier("workspace.actions.newSession")
                Divider()
                Button("Clear Saved Sessions…") { model.requestClearSavedSessions() }
                    .disabled(model.isClearingSessions)
                    .accessibilityIdentifier("workspace.actions.clearSessions")
                Divider()
                Button("Export Current Session…") {
                    model.exportCurrentSession()
                }
                .disabled(!model.sessions.contains(where: { $0.id == model.currentSessionID }))
                .accessibilityIdentifier("workspace.actions.export")
                Divider()
                Picker("Thinking", selection: Binding(
                    get: { model.thinkingVisibility },
                    set: { model.thinkingVisibility = $0 }
                )) {
                    ForEach(ThinkingVisibility.allCases) { visibility in
                        Text(visibility.title)
                            .tag(visibility)
                            .accessibilityIdentifier("workspace.actions.thinking.\(visibility.rawValue)")
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 32, height: 32)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Workspace actions")
            .accessibilityIdentifier("workspace.actions")

            if model.inspectorCollapsed && !model.justChatEnabled {
                HeaderIconButton(
                    symbol: "sidebar.right",
                    label: "Show inspector",
                    identifier: "workspace.showInspector"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.inspectorCollapsed = false
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 72)
        .background(LocusTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func runtimeBanner(_ message: String, recovering: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: recovering ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                .foregroundStyle(recovering ? LocusTheme.warning : LocusTheme.coral)
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button("Settings") { model.settingsPresented = true }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .underline()
                .accessibilityIdentifier("banner.settings")
            Button("Retry") {
                model.retryLocalServices()
            }
            .font(.system(size: 9, weight: .semibold))
            .accessibilityIdentifier("banner.retry")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background((recovering ? LocusTheme.warning : LocusTheme.coral).opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((recovering ? LocusTheme.warning : LocusTheme.coral).opacity(0.25))
                .frame(height: 1)
        }
    }
}

private struct WorkStatusStrip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var streamingReply: StreamingReplyState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isBusy ? LocusTheme.signalDeep : LocusTheme.success)
                    .frame(width: 6, height: 6)
                Text(model.currentWorkPhase)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if model.isBusy, let started = model.activeWorkStartedAt {
                    Text(elapsed(from: started, to: context.date))
                        .monospacedDigit()
                }
                Spacer()
                if model.isBusy {
                    Text("~\(model.estimatedStreamingTokens.formatted()) streamed tokens")
                }
                if let info = model.sessionInfo {
                    Text("provider · \(info.promptTokens.formatted()) in / \(info.completionTokens.formatted()) out")
                }
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 24)
            .frame(height: 25)
            .background(LocusTheme.panel)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workspace.workStatus")
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Codex-style Chat/Work segmented control. This intentionally uses custom
/// capsule styling instead of the native macOS segmented picker so it matches
/// the compact dark control used in Codex.
struct JustChatControl: View {
    let isChatSelected: Bool
    let setChatSelected: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(
                title: "Chat",
                selected: isChatSelected,
                identifier: "workspace.mode.chat"
            ) {
                setChatSelected(true)
            }

            segment(
                title: "Work",
                selected: !isChatSelected,
                identifier: "workspace.mode.work"
            ) {
                setChatSelected(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(LocusTheme.paperDeep)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .shadow(color: LocusTheme.ink.opacity(0.08), radius: 2, y: 1)
        .layoutPriority(2)
        .animation(.easeInOut(duration: 0.16), value: isChatSelected)
        .help(
            isChatSelected
                ? "Just Chat is on — no workspace files, commands, skills, or MCP tools"
                : "Work mode can plan, inspect, and change the workspace"
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat or Work mode")
        .accessibilityValue(isChatSelected ? "Chat" : "Work")
        .accessibilityIdentifier("workspace.justChat")
    }

    private func segment(
        title: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? LocusTheme.white : LocusTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule()
                            .fill(LocusTheme.inkSoft)
                            .shadow(color: LocusTheme.ink.opacity(0.16), radius: 1, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

struct TranscriptFollowState: Equatable {
    var isNearBottom = true
    var isFollowingOutput = true

    /// `isFollowingOutput` is the explicit pin. A layout pass can temporarily
    /// move the bottom marker more than 24 points before the matching scroll
    /// callback runs; that content growth must not masquerade as user intent.
    var permitsAutomaticScroll: Bool { isFollowingOutput }
    var showsJumpToLatest: Bool { !isNearBottom || !isFollowingOutput }

    mutating func userScrolled(upward: Bool) {
        if upward {
            isFollowingOutput = false
        } else if isNearBottom {
            isFollowingOutput = true
        }
    }

    mutating func updateBottom(isNear: Bool) {
        isNearBottom = isNear
    }

    mutating func jumpToLatest() {
        isNearBottom = true
        isFollowingOutput = true
    }

    mutating func detach() {
        isFollowingOutput = false
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    let streamingReply: StreamingReplyState
    @StateObject private var scrollCoordinator = TranscriptScrollCoordinator()

    private let bottomID = "conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.blocks.isEmpty {
                        EmptyConversationView()
                            .environmentObject(model)
                    } else {
                        ForEach(model.blocks) { block in
                            Group {
                                if block.kind == .assistant,
                                   block.id == model.activeStreamingAssistantID
                                {
                                    ActiveAssistantBlockView(
                                        reply: streamingReply,
                                        thinkingVisibility: model.thinkingVisibility
                                    )
                                    .id(block.id)
                                } else {
                                    MessageBlockView(
                                        block: block,
                                        thinkingVisibility: model.thinkingVisibility,
                                        actionsDisabled: model.isBusy || model.hasPendingPermission,
                                        canRewind: model.canRewind(to: block),
                                        canRegenerate: model.canRegenerate(block),
                                        onCopy: { model.copyMessage(block.text) },
                                        onUseAsDraft: { model.useAsDraft(block.text) },
                                        onRewind: { model.rewind(to: block) },
                                        onRegenerate: { model.retryLastResponse() }
                                    )
                                    .equatable()
                                }
                            }
                            .overlay {
                                if let style = model.transcriptMatchStyle(for: block.id) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            style == .current
                                                ? LocusTheme.signalDeep
                                                : LocusTheme.lineStrong.opacity(0.7),
                                            lineWidth: style == .current ? 2 : 1
                                        )
                                        .padding(-7)
                                        .allowsHitTesting(false)
                                }
                            }
                            .id(block.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 28)
                .padding(.top, model.blocks.isEmpty ? 0 : 26)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background {
                TranscriptScrollBridge(coordinator: scrollCoordinator)
            }
            .overlay(alignment: .bottom) {
                if scrollCoordinator.followState.showsJumpToLatest, !model.blocks.isEmpty {
                    Button {
                        scrollCoordinator.jumpToLatest(animated: true)
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(LocusTheme.white)
                            .clipShape(Capsule())
                            .overlay { Capsule().stroke(LocusTheme.line, lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("conversation.jumpToLatest")
                }
            }
            .onChange(of: model.blocks.count) {
                scrollCoordinator.contentMayHaveChanged()
            }
            .onChange(of: model.transcriptSearchSelection) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
            .onChange(of: model.transcriptSearchQuery) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
        }
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let match = model.currentTranscriptMatch else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            proxy.scrollTo(match, anchor: .center)
        }
    }
}

struct TranscriptScrollMetrics {
    static func bottomDistance(
        documentBounds: CGRect,
        visibleRect: CGRect,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.maxY - visibleRect.maxY, 0)
        }
        return max(visibleRect.minY - documentBounds.minY, 0)
    }

    static func bottomOriginY(
        documentBounds: CGRect,
        viewportHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.maxY - viewportHeight, documentBounds.minY)
        }
        return documentBounds.minY
    }
}

/// Owns the underlying NSScrollView. Streaming height changes are pinned once
/// per display refresh by adjusting the clip-view origin directly; no SwiftUI
/// scrollTo transaction is created for tokens or reasoning.
@MainActor
final class TranscriptScrollCoordinator: ObservableObject {
    @Published private(set) var followState = TranscriptFollowState()

    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var displayLink: CADisplayLink?
    private var pinPending = false
    private var isProgrammaticScroll = false
    private var isUserLiveScrolling = false
    private var lastOriginY: CGFloat = 0

    func attach(from anchor: NSView) {
        guard let candidate = anchor.enclosingScrollView else { return }
        if scrollView === candidate, documentView === candidate.documentView { return }
        detachObservers()
        scrollView = candidate
        documentView = candidate.documentView
        candidate.contentView.postsBoundsChangedNotifications = true
        candidate.documentView?.postsFrameChangedNotifications = true
        lastOriginY = candidate.contentView.bounds.origin.y

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: candidate.documentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.documentFrameChanged() }
        })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: candidate.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.boundsChanged() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.liveScrollStarted() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.userViewportChanged() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.liveScrollEnded() }
        })

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self, weak candidate] event in
            guard let self, let candidate,
                  let window = candidate.window, event.window === window
            else { return event }
            let point = candidate.convert(event.locationInWindow, from: nil)
            guard candidate.bounds.contains(point), event.scrollingDeltaY != 0 else { return event }
            self.wheelMoved(deltaY: event.scrollingDeltaY)
            return event
        }
        updateNearBottom()
        contentMayHaveChanged()
    }

    func contentMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.followState.permitsAutomaticScroll {
                self.schedulePin()
            } else {
                self.updateNearBottom()
            }
        }
    }

    func detach() {
        pinPending = false
        displayLink?.isPaused = true
        mutateState { $0.detach() }
    }

    func jumpToLatest(animated: Bool) {
        mutateState { $0.jumpToLatest() }
        pinPending = false
        displayLink?.isPaused = true
        scrollToBottom(animated: animated)
    }

    func detachAll() {
        detachObservers()
        scrollView = nil
        documentView = nil
    }

    private func wheelMoved(deltaY: CGFloat) {
        updateNearBottom()
        if deltaY > 0 {
            detach()
        } else {
            mutateState { $0.userScrolled(upward: false) }
        }
    }

    private func liveScrollStarted() {
        isUserLiveScrolling = true
        pinPending = false
        displayLink?.isPaused = true
        lastOriginY = scrollView?.contentView.bounds.origin.y ?? lastOriginY
    }

    private func liveScrollEnded() {
        userViewportChanged()
        isUserLiveScrolling = false
    }

    private func userViewportChanged() {
        guard let scrollView, !isProgrammaticScroll else { return }
        let origin = scrollView.contentView.bounds.origin.y
        let movedTowardBottom = documentView?.isFlipped == false
            ? origin < lastOriginY
            : origin > lastOriginY
        lastOriginY = origin
        updateNearBottom()
        if movedTowardBottom, followState.isNearBottom {
            mutateState { $0.userScrolled(upward: false) }
        } else if !movedTowardBottom {
            detach()
        }
    }

    private func boundsChanged() {
        guard let scrollView else { return }
        let origin = scrollView.contentView.bounds.origin.y
        if isProgrammaticScroll {
            lastOriginY = origin
            updateNearBottom()
        } else if isUserLiveScrolling {
            userViewportChanged()
        } else {
            lastOriginY = origin
            updateNearBottom()
        }
    }

    private func documentFrameChanged() {
        if followState.permitsAutomaticScroll {
            schedulePin()
        } else {
            updateNearBottom()
        }
    }

    private func updateNearBottom() {
        guard let scrollView, let documentView else { return }
        let distance = TranscriptScrollMetrics.bottomDistance(
            documentBounds: documentView.bounds,
            visibleRect: scrollView.documentVisibleRect,
            isFlipped: documentView.isFlipped
        )
        mutateState { $0.updateBottom(isNear: distance <= 24) }
    }

    private func schedulePin() {
        guard followState.permitsAutomaticScroll, let scrollView else { return }
        pinPending = true
        if displayLink == nil {
            let link = scrollView.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard pinPending, followState.permitsAutomaticScroll else {
            link.isPaused = true
            return
        }
        pinPending = false
        link.isPaused = true
        scrollToBottom(animated: false)
    }

    private func scrollToBottom(animated: Bool) {
        guard let scrollView, let documentView else { return }
        let origin = NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: TranscriptScrollMetrics.bottomOriginY(
                documentBounds: documentView.bounds,
                viewportHeight: scrollView.contentView.bounds.height,
                isFlipped: documentView.isFlipped
            )
        )
        isProgrammaticScroll = true
        let finish = { [weak self, weak scrollView] in
            guard let self else { return }
            if let scrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.lastOriginY = scrollView.contentView.bounds.origin.y
            }
            self.isProgrammaticScroll = false
            self.updateNearBottom()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(origin)
            } completionHandler: {
                DispatchQueue.main.async(execute: finish)
            }
        } else {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            finish()
        }
    }

    private func mutateState(_ mutation: (inout TranscriptFollowState) -> Void) {
        var next = followState
        mutation(&next)
        if next != followState { followState = next }
    }

    private func detachObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        displayLink?.invalidate()
        displayLink = nil
        pinPending = false
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        displayLink?.invalidate()
    }
}

private struct TranscriptScrollBridge: NSViewRepresentable {
    let coordinator: TranscriptScrollCoordinator

    func makeNSView(context: Context) -> TranscriptScrollAnchorView {
        let view = TranscriptScrollAnchorView(frame: .zero)
        view.transcriptCoordinator = coordinator
        DispatchQueue.main.async { coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ view: TranscriptScrollAnchorView, context: Context) {
        view.transcriptCoordinator = coordinator
        DispatchQueue.main.async { coordinator.attach(from: view) }
    }

    static func dismantleNSView(_ nsView: TranscriptScrollAnchorView, coordinator: ()) {
        nsView.transcriptCoordinator?.detachAll()
        nsView.transcriptCoordinator = nil
    }
}

private final class TranscriptScrollAnchorView: NSView {
    weak var transcriptCoordinator: TranscriptScrollCoordinator?
}

/// ⌘F search over the current conversation. Matches whole blocks (tool cards
/// excluded); ↵ and ⇧↵ walk matches with wrap-around, esc closes.
private struct TranscriptSearchBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var countText: String {
        let matches = model.transcriptSearchMatches
        if matches.isEmpty {
            return model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "0 results"
        }
        let current = min(max(model.transcriptSearchSelection, 0), matches.count - 1)
        return "\(current + 1) of \(matches.count)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)

            TextField("Find in conversation", text: $model.transcriptSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($focused)
                .accessibilityIdentifier("search.field")
                .onKeyPress(keys: [.return]) { press in
                    model.advanceTranscriptSearch(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.closeTranscriptSearch()
                    return .handled
                }

            if !countText.isEmpty {
                Text(countText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("search.count")
            }

            Button {
                model.advanceTranscriptSearch(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .disabled(model.transcriptSearchMatches.isEmpty)
            .help("Previous match (⇧↵)")
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("search.prev")

            Button {
                model.advanceTranscriptSearch(1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .disabled(model.transcriptSearchMatches.isEmpty)
            .help("Next match (↵)")
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("search.next")

            Button {
                model.closeTranscriptSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .help("Close search (esc)")
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("search.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LocusTheme.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .onAppear { focused = true }
    }
}

private struct EmptyConversationView: View {
    @EnvironmentObject private var model: AppModel

    private let suggestions = [
        ("sparkles", "Polish an existing interface without changing its behavior"),
        ("doc.text.magnifyingglass", "Audit this project and identify the three highest-risk areas"),
        ("checklist", "Find every TODO and turn them into an implementation plan"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(runtimeColor)
                    .frame(width: 7, height: 7)
                Text(runtimeStatus)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.top, 48)

            Text("What are we making\nbetter today?")
                .font(.system(size: 40, weight: .medium))
                .tracking(-1.8)
                .foregroundStyle(LocusTheme.ink)
                .padding(.top, 15)

            Text("Locus works inside your selected workspace with local Ollama models. You stay in control of every file change and command.")
                .font(.system(size: 11))
                .foregroundStyle(LocusTheme.muted)
                .lineSpacing(4)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 15)

            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)
                .padding(.vertical, 30)

            VStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                    Button {
                        model.send(item.1)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.0)
                                .font(.system(size: 13))
                                .foregroundStyle(index == 0 ? LocusTheme.ink : LocusTheme.muted)
                                .frame(width: 28, height: 28)
                                .background(index == 0 ? LocusTheme.signal : LocusTheme.paperDeep)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(item.1)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 46)
                        .locusCard(radius: 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("suggestion.\(index)")
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var activeRuntimePhase: RuntimePhase {
        model.isAgentOnline ? model.modelRuntimePhase : model.agentRuntimePhase
    }

    private var runtimeColor: Color {
        switch activeRuntimePhase {
        case .starting, .recovering: LocusTheme.warning
        case .online: LocusTheme.success
        case .unavailable: LocusTheme.coral
        }
    }

    private var runtimeStatus: String {
        switch activeRuntimePhase {
        case .starting: "LOCAL SERVICES · STARTING"
        case .online: "LOCAL SERVICES · READY WHEN YOU ARE"
        case .recovering: "LOCAL SERVICES · RECOVERING"
        case .unavailable: "LOCAL SERVICES · UNAVAILABLE"
        }
    }
}

/// An immutable transcript row. Keeping the observable AppModel out of this
/// view is what prevents a token publication for the active reply from
/// invalidating every completed Markdown row above it.
private struct ActiveAssistantBlockView: View {
    @ObservedObject var reply: StreamingReplyState
    let thinkingVisibility: ThinkingVisibility

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            BrandMark(compact: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Locus")
                    .font(.system(size: 10, weight: .bold))
                StreamingMessageContentView(
                    reply: reply,
                    thinkingVisibility: thinkingVisibility
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("message.streamingAssistant")
    }
}

private struct MessageBlockView: View, Equatable {
    let block: ChatBlock
    let thinkingVisibility: ThinkingVisibility
    let actionsDisabled: Bool
    let canRewind: Bool
    let canRegenerate: Bool
    let onCopy: () -> Void
    let onUseAsDraft: () -> Void
    let onRewind: () -> Void
    let onRegenerate: () -> Void
    @State private var isHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
            && lhs.thinkingVisibility == rhs.thinkingVisibility
            && lhs.actionsDisabled == rhs.actionsDisabled
            && lhs.canRewind == rhs.canRewind
            && lhs.canRegenerate == rhs.canRegenerate
    }

    var body: some View {
        Group {
            switch block.kind {
            case .user:
                conversationRow(name: "You", avatar: userAvatar) {
                    Text(block.text)
                        .font(.system(size: 12))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

            case .assistant:
                conversationRow(name: "Locus", avatar: AnyView(BrandMark(compact: true))) {
                    if block.text.isEmpty,
                       (block.reasoningText?.isEmpty ?? true),
                       block.isStreaming
                    {
                        ThinkingDots()
                    } else {
                        MessageContentView(
                            text: block.text,
                            isStreaming: block.isStreaming,
                            reasoningText: block.reasoningText,
                            thinkingVisibility: thinkingVisibility
                        )
                        if block.isStreaming {
                            Capsule()
                                .fill(LocusTheme.signalDeep)
                                .frame(width: 9, height: 2)
                                .opacity(0.8)
                        }
                    }
                }

            case .tool:
                if let tool = block.tool {
                    ToolCardView(tool: tool)
                        .padding(.leading, 43)
                }

            case .note:
                if let completion = block.completion {
                    TurnCompletionMarker(completion: completion)
                } else {
                    Label(block.text, systemImage: "info.circle")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LocusTheme.paperDeep.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            case .error:
                Label(block.text, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LocusTheme.coral)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.coral.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.coral.opacity(0.28), lineWidth: 1)
                    }
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(
            block.completion == nil
                ? "message.\(block.id.uuidString)"
                : "turnCompletion.\(block.id.uuidString)"
        )
        .contextMenu {
            if block.kind == .user || block.kind == .assistant {
                Button("Copy Message", action: onCopy)
                Button("Use as Draft", action: onUseAsDraft)
                    .disabled(actionsDisabled)
            }
            if block.kind == .user {
                Button("Rewind to This Message", action: onRewind)
                    .disabled(!canRewind)
            }
            if canRegenerate {
                Divider()
                Button("Regenerate Response", action: onRegenerate)
            }
        }
    }

    private var userAvatar: AnyView {
        AnyView(
            Text("N")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 30, height: 30)
                .background(LocusTheme.paperDeep)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        )
    }

    private func conversationRow<Content: View>(
        name: String,
        avatar: AnyView,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                    if isHovering {
                        messageActions
                            .transition(.opacity)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var messageActions: some View {
        if block.kind == .user || block.kind == .assistant {
            actionButton("doc.on.doc", help: "Copy message", identifier: "copy") {
                onCopy()
            }
            actionButton("arrow.turn.down.right", help: "Use as draft", identifier: "useAsDraft") {
                onUseAsDraft()
            }
            .disabled(actionsDisabled)
        }
        if block.kind == .user {
            actionButton("arrow.counterclockwise", help: "Rewind to this message", identifier: "rewind") {
                onRewind()
            }
            .disabled(!canRewind)
        }
        if canRegenerate {
            actionButton("arrow.clockwise", help: "Regenerate response", identifier: "regenerate") {
                onRegenerate()
            }
        }
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 22)
                .background(LocusTheme.paperDeep.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("message.\(block.id.uuidString).\(identifier)")
    }
}

private struct TurnCompletionMarker: View {
    let completion: TurnCompletion

    private var color: Color {
        switch completion.outcome {
        case .complete: LocusTheme.success
        case .interrupted, .maxIterations: LocusTheme.warning
        case .error: LocusTheme.coral
        }
    }

    private var symbol: String {
        switch completion.outcome {
        case .complete: "checkmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case .maxIterations: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)

            Text(completion.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize()

            Text("· Worked for \(completion.durationText)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize()

            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(completion.title). Worked for \(completion.durationText).")
    }
}

/// The bordered icon button used for the panel-restore controls in the header.
/// Shared so the two cannot drift apart.
private struct HeaderIconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct ContextUsageChip: View {
    @EnvironmentObject private var model: AppModel
    @State private var detailPresented = false

    /// nil when no window is known — the chip then shows a token count
    /// instead of pretending to know a percentage.
    private var fraction: Double? {
        model.contextWindowUsageFraction
    }

    /// True when the percentage is being divided by a number nothing measured,
    /// which the chip marks rather than presenting as fact.
    private var isAssumed: Bool {
        !model.contextWindowProvenance.isMeasured && fraction != nil
    }

    private var chipText: String {
        if let fraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
            return isAssumed ? "≈" + percent : percent
        }
        return "~" + model.contextUsedTokens.formatted(.number.notation(.compactName))
    }

    private var helpText: String {
        if fraction == nil { return "Context used — the model's window is unknown" }
        if isAssumed {
            return "Context window usage — assumed from the published window for this model"
        }
        return "Context window usage"
    }

    var body: some View {
        Button {
            detailPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .trim(from: 0, to: fraction.map { max($0, 0.02) } ?? 0)
                    .stroke(
                        (fraction ?? 0) > 0.8 ? LocusTheme.warning : LocusTheme.signalDeep,
                        // Dashed for a window nobody measured: the ring reads as
                        // precise, and this one is only as good as a vendor's
                        // documentation for a model id.
                        style: isAssumed
                            ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 2])
                            : StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .background {
                        Circle().stroke(LocusTheme.line, lineWidth: 2.5)
                    }
                    .frame(width: 12, height: 12)
                Text(chipText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(LocusTheme.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(
            fraction == nil
                ? "Context used \(chipText) tokens, window unknown"
                : "Context window \(chipText) used"
        )
        .accessibilityIdentifier("workspace.contextUsage")
        .popover(isPresented: $detailPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CONTEXT WINDOW")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                statRow(
                    "Model window",
                    model.contextWindowTokens.map { "\($0.formatted()) tokens" } ?? "Unknown"
                )
                statRow("Source", model.contextWindowProvenance.label)
                statRow("Session so far", "~\(model.contextUsedTokens.formatted()) tokens")
                if let usable = model.contextUsableTokens,
                   let window = model.contextWindowTokens, usable < window {
                    statRow("Usable for the conversation", "\(usable.formatted()) tokens")
                }
                // Cumulative across every model call this session, so they
                // routinely exceed the window above — labelled, because
                // unlabelled they read as a broken meter.
                statRow(
                    "Prompt tokens (session total)",
                    "\((model.sessionInfo?.promptTokens ?? 0).formatted())"
                )
                statRow(
                    "Completion tokens (session total)",
                    "\((model.sessionInfo?.completionTokens ?? 0).formatted())"
                )
                statRow(
                    "Context pack (next send)",
                    "\(model.includedContextTokens.formatted()) tokens · \(model.includedContextCount) files"
                )
                statRow("Messages", "\(model.sessionInfo?.messages ?? 0)")
            }
            .padding(14)
            .frame(width: 250)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
    }
}

private struct ThinkingDots: View {
    @State private var active = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(LocusTheme.muted)
                    .frame(width: 4, height: 4)
                    .offset(y: active ? (index == 1 ? -3 : 0) : (index == 1 ? 0 : -2))
            }
            Text("Thinking")
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .padding(.leading, 3)
        }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: active)
        .onAppear { active = true }
    }
}

private struct ToolCardView: View {
    let tool: ToolPayload
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(tool.tool)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Text(tool.summary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 39)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tool.tool), \(statusLabel), \(expanded ? "collapse" : "expand")")
            .accessibilityIdentifier("tool.\(tool.toolID).toggle")

            if expanded || tool.status == .awaitingPermission {
                VStack(alignment: .leading, spacing: 10) {
                    if !tool.detail.isEmpty {
                        ToolOutputText(text: tool.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(LocusTheme.paperDeep.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    if let result = tool.result, !result.isEmpty {
                        if DiffDetector.isDiff(result) {
                            DiffTextView(text: result)
                        } else {
                            Text(result)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(14)
                                .textSelection(.enabled)
                        }
                    }

                    if tool.status == .awaitingPermission {
                        // The decision itself lives in the composer panel;
                        // the card only points there.
                        Label(
                            "Waiting for your decision in the composer below",
                            systemImage: "arrow.down.to.line"
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.warning)
                    }
                }
                .padding(11)
                .overlay(alignment: .top) {
                    Rectangle().fill(LocusTheme.line).frame(height: 1)
                }
            }
        }
        .locusCard(radius: 9)
    }

    private var statusSymbol: String {
        switch tool.status {
        case .awaitingPermission: "shield.lefthalf.filled.badge.checkmark"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .denied: "nosign"
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .awaitingPermission: LocusTheme.warning
        case .running: LocusTheme.blue
        case .done: LocusTheme.success
        case .error: LocusTheme.coral
        case .denied: LocusTheme.muted
        }
    }

    private var statusLabel: String {
        switch tool.status {
        case .awaitingPermission: "needs approval"
        case .running: "running"
        case .done: "done"
        case .error: "error"
        case .denied: "denied"
        }
    }
}
