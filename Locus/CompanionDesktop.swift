import AppKit
import Carbon
import SwiftUI

/// Presentation only: the hosted content reads the same profile, conversation,
/// activity and draft as the inspector. Closing this panel never stops work.
@MainActor
final class CompanionDesktopController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    @Published var characterSize: Double = 80 { didSet { defaults?.set(characterSize, forKey: "Locus.Companion.desktopSize"); resize() } }
    @Published var alwaysOnTop = false {
        didSet { panel?.level = alwaysOnTop ? .floating : .normal; defaults?.set(alwaysOnTop, forKey: "Locus.Companion.desktopOnTop") }
    }
    @Published private(set) var shortcutUnavailable = false
    private var defaults: UserDefaults?
    private var panel: NSPanel?
    private var makeContent: (() -> AnyView)?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var snapping = false
    private var chatExpanded = false

    func configure(defaults: UserDefaults?, content: @escaping () -> AnyView) {
        self.defaults = defaults
        makeContent = content
        characterSize = min(144, max(64, defaults?.object(forKey: "Locus.Companion.desktopSize") as? Double ?? 80))
        alwaysOnTop = defaults?.bool(forKey: "Locus.Companion.desktopOnTop") ?? false
        guard defaults != nil, eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<CompanionDesktopController>.fromOpaque(context).takeUnretainedValue().toggle() }
            return noErr
        }, 1, &type, pointer, &eventHandler)
        let id = EventHotKeyID(signature: 0x4C435043, id: 1)
        shortcutUnavailable = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey | controlKey), id,
            GetApplicationEventTarget(), 0, &hotKey) != noErr
    }

    func toggle() { isVisible ? hide() : show() }
    func show() {
        guard let makeContent else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 230),
                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("locus.companion.desktop")
            window.title = "Companion"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = alwaysOnTop ? .floating : .normal
            window.delegate = self
            window.contentView = NSHostingView(rootView: makeContent())
            window.setFrameAutosaveName("Locus.Companion.desktop")
            window.setFrameUsingName("Locus.Companion.desktop")
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(Self.snappedFrame(window.frame, in: screen.visibleFrame), display: false)
            }
            panel = window
            resize()
        }
        panel?.orderFrontRegardless()
        isVisible = true
    }
    func setChatExpanded(_ expanded: Bool) {
        chatExpanded = expanded
        resize()
        DispatchQueue.main.async { [weak self] in self?.fitContent() }
    }
    private func fitContent() {
        guard let panel, let content = panel.contentView else { return }
        let ideal = content.fittingSize
        if ideal.width > 0, ideal.height > 0 {
            let maximum = (panel.screen ?? NSScreen.main)?.visibleFrame.size ?? ideal
            panel.setContentSize(NSSize(width: min(ideal.width, maximum.width), height: min(ideal.height, maximum.height - 38)))
        }
        if let screen = panel.screen { panel.setFrame(Self.snappedFrame(panel.frame, in: screen.visibleFrame), display: true) }
    }
    private func resize() {
        guard let panel else { return }
        panel.setContentSize(NSSize(width: chatExpanded ? 394 : 244,
                                    height: characterSize + (chatExpanded ? 600 : 118)))
        if let screen = panel.screen { panel.setFrame(Self.snappedFrame(panel.frame, in: screen.visibleFrame), display: true) }
    }
    func hide() { panel?.close(); isVisible = false }
    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil
        panel = nil
        chatExpanded = false
        isVisible = false
    }
    func windowDidMove(_ notification: Notification) {
        guard !snapping, let panel, let screen = panel.screen else { return }
        let frame = Self.snappedFrame(panel.frame, in: screen.visibleFrame)
        guard frame != panel.frame else { return }
        snapping = true
        panel.setFrame(frame, display: true)
        snapping = false
    }
    static func snappedFrame(_ frame: CGRect, in visible: CGRect, distance: CGFloat = 18) -> CGRect {
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(result.minY, visible.minY), max(visible.minY, visible.maxY - result.height))
        if abs(result.minX - visible.minX) <= distance { result.origin.x = visible.minX }
        if abs(result.maxX - visible.maxX) <= distance { result.origin.x = visible.maxX - result.width }
        if abs(result.minY - visible.minY) <= distance { result.origin.y = visible.minY }
        if abs(result.maxY - visible.maxY) <= distance { result.origin.y = visible.maxY - result.height }
        return result
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

extension AppModel {
    func configureCompanionDesktop() {
        companionDesktop.configure(defaults: persistenceEnabled ? .standard : nil) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(CompanionDesktopView(controller: self.companionDesktop)
                .appFeatureEnvironment(from: self))
        }
    }
}

struct CompanionDesktopView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agents: AgentTeamsModel
    @EnvironmentObject private var voice: VoiceControlModel
    @ObservedObject var controller: CompanionDesktopController
    @State private var chatShown = false

    var body: some View {
        ScrollView {
        VStack(spacing: 8) {
            if let profile = model.primaryCompanionProfile {
                Button { chatShown.toggle() } label: {
                    AgentAvatarView(profileID: profile.id, name: profile.name, size: controller.characterSize)
                }
                .buttonStyle(.plain).accessibilityLabel("Open \(profile.name)’s chat")
                .accessibilityIdentifier("companion.desktop.character")
                Text(profile.name).font(.headline)
                CompanionDesktopStatus(source: model.companionActivityPresentation, profileID: profile.id)
                if chatShown {
                    CompanionInspectorTab(tracksPointer: false, showsCharacterHeader: false, showsForegroundComposer: false).frame(width: 370, height: 360)
                    CompanionDesktopForegroundComposer(panel: model.companionPanel).frame(width: 370)
                }
                HStack {
                    CompanionToolsButton().labelStyle(.iconOnly).help("Companion tools")
                    Button(chatShown ? "Close chat" : "Chat") { chatShown.toggle() }
                    Menu {
                        Toggle("Always on top", isOn: $controller.alwaysOnTop)
                        Picker("Character size", selection: $controller.characterSize) {
                            Text("Small").tag(64.0); Text("Medium").tag(80.0); Text("Large").tag(112.0); Text("Extra large").tag(144.0)
                            if ![64.0, 80.0, 112.0, 144.0].contains(controller.characterSize) {
                                Text("Current (\(Int(controller.characterSize)) pt)").tag(controller.characterSize)
                            }
                        }
                        Text(controller.shortcutUnavailable ? "Summon shortcut is in use" : "Summon: ⌃⌥⌘C")
                        Button("Hide companion") { controller.hide() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Desktop companion options")
                }
            } else {
                Text("Set up your companion in Locus first.").padding()
                Button("Close") { controller.hide() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        }
        .scrollDisabled(!chatShown)
        .frame(width: chatShown ? 394 : 244,
               height: min(controller.characterSize + (chatShown ? 580 : 130), (NSScreen.main?.visibleFrame.height ?? 800) - 38))
        .environment(\.companionAllowsInactiveAnimation, true)
        .environment(\.companionPointerResponse, .neutral)
        .accessibilityIdentifier("companion.desktop")
        .onChange(of: chatShown) { _, value in controller.setChatExpanded(value) }
        .onDisappear { if voice.externalSessionID != nil { voice.cancelRecording() } }
    }
}

private struct CompanionDesktopStatus: View {
    @ObservedObject var source: CompanionActivityPresentation
    let profileID: UUID
    var body: some View {
        Text(source.summary(profileID: profileID)?.statusText ?? "Ready")
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
}


private struct CompanionDesktopForegroundComposer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var companionContext: CompanionContextSharingModel
    @EnvironmentObject private var composerState: ComposerStateModel
    @ObservedObject var panel: CompanionPanelModel
    @State private var sending = false
    @State private var error: String?
    var body: some View {
        if panel.isForegroundConversation, let sessionID = panel.selectedSessionID {
            VStack(alignment: .leading, spacing: 6) {
                CompanionContextSharingView(model: model.companionContext)
                TextField("Message your companion", text: Binding(
                    get: { composerState.draftText },
                    set: { model.setPaneDraft($0, for: sessionID) }), axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("companion.desktop.composer")
                HStack {
                    CompanionVoiceControls()
                    Spacer()
                    Button("Send") { send(sessionID) }
                        .disabled(sending || !model.isAgentOnline || model.savedAgentConversationState(sessionID).busy
                            || (model.paneDraft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && companionContext.attachments.isEmpty))
                        .accessibilityIdentifier("companion.desktop.send")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    private func send(_ sessionID: String) {
        guard !sending, let scope = model.companionScope, scope.sessionID == sessionID else { return }
        let original = model.paneDraft(for: sessionID)
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Please look at the shared context."
        let attachments = model.companionContext.scope == scope ? model.companionContext.attachments : []
        let mode = panel.mode
        sending = true; error = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                guard model.companionScope == scope else { return }
                try await model.sendSavedAgentTurn(sessionID: sessionID, workspace: scope.workspace,
                    profileID: scope.profileID, text: text, mode: mode, preservingForeground: true, attachments: attachments)
                model.companionContext.consume(Set(attachments.map(\.id)), for: scope)
                if model.paneDraft(for: sessionID) == original { model.setPaneDraft("", for: sessionID) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
